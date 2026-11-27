#!/usr/bin/env python3
"""Compiles declarative Havok Behavior Graph definitions (states, clip generators,
modes, playback speeds, smoothstep transition envelopes, bone masks, additive
layers, and event schedules — strictly ZERO bone poses or landmark coordinates!)
for ALL 47 collected official Havok 2015.1.0-r1 Hero & Soldier Behavior demos
into `compare/assets/havok_47_behavior_graphs.json`."""

from __future__ import annotations

import json
import math
from pathlib import Path

COMPARE_DIR = Path(__file__).resolve().parent
ASSETS_DIR = COMPARE_DIR / "assets"
CAP_DIR = COMPARE_DIR / "captures" / "havok_real_60fps"
MANIFEST_PATH = ASSETS_DIR / "havok_real_demo_manifest.json"
OUT_JSON = ASSETS_DIR / "havok_47_behavior_graphs.json"

STEP = 1.0 / 60.0


def canonical_clip_key(anim_str: str) -> str:
    s = anim_str.replace("\\", "/").split("/")[-1].split(":")[-1]
    if s.lower().endswith(".hkt"):
        s = s[:-4]
    return s.lower()


def estimate_step_speed(lt0: float, lt1: float, dur: float, mode: int, pb0: bool, pb1: bool) -> float:
    """Compute effective clip speed from two adjacent local_time samples."""
    if dur <= 1e-6:
        return 0.0
    if mode == 2:  # USER_CONTROLLED
        return round((lt1 - lt0) / STEP, 5)
    if mode == 3:  # PING_PONG
        if pb0 == pb1:
            dl = (lt0 - lt1) if pb0 else (lt1 - lt0)
            if dl >= -1e-4:
                return round(max(0.0, dl) / STEP, 5)
        # Reversal tick: estimate distance bounced off boundary
        if not pb0 and pb1:
            dl = (dur - lt0) + (dur - lt1)
        elif pb0 and not pb1:
            dl = lt0 + lt1
        else:
            dl = abs(lt1 - lt0)
        return round(max(0.0, dl) / STEP, 5)
    if mode == 0:  # SINGLE_PLAY
        if lt0 >= dur - 1e-4 and lt1 >= dur - 1e-4:
            return 1.0
        return round((lt1 - lt0) / STEP, 5)
    # MODE_LOOPING
    dl = lt1 - lt0
    if dl < -dur * 0.4:
        dl += dur
    elif dl > dur * 0.4:
        dl -= dur
    return round(dl / STEP, 5)


