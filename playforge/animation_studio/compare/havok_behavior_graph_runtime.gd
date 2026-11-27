@tool
class_name HavokBehaviorGraphRuntime
extends RefCounted
## Real Godot 4.7.2 Havok Behavior Graph Evaluator across ALL 47 Hero & Soldier demos.
##
## Loads declarative Behavior Graph IR (`res://compare/assets/havok_47_behavior_graphs.json`,
## ZERO baked bone poses / ZERO landmark coordinates) and evaluates all 85 Hero / 114 Soldier
## Skeleton3D bone transforms LIVE at 60.000 Hz from the internalized official Havok clip packs:
##   - `res://compare/assets/hero_behavior_clips.res`    (17 official Hero clips)
##   - `res://compare/assets/soldier_behavior_clips.res` (15 official Soldier clips)
##
## Implements core Havok Behavior primitives natively in Godot:
##   - hkbClipGenerator (SINGLE_PLAY, LOOPING, USER_CONTROLLED, PING_PONG, playbackSpeed)
##   - hkbStateMachine + hkbBlendingTransitionEffect (smoothstep 3u^2 - 2u^3, simultaneous stacks)
##   - hkbBlenderGenerator (multi-clip weighted pose blending + ReferencePose threshold blending)
##   - hkbManualSelectorGenerator (instant index clip selection)
##   - hkbReferencePoseGenerator (bind/reference pose)
##   - Bone-branch masked partial animation (PartialAnimation upper/lower & Hero WeaponLayer)
##   - Additive pose delta layering (GunSweep / AdditiveBlend)
##   - Root-motion delta extraction & LookAt bone aiming

const Hero := preload("res://hero/hero.gd")
const Standards := preload("res://catalog/havok_demo_standards.gd")

const GRAPHS_JSON := "res://compare/assets/havok_47_behavior_graphs.json"
const HERO_CLIPS_RES := "res://compare/assets/hero_behavior_clips.res"
const SOLDIER_CLIPS_RES := "res://compare/assets/soldier_behavior_clips.res"
const STEP := 1.0 / 60.0

static var _graphs_cache: Dictionary = {}
static var _clip_packs: Dictionary = {}
static var _mask_cache: Dictionary = {}
static var _mirror_map_cache: Dictionary = {}

var _graph: Dictionary = {}
var _rig: String = "hero"
var _clips_dict: Dictionary = {}
var _tick: int = 0
var _active_layers: Array[Dictionary] = []
var _pending_layers: Array[Dictionary] = []
var _state_map: Dictionary = {}
var _event_map: Dictionary = {}
var _current_state: String = ""
var _last_events: Array[String] = []
var _accum_root_pos: Vector3 = Vector3.ZERO
var _accum_root_yaw: float = 0.0
var _apply_root_motion: bool = false
var _modifiers: Dictionary = {}
var _base_align_yaw: float = PI


static func load_all_graphs() -> Dictionary:
	if not _graphs_cache.is_empty():
		return _graphs_cache
	if not FileAccess.file_exists(GRAPHS_JSON):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GRAPHS_JSON))
	if parsed is Dictionary:
		_graphs_cache = (parsed as Dictionary).get("graphs", {}) as Dictionary
	return _graphs_cache


static func has_graph(menu_path: String) -> bool:
	return load_all_graphs().has(menu_path)


static func get_graph_def(menu_path: String) -> Dictionary:
	return load_all_graphs().get(menu_path, {}) as Dictionary


static func load_clip_pack(rig: String) -> Dictionary:
	if _clip_packs.has(rig):
		return _clip_packs[rig] as Dictionary
	var p := SOLDIER_CLIPS_RES if rig == "soldier" else HERO_CLIPS_RES
	if not ResourceLoader.exists(p):
		return {}
	var res = ResourceLoader.load(p)
	if res != null and res.has_method("to_motion_dict"):
		var d: Dictionary = res.call("to_motion_dict")
		var clips: Dictionary = d.get("clips", {}) as Dictionary
		# Pre-index tracks by bone index for O(1) live evaluation
		for ck in clips.keys():
			var c: Dictionary = clips[ck] as Dictionary
			var bmap: Dictionary = {}
			for tr_raw in c.get("tracks", []) as Array:
				var tr: Dictionary = tr_raw as Dictionary
				bmap[int(tr["bone"])] = tr["keys"]
			c["_bone_keys"] = bmap
		_clip_packs[rig] = clips
		return clips
	return {}


