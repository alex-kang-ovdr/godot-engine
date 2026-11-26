extends RefCounted
## Quintic inertialization blender (Bollo 2016).
## On transition, captures pose offset and velocity once, then decays offsets
## over the blend duration while evaluating only the single target clip.

const PoseBuffer = preload("pose_buffer.gd")

var _has_prev := false
var _prev_pose: PoseBuffer
var _vel_pos: PackedVector3Array = PackedVector3Array()
var _vel_rot: PackedVector3Array = PackedVector3Array()
var _vel_scale: PackedVector3Array = PackedVector3Array()

var _active := false
var _elapsed := 0.0
var _duration := 0.0
var _bone_count := 0

var _pos_x0: PackedFloat32Array = PackedFloat32Array()
var _pos_v0: PackedFloat32Array = PackedFloat32Array()
var _pos_dir: PackedVector3Array = PackedVector3Array()
var _pos_t1: PackedFloat32Array = PackedFloat32Array()

var _rot_x0: PackedFloat32Array = PackedFloat32Array()
var _rot_v0: PackedFloat32Array = PackedFloat32Array()
var _rot_axis: PackedVector3Array = PackedVector3Array()
var _rot_t1: PackedFloat32Array = PackedFloat32Array()

var _scale_x0: PackedFloat32Array = PackedFloat32Array()
var _scale_v0: PackedFloat32Array = PackedFloat32Array()
var _scale_dir: PackedVector3Array = PackedVector3Array()
var _scale_t1: PackedFloat32Array = PackedFloat32Array()


func reset() -> void:
	_has_prev = false
	_prev_pose = null
	_active = false
	_elapsed = 0.0
	_duration = 0.0
	_bone_count = 0


func is_active() -> bool:
	return _active


func remaining_time() -> float:
	return maxf(0.0, _duration - _elapsed) if _active else 0.0


func progress() -> float:
	if not _active or _duration <= 0.0:
		return 1.0
	return clampf(_elapsed / _duration, 0.0, 1.0)


func record_output(pose: PoseBuffer, delta: float) -> void:
	if pose == null:
		return
	if _has_prev and _prev_pose != null and _prev_pose.bone_count == pose.bone_count and delta > 0.0:
		var inv_dt := 1.0 / delta
		for i in pose.bone_count:
			_vel_pos[i] = (pose.positions[i] - _prev_pose.positions[i]) * inv_dt
			var dq := _prev_pose.rotations[i].inverse() * pose.rotations[i]
			if dq.w < 0.0:
				dq = -dq
			var vec := Vector3(dq.x, dq.y, dq.z)
			var vlen := vec.length()
			if vlen > 1e-6:
				var angle := 2.0 * atan2(vlen, dq.w)
				_vel_rot[i] = (vec / vlen) * (angle * inv_dt)
			else:
				_vel_rot[i] = Vector3.ZERO
			_vel_scale[i] = (pose.scales[i] - _prev_pose.scales[i]) * inv_dt
	else:
		_vel_pos.resize(pose.bone_count)
		_vel_rot.resize(pose.bone_count)
		_vel_scale.resize(pose.bone_count)
		for i in pose.bone_count:
			_vel_pos[i] = Vector3.ZERO
			_vel_rot[i] = Vector3.ZERO
			_vel_scale[i] = Vector3.ZERO
	_prev_pose = pose.duplicate_buffer()
	_has_prev = true


