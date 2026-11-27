#!/usr/bin/env python3
"""Batch deterministic 60 FPS runner & screenshot collector for ALL official Havok 2015.1.0-r1
Hero & Soldier Behavior demos.

Runs every registered Hero & Soldier Behavior demo variant from the compiled official Havok
DX11 executable (`havok_hero_soldier_demos.exe`) in isolated subprocesses:
  - Run A: full 60.000 Hz deterministic trace JSON + real GPU DX11 screenshots (BMP -> PNG)
  - Run B: clean second OS process hash-only verification (`--no-shots --no-json`) to prove
           true cross-process bit-exact determinism (64-bit FNV-1a pose, trajectory, event hashes)

Produces:
  1. Full per-tick 60fps JSON traces + 1280x720 PNG screenshots in `--out`
  2. Compact SDK-free master comparison dataset JSON (`assets/havok_real_demo_manifest.json`)
  3. High-res visual contact sheets (`assets/havok_real_hero_contact_sheet.png` and
     `assets/havok_real_soldier_contact_sheet.png`)
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SCRIPT_DIR = Path(__file__).resolve().parent
SDK_ROOT = Path(r"D:\SDK\hk2015_1_0\hk2015_1_0_r1")
SDK_DEMOS_CWD = SDK_ROOT / "Demo" / "Demos"
DEFAULT_EXE = Path(tempfile.gettempdir()) / "codex_havok_real_demos" / "havok_hero_soldier_demos.exe"
DEFAULT_OUT = SCRIPT_DIR / "captures" / "havok_real_60fps"
DEFAULT_ASSETS = SCRIPT_DIR / "assets"

DONE_RE = re.compile(
    r"^\[DONE\] #(\d+) ok=(\d+) det=(\d+) ticks=(\d+) chars=(\d+) events=(\d+) shots=(\d+) "
    r"pose=([0-9a-f]+) traj=([0-9a-f]+) ev=([0-9a-f]+) \| (.+)$"
)

# 3 Hero Behavior demo files in SDK that are disabled by Havok SDK preprocessor/comments on x64 Release
SDK_DISABLED_HERO_SOLDIER_FILES = [
    {
        "file": "Behavior/Api/Docking/DockingHanging/DockingHangingDemo.cpp",
        "asset_family": "hero",
        "reason": "Havok SDK guards HKB_DECLARE_PHYSICS_DEMO with `#if !defined(HK_PLATFORM_X64)` (only Physics2012 or 32-bit x86).",
    },
    {
        "file": "Behavior/Api/Docking/DockingReRooting/DockingReRooting.cpp",
        "asset_family": "hero",
        "reason": "Havok SDK itself comments out both `//HKB_DECLARE_PHYSICS_2012_DEMO` and `//HKB_DECLARE_PHYSICS_DEMO`.",
    },
    {
        "file": "Behavior/Test/Determinism/Determinism.cpp",
        "asset_family": "hero",
        "reason": "Havok SDK guards registration with `#ifdef HK_ENABLE_DETERMINISM_CHECKS` (internal determinism-check build only).",
    },
]


def query_registered_demos(exe: Path) -> list[dict]:
    proc = subprocess.run(
        [str(exe), "--list"],
        cwd=str(SDK_DEMOS_CWD),
        capture_output=True,
        text=True,
        timeout=30,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"--list failed ({proc.returncode}): {proc.stderr}\n{proc.stdout}")
    demos: list[dict] = []
    for line in proc.stdout.splitlines():
        if not line.startswith("DEMO|"):
            continue
        parts = line.split("|", 5)
        if len(parts) != 6:
            continue
        _, idx_s, var_s, slug, menu_path, demo_path = parts
        demos.append(
            {
                "demo_index": int(idx_s),
                "variant_id": int(var_s),
                "slug": slug,
                "menu_path": menu_path,
                "demo_path": demo_path,
            }
        )
    return demos


def classify_asset_family(demo_path: str, characters: list[dict]) -> str:
    # Check both source file and character/skeleton names
    src_file = SDK_DEMOS_CWD / demo_path
    src_txt = src_file.read_text(errors="ignore") if src_file.exists() else ""
    has_hero = bool(re.search(r"GameAssets/Hero|HeroProject|HeroDemo::", src_txt, re.I))
    has_soldier = bool(re.search(r"GameAssets/Soldier|US_Soldier|FireTeamLeader|Soldier_Character", src_txt, re.I))
    for ch in characters:
        nm = (ch.get("name") or "").lower()
        lms = set(ch.get("landmarks") or [])
        if "hero" in nm or "Pelvis" in lms:
            has_hero = True
        if "soldier" in nm or "fireteam" in nm or "Root_M" in lms:
            has_soldier = True
    if has_hero and has_soldier:
        return "hero+soldier"
    if has_hero:
        return "hero"
    if has_soldier:
        return "soldier"
    return "other"


def run_demo_subprocess(
    exe: Path,
    demo_index: int,
    out_dir: Path,
    renderer: str,
    ticks: int,
    no_shots: bool,
    no_json: bool,
    timeout_s: int,
) -> dict:
    cmd = [
        str(exe),
        "--demo-index",
        str(demo_index),
        "--renderer",
        renderer,
        "--out",
        str(out_dir),
    ]
    if ticks > 0:
        cmd += ["--ticks", str(ticks)]
    if no_shots:
        cmd.append("--no-shots")
    if no_json:
        cmd.append("--no-json")

    t0 = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(SDK_DEMOS_CWD),
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        elapsed = time.perf_counter() - t0
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"timeout>{timeout_s}s", "elapsed_s": time.perf_counter() - t0}

    parsed = None
    for line in proc.stdout.splitlines():
        m = DONE_RE.match(line.strip())
        if m:
            parsed = {
                "ok": m.group(2) == "1",
                "inproc_det": m.group(3) == "1",
                "ticks": int(m.group(4)),
                "chars": int(m.group(5)),
                "events": int(m.group(6)),
                "shots": int(m.group(7)),
                "final_pose_hash": m.group(8),
                "trajectory_hash": m.group(9),
                "event_hash": m.group(10),
                "menu_path": m.group(11),
                "returncode": proc.returncode,
                "elapsed_s": round(elapsed, 3),
            }
            break
    if parsed is None:
        return {
            "ok": False,
            "returncode": proc.returncode,
            "elapsed_s": round(elapsed, 3),
            "error": (proc.stderr.strip() or proc.stdout.strip())[-400:],
        }
    return parsed


def convert_demo_bmps(shots_dir: Path, slug: str) -> list[dict]:
    results: list[dict] = []
    prefix = f"{slug}_t"
    for bmp_path in sorted(shots_dir.glob(f"{prefix}*.bmp")):
        png_path = bmp_path.with_suffix(".png")
        m = re.search(r"_t(\d+)\.bmp$", bmp_path.name)
        tick = int(m.group(1)) if m else -1
        with Image.open(bmp_path) as im:
            rgb = im.convert("RGB")
            arr = np.asarray(rgb)
            rgb.save(png_path, format="PNG", optimize=True)
            mean_rgb = [round(float(x), 2) for x in arr.mean(axis=(0, 1))]
            std_rgb = [round(float(x), 2) for x in arr.std(axis=(0, 1))]
            min_v = int(arr.min())
            max_v = int(arr.max())
            w, h = rgb.size
        bmp_path.unlink(missing_ok=True)
        results.append(
            {
                "tick": tick,
                "time": round(tick / 60.0, 6) if tick >= 0 else 0.0,
                "file": f"shots/{png_path.name}",
                "width": w,
                "height": h,
                "min_val": min_v,
                "max_val": max_v,
                "mean_rgb": mean_rgb,
                "std_rgb": std_rgb,
                "non_blank": max(std_rgb) > 2.0,
            }
        )
    return results


def summarize_demo_trace(
    trace_path: Path,
    shot_metas: list[dict],
    run_a: dict,
    run_b: dict | None,
) -> dict:
    data = json.loads(trace_path.read_text(encoding="utf-8"))
    frames = data.get("frames") or []
    characters = data.get("characters") or []
    summary = data.get("summary") or {}
    asset_family = classify_asset_family(data.get("demo_path", ""), characters)

    # Update screenshot paths inside raw JSON to .png so JSON references real PNG files
    shot_by_tick = {s["tick"]: s["file"] for s in shot_metas}
    for fr in frames:
        if "shot" in fr and fr["tick"] in shot_by_tick:
            fr["shot"] = shot_by_tick[fr["tick"]]
    summary["screenshots"] = [s["file"] for s in shot_metas]
    data["summary"] = summary
    trace_path.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")

    # Extract lossless event timeline & state transitions & sampled 60fps keyframes
    all_events: list[dict] = []
    state_transitions: list[dict] = []
    prev_states: dict[tuple[int, str], str] = {}
    unique_states: set[str] = set()
    unique_clips: set[str] = set()
    event_ticks: set[int] = set()

    max_disp = 0.0
    start_roots: dict[int, list[float]] = {}
    end_roots: dict[int, list[float]] = {}

    for fr in frames:
        tk = fr["tick"]
        tm = fr["time"]
        evs = fr.get("events") or []
        if evs:
            event_ticks.add(tk)
            for ev in evs:
                all_events.append(
                    {
                        "tick": tk,
                        "time": tm,
                        "char": ev["char"],
                        "id": ev["id"],
                        "name": ev["name"],
                    }
                )
        for ch in fr.get("chars") or []:
            ci = ch["idx"]
            rg = ch.get("root_g") or [0.0, 0.0, 0.0]
            if ci not in start_roots:
                start_roots[ci] = rg
            end_roots[ci] = rg
            if ci == 0:
                sr = start_roots[0]
                disp = math.sqrt((rg[0] - sr[0]) ** 2 + (rg[1] - sr[1]) ** 2 + (rg[2] - sr[2]) ** 2)
                if disp > max_disp:
                    max_disp = disp
            for sm_name, st_name in (ch.get("states") or {}).items():
                unique_states.add(f"{sm_name}:{st_name}")
                key = (ci, sm_name)
                if key not in prev_states:
                    prev_states[key] = st_name
                elif prev_states[key] != st_name:
                    state_transitions.append(
                        {
                            "tick": tk,
                            "time": tm,
                            "char": ci,
                            "sm": sm_name,
                            "from": prev_states[key],
                            "to": st_name,
                        }
                    )
                    prev_states[key] = st_name
            for cl in ch.get("clips") or []:
                if cl.get("anim"):
                    unique_clips.add(cl["anim"])

    # Compact deterministic keyframe table (every 15 ticks + first/last + all shot ticks + first 40 event ticks)
    key_ticks = {0, max(0, len(frames) - 1)}
    key_ticks.update(range(0, len(frames), 15))
    key_ticks.update(shot_by_tick.keys())
    key_ticks.update(sorted(event_ticks)[:40])
    keyframes = []
    for fr in frames:
        if fr["tick"] not in key_ticks:
            continue
        k_chars = []
        for ch in fr.get("chars") or []:
            k_chars.append(
                {
                    "idx": ch["idx"],
                    "root_hk": ch["root_hk"],
                    "root_g": ch["root_g"],
                    "yaw_g": ch["yaw_g"],
                    "lm": ch.get("lm") or {},
                    "states": ch.get("states") or {},
                    "clips": [
                        {"anim": c["anim"], "lt": c["lt"], "dur": c["dur"], "mode": c["mode"]}
                        for c in (ch.get("clips") or [])
                    ],
                }
            )
        keyframes.append(
            {
                "tick": fr["tick"],
                "time": fr["time"],
                "pose_hash": fr["pose_hash"],
                "events": fr.get("events") or [],
                "chars": k_chars,
            }
        )

    cross_det = False
    if run_b is not None:
        cross_det = (
            run_a["ok"]
            and run_b["ok"]
            and run_a["ticks"] == run_b["ticks"]
            and run_a["events"] == run_b["events"]
            and run_a["final_pose_hash"] == run_b["final_pose_hash"]
            and run_a["trajectory_hash"] == run_b["trajectory_hash"]
            and run_a["event_hash"] == run_b["event_hash"]
        )

    # Pick representative hero screenshot (highest visual variance, preferring mid/action frame)
    rep_shot = None
    if shot_metas:
        mid_shots = [s for s in shot_metas if s["non_blank"] and s["tick"] >= 15]
        pool = mid_shots if mid_shots else shot_metas
        # Prefer middle-third shot if non-blank
        rep_shot = pool[len(pool) // 2]

    return {
        "demo_index": data["demo_index"],
        "slug": data["slug"],
        "menu_path": data["menu_path"],
        "demo_path": data["demo_path"],
        "variant_id": data["variant_id"],
        "asset_family": asset_family,
        "demo_type": summary.get("demo_type", 0),
        "display_objects": summary.get("display_objects", 0),
        "hz": data["hz"],
        "dt": data["dt"],
        "executed_ticks": summary.get("executed_ticks", len(frames)),
        "bootstrap_iterations_default": data.get("bootstrap_iterations_default", 0),
        "z_up": data["z_up"],
        "world_up_hk": data["world_up_hk"],
        "renderer": data["renderer"],
        "resolution": data["resolution"],
        "characters": characters,
        "total_events": len(all_events),
        "unique_event_names": sorted({e["name"] for e in all_events}),
        "events": all_events,
        "state_transitions": state_transitions,
        "unique_states": sorted(unique_states),
        "unique_clips": sorted(unique_clips),
        "start_root_g": start_roots.get(0),
        "end_root_g": end_roots.get(0),
        "max_displacement_m": round(max_disp, 4),
        "camera_initial": frames[0].get("cam") if frames else None,
        "camera_final": frames[-1].get("cam") if frames else None,
        "final_pose_hash": run_a["final_pose_hash"],
        "trajectory_hash": run_a["trajectory_hash"],
        "event_hash": run_a["event_hash"],
        "cross_process_deterministic": cross_det,
        "run_a_elapsed_s": run_a["elapsed_s"],
        "run_b_elapsed_s": run_b["elapsed_s"] if run_b else None,
        "screenshots": shot_metas,
        "representative_shot": rep_shot["file"] if rep_shot else None,
        "all_shots_non_blank": bool(shot_metas) and all(s["non_blank"] for s in shot_metas),
        "keyframes": keyframes,
    }


def build_contact_sheet(
    entries: list[dict],
    out_dir: Path,
    dest_png: Path,
    title: str,
    cols: int = 4,
    tile_w: int = 480,
    tile_h: int = 270,
) -> None:
    if not entries:
        return
    pad = 12
    label_h = 44
    header_h = 56
    rows = math.ceil(len(entries) / cols)
    canvas_w = pad + cols * (tile_w + pad)
    canvas_h = header_h + pad + rows * (tile_h + label_h + pad)
    canvas = Image.new("RGB", (canvas_w, canvas_h), (18, 22, 28))
    draw = ImageDraw.Draw(canvas)
    try:
        font_title = ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 22)
        font_lbl = ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 14)
        font_sub = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 12)
    except Exception:
        font_title = ImageFont.load_default()
        font_lbl = ImageFont.load_default()
        font_sub = ImageFont.load_default()

    det_ok = sum(1 for e in entries if e.get("cross_process_deterministic"))
    draw.rectangle([0, 0, canvas_w, header_h], fill=(26, 33, 44))
    draw.text(
        (pad, 16),
        f"{title}  |  {len(entries)} Official Havok 2015.1.0-r1 DX11 Demos  |  60.000 Hz Determinism: {det_ok}/{len(entries)}",
        fill=(235, 242, 250),
        font=font_title,
    )

    for idx, entry in enumerate(entries):
        r = idx // cols
        c = idx % cols
        x0 = pad + c * (tile_w + pad)
        y0 = header_h + pad + r * (tile_h + label_h + pad)

        shot_rel = entry.get("representative_shot")
        if shot_rel and (out_dir / shot_rel).exists():
            with Image.open(out_dir / shot_rel) as im:
                thumb = im.convert("RGB").resize((tile_w, tile_h), Image.Resampling.LANCZOS)
                canvas.paste(thumb, (x0, y0))
        else:
            draw.rectangle([x0, y0, x0 + tile_w, y0 + tile_h], fill=(60, 24, 24))

        # Border
        border_col = (56, 189, 128) if entry.get("cross_process_deterministic") else (239, 68, 68)
        draw.rectangle([x0, y0, x0 + tile_w - 1, y0 + tile_h + label_h - 1], outline=border_col, width=2)

        # Label bar
        draw.rectangle([x0 + 1, y0 + tile_h, x0 + tile_w - 2, y0 + tile_h + label_h - 2], fill=(24, 30, 39))
        short_name = entry["menu_path"].replace("Behavior/", "")
        if len(short_name) > 54:
            short_name = "..." + short_name[-51:]
        draw.text((x0 + 8, y0 + tile_h + 4), f"#{entry['demo_index']} {short_name}", fill=(240, 246, 252), font=font_lbl)
        badge = "DET=OK" if entry.get("cross_process_deterministic") else "DET=FAIL"
        meta_line = (
            f"{badge} | {entry['executed_ticks']}f | ch={len(entry['characters'])} | "
            f"ev={entry['total_events']} | disp={entry['max_displacement_m']:.2f}m | pose={entry['final_pose_hash'][:8]}"
        )
        draw.text((x0 + 8, y0 + tile_h + 24), meta_line, fill=(148, 186, 218), font=font_sub)

    dest_png.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dest_png, format="PNG", optimize=True)


def cleanup_sdk_sidecars() -> None:
    for pat in ("internalState.hkt", "unusedSystems.txt", "frame*.bmp", "exitcode.txt"):
        for p in glob.glob(str(SDK_DEMOS_CWD / pat)):
            try:
                os.remove(p)
            except OSError:
                pass


def main() -> int:
    ap = argparse.ArgumentParser(description="Run ALL official Havok Hero & Soldier Behavior demos at deterministic 60 FPS.")
    ap.add_argument("--exe", type=Path, default=DEFAULT_EXE)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--assets-dir", type=Path, default=DEFAULT_ASSETS)
    ap.add_argument("--renderer", default="d3d11")
    ap.add_argument("--ticks", type=int, default=0, help="0 = official m_bootstrapIterations clamped [180, 1080]")
    ap.add_argument("--timeout", type=int, default=120, help="Per-demo timeout in seconds")
    ap.add_argument("--filter", default="", help="Optional substring filter on menu_path")
    ap.add_argument("--merge-manifest", action="store_true", help="Merge filtered run into existing manifest & rebuild sheets")
    ap.add_argument("--skip-determinism", action="store_true")
    ap.add_argument("--build", action="store_true", help="Invoke build_havok_real_demos.py first")
    args = ap.parse_args()

    if args.build or not args.exe.exists():
        print("[batch] Building official Havok Hero & Soldier Behavior demos executable...")
        rc = subprocess.call([sys.executable, str(SCRIPT_DIR / "build_havok_real_demos.py")])
        if rc != 0:
            return rc

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "shots").mkdir(parents=True, exist_ok=True)
    args.assets_dir.mkdir(parents=True, exist_ok=True)

    demos = query_registered_demos(args.exe)
    if args.filter:
        demos = [d for d in demos if args.filter.lower() in d["menu_path"].lower()]

    print(f"[batch] Registered Hero & Soldier Behavior demos to capture: {len(demos)} (renderer={args.renderer})")
    t_all = time.perf_counter()

    entries: list[dict] = []
    failures: list[dict] = []

    try:
        for i, d in enumerate(demos, 1):
            idx = d["demo_index"]
            slug = d["slug"]
            mp = d["menu_path"]
            print(f"[{i:02d}/{len(demos):02d}] #{idx:02d} {mp} ...", flush=True)

            # Remove stale shots for this slug
            for old in (args.out / "shots").glob(f"{slug}_t*.*"):
                old.unlink(missing_ok=True)

            run_a = run_demo_subprocess(
                args.exe, idx, args.out, args.renderer, args.ticks, no_shots=False, no_json=False, timeout_s=args.timeout
            )
            if not run_a.get("ok"):
                print(f"  [FAIL] Run A failed: {run_a}", flush=True)
                failures.append({"demo": d, "stage": "run_a", "detail": run_a})
                continue

            shot_metas = convert_demo_bmps(args.out / "shots", slug)

            run_b = None
            if not args.skip_determinism:
                run_b = run_demo_subprocess(
                    args.exe, idx, args.out, args.renderer, args.ticks, no_shots=True, no_json=True, timeout_s=args.timeout
                )

            trace_path = args.out / f"{slug}.json"
            entry = summarize_demo_trace(trace_path, shot_metas, run_a, run_b)
            entries.append(entry)

            det_tag = "DET=OK" if entry["cross_process_deterministic"] else "DET=DIFF"
            blank_tag = "SHOTS=OK" if entry["all_shots_non_blank"] else "SHOTS=BLANK!"
            print(
                f"  -> {det_tag} {blank_tag} fam={entry['asset_family']} ticks={entry['executed_ticks']} "
                f"chars={len(entry['characters'])} ev={entry['total_events']} shots={len(shot_metas)} "
                f"disp={entry['max_displacement_m']:.2f}m pose={entry['final_pose_hash'][:10]} "
                f"({run_a['elapsed_s']:.1f}s + {(run_b['elapsed_s'] if run_b else 0):.1f}s)",
                flush=True,
            )
            if (not args.skip_determinism and not entry["cross_process_deterministic"]) or not entry["all_shots_non_blank"]:
                failures.append({"demo": d, "stage": "verify", "det": entry["cross_process_deterministic"], "shots_ok": entry["all_shots_non_blank"]})
    finally:
        cleanup_sdk_sidecars()

    total_elapsed = round(time.perf_counter() - t_all, 2)
    manifest_path = args.assets_dir / "havok_real_demo_manifest.json"
    all_registered_count = len(query_registered_demos(args.exe)) if args.merge_manifest else len(demos)
    cleanup_sdk_sidecars()

    if args.merge_manifest and manifest_path.exists():
        prev = json.loads(manifest_path.read_text(encoding="utf-8"))
        by_idx = {e["demo_index"]: e for e in (prev.get("demos") or [])}
        for e in entries:
            by_idx[e["demo_index"]] = e
        entries = [by_idx[k] for k in sorted(by_idx.keys())]
        total_elapsed = round(float(prev.get("totals", {}).get("elapsed_s", 0.0)) + total_elapsed, 2)

    hero_entries = [e for e in entries if e["asset_family"] in ("hero", "hero+soldier")]
    soldier_entries = [e for e in entries if e["asset_family"] == "soldier"]
    other_entries = [e for e in entries if e["asset_family"] == "other"]

    manifest = {
        "schema": "havok-real-demo-manifest-v1",
        "havok_sdk": "hk2015_1_0_r1",
        "renderer": args.renderer,
        "hz": 60,
        "dt": 1.0 / 60.0,
        "single_threaded": True,
        "cross_process_determinism_verified": not args.skip_determinism,
        "totals": {
            "registered_demos": all_registered_count,
            "captured_ok": len(entries),
            "cross_process_deterministic_ok": sum(1 for e in entries if e["cross_process_deterministic"]),
            "all_shots_non_blank_ok": sum(1 for e in entries if e["all_shots_non_blank"]),
            "total_screenshots": sum(len(e["screenshots"]) for e in entries),
            "total_frames_simulated": sum(e["executed_ticks"] for e in entries),
            "total_events_recorded": sum(e["total_events"] for e in entries),
            "hero_demos": len(hero_entries),
            "soldier_demos": len(soldier_entries),
            "other_demos": len(other_entries),
            "sdk_disabled_files": len(SDK_DISABLED_HERO_SOLDIER_FILES),
            "failures": len(failures),
            "elapsed_s": total_elapsed,
        },
        "sdk_disabled_hero_soldier_files": SDK_DISABLED_HERO_SOLDIER_FILES,
        "demos": entries,
    }

    manifest_path.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")

    # Build visual contact sheets
    hero_sheet = args.assets_dir / "havok_real_hero_contact_sheet.png"
    soldier_sheet = args.assets_dir / "havok_real_soldier_contact_sheet.png"
    build_contact_sheet(hero_entries, args.out, hero_sheet, "Havok Real Hero Behavior Demos (DX11)")
    build_contact_sheet(soldier_entries, args.out, soldier_sheet, "Havok Real Soldier Behavior Demos (DX11)")

    print("\n================ SUMMARY ================")
    print(json.dumps(manifest["totals"], indent=2))
    print(f"Manifest:       {manifest_path} ({manifest_path.stat().st_size / 1024:.1f} KB)")
    if hero_sheet.exists():
        print(f"Hero sheet:     {hero_sheet} ({hero_sheet.stat().st_size / 1024:.1f} KB)")
    if soldier_sheet.exists():
        print(f"Soldier sheet:  {soldier_sheet} ({soldier_sheet.stat().st_size / 1024:.1f} KB)")
    if failures:
        print("Failures:", json.dumps(failures, indent=2))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
