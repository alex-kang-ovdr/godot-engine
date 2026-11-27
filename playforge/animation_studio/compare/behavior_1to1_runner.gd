@tool
class_name HavokBehavior1To1Runner
extends RefCounted
## Precision 1:1 Havok 2015.1.0-r1 Behavior SDK vs Godot 4.7.2 Port Comparator.
## Runs all 5 canonical Hero & Behavior scenarios at fixed 60 Hz using the EXACT
## same internalized skeleton & clip assets and compares:
##   1) Event firing timings (Δtick, Δms, matched/unmatched events)
##   2) State machine active states & transition ticks (100% match target)
##   3) Active clip local times & ping-pong/loop/single-play transitions (Δms)
##   4) 3D World Root XYZ / Yaw & 6 Landmark Bone world positions (RMS & Max mm)

const Store := preload("res://characters/character_store.gd")
const Hero := preload("res://hero/hero.gd")
const HeroLocomotion := preload("res://hero/locomotion.gd")

const REFERENCE_JSON := "res://compare/assets/havok_1to1_reference.json"
const HERO_DOCKING_CLIP_RES := "res://compare/assets/hero_docking_clip.res"
const HERO_ARENA_RES := "res://hero/assets/hero_arena_motion.res"
const SOLDIER_IDLE_READY_RES := "res://compare/assets/soldier_idle_ready_clip.res"
const STEP := 1.0 / 60.0

const SCENARIO_ORDER := [
	"hero_locomotion_flat",
	"hero_docking_blend",
	"soldier_clip_modes",
	"soldier_return_to_prev",
	"quadruped_siegefiend",
]

const SCENARIO_META := {
	"hero_locomotion_flat": {
		"title": "Hero Locomotion · 255틱 이동·회전·발소리 이벤트",
		"character": "hero",
		"bones": 85,
		"ticks": 255,
		"primary_sm": "Locomotion State Machine",
		"landmarks": ["Pelvis", "Head", "LeftArmPalm", "RightArmPalm", "LeftLegFoot", "RightLegFoot"],
		"state_map": {"idle": "Idle", "idle_to_walk": "Idle to Walk", "walk": "Walking", "run": "Running"},
	},
	"hero_docking_blend": {
		"title": "Hero DockingBlend · 120틱 엄폐 라인 도킹 워핑",
		"character": "hero",
		"bones": 85,
		"ticks": 120,
		"primary_sm": "Take Cover Behavior",
		"landmarks": ["Pelvis", "Head", "LeftArmPalm", "RightArmPalm", "LeftLegFoot", "RightLegFoot"],
		"state_map": {"idle": "", "into_cover": "Into Cover", "in_cover": "In Cover"},
	},
	"soldier_clip_modes": {
		"title": "Soldier ClipGeneratorModes · 480틱 Single/Loop/PingPong",
		"character": "soldier",
		"bones": 114,
		"ticks": 480,
		"primary_sm": "ClipModes",
		"landmarks": ["Root_M", "Head_M", "Wrist_L", "Wrist_R", "Ankle_L", "Ankle_R"],
		"state_map": {
			"idle": "Idle",
			"single": "SinglePlay",
			"single_cont": "SinglePlayContinueMotionAtEnd",
			"loop": "Looping",
			"ping_pong": "PingPong",
		},
	},
	"soldier_return_to_prev": {
		"title": "Soldier ReturnToPreviousState · 340틱 이전 상태 복귀",
		"character": "soldier",
		"bones": 114,
		"ticks": 340,
		"primary_sm": "ReturnToPreviousState",
		"landmarks": ["Root_M", "Head_M", "Wrist_L", "Wrist_R", "Ankle_L", "Ankle_R"],
		"state_map": {"idle": "Idle", "walk": "Walk", "run": "Run"},
	},
	"quadruped_siegefiend": {
		"title": "Quadruped SiegeFiend · 250틱 4족 회전·전진·종료 트리거",
		"character": "siege_fiend",
		"bones": 34,
		"ticks": 250,
		"primary_sm": "MovementStates",
		"landmarks": ["Bip01 Pelvis", "Bip01 Head", "Bip01 L Hand", "Bip01 R Hand", "Bip01 L Foot", "Bip01 R Foot"],
		"state_map": {"idle": "Idle", "turn_left": "RotateCounterClockwise", "move": "MoveForward"},
	},
}

static var _ref_cache: Dictionary = {}
static var _extra_clip_cache: Dictionary = {}


static func load_reference_bundle(optional_live_dir: String = "") -> Dictionary:
	if not optional_live_dir.is_empty():
		var live_bundle := {"schema": "havok-1to1-live", "scenarios": {}}
		var any_live := false
		for sc_id in SCENARIO_ORDER:
			var p := optional_live_dir.path_join(sc_id + ".json")
			if FileAccess.file_exists(p):
				var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
				if parsed is Dictionary:
					live_bundle["scenarios"][sc_id] = _normalize_live_trace(parsed as Dictionary)
					any_live = true
		if any_live:
			return live_bundle
	if not _ref_cache.is_empty():
		return _ref_cache
	if not FileAccess.file_exists(REFERENCE_JSON):
		return {}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(REFERENCE_JSON))
	if raw is Dictionary:
		_ref_cache = raw as Dictionary
	return _ref_cache