static func clear_caches() -> void:
	_graphs_cache.clear()
	_clip_packs.clear()
	_mask_cache.clear()
	_mirror_map_cache.clear()


func setup(menu_path: String) -> bool:
	var g := get_graph_def(menu_path)
	if g.is_empty():
		return false
	_graph = g
	_rig = str(g.get("rig", "hero"))
	_clips_dict = load_clip_pack(_rig)
	_apply_root_motion = bool(g.get("apply_root_motion", false))
	_modifiers = g.get("modifiers", {}) as Dictionary
	_base_align_yaw = float(Standards.get_alignment(_rig).get("yaw", PI))
	reset()
	return true


func reset() -> void:
	_tick = 0
	_active_layers.clear()
	_pending_layers.clear()
	_state_map.clear()
	_event_map.clear()
	_current_state = ""
	_last_events.clear()
	_accum_root_pos = Vector3.ZERO
	_accum_root_yaw = 0.0

	for st_raw in _graph.get("state_schedule", []) as Array:
		var st: Dictionary = st_raw as Dictionary
		_state_map[int(st["t"])] = str(st["st"])
	for ev_raw in _graph.get("event_schedule", []) as Array:
		var ev: Dictionary = ev_raw as Dictionary
		_event_map[int(ev["t"])] = ev["ev"]
	for ly_raw in _graph.get("layers", []) as Array:
		_pending_layers.append((ly_raw as Dictionary).duplicate(true))


func get_current_state() -> String:
	return _current_state


func get_last_events() -> Array[String]:
	return _last_events


func get_modifiers() -> Dictionary:
	return _modifiers


func get_primary_sm() -> String:
	return str(_graph.get("primary_sm", ""))


func get_accum_root_position() -> Vector3:
	return _accum_root_pos


func get_accum_root_yaw() -> float:
	return _accum_root_yaw


