#!/usr/bin/env python3
"""Offline extractor that builds `extract_havok_env_and_ragdoll.exe` against the
unmodified Havok 2015.1.0-r1 SDK and converts official SDK backgrounds, levels,
skybox, and Soldier ragdoll rig/physics/control palettes into zero-SDK-dependency
Godot 4.7.2 native assets under `playforge/animation_studio/compare/assets/`.

Outputs:
  1. compare/assets/env_hk_anim_level.glb      (hkAnimLevel_VertexColors_np.hkt + 7 PNGs + COLOR_0)
  2. compare/assets/env_attachment_scene.glb   (AttachmentScene_np.hkt meshes + textures)
  3. compare/assets/env_attachment_props.json  (AttachmentScene_np.hkt skull rigid bodies)
  4. compare/assets/havok_default_skybox.png   (stitched from Resources/Common/Graphics/defaultskybox_*.png)
  5. compare/assets/havok_soldier_ragdoll_spec.json (US_Leader_Ragdoll_np.hkt + US_Leader_to_Leader_Pack_2.hkt + 5 behavior .hkt control palettes)
"""

from __future__ import annotations

import io
import json
import math
import os
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

from PIL import Image

try:
    import numpy as np
except ImportError:
    np = None


SDK_ROOT = Path(os.environ.get("HAVOK_SDK_ROOT", r"D:\SDK\hk2015_1_0\hk2015_1_0_r1"))
RESOURCES = SDK_ROOT / "Demo" / "Demos" / "Resources"
SCRIPT_DIR = Path(__file__).resolve().parent
ASSETS_DIR = SCRIPT_DIR / "assets"
BUILD_DIR = Path(os.environ.get("TEMP", r"C:\Temp")) / "codex_havok_env_ragdoll"
EXTRACTOR_CPP = SCRIPT_DIR / "extract_havok_env_and_ragdoll.cpp"

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
    exe_path = BUILD_DIR / "extract_havok_env_and_ragdoll.exe"
    if exe_path.is_file() and exe_path.stat().st_mtime >= EXTRACTOR_CPP.stat().st_mtime and "--rebuild" not in sys.argv:
        print(f"[build] Up-to-date: {exe_path}")
        return exe_path

    lib_dir = SDK_ROOT / "Lib" / "x64_vs2015" / "release"
    vsdev = find_vs_devcmd()
    obj_path = BUILD_DIR / "extract_havok_env_and_ragdoll.obj"
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
    bat = BUILD_DIR / "run_build.cmd"
    bat.write_text(
        f'@echo off\r\ncall "{vsdev}" -arch=x64 -host_arch=x64 >nul\r\ncl @"{rsp_c}" || exit /b 1\r\nlink @"{rsp_l}" || exit /b 2\r\n',
        encoding="utf-8",
    )
    print(f"[build] Compiling {EXTRACTOR_CPP.name} ...")
    res = subprocess.run(["cmd.exe", "/c", str(bat)], capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr, file=sys.stderr)
        raise RuntimeError(f"Extractor compilation failed (exit {res.returncode})")
    print(f"[build] Built {exe_path} ({exe_path.stat().st_size // 1024} KB)")
    return exe_path


def find_texture_file(raw_name: str, search_dirs: list[Path]) -> Path | None:
    if not raw_name:
        return None
    base = Path(raw_name.replace("\\", "/")).name
    stem = Path(base).stem.lower()
    for d in search_dirs:
        if not d.is_dir():
            continue
        direct = d / base
        if direct.is_file():
            return direct
        for p in d.iterdir():
            if p.is_file() and (p.name.lower() == base.lower() or p.stem.lower() == stem):
                if p.suffix.lower() in (".png", ".tga", ".bmp", ".jpg", ".jpeg", ".dds"):
                    return p
    return None


def image_to_png_bytes(path: Path) -> bytes:
    if path.suffix.lower() == ".png":
        return path.read_bytes()
    with Image.open(path) as im:
        buf = io.BytesIO()
        im.convert("RGBA").save(buf, format="PNG")
        return buf.getvalue()