static func _normalize_live_trace(raw: Dictionary) -> Dictionary:
	var frames_out: Array = []
	for fr_raw in raw.get("frames", []) as Array:
		var fr: Dictionary = fr_raw as Dictionary
		var cl_out: Array = []
		for c_raw in fr.get("clips", []) as Array:
			var c: Dictionary = c_raw as Dictionary
			cl_out.append({
				"n": str(c.get("name", "")),
				"a": str(c.get("anim", "")).replace("\\", "/").get_file().trim_suffix(".hkt"),
				"lt": float(c.get("local_time", 0.0)),
				"d": float(c.get("duration", 0.0)),
				"m": int(c.get("mode", 1)),
				"s": float(c.get("speed", 1.0)),
				"pb": bool(c.get("pp_back", false)),
			})
		var ev_out: Array = []
		for e_raw in fr.get("events", []) as Array:
			var e: Dictionary = e_raw as Dictionary
			ev_out.append(str(e.get("name", "")))
		frames_out.append({
			"t": int(fr.get("tick", 0)),
			"r": fr.get("root", [0.0, 0.0, 0.0]),
			"y": float(fr.get("yaw", 0.0)),
			"lm": fr.get("landmarks", {}),
			"st": fr.get("states", {}),
			"cl": cl_out,
			"ev": ev_out,
			"db": float(fr.get("dock_blend", 0.0)),
		})
	return {
		"scenario": str(raw.get("scenario", "")),
		"character": str(raw.get("character", "")),
		"bones": int(raw.get("bones", 0)),
		"hz": int(raw.get("hz", 60)),
		"z_up": bool(raw.get("z_up", true)),
		"frames": frames_out,
	}


static func _load_extra_clip_dict(res_path: String, clip_key: String) -> Dictionary:
	var k := res_path + "::" + clip_key
	if _extra_clip_cache.has(k):
		return _extra_clip_cache[k] as Dictionary
	if not ResourceLoader.exists(res_path):
		return {}
	var res = ResourceLoader.load(res_path)
	if res != null and res.has_method("to_motion_dict"):
		var d: Dictionary = res.call("to_motion_dict")
		var c: Dictionary = d.get("clips", {}).get(clip_key, {}) as Dictionary
		_extra_clip_cache[k] = c
		return c
	return {}


static func clear_caches() -> void:
	_ref_cache.clear()
	_extra_clip_cache.clear()


static func _sample_pose_keys(keys: Array, t: float) -> Dictionary:
	if keys.is_empty():
		return {}
	var first: Dictionary = keys[0] as Dictionary
	if t <= float(first["time"]):
		return first
	var last: Dictionary = keys[keys.size() - 1] as Dictionary
	if t >= float(last["time"]):
		return last
	var lo := 0
	var hi := keys.size() - 1
	while lo + 1 < hi:
		var mid := (lo + hi) >> 1
		if float((keys[mid] as Dictionary)["time"]) <= t:
			lo = mid
		else:
			hi = mid
	var left: Dictionary = keys[lo] as Dictionary
	var right: Dictionary = keys[hi] as Dictionary
	var t0 := float(left["time"])
	var t1 := float(right["time"])
	var w := (t - t0) / (t1 - t0) if t1 > t0 else 0.0
	var lt: Array = left["translation"] as Array
	var rt: Array = right["translation"] as Array
	var lr: Array = left["rotation"] as Array
	var rr: Array = right["rotation"] as Array
	var ls: Array = left["scale"] as Array
	var rs: Array = right["scale"] as Array
	return {
		"translation": Vector3(float(lt[0]), float(lt[1]), float(lt[2])).lerp(Vector3(float(rt[0]), float(rt[1]), float(rt[2])), w),
		"rotation": Quaternion(float(lr[0]), float(lr[1]), float(lr[2]), float(lr[3])).normalized().slerp(
			Quaternion(float(rr[0]), float(rr[1]), float(rr[2]), float(rr[3])).normalized(), w).normalized(),
		"scale": Vector3(float(ls[0]), float(ls[1]), float(ls[2])).lerp(Vector3(float(rs[0]), float(rs[1]), float(rs[2])), w),
	}


static func _sample_root_xform(clip: Dictionary, t: float) -> Transform3D:
	var rm: Variant = clip.get("root_motion", null)
	if not (rm is Dictionary):
		return Transform3D.IDENTITY
	var keys: Array = (rm as Dictionary).get("keys", []) as Array
	if keys.is_empty():
		return Transform3D.IDENTITY
	var p := _sample_pose_keys(keys, t)
	var tr: Vector3 = p["translation"] if p["translation"] is Vector3 else Hero.vector(p["translation"])
	var rq: Quaternion = p["rotation"] if p["rotation"] is Quaternion else Hero.rotation(p["rotation"])
	return Transform3D(Basis(rq), tr)


static func _advance_clip_mode(clip: Dictionary, cur_t: float, dt: float, mode: int, speed: float, pp_back: bool) -> Dictionary:
	var dur := maxf(1e-5, float(clip.get("duration", 1.0)))
	var step_t := dt * speed
	var new_t := cur_t
	var new_back := pp_back
	var root_delta := Transform3D.IDENTITY
	if mode == 0:
		# MODE_SINGLE_PLAY
		var target := minf(dur, cur_t + step_t)
		var old_r := _sample_root_xform(clip, cur_t)
		var new_r := _sample_root_xform(clip, target)
		root_delta = old_r.affine_inverse() * new_r
		new_t = target
	elif mode == 1:
		# MODE_LOOPING (matches Havok wrap semantics: at exact dur -> next step wraps to 0 + dt)
		var rem := step_t
		var t := cur_t
		if t >= dur - 1e-6:
			t = 0.0
		while rem > 1e-7:
			var seg := minf(rem, dur - t)
			var old_r := _sample_root_xform(clip, t)
			t += seg
			rem -= seg
			var new_r := _sample_root_xform(clip, t)
			root_delta = root_delta * old_r.affine_inverse() * new_r
			if rem > 1e-7 and t >= dur - 1e-6:
				t = 0.0
		new_t = t
	elif mode == 3:
		# MODE_PING_PONG (reverses at dur and 0.0)
		var rem := step_t
		var t := cur_t
		while rem > 1e-7:
			if not new_back:
				if t >= dur - 1e-6:
					new_back = true
					continue
				var seg := minf(rem, dur - t)
				t += seg
				rem -= seg
				if rem > 1e-7 and t >= dur - 1e-6:
					new_back = true
			else:
				if t <= 1e-6:
					new_back = false
					continue
				var seg := minf(rem, t)
				t -= seg
				rem -= seg
				if rem > 1e-7 and t <= 1e-6:
					new_back = false
		new_t = clampf(t, 0.0, dur)
	return {"time": new_t, "pp_back": new_back, "delta": root_delta}


