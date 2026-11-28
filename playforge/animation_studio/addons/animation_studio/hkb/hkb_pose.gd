@tool
class_name HkbPose
extends RefCounted
## Full-Skeleton Pose Buffer mirroring Havok `hkaPose` / `hkbGeneratorOutput`.
## Automatically accelerates pose sampling, weighted SLERP blending, additive deltas,
## `hkaMirroredSkeleton` sagittal mirroring, and skeleton pose writes via the C++
## GDExtension `AnimationStudioHkbKernel` when available, with automatic pure-GDScript
## fallback when the native DLL is absent (e.g. WebAssembly / non-Windows platforms).

const NATIVE_CLASS := &"AnimationStudioHkbKernel"
const NATIVE_DESCRIPTOR := "res://addons/animation_studio/bin/animation_studio_pose_sampler.gdextension"

static var force_gdscript_fallback: bool = false
static var _native_kernel: RefCounted = null
static var _native_checked: bool = false

var bone_count: int = 0
var pos: PackedVector3Array = PackedVector3Array()
var rot_xyzw: PackedFloat32Array = PackedFloat32Array()
var scl: PackedVector3Array = PackedVector3Array()
var root_delta_pos: Vector3 = Vector3.ZERO
var root_delta_yaw: float = 0.0


static func get_native_kernel() -> RefCounted:
	if force_gdscript_fallback:
		return null
	if not _native_checked:
		_native_checked = true
		if not ClassDB.class_exists(NATIVE_CLASS):
			if OS.has_feature("windows") and OS.has_feature("x86_64") and OS.has_feature("debug"):
				if FileAccess.file_exists(NATIVE_DESCRIPTOR):
					GDExtensionManager.load_extension(NATIVE_DESCRIPTOR)
		if ClassDB.class_exists(NATIVE_CLASS):
			_native_kernel = ClassDB.instantiate(NATIVE_CLASS)
	return _native_kernel


static func is_native_active() -> bool:
	return get_native_kernel() != null


func get_rot(bi: int) -> Quaternion:
	var o := bi * 4
	if o < 0 or o + 3 >= rot_xyzw.size():
		return Quaternion.IDENTITY
	return Quaternion(rot_xyzw[o], rot_xyzw[o + 1], rot_xyzw[o + 2], rot_xyzw[o + 3])


func set_rot(bi: int, q: Quaternion) -> void:
	var o := bi * 4
	if o < 0 or o + 3 >= rot_xyzw.size():
		return
	rot_xyzw[o] = q.x
	rot_xyzw[o + 1] = q.y
	rot_xyzw[o + 2] = q.z
	rot_xyzw[o + 3] = q.w


func init_from_skeleton(skel: Skeleton3D) -> void:
	if skel == null or not is_instance_valid(skel):
		bone_count = 0
		return
	var k := get_native_kernel()
	if k != null:
		var d: Dictionary = k.call(&"init_pose_from_skeleton", skel) as Dictionary
		bone_count = int(d.get("bone_count", 0))
		pos = d.get("pos", PackedVector3Array()) as PackedVector3Array
		rot_xyzw = d.get("rot_xyzw", PackedFloat32Array()) as PackedFloat32Array
		scl = d.get("scl", PackedVector3Array()) as PackedVector3Array
	else:
		bone_count = skel.get_bone_count()
		pos.resize(bone_count)
		rot_xyzw.resize(bone_count * 4)
		scl.resize(bone_count)
		for bi in bone_count:
			var rest := skel.get_bone_rest(bi)
			pos[bi] = rest.origin
			set_rot(bi, rest.basis.get_rotation_quaternion().normalized())
			scl[bi] = rest.basis.get_scale()
	root_delta_pos = Vector3.ZERO
	root_delta_yaw = 0.0