class GlbWriter:
    def __init__(self) -> None:
        self.bin = bytearray()
        self.views: list[dict[str, Any]] = []
        self.accessors: list[dict[str, Any]] = []
        self.images: list[dict[str, Any]] = []
        self.textures: list[dict[str, Any]] = []
        self.materials: list[dict[str, Any]] = []

    def add_view(self, data: bytes, target: int | None = None) -> int:
        while len(self.bin) % 4:
            self.bin.append(0)
        off = len(self.bin)
        self.bin.extend(data)
        bv: dict[str, Any] = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target is not None:
            bv["target"] = target
        self.views.append(bv)
        return len(self.views) - 1

    def add_accessor(
        self,
        data: bytes,
        component_type: int,
        count: int,
        kind: str,
        target: int | None = None,
        bounds: tuple[list[float], list[float]] | None = None,
    ) -> int:
        bv = self.add_view(data, target)
        acc: dict[str, Any] = {
            "bufferView": bv,
            "componentType": component_type,
            "count": count,
            "type": kind,
        }
        if bounds is not None:
            acc["min"] = bounds[0]
            acc["max"] = bounds[1]
        self.accessors.append(acc)
        return len(self.accessors) - 1

    def add_png_texture(self, png_bytes: bytes, name: str) -> int:
        bv = self.add_view(png_bytes)
        img_idx = len(self.images)
        self.images.append({"bufferView": bv, "mimeType": "image/png", "name": name})
        tex_idx = len(self.textures)
        self.textures.append({"source": img_idx, "sampler": 0})
        return tex_idx

    def write_glb(self, doc: dict[str, Any], out_path: Path) -> None:
        while len(self.bin) % 4:
            self.bin.append(0)
        doc["buffers"] = [{"byteLength": len(self.bin)}]
        doc["bufferViews"] = self.views
        doc["accessors"] = self.accessors
        if self.images:
            doc["images"] = self.images
            doc["textures"] = self.textures
            doc["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
        if self.materials:
            doc["materials"] = self.materials

        json_bytes = json.dumps(doc, separators=(",", ":")).encode("utf-8")
        while len(json_bytes) % 4:
            json_bytes += b" "

        total_len = 12 + 8 + len(json_bytes) + 8 + len(self.bin)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total_len))
            f.write(struct.pack("<II", len(json_bytes), 0x4E4F534A))
            f.write(json_bytes)
            f.write(struct.pack("<II", len(self.bin), 0x004E4942))
            f.write(self.bin)


def zup_to_godot_vec3(x: float, y: float, z: float) -> tuple[float, float, float]:
    return (x, z, -y)


def zup_to_godot_quat(qx: float, qy: float, qz: float, qw: float) -> list[float]:
    return [qx, qz, -qy, qw]


