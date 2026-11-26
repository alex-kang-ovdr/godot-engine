extends RefCounted
## Stage 3 crowd evaluator & quantized clip representation.
## Evaluates N characters x M bones in parallel via WorkerThreadPool using flat
## quantized arrays, then applies poses on the main thread with split timing.

class QuantizedClip extends RefCounted:
	var bone_count: int = 0
	var key_count: int = 0
	var duration: float = 0.0
	var sample_rate: float = 60.0
	var pos_min: Vector3 = Vector3.ZERO
	var pos_range: Vector3 = Vector3.ONE
	# 6 bytes/key/bone for 16-bit XYZ position + 8 bytes/key/bone for 16-bit XYZW quaternion = 14 bytes/key/bone
	# (vs 28 bytes/key/bone uncompressed float32 pos+rot, or 40 bytes/key/bone with scale).
	var pos_q: PackedByteArray = PackedByteArray()
	var rot_q: PackedByteArray = PackedByteArray()

	func resident_bytes() -> int:
		return pos_q.size() + rot_q.size() + 64

	static func uncompressed_bytes(p_bones: int, p_keys: int, include_scale: bool = true) -> int:
		# Per key per bone: pos(12B) + rot(16B) + optional scale(12B) + key time(4B per track)
		var per_key := (12 + 16 + (12 if include_scale else 0)) + (12 if include_scale else 8)
		return p_bones * p_keys * per_key

	static func bake_from_animation(anim: Animation, skeleton: Skeleton3D, fps: float = 60.0) -> QuantizedClip:
		var clip := QuantizedClip.new()
		clip.bone_count = skeleton.get_bone_count()
		clip.duration = anim.length
		clip.sample_rate = fps
		clip.key_count = maxi(2, int(round(anim.length * fps)) + 1)

		var pos_tracks: PackedInt32Array = PackedInt32Array()
		var rot_tracks: PackedInt32Array = PackedInt32Array()
		pos_tracks.resize(clip.bone_count)
		rot_tracks.resize(clip.bone_count)
		pos_tracks.fill(-1)
		rot_tracks.fill(-1)

		for ti in anim.get_track_count():
			var path := anim.track_get_path(ti)
			if path.get_subname_count() != 1:
				continue
			var bi := skeleton.find_bone(StringName(path.get_subname(0)))
			if bi < 0:
				continue
			match anim.track_get_type(ti):
				Animation.TYPE_POSITION_3D:
					pos_tracks[bi] = ti
				Animation.TYPE_ROTATION_3D:
					rot_tracks[bi] = ti

		var total := clip.bone_count * clip.key_count
		var raw_pos: PackedVector3Array = PackedVector3Array()
		raw_pos.resize(total)
		var raw_rot: Array[Quaternion] = []
		raw_rot.resize(total)

		var pmin := Vector3(INF, INF, INF)
		var pmax := Vector3(-INF, -INF, -INF)
		var motion_scale := skeleton.motion_scale
		for k in clip.key_count:
			var t := minf(anim.length, float(k) / fps)
			var base := k * clip.bone_count
			for b in clip.bone_count:
				var rest := skeleton.get_bone_rest(b)
				var p := rest.origin
				var r := rest.basis.get_rotation_quaternion().normalized()
				if pos_tracks[b] >= 0:
					p = anim.position_track_interpolate(pos_tracks[b], t) * motion_scale
				if rot_tracks[b] >= 0:
					r = anim.rotation_track_interpolate(rot_tracks[b], t).normalized()
				if r.w < 0.0:
					r = -r
				raw_pos[base + b] = p
				raw_rot[base + b] = r
				pmin = pmin.min(p)
				pmax = pmax.max(p)

		clip.pos_min = pmin
		clip.pos_range = Vector3(
			maxf(1e-5, pmax.x - pmin.x),
			maxf(1e-5, pmax.y - pmin.y),
			maxf(1e-5, pmax.z - pmin.z)
		)

		clip.pos_q.resize(total * 6)
		clip.rot_q.resize(total * 8)
		for idx in total:
			var p := raw_pos[idx]
			var qx := clampi(int(round(((p.x - clip.pos_min.x) / clip.pos_range.x) * 65535.0)), 0, 65535)
			var qy := clampi(int(round(((p.y - clip.pos_min.y) / clip.pos_range.y) * 65535.0)), 0, 65535)
			var qz := clampi(int(round(((p.z - clip.pos_min.z) / clip.pos_range.z) * 65535.0)), 0, 65535)
			var po := idx * 6
			clip.pos_q.encode_u16(po, qx)
			clip.pos_q.encode_u16(po + 2, qy)
			clip.pos_q.encode_u16(po + 4, qz)

			var r := raw_rot[idx]
			var ro := idx * 8
			clip.rot_q.encode_s16(ro, clampi(int(round(r.x * 32767.0)), -32767, 32767))
			clip.rot_q.encode_s16(ro + 2, clampi(int(round(r.y * 32767.0)), -32767, 32767))
			clip.rot_q.encode_s16(ro + 4, clampi(int(round(r.z * 32767.0)), -32767, 32767))
			clip.rot_q.encode_s16(ro + 6, clampi(int(round(r.w * 32767.0)), -32767, 32767))
		return clip

	func sample_bone_pos(key_idx: int, bone_idx: int) -> Vector3:
		var po := (key_idx * bone_count + bone_idx) * 6
		return Vector3(
			pos_min.x + (float(pos_q.decode_u16(po)) / 65535.0) * pos_range.x,
			pos_min.y + (float(pos_q.decode_u16(po + 2)) / 65535.0) * pos_range.y,
			pos_min.z + (float(pos_q.decode_u16(po + 4)) / 65535.0) * pos_range.z
		)

	func sample_bone_rot(key_idx: int, bone_idx: int) -> Quaternion:
		var ro := (key_idx * bone_count + bone_idx) * 8
		return Quaternion(
			float(rot_q.decode_s16(ro)) / 32767.0,
			float(rot_q.decode_s16(ro + 2)) / 32767.0,
			float(rot_q.decode_s16(ro + 4)) / 32767.0,
			float(rot_q.decode_s16(ro + 6)) / 32767.0
		).normalized()