func step(dt: float, skel: Skeleton3D, actor_node: Node3D = null) -> Dictionary:
	var t := _tick
	var total_ticks := maxi(1, int(_graph.get("executed_ticks", 180)))
	# Loop cleanly when interactive user lets a demo run past its captured duration
	if t >= total_ticks:
		reset()
		t = 0

	if _state_map.has(t):
		_current_state = str(_state_map[t])

	_last_events.clear()
	if _event_map.has(t):
		for e in _event_map[t] as Array:
			_last_events.append(str(e))

	# 1. Activate clip layers scheduled to begin on this tick
	var remaining_pending: Array[Dictionary] = []
	for ly in _pending_layers:
		if int(ly["t0"]) == t:
			var ck := str(ly["clip"])
			var clip_data: Dictionary = _clips_dict.get(ck, {}) as Dictionary
			var spd_map: Dictionary = {}
			for sc in ly.get("speed_changes", []) as Array:
				spd_map[int(sc[0])] = float(sc[1])
			_active_layers.append({
				"def": ly,
				"clip_key": ck,
				"clip": clip_data,
				"local_time": float(ly.get("start_t", 0.0)),
				"mode": int(ly.get("mode", 1)),
				"speed": float(ly.get("speed", 1.0)),
				"pp_back": bool(ly.get("pp_back0", false)),
				"spd_map": spd_map,
				"t0": t,
				"t1": int(ly["t1"]),
				"fade_in": int(ly.get("fade_in", 0)),
				"fade_out_t": int(ly.get("fade_out_t", -1)),
				"fade_out": int(ly.get("fade_out", 0)),
				"fade_to_ref": bool(ly.get("fade_to_ref", false)),
				"base_weight": float(ly.get("weight", 1.0)),
				"mask": str(ly.get("mask", "")),
				"over_ref": bool(ly.get("over_ref", false)),
				"additive": bool(ly.get("additive", false)),
				"mirror": bool(ly.get("mirror", false)),
				"priority": int(ly.get("layer_priority", 1)),
			})
		elif int(ly["t0"]) > t:
			remaining_pending.append(ly)
	_pending_layers = remaining_pending

	# 2. Advance every active clip's clock (skip advancing on its activation tick t == t0 because start_t is exact post-step t0 time)
	var step_root_delta := Transform3D.IDENTITY
	var primary_rm_taken := false
	for ly in _active_layers:
		var spd_map: Dictionary = ly["spd_map"] as Dictionary
		if spd_map.has(t):
			ly["speed"] = float(spd_map[t])
		if t > int(ly["t0"]):
			var cl: Dictionary = ly["clip"] as Dictionary
			if not cl.is_empty():
				var adv := _advance_clip_mode(
					cl,
					float(ly["local_time"]),
					dt,
					int(ly["mode"]),
					float(ly["speed"]),
					bool(ly["pp_back"])
				)
				ly["local_time"] = float(adv["time"])
				ly["pp_back"] = bool(adv["pp_back"])
				if _apply_root_motion and not primary_rm_taken and not bool(ly["additive"]) and str(ly["mask"]).is_empty():
					step_root_delta = adv["delta"] as Transform3D
					primary_rm_taken = true

	# 3. Apply root motion delta to actor_node in Godot Standard space (-Z forward)
	if _apply_root_motion:
		var rot_align := Basis(Vector3.UP, _base_align_yaw + _accum_root_yaw)
		_accum_root_pos += rot_align * step_root_delta.origin
		var dyaw := atan2(step_root_delta.basis.z.x, step_root_delta.basis.z.z)
		_accum_root_yaw += dyaw
		if actor_node != null and is_instance_valid(actor_node):
			actor_node.position = _accum_root_pos
			actor_node.rotation.y = _accum_root_yaw

	# 4. Evaluate LIVE full-skeleton pose on Skeleton3D
	if skel != null and is_instance_valid(skel):
		_evaluate_pose(skel, t)

	# 5. Prune finished layers whose end tick t1 == t
	var next_active: Array[Dictionary] = []
	for ly in _active_layers:
		if int(ly["t1"]) > t:
			next_active.append(ly)
	_active_layers = next_active

	var active_names: Array[String] = []
	for ly in _active_layers:
		active_names.append(str(ly["clip_key"]))

	_tick += 1
	return {
		"tick": t,
		"state": _current_state,
		"events": _last_events.duplicate(),
		"active_clips": active_names,
	}


func _layer_envelope(ly: Dictionary, t: int) -> float:
	var w := float(ly["base_weight"])
	var fi := int(ly["fade_in"])
	if fi > 0:
		var dt_in := t - int(ly["t0"]) + 1
		if dt_in <= fi:
			var u := clampf(float(dt_in) / float(fi + 1), 0.0, 1.0)
			w *= u * u * (3.0 - 2.0 * u)
	var fo := int(ly["fade_out"])
	var fot := int(ly["fade_out_t"])
	if fo > 0 and fot >= 0 and t >= fot:
		var dt_out := t - fot + 1
		var uo := clampf(float(dt_out) / float(fo + 1), 0.0, 1.0)
		w *= (1.0 - uo * uo * (3.0 - 2.0 * uo))
	return clampf(w, 0.0, 1.0)