def convert_scene_to_glb(
    scene_json_path: Path,
    scene_bin_path: Path,
    out_glb_path: Path,
    tex_search_dirs: list[Path],
    z_up: bool = True,
    flip_v: bool = True,
    force_checker_for_floor: bool = False,
) -> dict[str, Any]:
    meta = json.loads(scene_json_path.read_text(encoding="utf-8"))
    raw_bin = scene_bin_path.read_bytes()

    w = GlbWriter()
    tex_cache: dict[str, int] = {}

    for m_idx, mat in enumerate(meta.get("materials", [])):
        name = mat.get("name", f"mat_{m_idx}")
        diff = mat.get("diffuse", [0.8, 0.8, 0.8, 1.0])
        base_color = [
            float(diff[0]) if diff[0] > 0.001 else 0.85,
            float(diff[1]) if diff[1] > 0.001 else 0.85,
            float(diff[2]) if diff[2] > 0.001 else 0.85,
            float(diff[3]) if len(diff) > 3 and diff[3] > 0.001 else 1.0,
        ]
        # Avoid pure black diffuse if a texture is bound
        tex_idx: int | None = None
        diff_tex = mat.get("diffuse_tex", "")
        if diff_tex:
            tf = find_texture_file(diff_tex, tex_search_dirs)
            if tf is not None:
                key = str(tf).lower()
                if key not in tex_cache:
                    tex_cache[key] = w.add_png_texture(image_to_png_bytes(tf), tf.name)
                tex_idx = tex_cache[key]
        elif mat.get("inplace_len", 0) > 0:
            off = int(mat["inplace_off"])
            ln = int(mat["inplace_len"])
            blob = raw_bin[off : off + ln]
            try:
                with Image.open(io.BytesIO(blob)) as im:
                    buf = io.BytesIO()
                    im.convert("RGBA").save(buf, format="PNG")
                    tex_idx = w.add_png_texture(buf.getvalue(), mat.get("inplace_name", f"inplace_{m_idx}"))
            except Exception as exc:
                print(f"[warn] Could not decode inplace texture on {name}: {exc}")

        if tex_idx is not None:
            # When textured in Havok, diffuse color defaults to white unless deliberately tinted
            if max(diff[:3]) < 0.05:
                base_color = [1.0, 1.0, 1.0, 1.0]
            else:
                base_color = [max(0.75, float(diff[0])), max(0.75, float(diff[1])), max(0.75, float(diff[2])), 1.0]

        pbr: dict[str, Any] = {
            "baseColorFactor": base_color,
            "metallicFactor": 0.0,
            "roughnessFactor": 0.86,
        }
        if tex_idx is not None:
            pbr["baseColorTexture"] = {"index": tex_idx}

        gltf_mat: dict[str, Any] = {
            "name": name,
            "pbrMetallicRoughness": pbr,
            "doubleSided": True,
        }
        w.materials.append(gltf_mat)

    if not w.materials:
        w.materials.append({
            "name": "DefaultHavokMat",
            "pbrMetallicRoughness": {"baseColorFactor": [0.78, 0.78, 0.78, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.88},
            "doubleSided": True,
        })

    # Optional checker texture for AttachmentScene ground plane (tile_diffuse.png) if floor has no texture
    checker_mat_idx: int | None = None
    if force_checker_for_floor:
        tile_png = RESOURCES / "Common" / "Graphics" / "tile_diffuse.png"
        if tile_png.is_file():
            ctex = w.add_png_texture(tile_png.read_bytes(), "tile_diffuse.png")
            checker_mat_idx = len(w.materials)
            w.materials.append({
                "name": "HavokCheckerFloor",
                "pbrMetallicRoughness": {
                    "baseColorFactor": [0.85, 0.85, 0.85, 1.0],
                    "baseColorTexture": {"index": ctex},
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.90,
                },
                "doubleSided": True,
            })

    # Group sections by node name
    by_node: dict[str, list[dict[str, Any]]] = {}
    for sec in meta.get("sections", []):
        by_node.setdefault(sec.get("node", "mesh"), []).append(sec)

    gltf_meshes: list[dict[str, Any]] = []
    gltf_nodes: list[dict[str, Any]] = []
    total_verts = 0
    total_tris = 0

    for node_name, secs in by_node.items():
        prims: list[dict[str, Any]] = []
        for sec in secs:
            nv = int(sec["verts"])
            ni = int(sec["indices"])
            pos_off = int(sec["pos_off"])
            nrm_off = int(sec["nrm_off"])
            uv_off = int(sec["uv_off"])
            col_off = int(sec["col_off"])
            idx_off = int(sec["idx_off"])

            raw_pos = struct.unpack_from(f"<{nv * 3}f", raw_bin, pos_off)
            pos_out = bytearray()
            min_p = [1e30, 1e30, 1e30]
            max_p = [-1e30, -1e30, -1e30]
            for vi in range(nv):
                px, py, pz = raw_pos[vi * 3], raw_pos[vi * 3 + 1], raw_pos[vi * 3 + 2]
                if z_up:
                    px, py, pz = zup_to_godot_vec3(px, py, pz)
                pos_out.extend(struct.pack("<3f", px, py, pz))
                if px < min_p[0]: min_p[0] = px
                if py < min_p[1]: min_p[1] = py
                if pz < min_p[2]: min_p[2] = pz
                if px > max_p[0]: max_p[0] = px
                if py > max_p[1]: max_p[1] = py
                if pz > max_p[2]: max_p[2] = pz

            attrs: dict[str, int] = {
                "POSITION": w.add_accessor(bytes(pos_out), 5126, nv, "VEC3", 34962, (min_p, max_p))
            }

            if sec.get("has_normal"):
                raw_nrm = struct.unpack_from(f"<{nv * 3}f", raw_bin, nrm_off)
                nrm_out = bytearray()
                for vi in range(nv):
                    nx, ny, nz = raw_nrm[vi * 3], raw_nrm[vi * 3 + 1], raw_nrm[vi * 3 + 2]
                    if z_up:
                        nx, ny, nz = zup_to_godot_vec3(nx, ny, nz)
                    ln = math.sqrt(nx * nx + ny * ny + nz * nz)
                    if ln > 1e-6:
                        nx /= ln; ny /= ln; nz /= ln
                    else:
                        nx, ny, nz = 0.0, 1.0, 0.0
                    nrm_out.extend(struct.pack("<3f", nx, ny, nz))
                attrs["NORMAL"] = w.add_accessor(bytes(nrm_out), 5126, nv, "VEC3", 34962)

            if sec.get("has_uv"):
                raw_uv = struct.unpack_from(f"<{nv * 2}f", raw_bin, uv_off)
                uv_out = bytearray()
                for vi in range(nv):
                    u = raw_uv[vi * 2]
                    v = (1.0 - raw_uv[vi * 2 + 1]) if flip_v else raw_uv[vi * 2 + 1]
                    uv_out.extend(struct.pack("<2f", u, v))
                attrs["TEXCOORD_0"] = w.add_accessor(bytes(uv_out), 5126, nv, "VEC2", 34962)

            if sec.get("has_color"):
                raw_col = struct.unpack_from(f"<{nv * 4}f", raw_bin, col_off)
                # Ensure vertex colors aren't pure zero (which would black out textured meshes)
                c_max = max(raw_col) if raw_col else 0.0
                if c_max > 0.05:
                    col_out = bytearray()
                    for vi in range(nv):
                        r, g, b, a = raw_col[vi * 4 : vi * 4 + 4]
                        # Gentle gamma lift so vertex-lit dungeon rooms match Havok DX11 readability
                        col_out.extend(struct.pack("<4f", min(1.0, r), min(1.0, g), min(1.0, b), 1.0))
                    attrs["COLOR_0"] = w.add_accessor(bytes(col_out), 5126, nv, "VEC4", 34962)

            raw_idx = raw_bin[idx_off : idx_off + ni * 4]
            idx_acc = w.add_accessor(raw_idx, 5125, ni, "SCALAR", 34963)

            m_idx = int(sec.get("material", 0))
            if m_idx < 0 or m_idx >= len(w.materials):
                m_idx = 0
            if checker_mat_idx is not None and ("ground" in node_name.lower() or "floor" in node_name.lower() or "plane" in node_name.lower() or "box01" in node_name.lower()):
                if "baseColorTexture" not in w.materials[m_idx]["pbrMetallicRoughness"]:
                    m_idx = checker_mat_idx

            prims.append({"attributes": attrs, "indices": idx_acc, "material": m_idx, "mode": 4})
            total_verts += nv
            total_tris += ni // 3

        if prims:
            mesh_idx = len(gltf_meshes)
            gltf_meshes.append({"name": node_name, "primitives": prims})
            gltf_nodes.append({"name": node_name, "mesh": mesh_idx})

    doc = {
        "asset": {"version": "2.0", "generator": "PlayForge Havok 2015.1.0-r1 Official Environment Extractor"},
        "scene": 0,
        "scenes": [{"name": out_glb_path.stem, "nodes": list(range(len(gltf_nodes)))}],
        "nodes": gltf_nodes,
        "meshes": gltf_meshes,
    }
    w.write_glb(doc, out_glb_path)
    print(f"[glb] Wrote {out_glb_path.name}: {len(gltf_nodes)} meshes, {total_verts} verts, {total_tris} tris, {len(w.images)} embedded textures ({out_glb_path.stat().st_size // 1024} KB)")
    return meta


def stitch_havok_skybox(out_png: Path, width: int = 1024, height: int = 512) -> None:
    """Stitches Havok's official 6-face defaultskybox PNGs into a seam-free
    equirectangular PanoramaSkyMaterial texture by verifying edge continuity
    across all 12 cube edges (matching hkgSkyBox face orientation in DX11)."""
    gdir = RESOURCES / "Common" / "Graphics"
    faces_raw: dict[str, Any] = {}
    for suffix in ("UP", "DN", "LF", "RT", "FR", "BK"):
        p = gdir / f"defaultskybox_{suffix}.png"
        if not p.is_file():
            raise FileNotFoundError(f"Missing Havok skybox face: {p}")
        with Image.open(p) as im:
            faces_raw[suffix] = np.asarray(im.convert("RGB"), dtype=np.float32) if np is not None else im.convert("RGB")

    if np is None:
        raise RuntimeError("numpy is required for seam-verified skybox stitching")

    # Helper to apply any of the 8 dihedral transforms (rot90 k=0..3 + optional fliplr)
    def xform(img: Any, tid: int) -> Any:
        res = np.rot90(img, tid % 4)
        if tid >= 4:
            res = np.fliplr(res)
        return res

    # Standard cube face coordinate frame (each face in [0..N-1, 0..N-1] with row=0 top, col=0 left):
    #   FR (-Z): right=+X, down=-Y
    #   RT (+X): right=+Z, down=-Y  (left edge meets FR right edge)
    #   BK (+Z): right=-X, down=-Y  (left edge meets RT right edge)
    #   LF (-X): right=-Z, down=-Y  (left edge meets BK right edge, right edge meets FR left edge)
    #   UP (+Y): right=+X, down=-Z  (bottom edge meets FR top edge)
    #   DN (-Y): right=+X, down=+Z  (top edge meets FR bottom edge)
    def edge_err(a: Any, b: Any) -> float:
        return float(np.mean((a - b) ** 2))

    # Fix FR in identity orientation (we visually verified FR has bright top, dark bottom, purple left, green right)
    F_fr = faces_raw["FR"]

    # Find best dihedral transform for each other face minimizing shared edge MSE against already-placed faces
    best_rt = min(range(8), key=lambda k: edge_err(xform(faces_raw["RT"], k)[:, 0], F_fr[:, -1]))
    F_rt = xform(faces_raw["RT"], best_rt)
    best_lf = min(range(8), key=lambda k: edge_err(xform(faces_raw["LF"], k)[:, -1], F_fr[:, 0]))
    F_lf = xform(faces_raw["LF"], best_lf)
    best_bk = min(
        range(8),
        key=lambda k: edge_err(xform(faces_raw["BK"], k)[:, 0], F_rt[:, -1])
        + edge_err(xform(faces_raw["BK"], k)[:, -1], F_lf[:, 0]),
    )
    F_bk = xform(faces_raw["BK"], best_bk)

    best_up = min(
        range(8),
        key=lambda k: edge_err(xform(faces_raw["UP"], k)[-1, :], F_fr[0, :])
        + edge_err(xform(faces_raw["UP"], k)[:, -1], F_rt[0, ::-1])
        + edge_err(xform(faces_raw["UP"], k)[0, :], F_bk[0, ::-1])
        + edge_err(xform(faces_raw["UP"], k)[:, 0], F_lf[0, :]),
    )
    F_up = xform(faces_raw["UP"], best_up)

    best_dn = min(
        range(8),
        key=lambda k: edge_err(xform(faces_raw["DN"], k)[0, :], F_fr[-1, :])
        + edge_err(xform(faces_raw["DN"], k)[:, -1], F_rt[-1, :])
        + edge_err(xform(faces_raw["DN"], k)[-1, :], F_bk[-1, ::-1])
        + edge_err(xform(faces_raw["DN"], k)[:, 0], F_lf[-1, ::-1]),
    )
    F_dn = xform(faces_raw["DN"], best_dn)

    # Verify total 12-edge MSE
    seam_mse = (
        edge_err(F_rt[:, 0], F_fr[:, -1])
        + edge_err(F_bk[:, 0], F_rt[:, -1])
        + edge_err(F_lf[:, 0], F_bk[:, -1])
        + edge_err(F_fr[:, 0], F_lf[:, -1])
        + edge_err(F_up[-1, :], F_fr[0, :])
        + edge_err(F_up[:, -1], F_rt[0, ::-1])
        + edge_err(F_up[0, :], F_bk[0, ::-1])
        + edge_err(F_up[:, 0], F_lf[0, :])
        + edge_err(F_dn[0, :], F_fr[-1, :])
        + edge_err(F_dn[:, -1], F_rt[-1, :])
        + edge_err(F_dn[-1, :], F_bk[-1, ::-1])
        + edge_err(F_dn[:, 0], F_lf[-1, ::-1])
    ) / 12.0
    print(f"[skybox] Solved face orientations (RT={best_rt}, LF={best_lf}, BK={best_bk}, UP={best_up}, DN={best_dn}), 12-edge avg MSE={seam_mse:.2f}")

    arr = {"FR": F_fr, "RT": F_rt, "BK": F_bk, "LF": F_lf, "UP": F_up, "DN": F_dn}
    h_f, w_f, _ = F_fr.shape

    us = (np.arange(width, dtype=np.float32) + 0.5) / float(width)
    vs = (np.arange(height, dtype=np.float32) + 0.5) / float(height)
    u_grid, v_grid = np.meshgrid(us, vs)
    phi = (u_grid - 0.5) * (2.0 * math.pi)
    theta = v_grid * math.pi

    sin_t = np.sin(theta)
    dx = sin_t * np.sin(phi)
    dy = np.cos(theta)
    dz = -sin_t * np.cos(phi)

    ax, ay, az = np.abs(dx), np.abs(dy), np.abs(dz)
    out = np.zeros((height, width, 3), dtype=np.float32)

    def sample_face(face_arr: Any, mask: Any, uc: Any, vc: Any) -> None:
        if not np.any(mask):
            return
        u_px = np.clip((uc[mask] * 0.5 + 0.5) * (w_f - 1), 0.0, w_f - 1.001)
        v_px = np.clip((vc[mask] * 0.5 + 0.5) * (h_f - 1), 0.0, h_f - 1.001)
        x0 = u_px.astype(np.int32)
        y0 = v_px.astype(np.int32)
        x1 = np.minimum(x0 + 1, w_f - 1)
        y1 = np.minimum(y0 + 1, h_f - 1)
        fx = (u_px - x0)[:, None]
        fy = (v_px - y0)[:, None]
        c00 = face_arr[y0, x0]
        c10 = face_arr[y0, x1]
        c01 = face_arr[y1, x0]
        c11 = face_arr[y1, x1]
        out[mask] = (c00 * (1 - fx) + c10 * fx) * (1 - fy) + (c01 * (1 - fx) + c11 * fx) * fy

    m_rt = (ax >= ay) & (ax >= az) & (dx >= 0)
    m_lf = (ax >= ay) & (ax >= az) & (dx < 0)
    m_up = (ay > ax) & (ay >= az) & (dy >= 0)
    m_dn = (ay > ax) & (ay >= az) & (dy < 0)
    m_fr = (az > ax) & (az > ay) & (dz < 0)
    m_bk = (az > ax) & (az > ay) & (dz >= 0)

    # Consistent with the 6-face orientation frame solved above:
    # FR (-Z): u=+x/az, v=-y/az
    # RT (+X): u=+z/ax, v=-y/ax
    # BK (+Z): u=-x/az, v=-y/az
    # LF (-X): u=-z/ax, v=-y/ax
    # UP (+Y): u=+x/ay, v=-z/ay  (so v=+1 -> z=-ay matches FR top edge v=-1!)
    # DN (-Y): u=+x/ay, v=+z/ay  (so v=-1 -> z=-ay matches FR bottom edge v=+1!)
    sample_face(arr["FR"], m_fr, dx / np.maximum(az, 1e-6), -dy / np.maximum(az, 1e-6))
    sample_face(arr["RT"], m_rt, dz / np.maximum(ax, 1e-6), -dy / np.maximum(ax, 1e-6))
    sample_face(arr["BK"], m_bk, -dx / np.maximum(az, 1e-6), -dy / np.maximum(az, 1e-6))
    sample_face(arr["LF"], m_lf, -dz / np.maximum(ax, 1e-6), -dy / np.maximum(ax, 1e-6))
    sample_face(arr["UP"], m_up, dx / np.maximum(ay, 1e-6), -dz / np.maximum(ay, 1e-6))
    sample_face(arr["DN"], m_dn, dx / np.maximum(ay, 1e-6), dz / np.maximum(ay, 1e-6))

    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), mode="RGB")
    out_png.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_png, format="PNG")
    print(f"[skybox] Wrote {out_png.name} ({width}x{height}, {out_png.stat().st_size // 1024} KB)")