var _clip: QuantizedClip
var _agent_count: int = 0
var _bone_count: int = 0
var _times: PackedFloat32Array = PackedFloat32Array()
var _out_pos: PackedVector3Array = PackedVector3Array()
var _out_rot: Array[Quaternion] = []
var _worker_us: PackedInt64Array = PackedInt64Array()


func setup(clip: QuantizedClip, agent_count: int) -> void:
	_clip = clip
	_agent_count = agent_count
	_bone_count = clip.bone_count
	_times.resize(agent_count)
	for i in agent_count:
		_times[i] = fposmod(float(i) * 0.037, clip.duration)
	var total := agent_count * _bone_count
	_out_pos.resize(total)
	_out_rot.resize(total)
	for i in total:
		_out_rot[i] = Quaternion.IDENTITY
	_worker_us.resize(agent_count)


func step_parallel(delta: float, skeletons: Array[Skeleton3D]) -> Dictionary:
	for i in _agent_count:
		_times[i] = fposmod(_times[i] + delta, _clip.duration)

	var t_dispatch := Time.get_ticks_usec()
	var task_id := WorkerThreadPool.add_group_task(_eval_agent, _agent_count, 8, true)
	var t_wait_start := Time.get_ticks_usec()
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	var t_wait_end := Time.get_ticks_usec()

	var t_apply_start := Time.get_ticks_usec()
	for a in _agent_count:
		var skel := skeletons[a]
		var base := a * _bone_count
		for b in _bone_count:
			skel.set_bone_pose_position(b, _out_pos[base + b])
			skel.set_bone_pose_rotation(b, _out_rot[base + b])
	var t_apply_end := Time.get_ticks_usec()

	var worker_sum_us := 0
	for i in _agent_count:
		worker_sum_us += _worker_us[i]

	return {
		"worker_cpu_ms": float(worker_sum_us) / 1000.0,
		"worker_wait_ms": float(t_wait_end - t_wait_start) / 1000.0,
		"main_apply_ms": float(t_apply_end - t_apply_start) / 1000.0,
		"main_total_ms": float((t_wait_end - t_dispatch) + (t_apply_end - t_apply_start)) / 1000.0,
	}


func _eval_agent(agent_idx: int) -> void:
	var t0 := Time.get_ticks_usec()
	var t := _times[agent_idx]
	var fkey := t * _clip.sample_rate
	var k0 := clampi(int(floor(fkey)), 0, _clip.key_count - 1)
	var k1 := mini(k0 + 1, _clip.key_count - 1)
	var frac := fkey - float(k0)
	var base := agent_idx * _bone_count
	for b in _bone_count:
		var p0 := _clip.sample_bone_pos(k0, b)
		var p1 := _clip.sample_bone_pos(k1, b)
		var r0 := _clip.sample_bone_rot(k0, b)
		var r1 := _clip.sample_bone_rot(k1, b)
		if r0.dot(r1) < 0.0:
			r1 = -r1
		_out_pos[base + b] = p0.lerp(p1, frac)
		_out_rot[base + b] = r0.slerp(r1, frac).normalized()
	_worker_us[agent_idx] = Time.get_ticks_usec() - t0