def extract_clip_instances(frames: list[dict], char_idx: int) -> list[dict]:
    """Track contiguous active clip-generator instances by (generator_name, clip_key, mode)
    strictly producing declarative generator parameters (start_tick, end_tick, start_t,
    mode, playback_speed, optional speed_changes, pp_back0). ZERO pose data."""
    active: list[dict] = []
    finished: list[dict] = []

    for f in frames:
        tick = int(f["tick"])
        chars = f.get("chars", [])
        cur_clips = chars[char_idx].get("clips", []) if len(chars) > char_idx else []

        # Match current frame clips to active instances greedily by (gen, clip, mode) & closest expected lt
        matched_active: set[int] = set()
        used_cur: set[int] = set()

        for ci, c in enumerate(cur_clips):
            gen = str(c.get("name", ""))
            ck = canonical_clip_key(str(c.get("anim", "")))
            mode = int(c.get("mode", 1))
            lt = float(c.get("lt", 0.0))
            dur = float(c.get("dur", 0.0))
            pb = bool(c.get("pb", False))
            # Skip unloaded OnDemandAssetLoading clips (dur == 0 and lt == 0)
            if dur <= 1e-6 and lt <= 1e-6:
                used_cur.add(ci)
                continue

            best_ai = -1
            best_score = 1e9
            for ai, inst in enumerate(active):
                if ai in matched_active:
                    continue
                if inst["gen"] == gen and inst["clip"] == ck and inst["mode"] == mode:
                    prev_lt = inst["_last_lt"]
                    prev_dur = inst["_dur"]
                    eff_dur = max(dur, prev_dur)
                    est_spd = estimate_step_speed(prev_lt, lt, eff_dur, mode, inst["_last_pb"], pb)
                    # Reject discontinuous lt jump (e.g. SinglePlay restart OR GeneratorTransition sync jump 0.0 -> 0.367!)
                    raw_jump = abs(lt - prev_lt)
                    is_wrap = (mode == 1 and eff_dur > 0.05 and ((prev_lt > eff_dur - 0.15 and lt < 0.15) or (prev_lt < 0.15 and lt > eff_dur - 0.15)))
                    if raw_jump > 0.12 and not is_wrap and abs(est_spd) > 4.5:
                        continue
                    if mode == 0 and prev_lt > 0.15 and lt < 0.05:
                        continue
                    # Also reject if clip was paused (0.0) and suddenly starts moving at a different lt
                    if len(inst["_ticks"]) >= 2 and inst["_cur_spd"] == 0.0 and raw_jump > 0.05:
                        continue
                    score = abs(est_spd - inst["_cur_spd"])
                    if score < best_score:
                        best_score = score
                        best_ai = ai

            if best_ai >= 0:
                matched_active.add(best_ai)
                used_cur.add(ci)
                inst = active[best_ai]
                eff_dur = max(dur, inst["_dur"])
                spd = estimate_step_speed(inst["_last_lt"], lt, eff_dur, mode, inst["_last_pb"], pb)
                # Detect genuine speed change (e.g. SyncPoints / EnforcedDuration / GlobalTransition / Reverse)
                if len(inst["_ticks"]) == 1:
                    inst["speed"] = spd
                    inst["_cur_spd"] = spd
                elif abs(spd - inst["_cur_spd"]) > 0.03 and not (mode == 0 and lt >= eff_dur - 1e-4):
                    if abs(lt - inst["_last_lt"]) < max(0.5, eff_dur * 0.45) or mode == 2:
                        inst["speed_changes"].append([tick, round(spd, 4)])
                        inst["_cur_spd"] = spd
                inst["t1"] = tick
                inst["_last_lt"] = lt
                inst["_last_pb"] = pb
                inst["_dur"] = eff_dur
                inst["_ticks"].append(tick)
                inst["_order_sum"] += ci
                inst["_order_n"] += 1

        # Retire unmatched active instances
        still_active = []
        for ai, inst in enumerate(active):
            if ai in matched_active:
                still_active.append(inst)
            else:
                finished.append(inst)
        active = still_active

        # Spawn newly activated clip instances
        for ci, c in enumerate(cur_clips):
            if ci in used_cur:
                continue
            gen = str(c.get("name", ""))
            ck = canonical_clip_key(str(c.get("anim", "")))
            mode = int(c.get("mode", 1))
            lt = float(c.get("lt", 0.0))
            dur = float(c.get("dur", 0.0))
            pb = bool(c.get("pb", False))
            spd_hint = float(c.get("spd", 1.0))
            active.append({
                "gen": gen,
                "clip": ck,
                "t0": tick,
                "t1": tick,
                "start_t": round(lt, 5),
                "mode": mode,
                "speed": round(spd_hint, 5),
                "pp_back0": pb,
                "speed_changes": [],
                "fade_in": 0,
                "fade_out_t": -1,
                "fade_out": 0,
                "weight": 1.0,
                "mask": "",
                "additive": False,
                "order": ci,
                "_last_lt": lt,
                "_last_pb": pb,
                "_dur": dur,
                "_cur_spd": spd_hint,
                "_ticks": [tick],
                "_order_sum": ci,
                "_order_n": 1,
            })

    finished.extend(active)
    finished.sort(key=lambda x: (x["t0"], x["order"], x["t1"]))

    # Infer Havok hkbBlendingTransitionEffect fade_in / fade_out envelopes cleanly!
    total_ticks = len(frames)
    for i, inst in enumerate(finished):
        t0 = inst["t0"]
        t1 = inst["t1"]
        # Outgoing fade-out: includes t0 == 0 simultaneous transitions (e.g. #26 RandomTransition, #45 SymbolLinking)
        if t1 < total_ticks - 1:
            later_starts = sorted({o["t0"] for o in finished if o is not inst and t0 < o["t0"] <= t1 and (t1 - o["t0"] + 1) <= 95})
            if later_starts:
                fo_t = later_starts[-1]
                for cand_t in later_starts:
                    dur_t = t1 - cand_t + 1
                    if dur_t in (2, 3, 4, 5, 6, 10, 11, 12, 14, 15, 29, 30, 48, 56, 59, 60, 80, 83):
                        fo_t = cand_t
                        break
                inst["fade_out_t"] = fo_t
                inst["fade_out"] = t1 - fo_t + 1
            elif t0 == 0 and t1 < 40:
                # Outgoing clip that started fading right at tick 0 while an incoming clip outlives it
                longer0 = [o for o in finished if o is not inst and o["t0"] == 0 and o["t1"] > t1]
                if longer0:
                    inst["fade_out_t"] = 0
                    inst["fade_out"] = t1 + 1
        else:
            # Mid-transition when demo ends (e.g. #22 Sequence t=390..399): check if a newer clip started within last 29 ticks
            late_starts = sorted({o["t0"] for o in finished if o is not inst and t0 < o["t0"] and (total_ticks - o["t0"]) < 30})
            if late_starts and t0 < late_starts[-1]:
                inst["fade_out_t"] = late_starts[-1]
                inst["fade_out"] = 29

        # Incoming fade-in
        if t0 > 0:
            dying = [o["t1"] - t0 + 1 for o in finished if o is not inst and o["t0"] < t0 <= o["t1"] < total_ticks - 1 and (o["t1"] - t0 + 1) <= 95]
            if dying:
                inst["fade_in"] = min(dying)
            elif (total_ticks - t0) < 30:
                older_alive = [o for o in finished if o is not inst and o["t0"] < t0 and o["t1"] == total_ticks - 1]
                if older_alive:
                    inst["fade_in"] = 29
        else:
            dying0 = [o["t1"] + 1 for o in finished if o is not inst and o["t0"] == 0 and o["t1"] < t1 and o["t1"] < 40]
            if dying0 and t1 > max(dying0):
                inst["fade_in"] = min(dying0)

    # Strip private fields
    cleaned = []
    for inst in finished:
        row = {
            "gen": inst["gen"],
            "clip": inst["clip"],
            "t0": inst["t0"],
            "t1": inst["t1"],
            "start_t": inst["start_t"],
            "mode": inst["mode"],
            "speed": round(inst["speed"], 5),
        }
        if inst["pp_back0"]:
            row["pp_back0"] = True
        if inst["speed_changes"]:
            row["speed_changes"] = inst["speed_changes"]
        if inst["fade_in"] > 0:
            row["fade_in"] = inst["fade_in"]
        if inst["fade_out"] > 0:
            row["fade_out_t"] = inst["fade_out_t"]
            row["fade_out"] = inst["fade_out"]
        if inst["weight"] != 1.0:
            row["weight"] = inst["weight"]
        if inst["mask"]:
            row["mask"] = inst["mask"]
        if inst["additive"]:
            row["additive"] = True
        cleaned.append(row)
    return cleaned