func read_from_skeleton(skel: Skeleton3D) -> void:
	if skel == null or not is_instance_valid(skel):
		bone_count = 0
		return
	var k := get_native_kernel()
	if k != null:
		var d: Dictionary = k.call(&"read_pose_from_skeleton", skel) as Dictionary
		bone_count = int(d.get("bone_count", 0))
		pos = d.get("pos", PackedVector3Array()) as PackedVector3Array
		rot_xyzw = d.get("rot_xyzw", PackedFloat32Array()) as PackedFloat32Array
		scl = d.get("scl", PackedVector3Array()) as PackedVector3Array
	else:
		bone_count = skel.get_bone_count()
		pos.resize(bone_count)
		rot_xyzw.resize(bone_count * 4)
		scl.resize(bone_count)
		for bi in bone_count:
			pos[bi] = skel.get_bone_pose_position(bi)
			set_rot(bi, skel.get_bone_pose_rotation(bi).normalized())
			scl[bi] = skel.get_bone_pose_scale(bi)
	root_delta_pos = Vector3.ZERO
	root_delta_yaw = 0.0


func clone() -> RefCounted:
	var c = get_script().new()
	c.bone_count = bone_count
	c.pos = pos.duplicate()
	c.rot_xyzw = rot_xyzw.duplicate()
	c.scl = scl.duplicate()
	c.root_delta_pos = root_delta_pos
	c.root_delta_yaw = root_delta_yaw
	return c


static func _ensure_packed_clip(clip: Dictionary) -> Dictionary:
	if clip.has("_packed_hkb"):
		return clip["_packed_hkb"] as Dictionary
	var fps := float(clip.get("fps", 60.0))
	if fps <= 1e-4:
		fps = 60.0
	var bkeys: Dictionary = clip.get("_bone_keys", {}) as Dictionary
	if bkeys.is_empty():
		for tr_raw in clip.get("tracks", []) as Array:
			var tr: Dictionary = tr_raw as Dictionary
			bkeys[int(tr["bone"])] = tr["keys"]
		clip["_bone_keys"] = bkeys

	var bone_ids := PackedInt32Array()
	var key_offsets := PackedInt32Array()
	var key_counts := PackedInt32Array()
	var total_keys := 0
	for bi in bkeys.keys():
		var keys: Array = bkeys[bi] as Array
		var kn := keys.size()
		if kn <= 0:
			continue
		bone_ids.append(int(bi))
		key_offsets.append(total_keys)
		key_counts.append(kn)
		total_keys += kn

	var key_times := PackedFloat32Array()
	var key_pos := PackedVector3Array()
	var key_rot := PackedFloat32Array()
	key_times.resize(total_keys)
	key_pos.resize(total_keys)
	key_rot.resize(total_keys * 4)

	var inv_fps := 1.0 / fps
	var cursor := 0
	for ti in bone_ids.size():
		var keys: Array = bkeys[bone_ids[ti]] as Array
		var kn := keys.size()
		var is_dict: bool = (keys[0] is Dictionary)
		for ki in kn:
			var dst_i := cursor + ki
			var ro := dst_i * 4
			if is_dict:
				var kd: Dictionary = keys[ki] as Dictionary
				key_times[dst_i] = float(kd["time"])
				var ta: Array = kd["translation"] as Array
				var ra: Array = kd["rotation"] as Array
				key_pos[dst_i] = Vector3(float(ta[0]), float(ta[1]), float(ta[2]))
				var q := Quaternion(float(ra[0]), float(ra[1]), float(ra[2]), float(ra[3])).normalized()
				key_rot[ro] = q.x
				key_rot[ro + 1] = q.y
				key_rot[ro + 2] = q.z
				key_rot[ro + 3] = q.w
			else:
				var a: Array = keys[ki] as Array
				key_times[dst_i] = float(ki) * inv_fps
				key_pos[dst_i] = Vector3(float(a[0]), float(a[1]), float(a[2]))
				var q := Quaternion(float(a[3]), float(a[4]), float(a[5]), float(a[6])).normalized()
				key_rot[ro] = q.x
				key_rot[ro + 1] = q.y
				key_rot[ro + 2] = q.z
				key_rot[ro + 3] = q.w
		cursor += kn

	var packed := {
		"bone_ids": bone_ids,
		"key_offsets": key_offsets,
		"key_counts": key_counts,
		"key_times": key_times,
		"key_pos": key_pos,
		"key_rot_xyzw": key_rot,
	}
	clip["_packed_hkb"] = packed
	return packed