def export_attachment_props(scene_meta: dict[str, Any], out_json: Path) -> None:
    """Writes Havok Z-up -> Godot Y-up converted dynamic props (skulls, crates) from AttachmentScene_np.hkt."""
    bodies_out = []
    for b in scene_meta.get("physics_bodies", []):
        p = b.get("position", [0.0, 0.0, 0.0])
        q = b.get("orientation", [0.0, 0.0, 0.0, 1.0])
        gp = list(zup_to_godot_vec3(float(p[0]), float(p[1]), float(p[2])))
        gq = zup_to_godot_quat(float(q[0]), float(q[1]), float(q[2]), float(q[3]))
        shape = b.get("shape")
        shape_g = None
        if isinstance(shape, dict):
            a0 = shape.get("aabb_min", [0, 0, 0])
            a1 = shape.get("aabb_max", [0, 0, 0])
            ext = [abs(a1[0] - a0[0]), abs(a1[2] - a0[2]), abs(a1[1] - a0[1])]
            shape_g = {
                "type": shape.get("type", "OTHER"),
                "extents_godot": [round(e, 5) for e in ext],
                "convex_radius": shape.get("convex_radius", 0.0),
            }
            if "sphere_radius" in shape:
                shape_g["sphere_radius"] = shape["sphere_radius"]
        bodies_out.append({
            "index": b.get("index", 0),
            "name": b.get("name", ""),
            "motion_type": b.get("motion_type", "STATIC"),
            "mass": b.get("mass", 0.0),
            "position_godot": [round(v, 5) for v in gp],
            "orientation_godot": [round(v, 6) for v in gq],
            "shape": shape_g,
        })
    doc = {
        "schema": "havok-attachment-scene-props-v1",
        "source": "Resources/Behavior/GameAssets/Terrain/AttachmentScene_np.hkt",
        "contains_sdk_hkt_runtime_dep": False,
        "bodies": bodies_out,
    }
    out_json.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    print(f"[props] Wrote {out_json.name} ({len(bodies_out)} physics bodies)")