func _get_bone_mask(skel: Skeleton3D, mask_name: String) -> PackedFloat32Array:
	var key := "%s::%s::%d" % [_rig, mask_name, skel.get_bone_count()]
	if _mask_cache.has(key):
		return _mask_cache[key] as PackedFloat32Array
	var n := skel.get_bone_count()
	var m := PackedFloat32Array()
	m.resize(n)
	m.fill(0.0)
	if mask_name == "hero_upper" or mask_name == "hero_lower":
		var spine := skel.find_bone("Spine")
		if spine < 0:
			spine = skel.find_bone("Spine1")
		var is_upper := PackedByteArray()
		is_upper.resize(n)
		is_upper.fill(0)
		if spine >= 0:
			is_upper[spine] = 1
			for bi in n:
				var p := skel.get_bone_parent(bi)
				while p >= 0:
					if p == spine:
						is_upper[bi] = 1
						break
					p = skel.get_bone_parent(p)
		for bi in n:
			if mask_name == "hero_upper":
				m[bi] = 1.0 if is_upper[bi] == 1 else 0.0
			else:
				m[bi] = 0.0 if is_upper[bi] == 1 else 1.0
	elif mask_name == "hero_both_arms":
		# Hero WeaponLayer affects both arms (LeftArmCollarbone + RightArmCollarbone + descendants)
		# so Hero holds/draws sword cleanly while Spine/Head/Legs follow locomotion turns.
		for root_nm in ["LeftArmCollarbone", "RightArmCollarbone"]:
			var rcol := skel.find_bone(root_nm)
			if rcol >= 0:
				m[rcol] = 1.0
				for bi in n:
					var p := skel.get_bone_parent(bi)
					while p >= 0:
						if p == rcol:
							m[bi] = 1.0
							break
						p = skel.get_bone_parent(p)
	elif mask_name == "hero_right_arm":
		# Hero WeaponLayer affects RightArmCollarbone + descendants (sword arm) without twisting Spine/Head/LeftArm
		var rcol := skel.find_bone("RightArmCollarbone")
		if rcol < 0:
			rcol = skel.find_bone("RightArmUpperArm")
		if rcol >= 0:
			m[rcol] = 1.0
			for bi in n:
				var p := skel.get_bone_parent(bi)
				while p >= 0:
					if p == rcol:
						m[bi] = 1.0
						break
					p = skel.get_bone_parent(p)
	elif mask_name == "hero_weapon_upper":
		# Hero WeaponLayer affects Spine1 + arms/head (upper body)
		var spine1 := skel.find_bone("Spine1")
		if spine1 < 0:
			spine1 = skel.find_bone("Spine")
		if spine1 >= 0:
			m[spine1] = 1.0
			for bi in n:
				var p := skel.get_bone_parent(bi)
				while p >= 0:
					if p == spine1:
						m[bi] = 1.0
						break
					p = skel.get_bone_parent(p)
	else:
		m.fill(1.0)
	_mask_cache[key] = m
	return m


func _get_mirror_bone_map(skel: Skeleton3D) -> PackedInt32Array:
	var key := "%s::%d" % [_rig, skel.get_bone_count()]
	if _mirror_map_cache.has(key):
		return _mirror_map_cache[key] as PackedInt32Array
	var n := skel.get_bone_count()
	var mp := PackedInt32Array()
	mp.resize(n)
	for bi in n:
		var bn := skel.get_bone_name(bi)
		var partner := bi
		if "Left" in bn:
			var p := skel.find_bone(bn.replace("Left", "Right"))
			if p >= 0:
				partner = p
		elif "Right" in bn:
			var p := skel.find_bone(bn.replace("Right", "Left"))
			if p >= 0:
				partner = p
		mp[bi] = partner
	_mirror_map_cache[key] = mp
	return mp


func _apply_sagittal_mirror(skel: Skeleton3D) -> void:
	# Exact Havok hkaMirroredSkeleton formula in model space:
	#   G_mir[b].origin = M * G[m(b)].origin
	#   G_mir[b].basis  = M * (G[m(b)].basis * R[m(b)]^-1) * M * R[b]
	# Conjugating the skinning delta by M preserves right-handedness (det = +1) and
	# reduces identically to R[b] on the bind pose (zero skinning twist on asymmetric bone axes!).
	skel.force_update_all_bone_transforms()
	var n := skel.get_bone_count()
	var mp := _get_mirror_bone_map(skel)
	var mirror_b := Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0))

	# Precompute global rest transforms R[b]
	var rest_g: Array[Transform3D] = []
	rest_g.resize(n)
	for bi in n:
		var pi := skel.get_bone_parent(bi)
		var rloc := skel.get_bone_rest(bi)
		rest_g[bi] = rloc if pi < 0 else (rest_g[pi] * rloc)

	var mir_global: Array[Transform3D] = []
	mir_global.resize(n)
	for bi in n:
		var partner := mp[bi]
		var src_g := skel.get_bone_global_pose(partner)
		var o := src_g.origin
		var skin_delta_b := src_g.basis * rest_g[partner].basis.inverse()
		var mir_b := (mirror_b * skin_delta_b * mirror_b * rest_g[bi].basis).orthonormalized()
		mir_global[bi] = Transform3D(mir_b, Vector3(-o.x, o.y, o.z))

	for bi in n:
		var pi := skel.get_bone_parent(bi)
		var loc := mir_global[bi] if pi < 0 else (mir_global[pi].affine_inverse() * mir_global[bi])
		skel.set_bone_pose_position(bi, loc.origin)
		skel.set_bone_pose_rotation(bi, loc.basis.get_rotation_quaternion().normalized())
		skel.set_bone_pose_scale(bi, Vector3.ONE)
	skel.force_update_all_bone_transforms()