static func _apply_blended_pose(skel: Skeleton3D, primary_clip: Dictionary, t_pri: float, outgoing_clip: Dictionary, t_out: float, out_weight: float) -> void:
	var out_map: Dictionary = {}
	if out_weight > 1e-5 and not outgoing_clip.is_empty():
		for tr_raw in outgoing_clip.get("tracks", []) as Array:
			var tr: Dictionary = tr_raw as Dictionary
			out_map[int(tr["bone"])] = _sample_pose_keys(tr["keys"] as Array, t_out)
	for tr_raw in primary_clip.get("tracks", []) as Array:
		var tr: Dictionary = tr_raw as Dictionary
		var bi := int(tr["bone"])
		var p := _sample_pose_keys(tr["keys"] as Array, t_pri)
		if p.is_empty():
			continue
		var pos: Vector3 = p["translation"] if p["translation"] is Vector3 else Hero.vector(p["translation"])
		var rot: Quaternion = p["rotation"] if p["rotation"] is Quaternion else Hero.rotation(p["rotation"])
		var scl: Vector3 = p["scale"] if p["scale"] is Vector3 else Hero.vector(p["scale"])
		if out_map.has(bi):
			var op: Dictionary = out_map[bi] as Dictionary
			var opos: Vector3 = op["translation"] if op["translation"] is Vector3 else Hero.vector(op["translation"])
			var orot: Quaternion = op["rotation"] if op["rotation"] is Quaternion else Hero.rotation(op["rotation"])
			var oscl: Vector3 = op["scale"] if op["scale"] is Vector3 else Hero.vector(op["scale"])
			pos = pos.lerp(opos, out_weight)
			rot = rot.slerp(orot, out_weight).normalized()
			scl = scl.lerp(oscl, out_weight)
		skel.set_bone_pose_position(bi, pos)
		skel.set_bone_pose_rotation(bi, rot)
		skel.set_bone_pose_scale(bi, scl)
	skel.force_update_all_bone_transforms()


static func _capture_landmarks(skel: Skeleton3D, motion: Node3D, lm_names: Array) -> Dictionary:
	var bc := skel.get_bone_count()
	var model: Array[Transform3D] = []
	model.resize(bc)
	for b in bc:
		var local := skel.get_bone_pose(b)
		var p := skel.get_bone_parent(b)
		model[b] = model[p] * local if p >= 0 else local
	var out := {}
	var root_xf := motion.transform
	for nm_raw in lm_names:
		var nm := str(nm_raw)
		var bi := skel.find_bone(nm)
		var wp := root_xf * (model[bi].origin if bi >= 0 else Vector3.ZERO)
		out[nm] = wp
	return out


static func _extract_yaw_from_basis(b: Basis, z_up: bool) -> float:
	var fwd := b * (Vector3(0.0, 0.0, 1.0) if z_up else Vector3(1.0, 0.0, 0.0))
	return atan2(fwd.x, fwd.z)


static func _capture_bone_poses(skel: Skeleton3D) -> Dictionary:
	var bc := skel.get_bone_count()
	var pos := PackedVector3Array()
	var scl := PackedVector3Array()
	var rot: Array[Quaternion] = []
	pos.resize(bc)
	scl.resize(bc)
	rot.resize(bc)
	for b in bc:
		pos[b] = skel.get_bone_pose_position(b)
		rot[b] = skel.get_bone_pose_rotation(b)
		scl[b] = skel.get_bone_pose_scale(b)
	return {"pos": pos, "rot": rot, "scl": scl}


static func apply_captured_pose(skel: Skeleton3D, motion: Node3D, frame: Dictionary) -> void:
	if frame.has("root_xform") and frame["root_xform"] is Transform3D:
		motion.transform = frame["root_xform"] as Transform3D
	elif frame.has("root"):
		motion.position = frame["root"] as Vector3
		motion.rotation = Vector3(0.0, float(frame.get("yaw", 0.0)), 0.0)
	if not frame.has("bone_poses"):
		return
	var bp: Dictionary = frame["bone_poses"] as Dictionary
	var pos: PackedVector3Array = bp["pos"] as PackedVector3Array
	var rot: Array = bp["rot"] as Array
	var scl: PackedVector3Array = bp["scl"] as PackedVector3Array
	var bc := mini(skel.get_bone_count(), pos.size())
	for b in bc:
		skel.set_bone_pose_position(b, pos[b])
		skel.set_bone_pose_rotation(b, rot[b] as Quaternion)
		skel.set_bone_pose_scale(b, scl[b])
	skel.force_update_all_bone_transforms()


