#!/usr/bin/env python3
"""Offline extractor that completes extraction of ALL remaining official Havok 2015.1.0-r1
animation clip `.hkt` files referenced across ALL 88 extracted non-Physics2012 `.hkt`
behavior graphs (`compare/assets/havok_hkb_graphs.json`), converting all coordinates into
Godot standard right-handed Y-up (`+Y` up, `-Z` forward, `+X` right) and packing them into
compact compressed Godot binary `HeroMotionData` `.res` bundles under `compare/assets/clips/`:
  - hero_full_clips.res        (Hero + HeroBodyIk + AnimationBundles clips, Z-up -> Godot Y-up)
  - soldier_full_clips.res     (Soldier clips, Maya Y-up aligned to Godot rig)
  - firefighter_full_clips.res (Firefighter clips, Z-up -> Godot Y-up)
  - ninja_full_clips.res       (Ninja clips, Z-up -> Godot Y-up)
  - misc_behavior_clips.res    (Retargeting, SiegeFiend, AnimatedAttachments, HandIk, Layering, Locomotion, Performance)

Policy:
  - Legacy Havok Physics2012 `.hkt` files are explicitly SPEC_OUT.
  - Existing 47-demo 1:1 verified `hero_behavior_clips.res` and `soldier_behavior_clips.res`
    are preserved untouched; these packs serve as full-library supplements loaded automatically
    by `HkbBehaviorGraph`.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SDK_ROOT = Path(os.environ.get("HAVOK_SDK_ROOT", r"D:\SDK\hk2015_1_0\hk2015_1_0_r1"))
RESOURCES = SDK_ROOT / "Demo" / "Demos" / "Resources"
ORACLE_EXE = Path(os.environ.get("HERO_ORACLE", r"C:\Users\taru0\AppData\Local\Temp\codex_havok_oracle\hero_oracle.exe"))
GODOT_EXE = Path(
    os.environ.get(
        "GODOT_BIN",
        r"D:\Github\GoDotProjects-worktrees\Forge-Refactoring-engine\bin\godot.windows.editor.x86_64.console.exe",
    )
)
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
ASSETS_DIR = SCRIPT_DIR / "assets"
CLIPS_DIR = ASSETS_DIR / "clips"
GRAPHS_JSON = ASSETS_DIR / "havok_hkb_graphs.json"

HERO_RIG = RESOURCES / r"Behavior\GameAssets\Hero\CharacterAssets\Rig.hkt"
SOLDIER_RIG = RESOURCES / r"Behavior\GameAssets\Soldier\CharacterAssets\US_Leader_Pack_2.hkt"
FIREFIGHTER_RIG = RESOURCES / r"Animation\NpRagdoll\Firefighter_Rig.hkt"
NINJA_RIG = RESOURCES / r"Behavior\GameAssets\Ninja\CharacterAssets\Ninja_blue.hkt"


def run_oracle(hkt_path: Path) -> dict | None:
    proc = subprocess.run([str(ORACLE_EXE), str(hkt_path), "--grid"], capture_output=True, text=True, check=False, timeout=60)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        return json.loads(proc.stdout)
    except Exception:
        return None


def conv_xform(vals: list[float], z_up: bool) -> dict:
    tx, ty, tz = float(vals[0]), float(vals[1]), float(vals[2])
    qx, qy, qz, qw = float(vals[3]), float(vals[4]), float(vals[5]), float(vals[6])
    sx, sy, sz = float(vals[7]), float(vals[8]), float(vals[9])
    if z_up:
        return {
            "translation": [tx, tz, -ty],
            "rotation": [qx, qz, -qy, qw],
            "scale": [sx, sz, sy],
        }
    return {
        "translation": [tx, ty, tz],
        "rotation": [qx, qy, qz, qw],
        "scale": [sx, sy, sz],
    }


def decimate_samples(samples: list[dict], target_hz: float) -> list[dict]:
    if len(samples) <= 3:
        return samples
    dur = float(samples[-1]["time"])
    if dur <= 0.05:
        return samples
    src_hz = (len(samples) - 1) / max(1e-6, dur)
    stride = max(1, int(round(src_hz / target_hz)))
    if stride <= 1:
        return samples
    out = samples[::stride]
    if out[-1]["time"] != samples[-1]["time"]:
        out.append(samples[-1])
    return out


def load_rig_bones(rig_path: Path | None, z_up: bool) -> tuple[list[dict], dict[str, int]]:
    if rig_path is None or not rig_path.is_file():
        return [], {}
    raw = run_oracle(rig_path)
    if not raw:
        return [], {}
    skel = next((c["skeleton"] for c in raw.get("containers", []) if c.get("skeleton")), None)
    if not skel:
        return [], {}
    bones = []
    name_to_idx: dict[str, int] = {}
    for idx, b in enumerate(skel["bones"]):
        nm = str(b["name"])
        name_to_idx[nm] = idx
        bones.append({
            "name": nm,
            "parent": int(b["parent"]),
            "bind": conv_xform(b["reference"], z_up),
        })
    return bones, name_to_idx


def extract_single_clip(args: tuple[str, Path, bool, float, list[dict], dict[str, int]]) -> tuple[str, dict | None, str]:
    key, hkt_path, z_up, target_hz, rig_bones, name_to_idx = args
    raw = run_oracle(hkt_path)
    if not raw:
        return key, None, "oracle_fail"
    clip = None
    clip_skel = None
    for c in raw.get("containers", []):
        if c.get("skeleton") and clip_skel is None:
            clip_skel = c["skeleton"]
        if c.get("clips") and clip is None:
            clip = c["clips"][0]
    if clip is None:
        return key, None, "no_clip"

    samples = clip.get("source_grid", clip.get("samples", []))
    if not samples:
        return key, None, "no_samples"
    samples = decimate_samples(samples, target_hz)

    binding = clip.get("binding", {})
    t2b = [int(i) for i in binding.get("trackToBoneIndices", [])]
    if not t2b:
        t2b = list(range(int(clip.get("numTransformTracks", len(samples[0]["tracks"])))))

    clip_bones = clip_skel.get("bones", []) if clip_skel else []
    mapped_bones: list[int] = []
    for bi in t2b:
        if bi < 0:
            mapped_bones.append(-1)
            continue
        if rig_bones:
            if clip_bones and bi < len(clip_bones):
                bnm = str(clip_bones[bi]["name"])
                if bnm in name_to_idx:
                    mapped_bones.append(name_to_idx[bnm])
                elif bi == 0:
                    mapped_bones.append(0)
                else:
                    mapped_bones.append(bi if bi < len(rig_bones) else -1)
            else:
                mapped_bones.append(bi if bi < len(rig_bones) else -1)
        else:
            mapped_bones.append(bi)

    tracks_by_bone: dict[int, list[dict]] = {}
    root_motion = []
    for s in samples:
        t = float(s["time"])
        for ti, xf_vals in enumerate(s["tracks"]):
            rbi = mapped_bones[ti] if ti < len(mapped_bones) else -1
            if rbi < 0:
                continue
            xf = conv_xform(xf_vals, z_up)
            tracks_by_bone.setdefault(rbi, []).append({"time": t, **xf})
        em = s.get("extractedMotion")
        if em is not None:
            xfm = conv_xform(em, z_up)
            root_motion.append({"time": t, "translation": xfm["translation"], "rotation": xfm["rotation"]})

    tracks = [{"bone": bi, "keys": tracks_by_bone[bi]} for bi in sorted(tracks_by_bone)]
    clip_dict = {
        "duration": float(clip["duration"]),
        "frame_count": int(clip.get("numOriginalFrames", len(samples))),
        "tracks": tracks,
        "root_motion": {"keys": root_motion} if root_motion else None,
    }
    return key, clip_dict, "ok"


def pack_to_godot_res(json_map: dict[Path, Path]) -> None:
    gd_lines = [
        "extends SceneTree",
        'const HeroMotionData = preload("res://hero/hero_motion_data.gd")',
        "func _initialize():",
    ]
    for src_json, dst_res in json_map.items():
        sj = str(src_json).replace("\\", "/")
        dr = str(dst_res).replace("\\", "/")
        tag = dst_res.stem
        gd_lines += [
            f'\tvar raw_{tag} = JSON.parse_string(FileAccess.get_file_as_string("{sj}"))',
            f"\tvar res_{tag} = HeroMotionData.new()",
            f"\tres_{tag}.pack_from_dict(raw_{tag})",
            f'\tvar err_{tag} = ResourceSaver.save(res_{tag}, "{dr}", ResourceSaver.FLAG_COMPRESS)',
            f'\tprint("SAVED {dst_res.name} err=", err_{tag}, " clips=", res_{tag}.packed_clips.size())',
        ]
    gd_lines.append("\tquit(0)")

    tmp_gd = SCRIPT_DIR / "_tmp_pack_all_clips.gd"
    tmp_gd.write_text("\n".join(gd_lines) + "\n", encoding="utf-8")
    try:
        proc = subprocess.run(
            [str(GODOT_EXE), "--headless", "--path", str(PROJECT_DIR), "--script", "res://compare/_tmp_pack_all_clips.gd"],
            capture_output=True,
            text=True,
            check=False,
        )
        print(proc.stdout)
        if proc.returncode != 0:
            raise RuntimeError(f"Godot pack failed: {proc.stderr}")
    finally:
        tmp_gd.unlink(missing_ok=True)


def main() -> int:
    CLIPS_DIR.mkdir(parents=True, exist_ok=True)
    graph_data = json.loads(GRAPHS_JSON.read_text(encoding="utf-8"))

    # Index every physical .hkt file in SDK (case-insensitive stem & filename)
    all_hkts: dict[str, list[Path]] = {}
    for p in RESOURCES.rglob("*.hkt"):
        all_hkts.setdefault(p.name.lower(), []).append(p)
    for p in RESOURCES.rglob("*.HKT"):
        if p not in all_hkts.get(p.name.lower(), []):
            all_hkts.setdefault(p.name.lower(), []).append(p)

    def pick_best_path(fam: str, bn_low: str) -> Path | None:
        cands = all_hkts.get(bn_low, [])
        if not cands:
            return None
        fam_low = fam.lower()
        for c in cands:
            if fam_low in str(c).lower():
                return c
        if fam in ("Hero", "HeroBodyIk", "AnimationBundles"):
            for c in cands:
                if "hero" in str(c).lower():
                    return c
        return cands[0]

    buckets: dict[str, dict[str, Path]] = {
        "hero_full_clips": {},
        "soldier_full_clips": {},
        "firefighter_full_clips": {},
        "ninja_full_clips": {},
        "misc_behavior_clips": {},
    }
    symbolic_skipped: list[str] = []

    for gk, g in graph_data["graphs"].items():
        fam = gk.split("/")[0] if "/" in gk else "Root"
        if fam in ("Hero", "HeroBodyIk", "AnimationBundles"):
            bname = "hero_full_clips"
        elif fam == "Soldier":
            bname = "soldier_full_clips"
        elif fam == "Firefighter":
            bname = "firefighter_full_clips"
        elif fam == "Ninja":
            bname = "ninja_full_clips"
        else:
            bname = "misc_behavior_clips"

        for n in g.get("nodes", []):
            if n.get("type") != "hkbClipGenerator":
                continue
            an = str(n.get("animation", "")).strip()
            if not an:
                continue
            bn = os.path.basename(an.replace("\\", "/"))
            if ":" in bn:
                bn = bn.split(":", 1)[1]
            bn_low = bn.lower()
            p = pick_best_path(fam, bn_low)
            if p is None:
                symbolic_skipped.append(f"{fam}:{an}")
                continue
            clip_key = bn_low[:-4] if bn_low.endswith(".hkt") else bn_low
            if clip_key not in buckets[bname]:
                buckets[bname][clip_key] = p

    # Also include ALL remaining Hero & Soldier SDK animation `.hkt`s for 100% clip completeness
    hero_anim_dir = RESOURCES / r"Behavior\GameAssets\Hero\Animations"
    if hero_anim_dir.is_dir():
        for p in sorted(list(hero_anim_dir.rglob("*.hkt")) + list(hero_anim_dir.rglob("*.HKT"))):
            ck = p.stem.lower()
            if ck not in buckets["hero_full_clips"]:
                buckets["hero_full_clips"][ck] = p

    soldier_anim_dir = RESOURCES / r"Behavior\GameAssets\Soldier\Animations"
    if soldier_anim_dir.is_dir():
        for p in sorted(soldier_anim_dir.glob("*.hkt")):
            ck = p.stem.lower()
            if ck not in buckets["soldier_full_clips"]:
                buckets["soldier_full_clips"][ck] = p

    pack_configs = [
        ("hero_full_clips", HERO_RIG, True, 20.0),
        ("soldier_full_clips", SOLDIER_RIG, False, 15.0),
        ("firefighter_full_clips", FIREFIGHTER_RIG, True, 20.0),
        ("ninja_full_clips", NINJA_RIG, True, 20.0),
        ("misc_behavior_clips", None, True, 20.0),
    ]

    manifest = {
        "schema": "havok-full-clip-packs-v1",
        "contains_sdk_hkt_runtime_dep": False,
        "axis_standard": "godot_y_up_neg_z_forward",
        "physics2012_policy": "SPEC_OUT",
        "packs": {},
        "symbolic_or_missing_in_sdk": sorted(set(symbolic_skipped)),
    }

    with tempfile.TemporaryDirectory(prefix="havok_all_clips_") as td:
        td_path = Path(td)
        json_to_res: dict[Path, Path] = {}

        for pack_name, rig_path, z_up, hz in pack_configs:
            cmap = buckets[pack_name]
            print(f"\n=== Extracting {pack_name}: {len(cmap)} clips (z_up={z_up}, hz={hz}) ===")
            rig_bones, name_to_idx = load_rig_bones(rig_path, z_up)
            jobs = [(k, p, z_up, hz, rig_bones, name_to_idx) for k, p in sorted(cmap.items())]
            clips_out: dict[str, dict] = {}
            failed: list[str] = []
            with ThreadPoolExecutor(max_workers=8) as pool:
                for key, cdict, status in pool.map(extract_single_clip, jobs):
                    if cdict is not None:
                        clips_out[key] = cdict
                    else:
                        failed.append(f"{key}({status})")
            print(f"  Extracted {len(clips_out)} / {len(cmap)} clips (failed={len(failed)})")
            if failed:
                print(f"  Failed samples: {failed[:8]}")
            pack_dict = {
                "schema_version": 1,
                "axis_standard": "godot_y_up_neg_z_forward",
                "skeleton": {"bones": rig_bones},
                "clips": clips_out,
            }
            jpath = td_path / f"{pack_name}.json"
            jpath.write_text(json.dumps(pack_dict, separators=(",", ":")), encoding="utf-8")
            rpath = CLIPS_DIR / f"{pack_name}.res"
            json_to_res[jpath] = rpath
            manifest["packs"][pack_name] = {
                "res_path": f"res://compare/assets/clips/{pack_name}.res",
                "clip_count": len(clips_out),
                "bone_count": len(rig_bones),
                "z_up_converted": z_up,
                "clips": sorted(clips_out.keys()),
                "failed": failed,
            }

        pack_to_godot_res(json_to_res)
        for pack_name in manifest["packs"]:
            rp = CLIPS_DIR / f"{pack_name}.res"
            kb = rp.stat().st_size / 1024.0 if rp.is_file() else 0.0
            manifest["packs"][pack_name]["size_kb"] = round(kb, 1)
            print(f"  PACK {rp.name:28s}: {manifest['packs'][pack_name]['clip_count']:3d} clips | {kb:7.1f} KB")

    manifest_path = CLIPS_DIR / "clip_packs_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    total_clips = sum(p["clip_count"] for p in manifest["packs"].values())
    print(f"\n[DONE] Total extracted full-library clips: {total_clips} -> {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
