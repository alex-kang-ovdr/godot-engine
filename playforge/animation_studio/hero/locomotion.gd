extends RefCounted
## Deterministic playback for the SDK Hero locomotion clips.
## The Behavior graph chooses walking with the left trigger, running otherwise,
## and stops after the stick remains in its dead zone for 0.1 seconds.

const DEAD_ZONE := 0.15
const STOP_DELAY := 0.1

var _rig: Skeleton3D
var _motion: Node3D
var _clips: Dictionary
var _clip_name := ""
var _clip_time := 0.0
var _state := "idle"
var _stop_elapsed := 0.0
var _input_speed := 0.0
var _turning := false
var _facing_angle := 0.0


func setup(rig: Skeleton3D, motion: Node3D, clips: Dictionary) -> void:
	_rig = rig
	_motion = motion
	_clips = clips
	_clip_name = ""
	_clip_time = 0.0
	_state = "idle"
	_stop_elapsed = 0.0
	_facing_angle = motion.rotation.y
	_enter_clip("idle")


func step(stick: Vector2, delta: float, walk_modifier := false) -> Dictionary:
	if _rig == null or _motion == null or delta <= 0.0:
		return _result(Vector3.ZERO)

	var magnitude := stick.length()
	var moving := magnitude >= DEAD_ZONE
	var next_state := _state
	if moving:
		_stop_elapsed = 0.0
		next_state = "walk" if walk_modifier else "run"
	else:
		_stop_elapsed += delta
		if _stop_elapsed >= STOP_DELAY:
			next_state = "idle"

	if next_state != _state:
		_state = next_state
		_enter_clip(_state)

	_input_speed = magnitude if moving else 0.0
	var target_yaw := atan2(stick.x, stick.y) if moving else _motion.rotation.y
	var yaw_gain := 2.0 if _state == "walk" else 3.0
	var yaw_step := 0.0
	if moving and magnitude >= 0.5:
		yaw_step = wrapf(target_yaw - _motion.rotation.y, -PI, PI) * yaw_gain * delta

	var remaining := delta
	var root_delta := Transform3D.IDENTITY
	var clip: Dictionary = _clips.get(_clip_name, {})
	var duration := float(clip.get("duration", 0.0))
	if duration <= 0.0:
		return _result(Vector3.ZERO)

	while remaining > 0.0:
		var segment := minf(remaining, duration - _clip_time)
		var old_time := _clip_time
		_clip_time += segment
		remaining -= segment
		var old_root := _sample_root(clip, old_time)
		var new_root := _sample_root(clip, _clip_time)
		root_delta = root_delta * old_root.affine_inverse() * new_root
		if _clip_time >= duration:
			_clip_time = 0.0

	_apply_pose(clip, _clip_time)
	_motion.transform = _motion.transform * root_delta
	_motion.rotation.y += yaw_step
	_turning = not is_zero_approx(yaw_step)
	_facing_angle = _motion.rotation.y
	return _result(root_delta.origin)


func _enter_clip(name: String) -> void:
	var chosen := name
	if not _clips.has(chosen):
		chosen = "idle" if _clips.has("idle") else str(_clips.keys()[0])
	_clip_name = chosen
	_clip_time = 0.0
	_apply_pose(_clips[chosen], 0.0)


func _sample_pose(keys: Array, time: float) -> Dictionary:
	if keys.is_empty():
		return {}
	if time <= float(keys[0].time):
		return keys[0]
	var last: Dictionary = keys[-1]
	if time >= float(last.time):
		return last
	for index in range(1, keys.size()):
		var right: Dictionary = keys[index]
		if time <= float(right.time):
			var left: Dictionary = keys[index - 1]
			var span := float(right.time) - float(left.time)
			var weight := (time - float(left.time)) / span if span > 0.0 else 0.0
			return {
				"translation": Vector3(left.translation[0], left.translation[1], left.translation[2]).lerp(
					Vector3(right.translation[0], right.translation[1], right.translation[2]), weight),
				"rotation": Quaternion(left.rotation[0], left.rotation[1], left.rotation[2], left.rotation[3]).slerp(
					Quaternion(right.rotation[0], right.rotation[1], right.rotation[2], right.rotation[3]), weight),
				"scale": Vector3(left.scale[0], left.scale[1], left.scale[2]).lerp(
					Vector3(right.scale[0], right.scale[1], right.scale[2]), weight)
			}
	return last


func _sample_root(clip: Dictionary, time: float) -> Transform3D:
	var root_data = clip.get("root_motion")
	if not root_data is Dictionary:
		return Transform3D.IDENTITY
	var keys: Array = root_data.get("keys", [])
	if keys.is_empty():
		return Transform3D.IDENTITY
	var pose := _sample_pose(keys, time)
	return Transform3D(
		Basis(Quaternion(pose.rotation[0], pose.rotation[1], pose.rotation[2], pose.rotation[3])),
		Vector3(pose.translation[0], pose.translation[1], pose.translation[2]))


func _apply_pose(clip: Dictionary, time: float) -> void:
	for track in clip.get("tracks", []):
		var bone_index := int(track.bone)
		var pose := _sample_pose(track.keys, time)
		if pose.is_empty():
			continue
		var position: Vector3 = pose.translation if pose.translation is Vector3 else Vector3(pose.translation[0], pose.translation[1], pose.translation[2])
		var rotation: Quaternion = pose.rotation if pose.rotation is Quaternion else Quaternion(pose.rotation[0], pose.rotation[1], pose.rotation[2], pose.rotation[3]).normalized()
		var scale: Vector3 = pose.scale if pose.scale is Vector3 else Vector3(pose.scale[0], pose.scale[1], pose.scale[2])
		_rig.set_bone_pose_position(bone_index, position)
		_rig.set_bone_pose_rotation(bone_index, rotation)
		_rig.set_bone_pose_scale(bone_index, scale)
	_rig.force_update_all_bone_transforms()


func _result(root_delta: Vector3) -> Dictionary:
	return {
		"state": _state,
		"clip": _clip_name,
		"time": _clip_time,
		"root_delta": root_delta,
		"turning": _turning,
		"speed": _input_speed,
		"facing": _facing_angle
	}
