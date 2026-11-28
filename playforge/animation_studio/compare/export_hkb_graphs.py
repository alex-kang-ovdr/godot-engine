#!/usr/bin/env python3
"""Offline extractor for REAL official Havok 2015.1.0-r1 hkbBehaviorGraph topologies.
Builds `extract_havok_hkb_graphs.exe` against the unmodified Havok SDK and exports
ALL official SDK Behavior `.hkt` graphs (Hero, Soldier, Locomotion, Firefighter, Ninja,
Orcs, HandIk, HeroBodyIk, Layering, Retargeting, SiegeFiend, AnimationSets,
AnimatedAttachments, Performance) into zero-SDK native JSON:
  `compare/assets/havok_hkb_graphs.json`
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path

SDK_ROOT = Path(os.environ.get("HAVOK_SDK_ROOT", r"D:\SDK\hk2015_1_0\hk2015_1_0_r1"))
RESOURCES = SDK_ROOT / "Demo" / "Demos" / "Resources" / "Behavior" / "GameAssets"
SCRIPT_DIR = Path(__file__).resolve().parent
ASSETS_DIR = SCRIPT_DIR / "assets"
BUILD_DIR = Path(os.environ.get("TEMP", r"C:\Temp")) / "codex_havok_hkb_graphs"
EXTRACTOR_CPP = SCRIPT_DIR / "extract_havok_hkb_graphs.cpp"
OUT_JSON = ASSETS_DIR / "havok_hkb_graphs.json"

LIBS = [
    "hkBase.lib",
    "hkCompat.lib",
    "hkInternal.lib",
    "hkSceneData.lib",
    "hkGeometryUtilities.lib",
    "hkImageUtilities.lib",
    "hkVisualize.lib",
    "hkcdInternal.lib",
    "hkcdCollide.lib",
    "hkaInternal.lib",
    "hkaAnimation.lib",
    "hkaPhysicsBridge.lib",
    "hkpConstraint.lib",
    "hkpConstraintSolver.lib",
    "hknpInternal.lib",
    "hknpPhysics.lib",
    "hkbInternal.lib",
    "hkbBehavior.lib",
    "hkbUtilities.lib",
    "hkbPhysicsBridge.lib",
    "hkbScript.lib",
    "hksVM.lib",
    "user32.lib",
    "advapi32.lib",
]


def find_vs_devcmd() -> Path:
    vswhere = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe")
    vs = subprocess.check_output(
        [str(vswhere), "-latest", "-products", "*", "-property", "installationPath"],
        text=True,
    ).strip()
    return Path(vs) / "Common7" / "Tools" / "VsDevCmd.bat"


def build_extractor() -> Path:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    exe_path = BUILD_DIR / "extract_havok_hkb_graphs.exe"
    if exe_path.is_file() and exe_path.stat().st_mtime >= EXTRACTOR_CPP.stat().st_mtime and "--rebuild" not in sys.argv:
        print(f"[build] Up-to-date: {exe_path}")
        return exe_path

    lib_dir = SDK_ROOT / "Lib" / "x64_vs2015" / "release"
    vsdev = find_vs_devcmd()
    obj_path = BUILD_DIR / "extract_havok_hkb_graphs.obj"
    rsp_c = BUILD_DIR / "compile.rsp"
    rsp_l = BUILD_DIR / "link.rsp"
    compile_lines = [
        "/nologo", "/c", "/MD", "/O2", "/fp:fast", "/GR-", "/EHs-c-", "/W1", "/std:c++14",
        "/DWIN32", "/D_WIN32", "/D_CONSOLE", "/DHK_TARGET_NAME=X64Vs2015",
        "/D_HAS_EXCEPTIONS=0", "/D_ALLOW_ITERATOR_DEBUG_LEVEL_MISMATCH",
        "/DNDEBUG", "/DHKS_BUILDRELEASE",
        f'/I"{SDK_ROOT / "Source"}"',
        f'/Fo"{obj_path}"',
        f'"{EXTRACTOR_CPP}"',
    ]
    link_lines = [
        "/nologo",
        "/SUBSYSTEM:CONSOLE",
        "/ignore:4221", "/ignore:4049", "/ignore:4099",
        f'/OUT:"{exe_path}"',
        f'/LIBPATH:"{lib_dir}"',
        f'"{obj_path}"',
        *LIBS,
    ]
    rsp_c.write_text("\n".join(compile_lines) + "\n", encoding="utf-8")
    rsp_l.write_text("\n".join(link_lines) + "\n", encoding="utf-8")
    cmd_bat = BUILD_DIR / "build.bat"
    cmd_bat.write_text(
        f'@echo off\r\ncall "{vsdev}" -arch=x64 -host_arch=x64 >nul\r\n'
        f'cl @"{rsp_c}" || exit /b 1\r\n'
        f'link @"{rsp_l}" || exit /b 1\r\n',
        encoding="utf-8",
    )
    print(f"[build] Compiling {EXTRACTOR_CPP.name} ...")
    subprocess.check_call(["cmd.exe", "/c", str(cmd_bat)])
    return exe_path


def collect_behavior_hkts() -> list[tuple[str, Path]]:
    items: list[tuple[str, Path]] = []
    for p in sorted(RESOURCES.rglob("*.hkt")):
        rel = p.relative_to(RESOURCES).as_posix()
        parts = rel.split("/")
        if "Behaviors" in parts:
            # Canonical key like "Hero/01_Locomotion", "Soldier/ControlPalettes", "Orcs/Captain"
            family = parts[0]
            stem = p.stem
            key = f"{family}/{stem}"
            items.append((key, p))
    return items


def main() -> int:
    from concurrent.futures import ThreadPoolExecutor

    exe = build_extractor()
    items = collect_behavior_hkts()
    out_parts_dir = BUILD_DIR / "parts"
    out_parts_dir.mkdir(parents=True, exist_ok=True)
    print(f"[extract] Scanning {len(items)} official SDK Behavior .hkt files (process-isolated) ...")

    def run_one(idx_item: tuple[int, tuple[str, Path]]) -> tuple[str, dict | None, str]:
        idx, (key, hkt_path) = idx_item
        part_json = out_parts_dir / f"g_{idx:03d}.json"
        if part_json.exists():
            part_json.unlink()
        proc = subprocess.run(
            [str(exe), "--single", key, str(hkt_path), str(part_json)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
        if proc.returncode == 0 and part_json.is_file():
            try:
                parsed = json.loads(part_json.read_text(encoding="utf-8"))
                if key in parsed:
                    return (key, parsed[key], "ok")
            except Exception as exc:
                return (key, None, f"json-err:{exc}")
        return (key, None, f"rc={proc.returncode}")

    graphs: dict[str, dict] = {}
    skipped: list[tuple[str, str]] = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for key, gdict, status in pool.map(run_one, enumerate(items)):
            if gdict is not None:
                graphs[key] = gdict
            else:
                skipped.append((key, status))

    out_payload = {
        "schema": "havok-hkb-graph-topology-v2",
        "contains_sdk_hkt_runtime_dep": False,
        "contains_baked_poses": False,
        "axis_standard": "godot_y_up_neg_z_forward",
        "physics2012_policy": "SPEC_OUT",
        "total_graphs": len(graphs),
        "skipped_legacy_count": len(skipped),
        "spec_out_legacy_physics2012": sorted(k for k, _ in skipped),
        "graphs": graphs,
    }
    OUT_JSON.write_text(json.dumps(out_payload, separators=(",", ":")), encoding="utf-8")

    node_types = Counter()
    total_vars = 0
    total_events = 0
    total_bindings = 0
    total_states = 0
    total_transitions = 0
    total_conditions = 0
    for k, g in graphs.items():
        total_vars += len(g.get("variables", []))
        total_events += len(g.get("events", []))
        for n in g.get("nodes", []):
            node_types[n["type"]] += 1
            total_bindings += len(n.get("bindings", []))
            for st in n.get("states", []):
                total_states += 1
                total_bindings += len(st.get("bindings", []))
                for tr in st.get("transitions", []):
                    total_transitions += 1
                    if tr.get("condition") is not None:
                        total_conditions += 1
            for wc in n.get("wildcards", []):
                total_transitions += 1
                if wc.get("condition") is not None:
                    total_conditions += 1
            for ch in n.get("children", []):
                total_bindings += len(ch.get("bindings", []))
            for ly in n.get("layers", []):
                total_bindings += len(ly.get("bindings", []))

    print(f"\n=== HAVOK HKB TOPOLOGY EXTRACTION SUMMARY ===")
    print(f"  Output         : {OUT_JSON} ({OUT_JSON.stat().st_size / 1024:.1f} KB)")
    print(f"  Total Graphs   : {len(graphs)} / {len(items)} (skipped legacy={len(skipped)})")
    if skipped:
        print(f"  Skipped        : {skipped[:12]}")
    print(f"  Variables      : {total_vars}")
    print(f"  Events         : {total_events}")
    print(f"  Var Bindings   : {total_bindings}")
    print(f"  States / Trans : {total_states} states / {total_transitions} transitions ({total_conditions} conditioned)")
    print(f"  Top Node Types : {dict(node_types.most_common(18))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