func sample_clip_dict(clip: Dictionary, local_time: float, skel: Skeleton3D) -> void:
	init_from_skeleton(skel)
	if clip.is_empty() or bone_count == 0:
		return
	var k := get_native_kernel()
	if k != null:
		var pk := _ensure_packed_clip(clip)
		var res: Dictionary = k.call(
			&"sample_clip_packed",
			pos, rot_xyzw, scl,
			pk["bone_ids"], pk["key_offsets"], pk["key_counts"],
			pk["key_times"], pk["key_pos"], pk["key_rot_xyzw"],
			local_time
		) as Dictionary
		pos = res.get("pos", pos) as PackedVector3Array
		rot_xyzw = res.get("rot_xyzw", rot_xyzw) as PackedFloat32Array
		scl = res.get("scl", scl) as PackedVector3Array
		return

	# Pure-GDScript fallback
	var fps := float(clip.get("fps", 60.0))
	if fps <= 1e-4:
		fps = 60.0
	var bkeys: Dictionary = clip.get("_bone_keys", {}) as Dictionary
	if bkeys.is_empty():
		for tr_raw in clip.get("tracks", []) as Array:
			var tr: Dictionary = tr_raw as Dictionary
			bkeys[int(tr["bone"])] = tr["keys"]
		clip["_bone_keys"] = bkeys

	var f_idx := maxf(0.0, local_time * fps)
	var k0 := int(floor(f_idx))
	var frac := f_idx - float(k0)
	for bi in bkeys.keys():
		var bone_i := int(bi)
		if bone_i < 0 or bone_i >= bone_count:
			continue
		var keys: Array = bkeys[bi] as Array
		var kn := keys.size()
		if kn == 0:
			continue
		var first_elem: Variant = keys[0]
		if first_elem is Dictionary:
			var lo := 0
			var hi := kn - 1
			if local_time <= float((keys[0] as Dictionary)["time"]):
				hi = 0
			elif local_time >= float((keys[hi] as Dictionary)["time"]):
				lo = hi
			else:
				while lo + 1 < hi:
					var mid := (lo + hi) >> 1
					if float((keys[mid] as Dictionary)["time"]) <= local_time:
						lo = mid
					else:
						hi = mid
			var kd0: Dictionary = keys[lo] as Dictionary
			var kd1: Dictionary = keys[hi] as Dictionary
			var t0 := float(kd0["time"])
			var t1 := float(kd1["time"])
			var w := (local_time - t0) / (t1 - t0) if t1 > t0 else 0.0
			var ta0: Array = kd0["translation"] as Array
			var ta1: Array = kd1["translation"] as Array
			var ra0: Array = kd0["rotation"] as Array
			var ra1: Array = kd1["rotation"] as Array
			var p0 := Vector3(float(ta0[0]), float(ta0[1]), float(ta0[2]))
			var p1 := Vector3(float(ta1[0]), float(ta1[1]), float(ta1[2]))
			var q0 := Quaternion(float(ra0[0]), float(ra0[1]), float(ra0[2]), float(ra0[3])).normalized()
			var q1 := Quaternion(float(ra1[0]), float(ra1[1]), float(ra1[2]), float(ra1[3])).normalized()
			if q0.dot(q1) < 0.0:
				q1 = -q1
			pos[bone_i] = p0.lerp(p1, w)
			set_rot(bone_i, q0.slerp(q1, w).normalized())
		else:
			var i0 := clampi(k0, 0, kn - 1)
			var i1 := clampi(k0 + 1, 0, kn - 1)
			var a: Array = keys[i0] as Array
			var b: Array = keys[i1] as Array
			var p0 := Vector3(float(a[0]), float(a[1]), float(a[2]))
			var p1 := Vector3(float(b[0]), float(b[1]), float(b[2]))
			var q0 := Quaternion(float(a[3]), float(a[4]), float(a[5]), float(a[6])).normalized()
			var q1 := Quaternion(float(b[3]), float(b[4]), float(b[5]), float(b[6])).normalized()
			if q0.dot(q1) < 0.0:
				q1 = -q1
			pos[bone_i] = p0.lerp(p1, frac)
			set_rot(bone_i, q0.slerp(q1, frac).normalized())


