#!/usr/bin/env python3
"""Export the Havok SDK Hero rig and sampled locomotion clips to JSON.

The SDK's HKT files are proprietary binary serialization. This script delegates
their decoding and animation sampling to the small, SDK-linked ``hero_oracle``
helper, then converts its output to a Godot Y-up interchange document. The
helper is built locally from the SDK sources and is intentionally not checked
in with this generated data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


DEFAULT_SDK = Path(r"D:\SDK\hk2015_1_0\hk2015_1_0_r1")
HERO_RELATIVE = Path("Demo/Demos/Resources/Behavior/GameAssets/Hero")
RIG_RELATIVE = HERO_RELATIVE / "CharacterAssets/Rig.hkt"
CLIPS = {
    "idle": HERO_RELATIVE / "Animations/Idle/Idle_0.hkt",
    "walk": HERO_RELATIVE / "Animations/Walk/Walk_0.hkt",
    "run": HERO_RELATIVE / "Animations/Run/Run_0.hkt",
    "turn": HERO_RELATIVE / "Animations/Idle/Idle_To_Run_90.hkt",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _vector(values: list[float], label: str, count: int) -> list[float]:
    if len(values) < count:
        raise ValueError(f"{label} expected at least {count} components, got {len(values)}")
    return [float(v) for v in values[:count]]


def _hk_vector_to_godot(values: list[float]) -> list[float]:
    """Map Havok's Z-up right-handed basis into Godot's Y-up basis."""
    x, y, z = _vector(values, "translation", 3)
    return [x, z, -y]


def _hk_rotation_to_godot(values: list[float]) -> list[float]:
    """Convert an HK [x,y,z,w] quaternion by basis conjugation."""
    x, y, z, w = _vector(values, "rotation", 4)
    return [x, z, -y, w]


def _hk_scale_to_godot(values: list[float]) -> list[float]:
    x, y, z = _vector(values, "scale", 3)
    return [x, z, y]


def _transform(values: list[float], label: str) -> dict[str, list[float]]:
    """Read [tx,ty,tz,qx,qy,qz,qw,sx,sy,sz] from the native helper."""
    if len(values) < 10:
        raise ValueError(f"{label} expected 10 transform components, got {len(values)}")
    return {
        "translation": _hk_vector_to_godot(values[0:3]),
        "rotation": _hk_rotation_to_godot(values[3:7]),
        "scale": _hk_scale_to_godot(values[7:10]),
    }


def _all_finite(value: Any, path: str = "root") -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError(f"non-finite number at {path}")
    if isinstance(value, dict):
        for key, child in value.items():
            _all_finite(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _all_finite(child, f"{path}[{index}]")


def _sample_times(duration: float, hz: float) -> list[float]:
    if duration <= 0.0:
        raise ValueError(f"clip duration must be positive, got {duration}")
    count = math.ceil(duration * hz)
    values = [min(index / hz, duration) for index in range(count + 1)]
    if values[-1] != duration:
        values.append(duration)
    return values


def _bone_transform(raw: list[float], bone_name: str) -> dict[str, list[float]]:
    return _transform(raw, f"bone {bone_name}")


def normalize_dump(
    raw: dict[str, Any],
    rig_path: Path,
    clip_paths: dict[str, Path],
    sample_hz: float,
    sdk_root: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Normalize the native oracle's single-asset JSON outputs."""
    rig_containers = raw.get("rig", {}).get("containers", [])
    rig_skeleton = next(
        (container.get("skeleton") for container in rig_containers if container.get("skeleton")),
        None,
    )
    if not rig_skeleton:
        raise ValueError("rig oracle output did not contain a skeleton")

    raw_bones = rig_skeleton.get("bones", [])
    if not raw_bones:
        raise ValueError("rig skeleton has no bones")
    bones = []
    for index, bone in enumerate(raw_bones):
        parent = int(bone["parent"])
        if parent < -1 or parent >= len(raw_bones) or parent == index:
            raise ValueError(f"invalid parent index {parent} for bone {index} ({bone.get('name')})")
        bones.append({
            "name": str(bone["name"]),
            "parent": parent,
            "bind": _transform(bone["reference"], f"bind bone {bone['name']}"),
        })
    root_bone = next((index for index, bone in enumerate(bones) if bone["parent"] < 0), 0)

    clips: dict[str, Any] = {}
    oracle_clips: dict[str, Any] = {}
    for clip_name, clip_path in clip_paths.items():
        clip_raw = raw.get("clips", {}).get(clip_name)
        if not clip_raw:
            raise ValueError(f"missing native oracle output for clip {clip_name!r}")
        clip = clip_raw.get("clip")
        if clip is None:
            for container in clip_raw.get("containers", []):
                candidate = next(
                    (item for item in container.get("clips", []) if item.get("name") == clip_name),
                    None,
                )
                if candidate is not None:
                    clip = candidate
                    break
            if clip is None:
                for container in clip_raw.get("containers", []):
                    clip_items = container.get("clips", [])
                    if clip_items:
                        clip = clip_items[0]
                        break
        if not clip:
            raise ValueError(f"clip {clip_name!r} has no animation payload")
        samples = clip.get("source_grid", clip.get("samples", []))
        if not samples:
            raise ValueError(f"clip {clip_name!r} has no sampled poses")
        binding = clip.get("binding", {})
        serialized_track_to_bone = [int(index) for index in binding.get("trackToBoneIndices", [])]
        track_to_bone = serialized_track_to_bone
        if not track_to_bone:
            track_count = int(clip.get("numTransformTracks", 0))
            original_skeleton_name = str(binding.get("originalSkeletonName", ""))
            if original_skeleton_name != str(rig_skeleton.get("name", "")):
                raise ValueError(
                    f"clip {clip_name!r} has an empty identity binding but references skeleton "
                    f"{original_skeleton_name!r}, expected {rig_skeleton.get('name')!r}"
                )
            if track_count <= 0 or track_count > len(bones):
                raise ValueError(
                    f"clip {clip_name!r} has empty binding and invalid transform-track count {track_count}"
                )
            # Havok treats an empty transformTrackToBoneIndices array as an
            # implicit identity map: transform track i drives bone i.
            track_to_bone = list(range(track_count))
        if len(set(track_to_bone)) != len(track_to_bone):
            raise ValueError(f"clip {clip_name!r} binding maps multiple tracks to the same bone")
        if any(index < -1 or index >= len(bones) for index in track_to_bone):
            raise ValueError(f"clip {clip_name!r} binding contains an invalid bone index")

        tracks_by_bone: dict[int, list[dict[str, Any]]] = {index: [] for index in range(len(bones))}
        extracted_motion = []
        def make_pose(sample: dict[str, Any]) -> tuple[dict[int, dict[str, list[float]]], dict[str, list[float]] | None]:
            sample_time = float(sample["time"])
            sample_tracks = sample.get("tracks", [])
            if len(sample_tracks) != len(track_to_bone):
                raise ValueError(
                    f"clip {clip_name!r} sample {sample_time:g}s has {len(sample_tracks)} tracks, "
                    f"binding has {len(track_to_bone)}"
                )
            pose: dict[int, dict[str, list[float]]] = {}
            for track_index, transform in enumerate(sample_tracks):
                bone_index = track_to_bone[track_index]
                if bone_index < 0:
                    continue
                if bone_index >= len(bones):
                    raise ValueError(
                        f"clip {clip_name!r} maps track {track_index} to invalid bone {bone_index}"
                    )
                pose[bone_index] = _bone_transform(transform, bones[bone_index]["name"])
            motion = sample.get("extractedMotion")
            converted_motion = _transform(motion, f"{clip_name} extracted motion") if motion is not None else None
            return pose, converted_motion

        for sample in samples:
            sample_time = float(sample["time"])
            pose, converted_motion = make_pose(sample)
            for bone_index, transform in pose.items():
                tracks_by_bone[bone_index].append({"time": sample_time, **transform})
            if converted_motion is not None:
                extracted_motion.append({"time": sample_time, **converted_motion})

        duration = float(clip["duration"])
        if abs(float(samples[0]["time"])) > 1e-6 or abs(float(samples[-1]["time"]) - duration) > 1e-5:
            raise ValueError(f"clip {clip_name!r} samples must include time 0 and exact duration")
        original_frame_count = int(clip.get("numOriginalFrames") or len(samples))
        if original_frame_count > 1:
            expected = [duration * index / (original_frame_count - 1) for index in range(original_frame_count)]
        else:
            expected = _sample_times(duration, sample_hz)
        sampled_grid = [float(sample["time"]) for sample in samples]
        if len(sampled_grid) != len(expected):
            raise ValueError(
                f"clip {clip_name!r} source grid has {len(sampled_grid)} samples; "
                f"expected exactly {len(expected)} for {original_frame_count} original frames"
            )
        if any(abs(expected_time - sample_time) >= 1e-6 for expected_time, sample_time in zip(expected, sampled_grid)):
            raise ValueError(
                f"clip {clip_name!r} source-grid sample times do not match the ordered original frame grid "
                f"(numOriginalFrames={original_frame_count})"
            )
        key_times = {round(time, 6) for time in sampled_grid}
        if any(round(float(sample["time"]), 6) in key_times for sample in clip.get("holdouts", [])):
            raise ValueError(f"clip {clip_name!r} has a holdout time duplicated in playback keys")

        oracle_times = [samples[0], samples[-1]]
        oracle_times.extend(clip.get("holdouts", []))
        unique_oracle_samples: dict[float, dict[str, Any]] = {}
        for sample in oracle_times:
            pose, converted_motion = make_pose(sample)
            full_pose = [dict(bone["bind"]) for bone in bones]
            for bone_index, transform in pose.items():
                full_pose[bone_index] = transform
            time = float(sample["time"])
            unique_oracle_samples[time] = {
                "time": time,
                "pose": full_pose,
                "root": {
                    "translation": converted_motion["translation"] if converted_motion else [0.0, 0.0, 0.0],
                    "rotation": converted_motion["rotation"] if converted_motion else [0.0, 0.0, 0.0, 1.0],
                },
            }

        clips[clip_name] = {
            "duration": duration,
            "loop": bool(clip.get("loop", clip.get("isLooping", False))),
            "source": {
                "path": clip_path.resolve().relative_to(sdk_root).as_posix(),
                "sha256": sha256(clip_path),
                "format": clip.get("type", "Havok animation"),
                "key_sampling": "SDK-evaluated original frame grid",
                "binding": {
                    "originalSkeletonName": binding.get("originalSkeletonName", ""),
                    "trackToBoneIndices": serialized_track_to_bone,
                    "implicitIdentity": not serialized_track_to_bone,
                },
                "originalFrames": original_frame_count,
                "transformTrackCount": int(clip.get("numTransformTracks", len(track_to_bone))),
                "floatTrackCount": int(clip.get("numFloatTracks", 0)),
            },
            "tracks": [
                {"bone": bone_index, "keys": keys}
                for bone_index, keys in tracks_by_bone.items()
                if keys
            ],
            "root_motion": {
                "bone": root_bone,
                "keys": extracted_motion,
            } if extracted_motion else None,
        }
        oracle_clips[clip_name] = {
            "source_sha256": sha256(clip_path),
            "samples": [unique_oracle_samples[time] for time in sorted(unique_oracle_samples)],
        }

    result = {
        "schema_version": 1,
        "source": {
            "sdk": "Havok 2015.1.0-r1",
            "sdk_root": str(sdk_root),
            "asset_root": HERO_RELATIVE.as_posix(),
            "reference": "Havok SDK 2015.1.0-r1 Demo/Demos/Resources/Behavior/GameAssets/Hero",
            "tool": "hero_oracle",
            "coordinate_conversion": "Havok Z-up right-handed to Godot Y-up: (x,y,z)->(x,z,-y)",
        },
        "skeleton": {
            "source": {"path": RIG_RELATIVE.as_posix(), "sha256": sha256(rig_path)},
            "bones": bones,
        },
        "clips": clips,
    }
    _all_finite(result)
    oracle_result = {"schema_version": 1, "clips": oracle_clips}
    _all_finite(oracle_result)
    return result, oracle_result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, default=DEFAULT_SDK, help="Havok SDK root")
    parser.add_argument("--oracle", type=Path, help="path to the SDK-linked hero_oracle executable")
    parser.add_argument("--output", type=Path, help="output JSON path")
    parser.add_argument("--oracle-output", type=Path, help="SDK oracle sample JSON path (default: alongside motion.json)")
    parser.add_argument("--pretty", action="store_true", help="indent generated JSON for inspection")
    parser.add_argument("--sample-hz", type=float, default=30.0, help="sampling rate used by helper when source frame count is absent")
    parser.add_argument(
        "--clip", action="append", default=[], metavar="ID=RELATIVE_PATH",
        help="add or replace a clip under the Hero asset root; repeatable",
    )
    parser.add_argument("--raw-dir", type=Path, help="keep raw oracle JSON in this directory")
    args = parser.parse_args()

    if args.sample_hz <= 0.0:
        parser.error("--sample-hz must be positive")
    sdk_root = args.sdk.resolve()
    asset_root = sdk_root / HERO_RELATIVE
    rig_path = asset_root / "CharacterAssets/Rig.hkt"
    clip_specs = dict(CLIPS)
    for spec in args.clip:
        if "=" not in spec:
            parser.error(f"invalid --clip {spec!r}; expected ID=RELATIVE_PATH")
        clip_name, relative_text = spec.split("=", 1)
        relative_path = Path(relative_text)
        if not clip_name or relative_path.is_absolute() or ".." in relative_path.parts:
            parser.error(f"--clip path must be relative to Hero and stay inside it: {spec!r}")
        clip_specs[clip_name] = HERO_RELATIVE / relative_path
    clip_paths = {name: sdk_root / relative for name, relative in clip_specs.items()}
    missing_assets = [path for path in [rig_path, *clip_paths.values()] if not path.is_file()]
    if missing_assets:
        parser.error("missing SDK assets: " + ", ".join(str(path) for path in missing_assets))
    oracle = args.oracle or Path(os.environ.get("HERO_ORACLE", ""))
    if not str(oracle) or not oracle.is_file():
        parser.error("pass --oracle or set HERO_ORACLE to the built helper executable")

    output_path = args.output or Path(__file__).resolve().parent / "generated" / "motion.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    raw_dir = args.raw_dir
    temporary = None
    if raw_dir is None:
        temporary = tempfile.TemporaryDirectory(prefix="hero_motion_oracle_")
        raw_dir = Path(temporary.name)
    else:
        raw_dir.mkdir(parents=True, exist_ok=True)

    # The helper emits JSON to stdout and retains the SDK reference pose,
    # per-clip binding, original frame grid, and independent holdout samples.
    paths = {"rig": rig_path, **clip_paths}
    raw: dict[str, Any] = {"rig": {}, "clips": {}}
    for name, asset_path in paths.items():
        command = [str(oracle), str(asset_path), "--grid", "--holdouts"]
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
        if completed.returncode:
            sys.stderr.write(completed.stdout)
            sys.stderr.write(completed.stderr)
            raise SystemExit(f"hero_oracle failed for {asset_path} with exit code {completed.returncode}")
        try:
            parsed = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise SystemExit(f"hero_oracle returned invalid JSON for {asset_path}: {error}") from error
        if args.raw_dir is not None:
            (raw_dir / f"{name}.json").write_text(
                json.dumps(parsed, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
        if name == "rig":
            raw["rig"] = parsed
        else:
            raw["clips"][name] = parsed

    result, oracle_result = normalize_dump(raw, rig_path, clip_paths, args.sample_hz, sdk_root)
    json_options = {"indent": 2} if args.pretty else {"separators": (",", ":")}
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, allow_nan=False, **json_options) + "\n", encoding="utf-8"
    )
    oracle_path = args.oracle_output or output_path.with_name("oracle.json")
    oracle_path.parent.mkdir(parents=True, exist_ok=True)
    oracle_path.write_text(
        json.dumps(oracle_result, ensure_ascii=False, allow_nan=False, **json_options) + "\n", encoding="utf-8"
    )
    print(
        f"Exported {len(result['skeleton']['bones'])} bones and {len(result['clips'])} clips "
        f"to {output_path} and {oracle_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