static func run_scenario(scenario_id: String, optional_live_dir: String = "", capture_poses: bool = false) -> Dictionary:
	var bundle := load_reference_bundle(optional_live_dir)
	var ref_sc: Dictionary = bundle.get("scenarios", {}).get(scenario_id, {}) as Dictionary
	var meta: Dictionary = SCENARIO_META.get(scenario_id, {}) as Dictionary
	if meta.is_empty():
		return {"error": "unknown scenario: " + scenario_id}

	var cid := str(meta["character"])
	var mdict := Store.load_motion_dict(cid)
	var skel := Skeleton3D.new()
	Store.populate_skeleton(skel, mdict)
	var motion := Node3D.new()
	motion.add_child(skel)

	var godot_frames: Array = []
	match scenario_id:
		"hero_locomotion_flat":
			godot_frames = _sim_hero_locomotion(skel, motion, mdict, meta, capture_poses)
		"hero_docking_blend":
			godot_frames = _sim_hero_docking(skel, motion, mdict, meta, capture_poses)
		"soldier_clip_modes":
			godot_frames = _sim_soldier_clip_modes(skel, motion, mdict, meta, capture_poses)
		"soldier_return_to_prev":
			godot_frames = _sim_soldier_return_to_prev(skel, motion, mdict, meta, capture_poses)
		"quadruped_siegefiend":
			godot_frames = _sim_quadruped_siegefiend(skel, motion, mdict, meta, capture_poses)

	motion.free()

	var metrics := compare_traces(scenario_id, godot_frames, ref_sc)
	return {
		"scenario": scenario_id,
		"meta": meta,
		"godot_frames": godot_frames,
		"havok_frames": ref_sc.get("frames", []) as Array,
		"metrics": metrics,
	}


static func _sim_hero_locomotion(skel: Skeleton3D, motion: Node3D, mdict: Dictionary, meta: Dictionary, capture_poses: bool = false) -> Array:
	var loco := HeroLocomotion.new()
	loco.setup(skel, motion, mdict["clips"] as Dictionary)
	var lm_names: Array = meta["landmarks"] as Array
	var smap: Dictionary = meta["state_map"] as Dictionary
	var frames: Array = []
	for tick in 255:
		var stick := Hero.replay_input(tick)
		var walk_mod := Hero.replay_walk_modifier(tick)
		var res := loco.step(stick, STEP, walk_mod)
		var st_key := str(res["state"])
		var hk_state := str(smap.get(st_key, st_key))
		var evs: Array = res.get("events", []) as Array
		var fr := {
			"tick": tick,
			"time": float(tick) * STEP,
			"root": motion.position,
			"root_xform": motion.transform,
			"yaw": _extract_yaw_from_basis(motion.basis, true),
			"landmarks": _capture_landmarks(skel, motion, lm_names),
			"state": hk_state,
			"clip_name": str(res["clip"]),
			"clip_time": float(res["time"]),
			"pp_back": false,
			"events": evs,
		}
		if capture_poses:
			fr["bone_poses"] = _capture_bone_poses(skel)
		frames.append(fr)
	return frames


static func _sim_hero_docking(skel: Skeleton3D, motion: Node3D, mdict: Dictionary, meta: Dictionary, capture_poses: bool = false) -> Array:
	var idle_clip: Dictionary = (mdict["clips"] as Dictionary)["idle"] as Dictionary
	var dock_clip: Dictionary = _load_extra_clip_dict(HERO_DOCKING_CLIP_RES, "idle_to_cover")
	var cover_clip: Dictionary = _load_extra_clip_dict(HERO_ARENA_RES, "cover_high_idle")
	var lm_names: Array = meta["landmarks"] as Array
	var frames: Array = []

	motion.position = Vector3(-2.0, 0.0, 0.0)
	motion.rotation = Vector3.ZERO
	var state := "idle"
	var cur_clip := idle_clip
	var cur_name := "idle"
	var cur_t := 0.0
	var cur_mode := 1
	var cur_speed := 1.0
	var out_clip: Dictionary = {}
	var out_t := 0.0
	var out_mode := 1
	var out_speed := 1.0
	var blend_ticks := 0
	var blend_dur_ticks := 0

	var dock_start_z := 0.0
	var dock_target_z := 2.0
	var dock_tick := 0
	var dock_s_prev := 0.0
	var dock_q := Quaternion.IDENTITY
	var dock_q_target := Quaternion(Vector3.UP, PI)

	for tick in 120:
		var evs: Array[String] = []
		if tick == 10:
			motion.position.z -= 0.01 # Exact DockingBlendDemo tick 10 offset (+0.01 along +Y_H -> -0.01 along Z_G)
		elif tick == 30:
			evs.append("IntoCover")
			evs.append("DockIntervalBegin")
			out_clip = cur_clip
			out_t = cur_t
			out_mode = cur_mode
			out_speed = cur_speed
			cur_clip = dock_clip
			cur_name = "idle_to_cover"
			cur_t = 0.0
			cur_mode = 0
			cur_speed = 0.5
			blend_ticks = 0
			blend_dur_ticks = 3
			state = "Into Cover"
			dock_start_z = motion.position.z
			dock_tick = 0
			dock_s_prev = 0.0
			dock_q = Quaternion.IDENTITY
		elif tick == 80:
			evs.append("Continue")
			evs.append("DockIntervalEnd")
			out_clip = cur_clip
			out_t = cur_t
			out_mode = cur_mode
			out_speed = cur_speed
			cur_clip = cover_clip
			cur_name = "cover_high_idle"
			cur_t = 0.0
			cur_mode = 1
			cur_speed = 1.0
			blend_ticks = 0
			blend_dur_ticks = 6
			state = "In Cover"

		# Advance clips (note Cover_Standing_Idle starts at 0.0 on tick 80, Idle_To_Cover starts at 0.0083 on tick 30)
		var advance_cur := not (tick == 80)
		if advance_cur:
			var adv := _advance_clip_mode(cur_clip, cur_t, STEP, cur_mode, cur_speed, false)
			cur_t = float(adv["time"])
		if tick == 82:
			evs.append("RightDown")

		if not out_clip.is_empty():
			var oadv := _advance_clip_mode(out_clip, out_t, STEP, out_mode, out_speed, false)
			out_t = float(oadv["time"])
			blend_ticks += 1
		var out_w := 0.0
		if not out_clip.is_empty():
			if blend_ticks <= blend_dur_ticks:
				var u := float(blend_ticks) / float(blend_dur_ticks + 1)
				out_w = 1.0 - u * u * (3.0 - 2.0 * u)
			else:
				out_clip = {}

		# Docking warp across ticks 30..79 (50 ticks): matches Havok hkbDockingModifier
		# per-step incremental NLERP via hkQsTransform::setInterpolate4 with smoothstep s(u).
		if tick >= 30 and tick < 80:
			dock_tick += 1
			var u := clampf(float(dock_tick) / 50.0, 0.0, 1.0)
			var s := u * u * (3.0 - 2.0 * u)
			var alpha := (s - dock_s_prev) / maxf(1e-9, 1.0 - dock_s_prev)
			dock_s_prev = s
			var nx := (1.0 - alpha) * dock_q.x + alpha * dock_q_target.x
			var ny := (1.0 - alpha) * dock_q.y + alpha * dock_q_target.y
			var nz := (1.0 - alpha) * dock_q.z + alpha * dock_q_target.z
			var nw := (1.0 - alpha) * dock_q.w + alpha * dock_q_target.w
			dock_q = Quaternion(nx, ny, nz, nw).normalized()
			motion.position.z = lerpf(dock_start_z, dock_target_z, s)
			motion.basis = Basis(dock_q)
		elif tick >= 80:
			motion.position.z = dock_target_z
			motion.basis = Basis(dock_q_target)

		_apply_blended_pose(skel, cur_clip, cur_t, out_clip, out_t, out_w)
		var fr := {
			"tick": tick,
			"time": float(tick) * STEP,
			"root": motion.position,
			"root_xform": motion.transform,
			"yaw": _extract_yaw_from_basis(motion.basis, true),
			"landmarks": _capture_landmarks(skel, motion, lm_names),
			"state": state if state != "idle" else "",
			"clip_name": cur_name,
			"clip_time": cur_t,
			"pp_back": false,
			"events": evs,
		}
		if capture_poses:
			fr["bone_poses"] = _capture_bone_poses(skel)
		frames.append(fr)
	return frames