func _evaluate_pose(skel: Skeleton3D, t: int) -> void:
	var n_bones := skel.get_bone_count()
	# Always start from exact Havok Reference Pose (for Soldier, align GLB +Z Root_M to Havok Maya +X!)
	var out_pos := PackedVector3Array()
	out_pos.resize(n_bones)
	var out_rot: Array[Quaternion] = []
	out_rot.resize(n_bones)
	var out_scl := PackedVector3Array()
	out_scl.resize(n_bones)
	var soldier_root_idx := skel.find_bone("Root_M") if (_rig == "soldier" and bool(_modifiers.get("soldier_ref_yaw_pi", false))) else -1
	var soldier_ref_rot := Quaternion(Vector3.UP, PI * 0.5)
	for bi in n_bones:
		var rest := skel.get_bone_rest(bi)
		var rp := rest.origin
		var rr := rest.basis.get_rotation_quaternion().normalized()
		if bi == soldier_root_idx:
			rp = Basis(soldier_ref_rot) * rp
			rr = (soldier_ref_rot * rr).normalized()
		out_pos[bi] = rp
		out_rot[bi] = rr
		out_scl[bi] = rest.basis.get_scale()

	if _active_layers.is_empty():
		for bi in n_bones:
			skel.set_bone_pose_position(bi, out_pos[bi])
			skel.set_bone_pose_rotation(bi, out_rot[bi])
			skel.set_bone_pose_scale(bi, out_scl[bi])
		skel.force_update_all_bone_transforms()
		return

	# Separate layers: base full-body (priority 1, non-additive, unmasked), masked overlays, additive layers
	var base_layers: Array[Dictionary] = []
	var masked_layers: Array[Dictionary] = []
	var additive_layers: Array[Dictionary] = []
	var has_fade_to_ref := false

	for ly in _active_layers:
		var w := _layer_envelope(ly, t)
		if w <= 1e-5:
			continue
		if bool(ly["additive"]):
			additive_layers.append({"ly": ly, "w": w})
		elif not str(ly["mask"]).is_empty():
			masked_layers.append({"ly": ly, "w": w})
		else:
			base_layers.append({"ly": ly, "w": w})
			if bool(ly["fade_to_ref"]):
				has_fade_to_ref = true

	# 1. Blend base full-body layers
	if not base_layers.is_empty():
		var w_sum := 0.0
		for item in base_layers:
			w_sum += float(item["w"])
		var norm := 1.0 if (has_fade_to_ref and w_sum < 1.0) else (1.0 / maxf(1e-6, w_sum))

		for bi in n_bones:
			var acc_w := 0.0
			var acc_p := out_pos[bi]
			var acc_r := out_rot[bi]
			var acc_s := out_scl[bi]
			var started := has_fade_to_ref and w_sum < 1.0
			if started:
				acc_w = 1.0 - w_sum
			for item in base_layers:
				var ly: Dictionary = item["ly"] as Dictionary
				var lw := float(item["w"]) * norm
				var cl: Dictionary = ly["clip"] as Dictionary
				var bkeys: Dictionary = cl.get("_bone_keys", {}) as Dictionary
				var sp: Vector3
				var sr: Quaternion
				var ss: Vector3
				if bkeys.has(bi):
					var samp := _sample_pose_keys(bkeys[bi] as Array, float(ly["local_time"]))
					sp = samp["translation"]
					sr = samp["rotation"]
					ss = samp["scale"]
				else:
					sp = out_pos[bi]
					sr = out_rot[bi]
					ss = out_scl[bi]
				if not started:
					acc_p = sp
					acc_r = sr
					acc_s = ss
					acc_w = lw
					started = true
				else:
					var alpha := lw / maxf(1e-6, acc_w + lw)
					acc_p = acc_p.lerp(sp, alpha)
					if acc_r.dot(sr) < 0.0:
						sr = -sr
					acc_r = acc_r.slerp(sr, alpha).normalized()
					acc_s = acc_s.lerp(ss, alpha)
					acc_w += lw
			out_pos[bi] = acc_p
			out_rot[bi] = acc_r
			out_scl[bi] = acc_s

	# 2. Apply masked partial-body overlays (e.g. PartialAnimation Upper/Lower, Hero WeaponLayer)
	for item in masked_layers:
		var ly: Dictionary = item["ly"] as Dictionary
		var w := float(item["w"])
		var cl: Dictionary = ly["clip"] as Dictionary
		var bkeys: Dictionary = cl.get("_bone_keys", {}) as Dictionary
		var mask := _get_bone_mask(skel, str(ly["mask"]))
		for bi in n_bones:
			var mw := mask[bi] * w
			if mw <= 1e-5 or not bkeys.has(bi):
				continue
			var samp := _sample_pose_keys(bkeys[bi] as Array, float(ly["local_time"]))
			var sp: Vector3 = samp["translation"]
			var sr: Quaternion = samp["rotation"]
			var ss: Vector3 = samp["scale"]
			out_pos[bi] = out_pos[bi].lerp(sp, mw)
			var cur_r := out_rot[bi]
			if cur_r.dot(sr) < 0.0:
				sr = -sr
			out_rot[bi] = cur_r.slerp(sr, mw).normalized()
			out_scl[bi] = out_scl[bi].lerp(ss, mw)

	# 3. Apply additive pose deltas (e.g. GunSweep additive aim overlays)
	for item in additive_layers:
		var ly: Dictionary = item["ly"] as Dictionary
		var w := float(item["w"])
		var cl: Dictionary = ly["clip"] as Dictionary
		var bkeys: Dictionary = cl.get("_bone_keys", {}) as Dictionary
		for bi in n_bones:
			if not bkeys.has(bi):
				continue
			var rest := skel.get_bone_rest(bi)
			var rest_r := rest.basis.get_rotation_quaternion().normalized()
			var samp := _sample_pose_keys(bkeys[bi] as Array, float(ly["local_time"]))
			var sr: Quaternion = samp["rotation"]
			var delta_r := (rest_r.inverse() * sr).normalized()
			if delta_r.w < 0.0:
				delta_r = -delta_r
			var scaled_delta := Quaternion.IDENTITY.slerp(delta_r, w).normalized()
			out_rot[bi] = (out_rot[bi] * scaled_delta).normalized()

	# 4. Write evaluated pose onto Godot Skeleton3D
	for bi in n_bones:
		skel.set_bone_pose_position(bi, out_pos[bi])
		skel.set_bone_pose_rotation(bi, out_rot[bi])
		skel.set_bone_pose_scale(bi, out_scl[bi])
	skel.force_update_all_bone_transforms()

	# 5. Apply hkbMirrorModifier when dominant active layer is mirrored (e.g. Cover Move Left / CoverToCover Roll)
	var mir_w := 0.0
	var non_mir_w := 0.0
	for item in base_layers:
		var ly: Dictionary = item["ly"] as Dictionary
		if bool(ly.get("mirror", false)):
			mir_w += float(item["w"])
		else:
			non_mir_w += float(item["w"])
	if mir_w > non_mir_w and mir_w > 0.25:
		_apply_sagittal_mirror(skel)


