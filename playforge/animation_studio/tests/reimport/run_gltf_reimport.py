#!/usr/bin/env python3
"""End-to-end glTF scene reimport check for Animation Studio pose clips."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile


SCRIPT_DIR = Path(__file__).resolve().parent
ANIMATION_STUDIO = SCRIPT_DIR.parents[1]
RUN_INDEX = 0


def _append_aligned(buffer: bytearray, payload: bytes) -> tuple[int, int]:
    while len(buffer) % 4:
        buffer.append(0)
    offset = len(buffer)
    buffer.extend(payload)
    return offset, len(payload)


def _write_fixture(project: Path) -> int:
    binary = bytearray()
    views = []

    def view(payload: bytes, target: int | None = None) -> int:
        offset, length = _append_aligned(binary, payload)
        descriptor = {"buffer": 0, "byteOffset": offset, "byteLength": length}
        if target is not None:
            descriptor["target"] = target
        views.append(descriptor)
        return len(views) - 1

    position_view = view(struct.pack("<9f", -0.5, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 1.0, 0.0), 34962)
    joints_view = view(bytes([0, 0, 0, 0] * 3), 34962)
    weights_view = view(struct.pack("<12f", 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0), 34962)
    indices_view = view(struct.pack("<3H", 0, 1, 2), 34963)
    times_view = view(struct.pack("<2f", 0.0, 1.0))
    translation_view = view(struct.pack("<6f", 0.0, 0.0, 0.0, 2.0, 0.0, 0.0))
    binary_path = project / "fixture.bin"
    binary_path.write_bytes(binary)

    accessors = [
        {"bufferView": position_view, "componentType": 5126, "count": 3, "type": "VEC3", "min": [-0.5, 0.0, 0.0], "max": [0.5, 1.0, 0.0]},
        {"bufferView": joints_view, "componentType": 5121, "count": 3, "type": "VEC4"},
        {"bufferView": weights_view, "componentType": 5126, "count": 3, "type": "VEC4"},
        {"bufferView": indices_view, "componentType": 5123, "count": 3, "type": "SCALAR", "min": [0], "max": [2]},
        {"bufferView": times_view, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0.0], "max": [1.0]},
        {"bufferView": translation_view, "componentType": 5126, "count": 2, "type": "VEC3", "min": [0.0, 0.0, 0.0], "max": [2.0, 0.0, 0.0]},
    ]
    gltf = {
        "asset": {"version": "2.0", "generator": "Animation Studio reimport probe"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {"name": "Root", "children": [1, 4]},
            {"name": "Armature", "children": [2, 3]},
            {"name": "Hand"},
            {"name": "HandOverride"},
            {"name": "SkinnedMesh", "mesh": 0, "skin": 0},
        ],
        "skins": [{"name": "ProbeSkin", "skeleton": 1, "joints": [2, 3]}],
        "meshes": [{"name": "ProbeMesh", "primitives": [{"attributes": {"POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2}, "indices": 3}]}],
        "animations": [{"name": "Move", "samplers": [{"input": 4, "output": 5, "interpolation": "LINEAR"}], "channels": [{"sampler": 0, "target": {"node": 2, "path": "translation"}}]}],
        "buffers": [{"uri": "fixture.bin", "byteLength": len(binary)}],
        "bufferViews": views,
        "accessors": accessors,
    }
    (project / "fixture.gltf").write_text(json.dumps(gltf, separators=(",", ":")), encoding="utf-8")
    return views[translation_view]["byteOffset"] + 12


def _run(godot: str, project: Path, args: list[str], timeout: int, marker: str | None = None) -> str:
    global RUN_INDEX
    RUN_INDEX += 1
    command = [godot, "--headless", "--path", str(project), *args]
    completed = subprocess.run(command, text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=timeout)
    output = (completed.stdout or "") + (completed.stderr or "")
    print(output, end="" if output.endswith("\n") else "\n")
    for line in output.splitlines():
        if "ERROR:" in line or "WARNING:" in line:
            print(f"GODOT_DIAGNOSTIC #{RUN_INDEX} [{ ' '.join(args) }]: {line}")
    if completed.returncode != 0:
        raise RuntimeError(f"Godot exited {completed.returncode}: {' '.join(command)}")
    if "SCRIPT ERROR" in output:
        raise RuntimeError("Godot reported SCRIPT ERROR.")
    if "ERROR:" in output:
        raise RuntimeError("Godot reported ERROR.")
    if marker is not None and marker not in output:
        raise RuntimeError(f"Expected verification marker {marker!r} was absent.")
    return output


def _configure_sidecar_import(import_file: Path) -> None:
    text = import_file.read_text(encoding="utf-8")
    replacement = '_subresources={"animations": {"Move": {"save_to_file/enabled": true, "save_to_file/path": "res://fixture_anim.tres", "save_to_file/keep_custom_tracks": true}}}'
    text = text.replace("_subresources={}", replacement)
    import_file.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN"), help="Godot executable path; defaults to GODOT_BIN.")
    parser.add_argument("--timeout", type=int, default=120, help="Per-process timeout in seconds (default: 120).")
    options = parser.parse_args()
    godot = options.godot or shutil.which("godot") or shutil.which("godot4")
    if not godot:
        parser.error("Pass --godot or set GODOT_BIN to the Godot executable.")

    with tempfile.TemporaryDirectory(prefix="animation-studio-gltf-reimport-") as scratch:
        project = Path(scratch)
        (project / "addons" / "animation_studio").mkdir(parents=True)
        (project / "tests" / "reimport").mkdir(parents=True)
        shutil.copy2(ANIMATION_STUDIO / "addons" / "animation_studio" / "pose_clip.gd", project / "addons" / "animation_studio" / "pose_clip.gd")
        shutil.copy2(SCRIPT_DIR / "verify_gltf_reimport.gd", project / "tests" / "reimport" / "verify_gltf_reimport.gd")
        (project / "project.godot").write_text('config_version=5\n\n[application]\nconfig/name="Animation Studio glTF Reimport Probe"\n', encoding="utf-8")
        translation_endpoint_offset = _write_fixture(project)

        _run(godot, project, ["--script", "res://tests/reimport/verify_gltf_reimport.gd", "--", "seed"], options.timeout, "PASS_SEED:")
        _run(godot, project, ["--editor", "--import"], options.timeout)
        import_file = project / "fixture.gltf.import"
        if not import_file.exists():
            raise RuntimeError("Godot did not create fixture.gltf.import.")
        _configure_sidecar_import(import_file)
        gltf_path = project / "fixture.gltf"
        gltf = json.loads(gltf_path.read_text(encoding="utf-8"))
        gltf["asset"]["generator"] = "Animation Studio sidecar setup"
        gltf_path.write_text(json.dumps(gltf, separators=(",", ":")), encoding="utf-8")
        binary_path = project / "fixture.bin"
        binary = bytearray(binary_path.read_bytes())
        struct.pack_into("<3f", binary, translation_endpoint_offset, 2.25, 0.0, 0.0)
        binary_path.write_bytes(binary)
        _run(godot, project, ["--editor", "--import"], options.timeout)
        sidecar = project / "fixture_anim.tres"
        if not sidecar.exists():
            raise RuntimeError("Scene importer did not save the requested animation sidecar. Import settings:\n" + import_file.read_text(encoding="utf-8"))
        _run(godot, project, ["--script", "res://tests/reimport/verify_gltf_reimport.gd", "--", "prepare"], options.timeout, "PASS_PREPARE:")

        binary = bytearray(binary_path.read_bytes())
        struct.pack_into("<3f", binary, translation_endpoint_offset, 4.0, 0.0, 0.0)
        binary_path.write_bytes(binary)
        gltf = json.loads(gltf_path.read_text(encoding="utf-8"))
        gltf["accessors"][5]["max"] = [4.0, 0.0, 0.0]
        gltf["asset"]["generator"] = "Animation Studio source update"
        gltf_path.write_text(json.dumps(gltf, separators=(",", ":")), encoding="utf-8")
        _run(godot, project, ["--editor", "--import"], options.timeout)

        _run(godot, project, ["--script", "res://tests/reimport/verify_gltf_reimport.gd", "--", "verify"], options.timeout, "PASS_VERIFY:")

    print("PASS: temporary glTF import, custom mapping retention, refreshed sample, source isolation")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
