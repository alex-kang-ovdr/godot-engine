#!/usr/bin/env python3
"""P2 Additional Official Havok 2015.1.0-r1 SDK Asset Extractor (Offline -> Zero-SDK Godot Native).
Reuses `extract_havok_env_and_ragdoll.exe` and GLB/skybox pipelines from `export_env_and_ragdoll.py`
to internalize additional official SDK environments, props, ragdoll physics rigs, and skyboxes:

  Environments / Props (GLB):
    1. compare/assets/env_hk_gdc_level.glb      (ShowCase/Gdc2005/Level/hkGdcLevel_VertexColors.hkt)
    2. compare/assets/env_ninja_environment.glb (Behavior/GameAssets/Ninja/Terrains/NinjaEnvironment.hkt)
    3. compare/assets/env_hand_ik_door.glb      (Behavior/GameAssets/HandIk/CharacterAssets/door_rig_np.hkt)
    4. compare/assets/env_climbing_wall.glb     (Behavior/GameAssets/HeroBodyIk/Terrain/EnvironmentClimbingWall_v2_np.hkt)
    5. compare/assets/env_teapot.glb            (Animation/Teapot/teapot.hkt)

  Additional Ragdoll Physics Specs (JSON):
    6. compare/assets/ragdoll_firefighter_spec.json  (Animation/NpRagdoll/Firefighter_Rig.hkt)
    7. compare/assets/ragdoll_ninja_spec.json        (Behavior/GameAssets/Ninja/CharacterAssets/Ninja_ragdoll_np.hkt)
    8. compare/assets/ragdoll_orc_captain_spec.json  (Behavior/GameAssets/Orcs/Captain/CharacterAssets/CaptainRagdoll_np.hkt)
    9. compare/assets/ragdoll_havok_girl_spec.json   (Animation/NpRagdoll/havokgirl_ragdoll.hkt)

  Additional Official SDK Skyboxes (Equirectangular PNGs):
   10. compare/assets/skyboxes/sky_boardwalk.png
   11. compare/assets/skyboxes/sky_clouds.png
   12. compare/assets/skyboxes/sky_duskfair.png
   13. compare/assets/skyboxes/sky_sincity.png
   14. compare/assets/skyboxes/sky_skynin.png
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import export_env_and_ragdoll as base_exp  # noqa: E402

RESOURCES = base_exp.RESOURCES
ASSETS_DIR = base_exp.ASSETS_DIR
BUILD_DIR = base_exp.BUILD_DIR


def stitch_skybox_prefix(sky_dir: Path, prefix: str, out_png: Path) -> bool:
    """Stitch official Havok 6-face cubemap (`<prefix>_{UP,DN,LF,RT,FR,BK}.png`) into 2:1 equirectangular PNG."""
    from PIL import Image
    import math
    import numpy as np

    faces = {}
    for code in ("UP", "DN", "LF", "RT", "FR", "BK"):
        cand = sky_dir / f"{prefix}_{code}.png"
        if not cand.is_file():
            # Case-insensitive fallback
            hits = [p for p in sky_dir.glob("*.png") if p.name.lower() == f"{prefix}_{code}.png".lower()]
            if hits:
                cand = hits[0]
            else:
                # Single-face uniform skyboxes in SDK (e.g. SkyboxEmptySpace only ships _FR.png)
                fr_fallback = sky_dir / f"{prefix}_FR.png"
                if fr_fallback.is_file():
                    cand = fr_fallback
                else:
                    print(f"  [SKIP skybox] Missing {cand.name}")
                    return False
        faces[code] = np.asarray(Image.open(cand).convert("RGB"), dtype=np.float32)

    out_w, out_h = 1024, 512
    u = (np.arange(out_w, dtype=np.float32) + 0.5) / out_w
    v = (np.arange(out_h, dtype=np.float32) + 0.5) / out_h
    lon = (u * 2.0 - 1.0) * math.pi
    lat = (0.5 - v) * math.pi
    cos_lat = np.cos(lat)[:, None]
    sin_lat = np.sin(lat)[:, None]
    dx = cos_lat * np.sin(lon)[None, :]
    dy = np.broadcast_to(sin_lat, (out_h, out_w))
    dz = cos_lat * np.cos(lon)[None, :]

    ax, ay, az = np.abs(dx), np.abs(dy), np.abs(dz)
    out = np.zeros((out_h, out_w, 3), dtype=np.float32)

    def sample(img: np.ndarray, su: np.ndarray, sv: np.ndarray) -> np.ndarray:
        h, w = img.shape[:2]
        x = np.clip((su * 0.5 + 0.5) * (w - 1), 0, w - 1)
        y = np.clip((sv * 0.5 + 0.5) * (h - 1), 0, h - 1)
        x0 = np.floor(x).astype(np.int32)
        y0 = np.floor(y).astype(np.int32)
        x1 = np.minimum(x0 + 1, w - 1)
        y1 = np.minimum(y0 + 1, h - 1)
        fx = (x - x0)[..., None]
        fy = (y - y0)[..., None]
        c00 = img[y0, x0]
        c10 = img[y0, x1]
        c01 = img[y1, x0]
        c11 = img[y1, x1]
        return (c00 * (1 - fx) + c10 * fx) * (1 - fy) + (c01 * (1 - fx) + c11 * fx) * fy

    # Use same Havok cubemap face orientation verified in export_env_and_ragdoll.py
    masks = [
        ("FR", (az >= ax) & (az >= ay) & (dz > 0), lambda: (dx / az, -dy / az)),
        ("BK", (az >= ax) & (az >= ay) & (dz <= 0), lambda: (-dx / az, -dy / az)),
        ("RT", (ax > az) & (ax >= ay) & (dx > 0), lambda: (-dz / ax, -dy / ax)),
        ("LF", (ax > az) & (ax >= ay) & (dx <= 0), lambda: (dz / ax, -dy / ax)),
        ("UP", (ay > ax) & (ay > az) & (dy > 0), lambda: (dx / ay, dz / ay)),
        ("DN", (ay > ax) & (ay > az) & (dy <= 0), lambda: (dx / ay, -dz / ay)),
    ]
    for code, m, uv_fn in masks:
        if not np.any(m):
            continue
        su, sv = uv_fn()
        out[m] = sample(faces[code], su[m], sv[m])

    out_png.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(out_png, optimize=True)
    print(f"  [OK skybox] {out_png.name} ({out_png.stat().st_size / 1024:.1f} KB)")
    return True


def export_scene_glb(exe: Path, rel_hkt: str, out_glb: Path, tex_dirs: list[Path], zup_to_yup: bool = True) -> bool:
    hkt = RESOURCES / rel_hkt
    if not hkt.is_file():
        print(f"  [SKIP scene] Not found: {hkt}")
        return False
    slug = out_glb.stem
    raw_json = BUILD_DIR / f"{slug}_raw.json"
    raw_bin = BUILD_DIR / f"{slug}_raw.bin"
    try:
        subprocess.check_call([str(exe), "--scene", str(hkt), str(raw_json), str(raw_bin)])
        scene_dict = json.loads(raw_json.read_text(encoding="utf-8"))
        n_sections = len(scene_dict.get("sections", []))
        if n_sections == 0:
            print(f"  [SKIP scene] {rel_hkt}: 0 sections (physics_bodies={len(scene_dict.get('physics_bodies', []))})")
            return False
        base_exp.convert_scene_to_glb(raw_json, raw_bin, out_glb, tex_dirs, z_up=zup_to_yup)
        print(f"  [OK scene] {out_glb.name} ({out_glb.stat().st_size / 1024:.1f} KB, sections={n_sections})")
        return True
    except Exception as exc:
        print(f"  [WARN scene] Failed {rel_hkt}: {exc}")
        return False


def export_ragdoll_spec(exe: Path, rag_rel: str, map_rel: str, out_json: Path, beh_rels: list[str]) -> bool:
    rag_p = RESOURCES / rag_rel
    map_p = RESOURCES / map_rel if map_rel else rag_p
    if not rag_p.is_file():
        print(f"  [SKIP ragdoll] Not found: {rag_p}")
        return False
    if not map_p.is_file():
        map_p = rag_p
    cmd = [str(exe), "--ragdoll", str(rag_p), str(map_p), str(out_json)]
    for br in beh_rels:
        bp = RESOURCES / br
        if bp.is_file():
            cmd.append(str(bp))
    try:
        subprocess.check_call(cmd)
        spec = json.loads(out_json.read_text(encoding="utf-8"))
        print(f"  [OK ragdoll] {out_json.name} ({out_json.stat().st_size / 1024:.1f} KB, "
              f"bones={spec['bone_count']}, bodies={spec['body_count']}, constraints={spec['constraint_count']})")
        return True
    except Exception as exc:
        print(f"  [WARN ragdoll] Failed {rag_rel}: {exc}")
        return False


def main() -> int:
    exe = base_exp.build_extractor()
    summary = {"scenes": [], "ragdolls": [], "skyboxes": []}

    print("\n=== 1. Extracting Additional Official SDK Environments & Props (GLB) ===")
    scene_jobs = [
        ("Animation/ShowCase/Gdc2005/Level/hkGdcLevel_VertexColors.hkt", ASSETS_DIR / "env_hk_gdc_level.glb",
         [RESOURCES / "Animation/ShowCase/Gdc2005/Level", RESOURCES / "Animation/ShowCase/Level", RESOURCES / "Behavior/GameAssets/HandIk/Terrain"]),
        ("Behavior/GameAssets/Ninja/Terrains/NinjaEnvironment.hkt", ASSETS_DIR / "env_ninja_environment.glb",
         [RESOURCES / "Behavior/GameAssets/Ninja/Terrains", RESOURCES / "Behavior/GameAssets/Ninja"]),
        ("Behavior/GameAssets/HeroBodyIk/Terrain/EnvironmentClimbingWall_v2_np.hkt", ASSETS_DIR / "env_climbing_wall.glb",
         [RESOURCES / "Behavior/GameAssets/HeroBodyIk/Terrain", RESOURCES / "Behavior/GameAssets/Hero/Terrain"]),
        ("Animation/CharacterFootIk/hkFootIkTestRunway.hkt", ASSETS_DIR / "env_foot_ik_runway.glb",
         [RESOURCES / "Animation/CharacterFootIk"]),
        ("Animation/ShowCase/Level/hkAnimSeesaw.hkt", ASSETS_DIR / "env_anim_seesaw.glb",
         [RESOURCES / "Animation/ShowCase/Level"]),
        ("Animation/ShowCase/Objects/hkAnimBricks.hkt", ASSETS_DIR / "env_anim_bricks.glb",
         [RESOURCES / "Animation/ShowCase/Objects"]),
        ("Behavior/GameAssets/Orcs/Terrain/Grid.hkt", ASSETS_DIR / "env_orcs_grid.glb",
         [RESOURCES / "Behavior/GameAssets/Orcs/Terrain"]),
        ("Animation/Penetration/penetration_landscape_np.hkt", ASSETS_DIR / "env_penetration_landscape.glb",
         [RESOURCES / "Animation/Penetration"]),
        # Remaining SDK models & props (Godot Y-up, -Z forward standard; legacy Physics2012-only files SPEC_OUT)
        ("Behavior/GameAssets/Locomotion/CharacterAssets/Boar_Rig_Final.HKT", ASSETS_DIR / "prop_boar_rig.glb",
         [RESOURCES / "Behavior/GameAssets/Locomotion/CharacterAssets", RESOURCES / "Behavior/GameAssets/Locomotion"]),
        ("Animation/Penetration/penetration_rig_np.hkt", ASSETS_DIR / "prop_penetration_rig.glb",
         [RESOURCES / "Animation/Penetration"]),
        ("Behavior/GameAssets/HeroBodyIk/CharacterAssets/SwordfightTargetDummy_v1.hkt", ASSETS_DIR / "prop_swordfight_dummy.glb",
         [RESOURCES / "Behavior/GameAssets/HeroBodyIk/CharacterAssets"]),
        ("Common/Geometries/teapot.hkt", ASSETS_DIR / "prop_teapot.glb",
         [RESOURCES / "Common/Geometries", RESOURCES / "Animation/Teapot"]),
    ]
    for rel, out_glb, tdirs in scene_jobs:
        if export_scene_glb(exe, rel, out_glb, tdirs, zup_to_yup=True):
            summary["scenes"].append(out_glb.name)

    # Door rig physics-only asset (0 hkxMesh sections; extract non-Physics2012 _np physics spec!)
    door_hkt = RESOURCES / "Behavior/GameAssets/HandIk/CharacterAssets/door_rig_np.hkt"
    door_spec_out = ASSETS_DIR / "prop_door_rig_spec.json"
    if door_hkt.is_file():
        door_raw_json = BUILD_DIR / "prop_door_rig_raw.json"
        door_raw_bin = BUILD_DIR / "prop_door_rig_raw.bin"
        try:
            subprocess.check_call([str(exe), "--scene", str(door_hkt), str(door_raw_json), str(door_raw_bin)])
            door_scene = json.loads(door_raw_json.read_text(encoding="utf-8"))
            # Convert Z-up physics body origins to Godot Y-up (x, z, -y)
            bodies_godot = []
            for b in door_scene.get("physics_bodies", []):
                p = b.get("pos", [0.0, 0.0, 0.0])
                q = b.get("rot", [0.0, 0.0, 0.0, 1.0])
                bodies_godot.append({
                    **b,
                    "pos_godot": [float(p[0]), float(p[2]), -float(p[1])],
                    "rot_godot": [float(q[0]), float(q[2]), -float(q[1]), float(q[3])],
                })
            door_spec_out.write_text(json.dumps({
                "schema": "havok-door-rig-spec-v1",
                "axis_standard": "godot_y_up_neg_z_forward",
                "physics2012_policy": "SPEC_OUT",
                "body_count": len(bodies_godot),
                "bodies": bodies_godot,
            }, indent=2), encoding="utf-8")
            summary.setdefault("props_specs", []).append(door_spec_out.name)
            print(f"  [OK door_spec] {door_spec_out.name} (bodies={len(bodies_godot)})")
        except Exception as exc:
            print(f"  [WARN door_spec] {exc}")

    print("\n=== 2. Extracting Additional Official SDK Ragdoll Physics Specs (Non-Physics2012 JSON) ===")
    ragdoll_jobs = [
        ("Animation/NpRagdoll/Firefighter_Rig.hkt", "Animation/NpRagdoll/Firefighter_Rig.hkt",
         ASSETS_DIR / "ragdoll_firefighter_spec.json", []),
        ("Behavior/GameAssets/Ninja/CharacterAssets/Ninja_ragdoll_np.hkt", "Behavior/GameAssets/Ninja/CharacterAssets/Ninja_ragdoll_np.hkt",
         ASSETS_DIR / "ragdoll_ninja_spec.json", []),
        ("Behavior/GameAssets/Orcs/Captain/CharacterAssets/CaptainRagdoll_np.hkt", "Behavior/GameAssets/Orcs/Captain/CharacterAssets/CaptainRagdoll_np.hkt",
         ASSETS_DIR / "ragdoll_orc_captain_spec.json", []),
        ("Animation/NpRagdoll/havokgirl_ragdoll.hkt", "Animation/NpRagdoll/havokgirl_ragdoll.hkt",
         ASSETS_DIR / "ragdoll_havok_girl_spec.json", []),
        ("Animation/NpRagdoll/highres_ragdoll.hkt", "Animation/NpRagdoll/highres_ragdoll.hkt",
         ASSETS_DIR / "ragdoll_highres_spec.json", []),
        ("Animation/NpRagdoll/zombie_dismemberment_ragdoll.hkt", "Animation/NpRagdoll/zombie_dismemberment_ragdoll.hkt",
         ASSETS_DIR / "ragdoll_zombie_spec.json", []),
        ("Behavior/GameAssets/Orcs/Troll/CharacterAssets/TrollRagdoll_np.hkt", "Behavior/GameAssets/Orcs/Troll/CharacterAssets/TrollRagdoll_np.hkt",
         ASSETS_DIR / "ragdoll_orc_troll_spec.json", []),
        ("Animation/Ragdoll/dismemberment_ragdoll_np.hkt", "Animation/Ragdoll/dismemberment_ragdoll_np.hkt",
         ASSETS_DIR / "ragdoll_dismemberment_spec.json", []),
    ]
    for rag_rel, map_rel, out_json, behs in ragdoll_jobs:
        if export_ragdoll_spec(exe, rag_rel, map_rel, out_json, behs):
            summary["ragdolls"].append(out_json.name)

    print("\n=== 3. Stitching ALL Official SDK Skyboxes (13/13 PNG) ===")
    sky_root = RESOURCES / "Common/Graphics/Skybox"
    sky_out = ASSETS_DIR / "skyboxes"
    all_sky_prefixes = (
        "Boardwalk", "clouds", "Dockblur", "duskfair", "duskfair_180", "duskfair_270",
        "meadowblur", "roomblur", "sincity", "SkyboxEmptySpace", "skynin", "skyrays", "subwayblur",
    )
    for prefix in all_sky_prefixes:
        out_png = sky_out / f"sky_{prefix.lower()}.png"
        if stitch_skybox_prefix(sky_root, prefix, out_png):
            summary["skyboxes"].append(out_png.name)

    manifest_out = ASSETS_DIR / "havok_extra_sdk_assets.json"
    manifest_out.write_text(json.dumps({
        "schema": "havok-extra-sdk-assets-v2",
        "contains_sdk_hkt_runtime_dep": False,
        "axis_standard": "godot_y_up_neg_z_forward",
        "physics2012_policy": "SPEC_OUT",
        "spec_out_legacy_physics2012_assets": [
            "Animation/Ragdoll/dismemberment_skin.hkt",
            "Behavior/GameAssets/FlyingImp/CharacterAssets/FlyingImpSkelSkinRagdoll.hkt",
            "Cloth/*_ragdoll*.hkt",
        ],
        **summary,
    }, indent=2), encoding="utf-8")
    print(f"\n[DONE] P2 Extra SDK Assets Manifest -> {manifest_out}")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