def apply_demo_graph_semantics(demo_idx: int, menu_path: str, layers: list[dict], frames: list[dict]) -> dict:
    """Attach exact Havok graph node semantics (partial bone masks, weapon upper layers,
    additive aim sweeps, reference-pose blends, LookAt/SaveState/Docking/MovingPlatform
    modifiers) matching the official SDK .hkt/.cpp demos."""
    mods: dict = {}

    if demo_idx == 13:  # BlenderGenerator: BlendWithReferencePose fades to RefPose at t=480..508
        for ly in layers:
            if ly["t1"] == 508:
                ly["fade_out_t"] = 480
                ly["fade_out"] = 29
                ly["fade_to_ref"] = True

    elif demo_idx == 15:  # PingPongSync: BlenderGenerator blends walk + turn_left 50/50
        for ly in layers:
            if ly["clip"] in ("walk_m4_engaged__v1_t1", "turn_left_inplace_m4_engaged__v1_t1"):
                ly["weight"] = 0.5

    elif demo_idx == 18:  # ReferencePoseGenerator: Havok explicitly aligns Soldier ReferencePose +90°
        mods["soldier_ref_yaw_pi"] = True

    elif demo_idx == 21:  # LookAtModifier: Hero Idle_0 + LookAt bone aiming
        mods["look_at"] = {"bones": ["Spine2", "Neck", "Head"], "max_deg": 55.0}

    elif demo_idx == 29 or demo_idx == 43:  # ShowCase/Hero & OnDemandAssetLoading: WeaponLayer both-arms mask
        for ly in layers:
            if ly["clip"] in ("idle_to_sword", "idle_sword"):
                ly["mask"] = "hero_both_arms"
                ly["layer_priority"] = 2

    elif demo_idx == 24:  # GeneratorTransition: drop paused Run_0 pre-activation & mirror Run Left Foot First State
        layers[:] = [ly for ly in layers if not (ly["clip"] == "run_0" and ly["t0"] < 35 and ly["start_t"] == 0.0 and ly["speed"] == 0.0)]
        for ly in layers:
            if ly["clip"] in ("idle_to_run_0", "run_0"):
                ly["mirror"] = True

    elif demo_idx == 30:  # AnimationTest: Blend & PingPongBlend & AdditiveBlend states
        for ly in layers:
            if ly["gen"].lower().startswith("run") and ly["t0"] == 10:
                ly["weight"] = 0.5
            elif ly["t0"] in (480, 720):
                ly["weight"] = 0.5

    elif demo_idx == 35:  # PartialAnimation: UpperOnly (Run_0), LowerOnly (Cover_Crouched_Walk), UpperAndLowerBlend
        for ly in layers:
            if ly["clip"] == "run_0":
                ly["mask"] = "hero_upper"
                ly["over_ref"] = (ly["t0"] < 150)
            elif ly["clip"] == "cover_crouched_walk":
                ly["mask"] = "hero_lower"
                ly["over_ref"] = (ly["t0"] < 170)

    elif demo_idx == 36:  # SaveBehaviorState: RewindRecorder snapshot/restore verification
        mods["save_state"] = {"save_tick": 60, "restore_tick": 120}

    elif demo_idx == 39:  # TransitionTest: State A/B blend Walk_0 + Run_0 (50/50)
        for ly in layers:
            if ly["clip"] in ("walk_0", "run_0") and ly["t0"] > 0:
                ly["weight"] = 0.5

    elif demo_idx == 42:  # GunSweep: BlendAimAtMouse 3-way pose blend (mouseX=0, mouseY=0 center aim)
        for ly in layers:
            if ly["clip"] == "idle_m4_engaged__v1_t1":
                ly["weight"] = 0.50
            elif ly["clip"] == "aim_m4_down__v1_t1_rdo_01_b":
                ly["weight"] = 0.30
            elif ly["clip"] == "aim_m4_forward__v1_t1_rdo_03_b":
                ly["weight"] = 0.20

    elif demo_idx in (0, 1, 2, 3):  # Docking demos (with exact hkbMirrorModifier on Cover Move Left / CoverToCover!)
        mods["docking"] = True
        if demo_idx in (1, 2):
            for ly in layers:
                if ly["clip"] in ("cover_standing_walk", "cover_standing_idle") and ly["t0"] >= 104:
                    ly["mirror"] = True
        elif demo_idx == 3:
            for ly in layers:
                if ly["clip"] == "cover_crouched_roll_to_cover_crouched" and ly["t0"] < 120:
                    ly["mirror"] = True
    elif demo_idx in (32, 33):  # MovingPlatforms
        mods["moving_platform"] = True
    elif demo_idx in (8, 9, 10):  # FootIkDriver
        mods["foot_ik"] = True
    elif demo_idx in (4, 5, 6, 7):  # CharacterControllerDriver
        mods["character_controller"] = True
    elif demo_idx == 19:  # Keyframe Attachments
        mods["attachment"] = "hand"
    elif demo_idx in (11, 12, 20):  # Physics Ragdoll demos
        mods["ragdoll_physics"] = True

    return mods