def main() -> int:
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    exe = build_extractor()

    # 1. Official Havok Default Skybox
    stitch_havok_skybox(ASSETS_DIR / "havok_default_skybox.png", 1024, 512)

    # 2. Official hkAnimLevel_VertexColors_np.hkt (used by #04..#07 CharacterControllerDriver & #08..#10 FootIkDriver)
    lvl_dir = RESOURCES / "Animation" / "ShowCase" / "Level"
    lvl_hkt = lvl_dir / "hkAnimLevel_VertexColors_np.hkt"
    lvl_json = BUILD_DIR / "hkAnimLevel.json"
    lvl_bin = BUILD_DIR / "hkAnimLevel.bin"
    subprocess.run([str(exe), "--scene", str(lvl_hkt), str(lvl_json), str(lvl_bin)], check=True)
    convert_scene_to_glb(
        lvl_json,
        lvl_bin,
        ASSETS_DIR / "env_hk_anim_level.glb",
        [lvl_dir, RESOURCES / "Common" / "Graphics"],
        z_up=True,
        flip_v=True,
    )

    # 3. Official AttachmentScene_np.hkt (used by #19 Keyframe Attachments, #20 Ragdoll Attachments, #45/#46 SymbolLinking)
    att_dir = RESOURCES / "Behavior" / "GameAssets" / "Terrain"
    att_hkt = att_dir / "AttachmentScene_np.hkt"
    att_json = BUILD_DIR / "AttachmentScene.json"
    att_bin = BUILD_DIR / "AttachmentScene.bin"
    subprocess.run([str(exe), "--scene", str(att_hkt), str(att_json), str(att_bin)], check=True)
    att_meta = convert_scene_to_glb(
        att_json,
        att_bin,
        ASSETS_DIR / "env_attachment_scene.glb",
        [att_dir, RESOURCES / "Common" / "Graphics"],
        z_up=True,
        flip_v=True,
        force_checker_for_floor=True,
    )
    export_attachment_props(att_meta, ASSETS_DIR / "env_attachment_props.json")

    # 4. Official Soldier Ragdoll + SkeletonMapper + All 5 Ragdoll Behavior Control Palettes
    sol_char = RESOURCES / "Behavior" / "GameAssets" / "Soldier" / "CharacterAssets"
    sol_beh = RESOURCES / "Behavior" / "GameAssets" / "Soldier" / "Behaviors"
    rag_hkt = sol_char / "US_Leader_Ragdoll_np.hkt"
    map_hkt = sol_char / "US_Leader_to_Leader_Pack_2.hkt"
    beh_list = [
        sol_beh / "ControlPalettes.hkt",
        sol_beh / "MultipleControllers.hkt",
        sol_beh / "Stagger.hkt",
        sol_beh / "CharacterWithRagdollAttachments.hkt",
        sol_beh / "AnimationTest.hkt",
    ]
    rag_out = ASSETS_DIR / "havok_soldier_ragdoll_spec.json"
    subprocess.run(
        [str(exe), "--ragdoll", str(rag_hkt), str(map_hkt), str(rag_out), *[str(b) for b in beh_list]],
        check=True,
    )
    print(f"[ragdoll] Spec ready: {rag_out.name} ({rag_out.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