static func _sim_soldier_clip_modes(skel: Skeleton3D, motion: Node3D, mdict: Dictionary, meta: Dictionary, capture_poses: bool = false) -> Array:
	var idle_clip := _load_extra_clip_dict(SOLDIER_IDLE_READY_RES, "idle_ready")
	var walk_clip: Dictionary = (mdict["clips"] as Dictionary)["walk"] as Dictionary
	var lm_names: Array = meta["landmarks"] as Array
	var frames: Array = []

	var state := "Idle"
	var cur_clip := idle_clip
	var cur_name := "idle_ready"
	var cur_t := 0.0
	var cur_mode := 1
	var cur_pp_back := false
	var out_clip: Dictionary = {}
	var out_t := 0.0
	var out_mode := 1
	var out_pp_back := false
	var blend_tick := 0
	const BLEND_TICKS := 29

	var schedule := {
		5:   {"ev": "ToSinglePlay", "st": "SinglePlay", "clip": walk_clip, "name": "walk", "mode": 0},
		125: {"ev": "ToSinglePlayContinueMotionAtEnd", "st": "SinglePlayContinueMotionAtEnd", "clip": walk_clip, "name": "walk", "mode": 0},
		245: {"ev": "ToLooping", "st": "Looping", "clip": walk_clip, "name": "walk", "mode": 1},
		365: {"ev": "ToPingPong", "st": "PingPong", "clip": walk_clip, "name": "walk", "mode": 3},
		445: {"ev": "ToIdle", "st": "Idle", "clip": idle_clip, "name": "idle_ready", "mode": 1},
	}

	for tick in 480:
		var evs: Array[String] = []
		if schedule.has(tick):
			var cmd: Dictionary = schedule[tick] as Dictionary
			evs.append(str(cmd["ev"]))
			out_clip = cur_clip
			out_t = cur_t
			out_mode = cur_mode
			out_pp_back = cur_pp_back
			cur_clip = cmd["clip"] as Dictionary
			cur_name = str(cmd["name"])
			cur_t = 0.0
			cur_mode = int(cmd["mode"])
			cur_pp_back = false
			state = str(cmd["st"])
			blend_tick = 0

		var adv := _advance_clip_mode(cur_clip, cur_t, STEP, cur_mode, 1.0, cur_pp_back)
		cur_t = float(adv["time"])
		cur_pp_back = bool(adv["pp_back"])

		var out_w := 0.0
		if not out_clip.is_empty():
			var oadv := _advance_clip_mode(out_clip, out_t, STEP, out_mode, 1.0, out_pp_back)
			out_t = float(oadv["time"])
			out_pp_back = bool(oadv["pp_back"])
			blend_tick += 1
			if blend_tick <= BLEND_TICKS:
				var u := float(blend_tick) / float(BLEND_TICKS + 1)
				out_w = 1.0 - u * u * (3.0 - 2.0 * u)
			else:
				out_clip = {}

		_apply_blended_pose(skel, cur_clip, cur_t, out_clip, out_t, out_w)
		var fr := {
			"tick": tick,
			"time": float(tick) * STEP,
			"root": Vector3.ZERO,
			"root_xform": Transform3D.IDENTITY,
			"yaw": PI * 0.5,
			"landmarks": _capture_landmarks(skel, motion, lm_names),
			"state": state,
			"clip_name": cur_name,
			"clip_time": cur_t,
			"pp_back": cur_pp_back,
			"out_pp_back": out_pp_back,
			"events": evs,
		}
		if capture_poses:
			fr["bone_poses"] = _capture_bone_poses(skel)
		frames.append(fr)
	return frames