func blend_with(other, weight: float, bone_weights: PackedFloat32Array = PackedFloat32Array()) -> void:
	if other == null or other.bone_count != bone_count or weight <= 1e-6:
		return
	var k := get_native_kernel()
	if k != null:
		var res: Dictionary = k.call(
			&"blend_poses",
			pos, rot_xyzw, scl,
			other.pos, other.rot_xyzw, other.scl,
			weight, bone_weights
		) as Dictionary
		pos = res.get("pos", pos) as PackedVector3Array
		rot_xyzw = res.get("rot_xyzw", rot_xyzw) as PackedFloat32Array
		scl = res.get("scl", scl) as PackedVector3Array
	else:
		var has_bw := not bone_weights.is_empty()
		for bi in bone_count:
			var bw := weight
			if has_bw:
				var m := bone_weights[bi] if bi < bone_weights.size() else 1.0
				bw = clampf(weight * m, 0.0, 1.0)
			if bw <= 1e-6:
				continue
			if bw >= 0.9999:
				pos[bi] = other.pos[bi]
				set_rot(bi, other.get_rot(bi))
				scl[bi] = other.scl[bi]
			else:
				pos[bi] = pos[bi].lerp(other.pos[bi], bw)
				var qa: Quaternion = get_rot(bi)
				var qb: Quaternion = other.get_rot(bi)
				if qa.dot(qb) < 0.0:
					qb = -qb
				set_rot(bi, qa.slerp(qb, bw).normalized())
				scl[bi] = scl[bi].lerp(other.scl[bi], bw)
	root_delta_pos = root_delta_pos.lerp(other.root_delta_pos, clampf(weight, 0.0, 1.0))
	root_delta_yaw = lerpf(root_delta_yaw, other.root_delta_yaw, clampf(weight, 0.0, 1.0))


func apply_additive(delta_pose, ref_pose, weight: float, bone_weights: PackedFloat32Array = PackedFloat32Array()) -> void:
	if delta_pose == null or ref_pose == null or delta_pose.bone_count != bone_count or weight <= 1e-6:
		return
	var k := get_native_kernel()
	if k != null:
		var res: Dictionary = k.call(
			&"apply_additive",
			pos, rot_xyzw,
			delta_pose.pos, delta_pose.rot_xyzw,
			ref_pose.pos, ref_pose.rot_xyzw,
			weight, bone_weights
		) as Dictionary
		pos = res.get("pos", pos) as PackedVector3Array
		rot_xyzw = res.get("rot_xyzw", rot_xyzw) as PackedFloat32Array
		return

	var has_bw := not bone_weights.is_empty()
	for bi in bone_count:
		var bw := weight
		if has_bw:
			bw = clampf(weight * (bone_weights[bi] if bi < bone_weights.size() else 1.0), 0.0, 1.0)
		if bw <= 1e-6:
			continue
		var dp: Vector3 = delta_pose.pos[bi] - ref_pose.pos[bi]
		pos[bi] += dp * bw
		var dr: Quaternion = delta_pose.get_rot(bi)
		var rr: Quaternion = ref_pose.get_rot(bi)
		var dq: Quaternion = (dr * rr.inverse()).normalized()
		if dq.w < 0.0:
			dq = -dq
		var scaled_dq := Quaternion.IDENTITY.slerp(dq, bw).normalized()
		set_rot(bi, (scaled_dq * get_rot(bi)).normalized())