func trigger(target_pose: PoseBuffer, duration: float) -> bool:
	if not _has_prev or _prev_pose == null or target_pose == null or duration <= 0.0:
		_active = false
		return false
	if _prev_pose.bone_count != target_pose.bone_count:
		_active = false
		return false

	_bone_count = target_pose.bone_count
	_duration = duration
	_elapsed = 0.0
	_active = true

	_pos_x0.resize(_bone_count)
	_pos_v0.resize(_bone_count)
	_pos_dir.resize(_bone_count)
	_pos_t1.resize(_bone_count)

	_rot_x0.resize(_bone_count)
	_rot_v0.resize(_bone_count)
	_rot_axis.resize(_bone_count)
	_rot_t1.resize(_bone_count)

	_scale_x0.resize(_bone_count)
	_scale_v0.resize(_bone_count)
	_scale_dir.resize(_bone_count)
	_scale_t1.resize(_bone_count)

	for i in _bone_count:
		# Position offset
		var dp: Vector3 = _prev_pose.positions[i] - target_pose.positions[i]
		var px0 := dp.length()
		if px0 > 1e-6:
			var dir := dp / px0
			var pv0 := minf(0.0, _vel_pos[i].dot(dir))
			_pos_x0[i] = px0
			_pos_v0[i] = pv0
			_pos_dir[i] = dir
			_pos_t1[i] = _effective_duration(px0, pv0, duration)
		else:
			_pos_x0[i] = 0.0
			_pos_v0[i] = 0.0
			_pos_dir[i] = Vector3.ZERO
			_pos_t1[i] = 0.0

		# Rotation offset (q_err such that target * q_err == prev)
		var q_err: Quaternion = target_pose.rotations[i].inverse() * _prev_pose.rotations[i]
		if q_err.w < 0.0:
			q_err = -q_err
		var qvec := Vector3(q_err.x, q_err.y, q_err.z)
		var qlen := qvec.length()
		if qlen > 1e-6:
			var axis := qvec / qlen
			var rx0 := 2.0 * atan2(qlen, q_err.w)
			var rv0 := minf(0.0, _vel_rot[i].dot(axis))
			_rot_x0[i] = rx0
			_rot_v0[i] = rv0
			_rot_axis[i] = axis
			_rot_t1[i] = _effective_duration(rx0, rv0, duration)
		else:
			_rot_x0[i] = 0.0
			_rot_v0[i] = 0.0
			_rot_axis[i] = Vector3.UP
			_rot_t1[i] = 0.0

		# Scale offset
		var ds: Vector3 = _prev_pose.scales[i] - target_pose.scales[i]
		var sx0 := ds.length()
		if sx0 > 1e-6:
			var sdir := ds / sx0
			var sv0 := minf(0.0, _vel_scale[i].dot(sdir))
			_scale_x0[i] = sx0
			_scale_v0[i] = sv0
			_scale_dir[i] = sdir
			_scale_t1[i] = _effective_duration(sx0, sv0, duration)
		else:
			_scale_x0[i] = 0.0
			_scale_v0[i] = 0.0
			_scale_dir[i] = Vector3.ZERO
			_scale_t1[i] = 0.0

	return true


func apply(target_pose: PoseBuffer, delta: float) -> PoseBuffer:
	var result := target_pose.duplicate_buffer()
	if not _active:
		return result
	_elapsed += maxf(0.0, delta)
	if _elapsed >= _duration:
		_active = false
		return result
	for i in _bone_count:
		if _pos_x0[i] > 0.0 and _elapsed < _pos_t1[i]:
			var p_mag := _eval_quintic(_pos_x0[i], _pos_v0[i], _pos_t1[i], _elapsed)
			result.positions[i] += _pos_dir[i] * p_mag
		if _rot_x0[i] > 0.0 and _elapsed < _rot_t1[i]:
			var r_ang := _eval_quintic(_rot_x0[i], _rot_v0[i], _rot_t1[i], _elapsed)
			result.rotations[i] = (result.rotations[i] * Quaternion(_rot_axis[i], r_ang)).normalized()
		if _scale_x0[i] > 0.0 and _elapsed < _scale_t1[i]:
			var s_mag := _eval_quintic(_scale_x0[i], _scale_v0[i], _scale_t1[i], _elapsed)
			result.scales[i] += _scale_dir[i] * s_mag
	return result


static func _effective_duration(x0: float, v0: float, max_duration: float) -> float:
	if v0 < -1e-6:
		return minf(max_duration, -5.0 * x0 / v0)
	return max_duration


static func _eval_quintic(x0: float, v0: float, t1: float, t: float) -> float:
	if t <= 0.0:
		return x0
	if t >= t1 or t1 <= 1e-6:
		return 0.0
	var t1_2 := t1 * t1
	var t1_3 := t1_2 * t1
	var t1_4 := t1_3 * t1
	var t1_5 := t1_4 * t1
	var a0 := (-8.0 * v0 * t1 - 20.0 * x0) / t1_2
	var A := -(a0 * t1_2 + 6.0 * v0 * t1 + 12.0 * x0) / (2.0 * t1_5)
	var B := (3.0 * a0 * t1_2 + 16.0 * v0 * t1 + 30.0 * x0) / (2.0 * t1_4)
	var C := -(3.0 * a0 * t1_2 + 12.0 * v0 * t1 + 20.0 * x0) / (2.0 * t1_3)
	var t2 := t * t
	var t3 := t2 * t
	var t4 := t3 * t
	var t5 := t4 * t
	return A * t5 + B * t4 + C * t3 + 0.5 * a0 * t2 + v0 * t + x0