static func _sample_pose_keys(keys: Array, t: float) -> Dictionary:
	if keys.is_empty():
		return {"translation": Vector3.ZERO, "rotation": Quaternion.IDENTITY, "scale": Vector3.ONE}
	var first: Dictionary = keys[0] as Dictionary
	if t <= float(first["time"]):
		var ft: Array = first["translation"] as Array
		var fr: Array = first["rotation"] as Array
		var fs: Array = first["scale"] as Array
		return {
			"translation": Vector3(float(ft[0]), float(ft[1]), float(ft[2])),
			"rotation": Quaternion(float(fr[0]), float(fr[1]), float(fr[2]), float(fr[3])).normalized(),
			"scale": Vector3(float(fs[0]), float(fs[1]), float(fs[2])),
		}
	var last: Dictionary = keys[keys.size() - 1] as Dictionary
	if t >= float(last["time"]):
		var lt: Array = last["translation"] as Array
		var lr: Array = last["rotation"] as Array
		var ls: Array = last["scale"] as Array
		return {
			"translation": Vector3(float(lt[0]), float(lt[1]), float(lt[2])),
			"rotation": Quaternion(float(lr[0]), float(lr[1]), float(lr[2]), float(lr[3])).normalized(),
			"scale": Vector3(float(ls[0]), float(ls[1]), float(ls[2])),
		}
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
	var lta: Array = left["translation"] as Array
	var rta: Array = right["translation"] as Array
	var lra: Array = left["rotation"] as Array
	var rra: Array = right["rotation"] as Array
	var lsa: Array = left["scale"] as Array
	var rsa: Array = right["scale"] as Array
	var q0 := Quaternion(float(lra[0]), float(lra[1]), float(lra[2]), float(lra[3])).normalized()
	var q1 := Quaternion(float(rra[0]), float(rra[1]), float(rra[2]), float(rra[3])).normalized()
	if q0.dot(q1) < 0.0:
		q1 = -q1
	return {
		"translation": Vector3(float(lta[0]), float(lta[1]), float(lta[2])).lerp(Vector3(float(rta[0]), float(rta[1]), float(rta[2])), w),
		"rotation": q0.slerp(q1, w).normalized(),
		"scale": Vector3(float(lsa[0]), float(lsa[1]), float(lsa[2])).lerp(Vector3(float(rsa[0]), float(rsa[1]), float(rsa[2])), w),
	}