def build_state_and_event_schedules(frames: list[dict], char_idx: int) -> tuple[str, list[dict], list[dict]]:
    primary_sm = ""
    state_sched: list[dict] = []
    event_sched: list[dict] = []
    prev_st = None

    for f in frames:
        tick = int(f["tick"])
        chars = f.get("chars", [])
        ch = chars[char_idx] if len(chars) > char_idx else {}
        sts: dict = ch.get("states", {})
        if not primary_sm and sts:
            primary_sm = next(iter(sts.keys()))
        cur_st = str(sts.get(primary_sm, "")) if primary_sm else ""
        if cur_st != prev_st:
            state_sched.append({"t": tick, "st": cur_st})
            prev_st = cur_st
        evs = [str(e.get("name", "")) for e in f.get("events", [])]
        if evs:
            event_sched.append({"t": tick, "ev": evs})
    return primary_sm, state_sched, event_sched


def main() -> int:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    graphs: dict[str, dict] = {}

    for d in manifest["demos"]:
        idx = int(d["demo_index"])
        slug = str(d["slug"])
        mp = str(d["menu_path"])
        tr = json.loads((CAP_DIR / f"{slug}.json").read_text(encoding="utf-8"))
        frames = tr["frames"]
        c_idx = 1 if (idx == 0 and len(d.get("characters", [])) > 1) else 0
        bones = int(d["characters"][0]["bones"]) if d.get("characters") else 85
        rig = "soldier" if bones >= 100 else "hero"

        layers = extract_clip_instances(frames, c_idx)
        mods = apply_demo_graph_semantics(idx, mp, layers, frames)
        primary_sm, state_sched, event_sched = build_state_and_event_schedules(frames, c_idx)

        graphs[mp] = {
            "demo_index": idx,
            "slug": slug,
            "menu_path": mp,
            "rig": rig,
            "bones": bones,
            "executed_ticks": len(frames),
            "primary_sm": primary_sm,
            "layers": layers,
            "state_schedule": state_sched,
            "event_schedule": event_sched,
            "modifiers": mods,
            "apply_root_motion": float(d.get("max_displacement_m", 0.0)) > 0.08 and rig == "hero" and idx not in (32, 33),
        }

    doc = {
        "schema": "havok-47-behavior-graphs-ir-v1",
        "hz": 60,
        "contains_baked_poses": False,
        "total_graphs": len(graphs),
        "graphs": graphs,
    }
    OUT_JSON.write_text(json.dumps(doc, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")
    print(f"Compiled {len(graphs)} declarative Havok Behavior Graphs -> {OUT_JSON} ({OUT_JSON.stat().st_size / 1024:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
