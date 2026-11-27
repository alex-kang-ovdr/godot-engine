#!/usr/bin/env python3
"""Offline exporter that extracts ALL 32 unique official Havok 2015.1.0-r1
Hero (17) & Soldier (15) Behavior .hkt clips via hero_oracle.exe and packs them
into two compact, SDK-free native Godot HeroMotionData binary resources:
  - compare/assets/hero_behavior_clips.res
  - compare/assets/soldier_behavior_clips.res
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import tempfile
from pathlib import Path

SDK_ROOT = Path(os.environ.get("HAVOK_SDK_ROOT", r"D:\SDK\hk2015_1_0\hk2015_1_0_r1"))
ORACLE_EXE = Path(os.environ.get("HERO_ORACLE", r"C:\Users\taru0\AppData\Local\Temp\codex_havok_oracle\hero_oracle.exe"))
GODOT_EXE = Path(
    os.environ.get(
        "GODOT_BIN",
        r"D:\Github\GoDotProjects-worktrees\Forge-Refactoring-engine\bin\godot.windows.editor.x86_64.console.exe",
    )
)
PROJECT_DIR = Path(__file__).resolve().parent.parent
ASSETS_DIR = Path(__file__).resolve().parent / "assets"

HERO_RIG = SDK_ROOT / r"Demo\Demos\Resources\Behavior\GameAssets\Hero\CharacterAssets\Rig.hkt"
HERO_ANIMS_DIR = SDK_ROOT / r"Demo\Demos\Resources\Behavior\GameAssets\Hero\Animations"
HERO_CLIPS = {
    "idle_0": "Idle/Idle_0.hkt",
    "walk_0": "Walk/Walk_0.hkt",
    "run_0": "Run/Run_0.hkt",
    "idle_to_run_0": "Idle/Idle_To_Run_0.hkt",
    "idle_to_run_180": "Idle/Idle_To_Run_180.hkt",
    "idle_to_cover_standing": "Idle/Idle_To_Cover_Standing.hkt",
    "idle_to_cover_crouched": "Idle/Idle_To_Cover_Crouched.hkt",
    "cover_standing_idle": "Cover/Cover_Standing_Idle.hkt",
    "cover_standing_walk": "Cover/Cover_Standing_Walk.hkt",
    "cover_crouched_idle": "Cover/Cover_Crouched_Idle.hkt",
    "cover_crouched_walk": "Cover/Cover_Crouched_Walk.hkt",
    "cover_crouched_roll_to_cover_crouched": "Cover/Cover_Crouched_Roll_to_Cover_Crouched.HKT",
    "idle_sword": "Idle/Idle_Sword.hkt",
    "idle_to_sword": "Idle/Idle_To_Sword.hkt",
    "jump_on_spot": "Jump_on_spot.hkt",
    "jump_walk_all": "Jump_Walk_All.hkt",
    "inair_from_idle": "InAir_From_Idle.HKT",
}

SOLDIER_RIG = SDK_ROOT / r"Demo\Demos\Resources\Behavior\GameAssets\Soldier\CharacterAssets\US_Leader_Pack_2.hkt"
SOLDIER_ANIMS_DIR = SDK_ROOT / r"Demo\Demos\Resources\Behavior\GameAssets\Soldier\Animations"
SOLDIER_CLIPS = {
    "idle_m4_ready__v1_t1": "idle_m4_ready__v1_t1.hkt",
    "walk_m4_ready__v1_t1": "walk_m4_ready__v1_t1.hkt",
    "run_m4_ready__v1_t5": "run_m4_ready__v1_t5.hkt",
    "jog_m4_ready__v1_t1": "jog_m4_ready__v1_t1.hkt",
    "kneel_m4_ready__v1_t1": "kneel_m4_ready__v1_t1.hkt",
    "idle_m4_engaged__v1_t1": "idle_m4_engaged__v1_t1.hkt",
    "walk_m4_engaged__v1_t1": "walk_m4_engaged__v1_t1.hkt",
    "walk_slow_m4_engaged__v1_t1": "walk_slow_m4_engaged__v1_t1.hkt",
    "run_m4_engaged__v1_t2": "run_m4_engaged__v1_t2.hkt",
    "idle_m4_ready_inspect_cock_reload__v1_t1": "idle_m4_ready_inspect_cock_reload__v1_t1.hkt",
    "turn_left_inplace_m4_engaged__v1_t1": "turn_left_inplace_m4_engaged__v1_t1.hkt",
    "turn_right_inplace_m4_engaged__v1_t1": "turn_right_inplace_m4_engaged__v1_t1.hkt",
    "death_shot_chest_front__v1_t1_rdo_01_b_f30_70": "death_shot_chest_front__v1_t1_RDo_01_B_f30_70.hkt",
    "aim_m4_down__v1_t1_rdo_01_b": "aim_m4_down__v1_t1_RDo_01_B.hkt",
    "aim_m4_forward__v1_t1_rdo_03_b": "aim_m4_forward__v1_t1_RDo_03_B.hkt",
}


def run_oracle(hkt_path: Path) -> dict:
    proc = subprocess.run([str(ORACLE_EXE), str(hkt_path), "--grid"], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"hero_oracle failed on {hkt_path}: {proc.stderr[:400]}")
    return json.loads(proc.stdout)


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
    """Keep exact full grid for short clips (<= 2.2s) and clean uniform stride for long clips,
    always retaining exact first & last frames."""
    if len(samples) <= 3:
        return samples
    dur = float(samples[-1]["time"])
    if dur <= 2.2:
        return samples
    src_hz = (len(samples) - 1) / max(1e-6, dur)
    stride = max(1, int(round(src_hz / target_hz)))
    if stride <= 1:
        return samples
    out = samples[::stride]
    if out[-1]["time"] != samples[-1]["time"]:
        out.append(samples[-1])
    return out


def export_pack(rig_path: Path, anims_dir: Path, clip_map: dict[str, str], z_up: bool, target_hz: float) -> dict:
    rig_raw = run_oracle(rig_path)
    rig_skel = next(c["skeleton"] for c in rig_raw["containers"] if c.get("skeleton"))
    raw_bones = rig_skel["bones"]
    bones = []
    name_to_idx: dict[str, int] = {}
    for idx, b in enumerate(raw_bones):
        nm = str(b["name"])
        name_to_idx[nm] = idx
        bones.append({
            "name": nm,
            "parent": int(b["parent"]),
            "bind": conv_xform(b["reference"], z_up),
        })

    clips_out = {}
    for key, rel in clip_map.items():
        hkt_path = anims_dir / rel
        if not hkt_path.is_file():
            raise FileNotFoundError(f"Missing HKT: {hkt_path}")
        raw = run_oracle(hkt_path)
        clip = None
        clip_skel = None
        for c in raw.get("containers", []):
            if c.get("skeleton") and clip_skel is None:
                clip_skel = c["skeleton"]
            if c.get("clips") and clip is None:
                clip = c["clips"][0]
        if clip is None:
            raise ValueError(f"No clip in {hkt_path}")

        samples = clip.get("source_grid", clip.get("samples", []))
        samples = decimate_samples(samples, target_hz)
        binding = clip.get("binding", {})
        t2b = [int(i) for i in binding.get("trackToBoneIndices", [])]
        if not t2b:
            t2b = list(range(int(clip.get("numTransformTracks", len(samples[0]["tracks"])))))

        # Map clip skeleton bone indices onto target rig skeleton indices by name when available
        clip_bones = clip_skel.get("bones", []) if clip_skel else []
        mapped_bones: list[int] = []
        for bi in t2b:
            if bi < 0:
                mapped_bones.append(-1)
                continue
            if clip_bones and bi < len(clip_bones):
                bnm = str(clip_bones[bi]["name"])
                if bnm in name_to_idx:
                    mapped_bones.append(name_to_idx[bnm])
                elif bi == 0:
                    mapped_bones.append(0)
                else:
                    mapped_bones.append(bi if bi < len(bones) else -1)
            else:
                mapped_bones.append(bi if bi < len(bones) else -1)

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
        clips_out[key] = {
            "duration": float(clip["duration"]),
            "frame_count": int(clip.get("numOriginalFrames", len(samples))),
            "tracks": tracks,
            "root_motion": {"keys": root_motion} if root_motion else None,
        }
        print(f"  [{key:<46}] dur={float(clip['duration']):6.3f}s keys={len(samples):4d} tracks={len(tracks):3d} rm={len(root_motion):4d}")

    return {"schema_version": 1, "skeleton": {"bones": bones}, "clips": clips_out}


def pack_to_godot_res(json_map: dict[Path, Path]) -> None:
    gd_lines = [
        "extends SceneTree",
        'const HeroMotionData = preload("res://hero/hero_motion_data.gd")',
        "func _initialize():",
    ]
    for src_json, dst_res in json_map.items():
        sj = str(src_json).replace("\\", "/")
        dr = str(dst_res).replace("\\", "/")
        gd_lines += [
            f'\tvar raw_{dst_res.stem} = JSON.parse_string(FileAccess.get_file_as_string("{sj}"))',
            f"\tvar res_{dst_res.stem} = HeroMotionData.new()",
            f"\tres_{dst_res.stem}.pack_from_dict(raw_{dst_res.stem})",
            f'\tvar err_{dst_res.stem} = ResourceSaver.save(res_{dst_res.stem}, "{dr}", ResourceSaver.FLAG_COMPRESS)',
            f'\tprint("SAVED {dst_res.name} err=", err_{dst_res.stem}, " clips=", res_{dst_res.stem}.packed_clips.size())',
        ]
    gd_lines.append("\tquit(0)")

    tmp_gd = Path(__file__).resolve().parent / "_tmp_pack_behavior_clips.gd"
    tmp_gd.write_text("\n".join(gd_lines) + "\n", encoding="utf-8")
    try:
        proc = subprocess.run(
            [str(GODOT_EXE), "--headless", "--path", str(PROJECT_DIR), "--script", "res://compare/_tmp_pack_behavior_clips.gd"],
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
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="havok_beh_clips_") as td:
        td_path = Path(td)
        print(f"=== Exporting {len(HERO_CLIPS)} Hero Behavior clips (Z-up -> Godot Y-up) ===")
        hero_dict = export_pack(HERO_RIG, HERO_ANIMS_DIR, HERO_CLIPS, z_up=True, target_hz=30.0)
        hero_json = td_path / "hero_behavior_clips.json"
        hero_json.write_text(json.dumps(hero_dict, separators=(",", ":")), encoding="utf-8")

        print(f"\n=== Exporting {len(SOLDIER_CLIPS)} Soldier Behavior clips (Maya Y-up) ===")
        soldier_dict = export_pack(SOLDIER_RIG, SOLDIER_ANIMS_DIR, SOLDIER_CLIPS, z_up=False, target_hz=20.0)
        soldier_json = td_path / "soldier_behavior_clips.json"
        soldier_json.write_text(json.dumps(soldier_dict, separators=(",", ":")), encoding="utf-8")

        hero_res = ASSETS_DIR / "hero_behavior_clips.res"
        soldier_res = ASSETS_DIR / "soldier_behavior_clips.res"
        pack_to_godot_res({hero_json: hero_res, soldier_json: soldier_res})

        print(f"hero_behavior_clips.res:    {hero_res.stat().st_size / 1024:.1f} KB")
        print(f"soldier_behavior_clips.res: {soldier_res.stat().st_size / 1024:.1f} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