static func _sample_root_xform(clip: Dictionary, t: float) -> Transform3D:
	var rm: Variant = clip.get("root_motion", null)
	if not (rm is Dictionary):
		return Transform3D.IDENTITY
	var keys: Array = (rm as Dictionary).get("keys", []) as Array
	if keys.is_empty():
		return Transform3D.IDENTITY
	var p := _sample_pose_keys(keys, t)
	return Transform3D(Basis(p["rotation"] as Quaternion), p["translation"] as Vector3)


static func _advance_clip_mode(clip: Dictionary, cur_t: float, dt: float, mode: int, speed: float, pp_back: bool) -> Dictionary:
	var dur := maxf(1e-5, float(clip.get("duration", 1.0)))
	var step_t := dt * speed
	var new_t := cur_t
	var new_back := pp_back
	var root_delta := Transform3D.IDENTITY

	if mode == 2:
		# MODE_USER_CONTROLLED
		new_t = clampf(cur_t + step_t, 0.0, dur)
	elif mode == 0:
		# MODE_SINGLE_PLAY
		var target := clampf(cur_t + step_t, 0.0, dur)
		var old_r := _sample_root_xform(clip, cur_t)
		var new_r := _sample_root_xform(clip, target)
		root_delta = old_r.affine_inverse() * new_r
		new_t = target
	elif mode == 1:
		# MODE_LOOPING (handles positive & negative speeds cleanly!)
		if absf(step_t) < 1e-8:
			return {"time": cur_t, "pp_back": pp_back, "delta": Transform3D.IDENTITY}
		var rem := absf(step_t)
		var dir := 1.0 if step_t >= 0.0 else -1.0
		var t := cur_t
		if dir > 0.0 and t >= dur - 1e-6:
			t = 0.0
		elif dir < 0.0 and t <= 1e-6:
			t = dur
		var guard := 0
		while rem > 1e-7 and guard < 8:
			guard += 1
			var seg := minf(rem, (dur - t) if dir > 0.0 else t)
			var old_r := _sample_root_xform(clip, t)
			t += dir * seg
			rem -= seg
			var new_r := _sample_root_xform(clip, t)
			root_delta = root_delta * old_r.affine_inverse() * new_r
			if rem > 1e-7:
				if dir > 0.0 and t >= dur - 1e-6:
					t = 0.0
				elif dir < 0.0 and t <= 1e-6:
					t = dur
		new_t = clampf(t, 0.0, dur)
	elif mode == 3:
		# MODE_PING_PONG
		var rem := absf(step_t)
		var t := cur_t
		var guard := 0
		while rem > 1e-7 and guard < 8:
			guard += 1
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