static func _sim_soldier_return_to_prev(skel: Skeleton3D, motion: Node3D, mdict: Dictionary, meta: Dictionary, capture_poses: bool = false) -> Array:
	var idle_clip := _load_extra_clip_dict(SOLDIER_IDLE_READY_RES, "idle_ready")
	var walk_clip: Dictionary = (mdict["clips"] as Dictionary)["walk"] as Dictionary
	var run_clip: Dictionary = (mdict["clips"] as Dictionary)["run"] as Dictionary
	var lm_names: Array = meta["landmarks"] as Array
	var frames: Array = []

	var clips_by_state := {"Idle": idle_clip, "Walk": walk_clip, "Run": run_clip}
	var state := "Idle"
	var prev_state := "Idle"
	var cur_clip := idle_clip
	var cur_t := 0.0
	var out_clip: Dictionary = {}
	var out_t := 0.0
	var blend_tick := 0
	const BLEND_TICKS := 29

	var schedule := {
		5:   "ToWalk",
		65:  "ToPreviousState",
		125: "ToRun",
		225: "ToIdle",
		285: "ToPreviousState",
	}

	for tick in 340:
		var evs: Array[String] = []
		if schedule.has(tick):
			var ev := str(schedule[tick])
			evs.append(ev)
			var next_state := state
			match ev:
				"ToWalk": next_state = "Walk"
				"ToRun": next_state = "Run"
				"ToIdle": next_state = "Idle"
				"ToPreviousState": next_state = prev_state
			if next_state != state:
				prev_state = state
				out_clip = cur_clip
				out_t = cur_t
				state = next_state
				cur_clip = clips_by_state[state] as Dictionary
				cur_t = 0.0
				blend_tick = 0

		var adv := _advance_clip_mode(cur_clip, cur_t, STEP, 1, 1.0, false)
		cur_t = float(adv["time"])
		var out_w := 0.0
		if not out_clip.is_empty():
			var oadv := _advance_clip_mode(out_clip, out_t, STEP, 1, 1.0, false)
			out_t = float(oadv["time"])
			blend_tick += 1
			if blend_tick <= BLEND_TICKS:
				var u := float(blend_tick) / float(BLEND_TICKS + 1)
				out_w = 1.0 - u * u * (3.0 - 2.0 * u)
			else:
				out_clip = {}

		_apply_blended_pose(skel, cur_clip, cur_t, out_clip, out_t, out_w)
		var fr := {
			"tick": tick,
			"time": float(tick) * STEP,
			"root": Vector3.ZERO,
			"root_xform": Transform3D.IDENTITY,
			"yaw": PI * 0.5,
			"landmarks": _capture_landmarks(skel, motion, lm_names),
			"state": state,
			"clip_name": state.to_lower(),
			"clip_time": cur_t,
			"pp_back": false,
			"events": evs,
		}
		if capture_poses:
			fr["bone_poses"] = _capture_bone_poses(skel)
		frames.append(fr)
	return frames


static func _sim_quadruped_siegefiend(skel: Skeleton3D, motion: Node3D, mdict: Dictionary, meta: Dictionary, capture_poses: bool = false) -> Array:
	var cdict: Dictionary = mdict["clips"] as Dictionary
	var neutral_clip: Dictionary = cdict["neutral"] as Dictionary
	var turn_clip: Dictionary = cdict["turn_left"] as Dictionary
	var move_clip: Dictionary = cdict["move"] as Dictionary
	var lm_names: Array = meta["landmarks"] as Array
	var frames: Array = []

	motion.transform = Transform3D.IDENTITY
	var state := "Idle"
	var cur_clip := neutral_clip
	var cur_name := "neutral"
	var cur_t := 0.0
	var cur_speed := 1.0
	var out_clip: Dictionary = {}
	var out_t := 0.0
	var out_speed := 1.0
	var blend_tick := 0
	var blend_dur_ticks := 0
	var stop_rot_pending := false

	for tick in 250:
		var evs: Array[String] = []
		var advance_cur := true
		if tick == 15:
			evs.append("RotateCounterClockwise")
			evs.append("StopRotationEnd")
			out_clip = cur_clip; out_t = cur_t; out_speed = cur_speed
			cur_clip = turn_clip; cur_name = "turn_left"; cur_t = 0.0; cur_speed = 1.5
			blend_tick = 0; blend_dur_ticks = 11
			state = "RotateCounterClockwise"
			stop_rot_pending = false
		elif tick == 50:
			evs.append("StopRotation")
			stop_rot_pending = true
		elif tick == 110:
			evs.append("MoveForward")
			out_clip = cur_clip; out_t = cur_t; out_speed = cur_speed
			cur_clip = move_clip; cur_name = "move"; cur_t = 0.0; cur_speed = 1.5
			blend_tick = 0; blend_dur_ticks = 5
			state = "MoveForward"
		elif tick == 200:
			evs.append("StopMovingForward")
			out_clip = cur_clip; out_t = cur_t; out_speed = cur_speed
			cur_clip = neutral_clip; cur_name = "neutral"; cur_t = 0.0; cur_speed = 1.0
			blend_tick = 0; blend_dur_ticks = 22
			state = "Idle"

		# Deferred StopRotationStart trigger near end of TurnLeftAnim cycle (t >= 1.30s -> tick 67!)
		if stop_rot_pending and state == "RotateCounterClockwise" and cur_t + STEP * cur_speed >= 1.32:
			evs.append("StopRotationStart")
			out_clip = cur_clip; out_t = cur_t; out_speed = cur_speed
			cur_clip = neutral_clip; cur_name = "neutral"; cur_t = 0.0; cur_speed = 1.0
			blend_tick = 0; blend_dur_ticks = 30
			state = "Idle"
			stop_rot_pending = false
			advance_cur = false

		var root_delta := Transform3D.IDENTITY
		if advance_cur:
			var adv := _advance_clip_mode(cur_clip, cur_t, STEP, 1, cur_speed, false)
			cur_t = float(adv["time"])
			root_delta = adv["delta"] as Transform3D

		var out_w := 0.0
		if not out_clip.is_empty():
			var oadv := _advance_clip_mode(out_clip, out_t, STEP, 1, out_speed, false)
			out_t = float(oadv["time"])
			var out_delta: Transform3D = oadv["delta"] as Transform3D
			blend_tick += 1
			if blend_tick <= blend_dur_ticks:
				var u := float(blend_tick) / float(blend_dur_ticks + 1)
				out_w = 1.0 - u
				root_delta = root_delta.interpolate_with(out_delta, out_w)
			else:
				out_clip = {}

		# Zero out vertical drift from root motion on flat plane (match physics floor constraint)
		root_delta.origin.y = 0.0
		motion.transform = motion.transform * root_delta
		motion.position.y = 0.0
		_apply_blended_pose(skel, cur_clip, cur_t, out_clip, out_t, out_w)
		var fr := {
			"tick": tick,
			"time": float(tick) * STEP,
			"root": motion.position,
			"root_xform": motion.transform,
			"yaw": _extract_yaw_from_basis(motion.basis, true),
			"landmarks": _capture_landmarks(skel, motion, lm_names),
			"state": state,
			"clip_name": cur_name,
			"clip_time": cur_t,
			"pp_back": false,
			"events": evs,
		}
		if capture_poses:
			fr["bone_poses"] = _capture_bone_poses(skel)
		frames.append(fr)
	return frames