func apply_mirror(skel: Skeleton3D, mirror_map: Dictionary) -> void:
	## Exact hkaMirroredSkeleton sagittal X-plane reflection: q' = m * q * m^-1 + L/R bone swap.
	if skel == null or mirror_map.is_empty() or bone_count == 0:
		return
	var pairs: PackedInt32Array = mirror_map.get("pair", PackedInt32Array())
	var ref_p: PackedVector3Array = mirror_map.get("ref_pos", PackedVector3Array())
	var ref_r_xyzw: PackedFloat32Array = mirror_map.get("ref_rot_xyzw", PackedFloat32Array())
	if pairs.size() != bone_count or ref_r_xyzw.size() != bone_count * 4:
		return

	var k := get_native_kernel()
	if k != null:
		var res: Dictionary = k.call(&"mirror_pose_local", pos, rot_xyzw, pairs, ref_p, ref_r_xyzw) as Dictionary
		pos = res.get("pos", pos) as PackedVector3Array
		rot_xyzw = res.get("rot_xyzw", rot_xyzw) as PackedFloat32Array
		return

	var src_pos := pos.duplicate()
	var src_rot := rot_xyzw.duplicate()
	for bi in bone_count:
		var partner := pairs[bi]
		if partner < 0 or partner >= bone_count:
			continue
		var po := partner * 4
		var bo := bi * 4
		var p_src := src_pos[partner]
		var q_src := Quaternion(src_rot[po], src_rot[po + 1], src_rot[po + 2], src_rot[po + 3])
		var q_ref_partner := Quaternion(ref_r_xyzw[po], ref_r_xyzw[po + 1], ref_r_xyzw[po + 2], ref_r_xyzw[po + 3])
		var q_ref_self := Quaternion(ref_r_xyzw[bo], ref_r_xyzw[bo + 1], ref_r_xyzw[bo + 2], ref_r_xyzw[bo + 3])
		var q_delta := (q_ref_partner.inverse() * q_src).normalized()
		var q_delta_m := Quaternion(q_delta.x, -q_delta.y, -q_delta.z, q_delta.w).normalized()
		set_rot(bi, (q_ref_self * q_delta_m).normalized())
		var dp := p_src - ref_p[partner]
		pos[bi] = ref_p[bi] + Vector3(-dp.x, dp.y, dp.z)


static func build_mirror_map(skel: Skeleton3D) -> Dictionary:
	var n := skel.get_bone_count()
	var pair := PackedInt32Array()
	pair.resize(n)
	var ref_rot_xyzw := PackedFloat32Array()
	ref_rot_xyzw.resize(n * 4)
	var ref_pos := PackedVector3Array()
	ref_pos.resize(n)
	var name_to_idx := {}
	for i in n:
		var nm := skel.get_bone_name(i)
		name_to_idx[nm] = i
		var r := skel.get_bone_rest(i)
		ref_pos[i] = r.origin
		var q := r.basis.get_rotation_quaternion().normalized()
		var o := i * 4
		ref_rot_xyzw[o] = q.x
		ref_rot_xyzw[o + 1] = q.y
		ref_rot_xyzw[o + 2] = q.z
		ref_rot_xyzw[o + 3] = q.w
	for i in n:
		var nm := skel.get_bone_name(i)
		var partner := i
		var cands: Array[String] = []
		if "Left" in nm:
			cands.append(nm.replace("Left", "Right"))
		elif "Right" in nm:
			cands.append(nm.replace("Right", "Left"))
		elif nm.ends_with("_L"):
			cands.append(nm.substr(0, nm.length() - 2) + "_R")
		elif nm.ends_with("_R"):
			cands.append(nm.substr(0, nm.length() - 2) + "_L")
		elif "_L_" in nm:
			cands.append(nm.replace("_L_", "_R_"))
		elif "_R_" in nm:
			cands.append(nm.replace("_R_", "_L_"))
		for c in cands:
			if name_to_idx.has(c):
				partner = int(name_to_idx[c])
				break
		pair[i] = partner
	return {"pair": pair, "ref_rot_xyzw": ref_rot_xyzw, "ref_pos": ref_pos}


func apply_to_skeleton(skel: Skeleton3D, force_update: bool = true) -> void:
	if skel == null or not is_instance_valid(skel):
		return
	var k := get_native_kernel()
	if k != null:
		k.call(&"apply_pose_to_skeleton", skel, pos, rot_xyzw, scl, force_update)
		return
	var n := mini(bone_count, skel.get_bone_count())
	for bi in n:
		skel.set_bone_pose_position(bi, pos[bi])
		skel.set_bone_pose_rotation(bi, get_rot(bi))
		skel.set_bone_pose_scale(bi, scl[bi])
	if force_update:
		skel.force_update_all_bone_transforms()
