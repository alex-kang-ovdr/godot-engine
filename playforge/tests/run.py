#!/usr/bin/env python3
"""PlayForge 엔진 패치 회귀 시험 실행기 (Python 3 표준 라이브러리만 사용).

사용법:
    python playforge/tests/run.py [--godot PATH] [--quick] [--only SUITE[,SUITE]] [--repeat N]

편집기 실행 파일 결정 순서: --godot 인자 > 환경 변수 GODOT_BIN > <저장소>/bin/godot.windows.editor.x86_64.console.exe
결과: playforge/tests/results/latest.json (git 제외). 실패·중단이 하나라도 있으면 종료 코드 1.
자세한 설명은 같은 폴더의 README.md.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import subprocess
import sys
import time
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
PROJECT_DIR = TESTS_DIR / "project"
REPO_ROOT = TESTS_DIR.parent.parent
RESULTS_DIR = TESTS_DIR / "results"
DEFAULT_BIN = REPO_ROOT / "bin" / "godot.windows.editor.x86_64.console.exe"
PREFIX = "PFTEST "

# name, scene, 추가 엔진 인자, 사용자 인자(-- 뒤), 제한 시간(초), 지키는 커밋
SUITES = [
    ("avatar_bootstrap", "res://avatar/bootstrap_empty_3d.tscn", [], [], 60, "a18fb005 fe0b4fe1 ed003ce5"),
    ("avatar_bootstrap_cli_portrait", "res://avatar/bootstrap_empty_3d.tscn", [], ["--avatar-presentation-mode=upper_body"], 60, "fe0b4fe1"),
    ("avatar_seal", "res://avatar/avatar_seal.tscn", [], [], 60, "a18fb005"),
    ("corehud_seal", "res://avatar/corehud_seal.tscn", [], [], 60, "a18fb005 fe0b4fe1"),
    ("portrait_seal", "res://avatar/portrait_seal.tscn", [], [], 60, "fe0b4fe1"),
    ("portrait_mode_switch", "res://avatar/portrait_mode_switch.tscn", [], [], 60, "fe0b4fe1"),
    ("sealed_parent_free", "res://avatar/sealed_parent_free.tscn", [], [], 60, "a18fb005"),
    ("hide_budget", "res://avatar/hide_budget.tscn", [], [], 120, "ed003ce5"),
    ("vfs_seal", "res://avatar/vfs_seal.tscn", [], [], 60, "a18fb005"),
    ("seal_gaps", "res://avatar/seal_gaps.tscn", [], [], 60, "a18fb005 (관찰 전용)"),
    # 물리 스위트는 --fixed-fps 로 실시간 동기화를 끄고 최대 속도로 틱을 돌린다(틱 수는 같으므로 결과도 같다).
    ("jolt_api", "res://jolt/jolt_api.tscn", ["--fixed-fps", "60"], [], 120, "83f5f345 e7a83dd7"),
    ("jolt_determinism", "res://jolt/jolt_determinism.tscn", ["--fixed-fps", "60"], [], 300, "83f5f345 c9050da1 e7a83dd7"),
    ("jolt_contacts", "res://jolt/jolt_contacts.tscn", ["--fixed-fps", "60"], [], 120, "c9050da1"),
    ("enet_rpc_netdebug", "res://network/net_debug.tscn", [], [], 60, "Forge-Refactoring-Multiplayer E3"),
]

# 실행으로 관찰할 수 없는 패치(빌드 플래그 등)는 소스에 표식이 남아 있는지만 확인한다.
# 경로는 저장소 루트 기준. (커밋, 파일, 있어야 할 문자열 목록)
SOURCE_MARKERS = [
    ("a18fb005", "core/object/object.h", ["struct PlatformSealScope", "_platform_sealed"]),
    ("a18fb005", "main/main.cpp", ["--playforge-core-pack", "--playforge-ugc-pack", 'seal_prefix("addons/playforge_avatar/")']),
    ("a18fb005", "scene/main/canvas_layer.cpp", ["p_xform > 100", "CanvasLayer.layer_clamped"]),
    ("fe0b4fe1", "scene/gui/control.cpp", ["platform_min_size", "Control.set_scale"]),
    ("fe0b4fe1", "scene/main/canvas_item.cpp", ["0.85f"]),
    ("ed003ce5", "modules/playforge_core/playforge_platform.h", ["AVATAR_HIDE_MAX_BUDGET_SEC = 30.0", "AVATAR_HIDE_RECHARGE_RATE = 0.2"]),
    ("83f5f345", "modules/jolt_physics/jolt_physics_server_3d.cpp", ["JPH::JobSystemThreadPool", "batch_fill_multimesh_buffer"]),
    ("83f5f345", "modules/jolt_physics/spaces/jolt_space_3d.cpp", ["JoltPreStep"]),
    ("83f5f345", "modules/playforge_core/register_types.cpp", ["GDREGISTER_CLASS(PlayForgePhysicsBatch)"]),
    ("70892ae8", "modules/jolt_physics/SCsub", ["/arch:AVX2", "-mavx2", "-mfma"]),
    ("c9050da1", "modules/jolt_physics/spaces/jolt_contact_listener_3d.h", ["has_reported_contacts", "has_area_overlaps"]),
    ("c9050da1", "modules/jolt_physics/spaces/jolt_contact_listener_3d.cpp", ["OnContactAdded(p_body1, p_body2, p_manifold, p_settings);"]),
    ("e7a83dd7", "thirdparty/jolt_physics/Jolt/Physics/Collision/PlayForgeGskExperiment.h", ["g_playforge_gsk_mode", "PlayForgeGskStats"]),
    ("e7a83dd7", "thirdparty/jolt_physics/Jolt/Physics/PhysicsSystem.cpp", ["g_playforge_gsk_stats", "SetBodyPairGskAxis"]),
    ("e7a83dd7", "modules/playforge_core/playforge_physics_batch.cpp", ["get_jolt_narrow_stats"]),
]


def resolve_godot(arg: str | None) -> Path:
    for cand in (arg, os.environ.get("GODOT_BIN")):
        if cand:
            return Path(cand).resolve()
    return DEFAULT_BIN


def git_head() -> str:
    try:
        return subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return ""


def run_suite(godot: Path, name: str, scene: str, engine_args: list[str], user_args: list[str], timeout: int) -> dict:
    cmd = [str(godot), "--headless", *engine_args, "--path", str(PROJECT_DIR), scene]
    if user_args:
        cmd += ["--", *user_args]
    t0 = time.monotonic()
    timed_out = False
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
        out = proc.stdout.decode("utf-8", "replace")
        err = proc.stderr.decode("utf-8", "replace")
        rc = proc.returncode
    except subprocess.TimeoutExpired as e:
        timed_out = True
        out = (e.stdout or b"").decode("utf-8", "replace")
        err = (e.stderr or b"").decode("utf-8", "replace")
        rc = None
    elapsed = time.monotonic() - t0

    records = []
    for line in out.splitlines():
        if line.startswith(PREFIX):
            try:
                records.append(json.loads(line[len(PREFIX):]))
            except json.JSONDecodeError:
                records.append({"status": "FAIL", "test": "unparseable_output", "detail": line})
    tests = [r for r in records if r.get("status") in ("PASS", "FAIL")]
    summary = next((r for r in records if r.get("status") == "SUMMARY"), None)
    start = next((r for r in records if r.get("status") == "START"), {})
    problems = []
    if timed_out:
        problems.append(f"timeout after {timeout}s")
    elif summary is None:
        problems.append(f"no SUMMARY line: engine exited abnormally (exit code {rc} = 0x{(rc or 0) & 0xFFFFFFFF:08X})")
    if any(r["status"] == "FAIL" for r in tests):
        problems.append("failed checks")
    if summary is not None and not timed_out and rc != (1 if summary.get("fail", 0) else 0):
        problems.append(f"exit code {rc} does not match summary")
    last_running = next((r for r in reversed(records) if r.get("status") in ("PASS", "FAIL", "INFO")), None)
    return {
        "suite": name,
        "scene": scene,
        "command": cmd,
        "ok": not problems,
        "problems": problems,
        "exit_code": rc,
        "seconds": round(elapsed, 2),
        "engine_hash": start.get("engine", ""),
        "tests": tests,
        "info": [r for r in records if r.get("status") == "INFO"],
        "gaps": [r for r in records if r.get("status") == "GAP"],
        "not_covered": [r for r in records if r.get("status") == "NOT_COVERED"],
        "last_record_before_exit": last_running if summary is None else None,
        "stderr_tail": "\n".join(err.splitlines()[-15:]) if problems else "",
    }


def check_source_markers() -> dict:
    tests = []
    for commit, rel, needles in SOURCE_MARKERS:
        path = REPO_ROOT / rel
        text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else None
        missing = [n for n in needles if text is None or n not in text]
        tests.append({
            "status": "PASS" if not missing else "FAIL",
            "suite": "source_markers",
            "test": f"{rel}",
            "commit": commit,
            "detail": "file missing" if text is None else (f"missing: {missing}" if missing else f"{len(needles)} marker(s) present"),
        })
    ok = all(t["status"] == "PASS" for t in tests)
    return {"suite": "source_markers", "ok": ok, "problems": [] if ok else ["missing source markers"], "tests": tests,
            "info": [], "gaps": [], "not_covered": [], "seconds": 0.0}


def cross_process_determinism(runs: list[dict]) -> dict:
    """같은 스위트를 두 프로세스로 돌린 결과의 xproc_hash 비교."""
    hashes = []
    for r in runs:
        h = {i["test"]: i["data"].get("xproc_hash") for i in r["info"] if isinstance(i.get("data"), dict) and "xproc_hash" in i["data"]}
        hashes.append(h)
    tests = []
    keys = sorted(set().union(*hashes)) if hashes else []
    for k in keys:
        vals = [h.get(k) for h in hashes]
        same = len(vals) >= 2 and None not in vals and len(set(vals)) == 1
        tests.append({"status": "PASS" if same else "FAIL", "suite": "jolt_determinism_cross_process", "test": k.replace("xproc_hash_", "cross_process_hash_equal_"),
                      "commit": "83f5f345 c9050da1 e7a83dd7", "detail": " vs ".join((v or "missing")[:16] for v in vals)})
    if not tests:
        tests.append({"status": "FAIL", "suite": "jolt_determinism_cross_process", "test": "hashes_collected", "commit": "83f5f345", "detail": "no xproc_hash records"})
    ok = all(t["status"] == "PASS" for t in tests)
    return {"suite": "jolt_determinism_cross_process", "ok": ok, "problems": [] if ok else ["cross-process hash mismatch"], "tests": tests,
            "info": [], "gaps": [], "not_covered": [], "seconds": 0.0}


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            # 파이프로 받을 때도 한국어가 깨지지 않게 UTF-8 로 쓴다(콘솔 직접 출력은 영향 없음).
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass
    ap = argparse.ArgumentParser(description="PlayForge engine patch regression tests")
    ap.add_argument("--godot", help="Godot editor binary (default: env GODOT_BIN, else <repo>/bin/godot.windows.editor.x86_64.console.exe)")
    ap.add_argument("--quick", action="store_true", help="skip the ~30 s hide-budget exhaustion check")
    ap.add_argument("--only", help="comma-separated suite names")
    ap.add_argument("--repeat", type=int, default=1, help="run every suite N times (stability)")
    ap.add_argument("--output", default=str(RESULTS_DIR / "latest.json"))
    args = ap.parse_args()

    godot = resolve_godot(args.godot)
    if not godot.is_file():
        print(f"Godot binary not found: {godot}", file=sys.stderr)
        return 2
    try:
        version = subprocess.run([str(godot), "--headless", "--version"], capture_output=True, timeout=60).stdout.decode("utf-8", "replace").strip().splitlines()[-1]
    except Exception as e:  # noqa: BLE001
        version = f"unknown ({e})"
    head = git_head()

    only = set(args.only.split(",")) if args.only else None
    results = []
    if only is None or "source_markers" in only:
        results.append(check_source_markers())
    det_runs = []
    for rep in range(max(1, args.repeat)):
        for name, scene, eargs, uargs, timeout, guards in SUITES:
            if only and name not in only:
                continue
            uargs = list(uargs) + (["--quick"] if args.quick and name == "hide_budget" else [])
            # 결정성 스위트는 프로세스 간 비교를 위해 반복 횟수와 상관없이 최소 2회 돈다.
            n = 2 if name == "jolt_determinism" and args.repeat == 1 else 1
            for k in range(n):
                label = name if (rep == 0 and k == 0) else f"{name}#{rep * n + k + 1}"
                print(f"[run] {label} ...", flush=True)
                r = run_suite(godot, name, scene, eargs, uargs, timeout)
                r["label"] = label
                r["guards"] = guards
                results.append(r)
                if name == "jolt_determinism":
                    det_runs.append(r)
                print(f"      {'ok' if r['ok'] else 'FAIL'}  {sum(t['status'] == 'PASS' for t in r['tests'])} pass / "
                      f"{sum(t['status'] == 'FAIL' for t in r['tests'])} fail  {r['seconds']}s  {'; '.join(r['problems'])}", flush=True)
    if len(det_runs) >= 2:
        results.append(cross_process_determinism(det_runs))

    engine_hashes = sorted({r.get("engine_hash", "") for r in results if r.get("engine_hash")})
    binary_matches_head = bool(head) and engine_hashes == [head]
    overall_ok = all(r["ok"] for r in results)
    report = {
        "timestamp": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "godot_binary": str(godot),
        "godot_version": version,
        "engine_hash_reported": engine_hashes,
        "repo_head": head,
        "binary_matches_repo_head": binary_matches_head,
        "ok": overall_ok,
        "suites": results,
    }
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print()
    print(f"Godot: {version}  ({godot})")
    print(f"engine hash {engine_hashes} vs repo HEAD {head[:12]}: {'match' if binary_matches_head else 'MISMATCH (runtime results describe the binary, not HEAD)'}")
    print(f"{'suite':40} {'result':6} {'pass':>5} {'fail':>5}  guards")
    for r in results:
        print(f"{r.get('label', r['suite']):40} {'ok' if r['ok'] else 'FAIL':6} {sum(t['status'] == 'PASS' for t in r['tests']):5d} "
              f"{sum(t['status'] == 'FAIL' for t in r['tests']):5d}  {r.get('guards', '')}")
        for t in r["tests"]:
            if t["status"] == "FAIL":
                print(f"    FAIL {t['test']} [{t.get('commit', '')}] {t.get('detail', '')}")
        for p in r["problems"]:
            if p != "failed checks":
                print(f"    !! {p}")
                if r.get("last_record_before_exit"):
                    print(f"       last record: {json.dumps(r['last_record_before_exit'], ensure_ascii=False)}")
    gaps = [g for r in results if r.get("label", r["suite"]) == r["suite"] for g in r["gaps"]]
    if gaps:
        print("\nGAP (관찰, 판정 없음):")
        for g in gaps:
            print(f"    {g['suite']}::{g['test']} [{g.get('commit', '')}] {g.get('detail', '')}")
    nc = [g for r in results if r.get("label", r["suite"]) == r["suite"] for g in r["not_covered"]]
    if nc:
        print("\nNOT_COVERED:")
        for g in nc:
            print(f"    {g['suite']}::{g['test']} [{g.get('commit', '')}] {g.get('detail', '')}")
    print(f"\n{'ALL GREEN' if overall_ok else 'FAILURES PRESENT'} -> {out}")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