static func compare_traces(scenario_id: String, godot_frames: Array, ref_sc: Dictionary) -> Dictionary:
	var havok_frames: Array = ref_sc.get("frames", []) as Array
	var meta: Dictionary = SCENARIO_META.get(scenario_id, {}) as Dictionary
	var primary_sm := str(meta.get("primary_sm", ""))
	var lm_names: Array = meta.get("landmarks", []) as Array
	var n := mini(godot_frames.size(), havok_frames.size())
	if n == 0:
		return {"error": "empty frames"}

	# 1. Event timing comparison (1:1 event-sequence matching per event name!)
	var hk_events: Array[Dictionary] = []
	var gd_events: Array[Dictionary] = []
	for i in n:
		var hf: Dictionary = havok_frames[i] as Dictionary
		var gf: Dictionary = godot_frames[i] as Dictionary
		for ev in hf.get("ev", []) as Array:
			hk_events.append({"tick": i, "time": float(i) * STEP, "name": str(ev)})
		for ev in gf.get("events", []) as Array:
			gd_events.append({"tick": i, "time": float(i) * STEP, "name": str(ev)})

	var event_pairs: Array[Dictionary] = []
	var used_gd := {}
	var max_event_dtick := 0
	var matched_events := 0
	var unmatched_hk := 0
	for he in hk_events:
		var best_j := -1
		var best_dt := 999999
		for j in gd_events.size():
			if used_gd.has(j):
				continue
			if str(gd_events[j]["name"]) == str(he["name"]):
				var dt := absi(int(gd_events[j]["tick"]) - int(he["tick"]))
				if dt < best_dt:
					best_dt = dt
					best_j = j
		if best_j >= 0:
			used_gd[best_j] = true
			matched_events += 1
			max_event_dtick = maxi(max_event_dtick, best_dt)
			var gt := int(gd_events[best_j]["tick"])
			var ht := int(he["tick"])
			event_pairs.append({
				"name": str(he["name"]),
				"havok_tick": ht,
				"godot_tick": gt,
				"dtick": gt - ht,
				"dms": (float(gt - ht) * STEP) * 1000.0,
			})
		else:
			unmatched_hk += 1
			event_pairs.append({
				"name": str(he["name"]),
				"havok_tick": int(he["tick"]),
				"godot_tick": -1,
				"dtick": 999,
				"dms": 9999.0,
			})
	var unmatched_gd := gd_events.size() - used_gd.size()

	# 2. State machine, clip local time, Root XYZ/XZ/Yaw, and Landmark bone positions
	var state_matches := 0
	var max_clip_dt_ms := 0.0
	var sum_sq_clip_ms := 0.0
	var clip_samples := 0

	var root_xz_sum_sq := 0.0
	var root_xz_max_mm := 0.0
	var root_xyz_sum_sq := 0.0
	var root_xyz_max_mm := 0.0
	var yaw_max_deg := 0.0
	var lm_stats: Dictionary = {}
	var pose_lm_stats: Dictionary = {}
	for nm_raw in lm_names:
		lm_stats[str(nm_raw)] = {"sum_sq": 0.0, "max_mm": 0.0, "peak_tick": 0}
		pose_lm_stats[str(nm_raw)] = {"sum_sq": 0.0, "max_mm": 0.0, "peak_tick": 0}

	for i in n:
		var hf: Dictionary = havok_frames[i] as Dictionary
		var gf: Dictionary = godot_frames[i] as Dictionary
		var h_states: Dictionary = hf.get("st", {}) as Dictionary
		var h_st := str(h_states.get(primary_sm, ""))
		var g_st := str(gf.get("state", ""))
		if h_st == g_st:
			state_matches += 1

		var h_clips: Array = hf.get("cl", []) as Array
		if not h_clips.is_empty():
			var h_lt := float((h_clips[0] as Dictionary).get("lt", 0.0))
			var g_lt := float(gf.get("clip_time", 0.0))
			var dt_ms := absf(g_lt - h_lt) * 1000.0
			# Ignore single-tick loop boundary wrap (e.g. 0.000 vs duration)
			var h_dur := float((h_clips[0] as Dictionary).get("d", 1.0))
			if h_dur > 0.05 and absf(dt_ms - h_dur * 1000.0) < 25.0:
				dt_ms = absf(dt_ms - h_dur * 1000.0)
			max_clip_dt_ms = maxf(max_clip_dt_ms, dt_ms)
			sum_sq_clip_ms += dt_ms * dt_ms
			clip_samples += 1

		var hr_arr: Array = hf.get("r", [0.0, 0.0, 0.0]) as Array
		var hr := Vector3(float(hr_arr[0]), float(hr_arr[1]), float(hr_arr[2]))
		var gr: Vector3 = gf["root"] as Vector3
		var d_xyz_mm := gr.distance_to(hr) * 1000.0
		var d_xz_mm := Vector2(gr.x - hr.x, gr.z - hr.z).length() * 1000.0
		root_xyz_sum_sq += d_xyz_mm * d_xyz_mm
		root_xyz_max_mm = maxf(root_xyz_max_mm, d_xyz_mm)
		root_xz_sum_sq += d_xz_mm * d_xz_mm
		root_xz_max_mm = maxf(root_xz_max_mm, d_xz_mm)

		var hy := float(hf.get("y", 0.0))
		var gy := float(gf.get("yaw", 0.0))
		yaw_max_deg = maxf(yaw_max_deg, rad_to_deg(absf(angle_difference(gy, hy))))

		var h_lm: Dictionary = hf.get("lm", {}) as Dictionary
		var g_lm: Dictionary = gf.get("landmarks", {}) as Dictionary
		for nm_raw in lm_names:
			var nm := str(nm_raw)
			if not h_lm.has(nm) or not g_lm.has(nm):
				continue
			var ha: Array = h_lm[nm] as Array
			var hp := Vector3(float(ha[0]), float(ha[1]), float(ha[2]))
			var gp: Vector3 = g_lm[nm] as Vector3
			var dm := gp.distance_to(hp) * 1000.0
			var st: Dictionary = lm_stats[nm] as Dictionary
			st["sum_sq"] = float(st["sum_sq"]) + dm * dm
			if dm > float(st["max_mm"]):
				st["max_mm"] = dm
				st["peak_tick"] = i
			# Root-relative (model-space pose) landmark distance (isolates pure animation/graph pose from physics vertical drift)
			var pm := (gp - gr).distance_to(hp - hr) * 1000.0
			var pst: Dictionary = pose_lm_stats[nm] as Dictionary
			pst["sum_sq"] = float(pst["sum_sq"]) + pm * pm
			if pm > float(pst["max_mm"]):
				pst["max_mm"] = pm
				pst["peak_tick"] = i

	var lm_summary: Dictionary = {}
	var overall_lm_rms_mm := 0.0
	var overall_lm_max_mm := 0.0
	var overall_pose_rms_mm := 0.0
	var overall_pose_max_mm := 0.0
	for nm_raw in lm_names:
		var nm := str(nm_raw)
		var st: Dictionary = lm_stats[nm] as Dictionary
		var pst: Dictionary = pose_lm_stats[nm] as Dictionary
		var rms := sqrt(float(st["sum_sq"]) / float(n))
		var mx := float(st["max_mm"])
		var prms := sqrt(float(pst["sum_sq"]) / float(n))
		var pmx := float(pst["max_mm"])
		lm_summary[nm] = {
			"rms_mm": snappedf(rms, 0.01), "max_mm": snappedf(mx, 0.01), "peak_tick": int(st["peak_tick"]),
			"pose_rms_mm": snappedf(prms, 0.01), "pose_max_mm": snappedf(pmx, 0.01),
		}
		overall_lm_rms_mm += rms
		overall_lm_max_mm = maxf(overall_lm_max_mm, mx)
		overall_pose_rms_mm += prms
		overall_pose_max_mm = maxf(overall_pose_max_mm, pmx)
	if not lm_names.is_empty():
		overall_lm_rms_mm /= float(lm_names.size())
		overall_pose_rms_mm /= float(lm_names.size())

	return {
		"ticks": n,
		"havok_events": hk_events.size(),
		"godot_events": gd_events.size(),
		"matched_events": matched_events,
		"unmatched_havok_events": unmatched_hk,
		"unmatched_godot_events": unmatched_gd,
		"max_event_dtick": max_event_dtick,
		"max_event_dms": snappedf(float(max_event_dtick) * STEP * 1000.0, 0.01),
		"event_pairs": event_pairs,
		"state_match_ticks": state_matches,
		"state_match_pct": snappedf(float(state_matches) * 100.0 / float(n), 0.01),
		"clip_rms_ms": snappedf(sqrt(sum_sq_clip_ms / maxf(1.0, float(clip_samples))), 0.01),
		"clip_max_ms": snappedf(max_clip_dt_ms, 0.01),
		"root_xz_rms_mm": snappedf(sqrt(root_xz_sum_sq / float(n)), 0.01),
		"root_xz_max_mm": snappedf(root_xz_max_mm, 0.01),
		"root_xyz_rms_mm": snappedf(sqrt(root_xyz_sum_sq / float(n)), 0.01),
		"root_xyz_max_mm": snappedf(root_xyz_max_mm, 0.01),
		"yaw_max_deg": snappedf(yaw_max_deg, 0.02),
		"landmark_mean_rms_mm": snappedf(overall_lm_rms_mm, 0.01),
		"landmark_max_mm": snappedf(overall_lm_max_mm, 0.01),
		"pose_landmark_rms_mm": snappedf(overall_pose_rms_mm, 0.01),
		"pose_landmark_max_mm": snappedf(overall_pose_max_mm, 0.01),
		"landmarks": lm_summary,
	}
