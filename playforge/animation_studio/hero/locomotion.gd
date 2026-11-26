extends RefCounted
## Deterministic playback for the SDK Hero locomotion clips.
## The Behavior graph chooses walking with the left trigger, running otherwise,
## and stops after the stick remains in its dead zone for 0.1 seconds.

# Hero's controller uses squared stick distances for the dead zone and hold timer.
const STICK_THRESHOLD_SQUARED := 0.1
const STICK_RESPONSE := 0.9
const START_HOLD := 0.01
const STOP_HOLD := 0.1
# Locomotion state switches before its outgoing animation finishes blending.
const IDLE_BLEND_TIME := 0.18
# Forward replay selects Walk_Face_180 and enters Walking 26 physics ticks later.
const WALK_ENTRY_TIME := 26.0 / 60.0
# The SDK transition turns the initial rig around to face camera-relative forward.
const FORWARD_HEADING := PI

var _rig: Skeleton3D
var _motion: Node3D
var _clips: Dictionary
var _clip_name := ""
var _clip_time := 0.0
var _state := "idle"
var _filtered_stick := Vector2.ZERO
var _stick_hold := 0.0
var _state_elapsed := 0.0
var _outgoing_clip: Dictionary
var _outgoing_time := 0.0
var _outgoing_loop := true
var _blend_duration := 0.0
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
	_filtered_stick = Vector2.ZERO
	_stick_hold = 0.0
	_state_elapsed = 0.0
	_outgoing_clip = {}
	_outgoing_time = 0.0
	_blend_duration = 0.0
	_motion.rotation.y = 0.0 if clips.has("idle_to_walk") else FORWARD_HEADING
	_facing_angle = _motion.rotation.y
	_enter_clip("idle")


func step(stick: Vector2, delta: float, walk_modifier := false) -> Dictionary:
	if _rig == null or _motion == null or delta <= 0.0:
		return _result(Vector3.ZERO)

	var previous_stick := _filtered_stick
	_filtered_stick = previous_stick.lerp(stick, STICK_RESPONSE)
	if previous_stick.distance_squared_to(_filtered_stick) < STICK_THRESHOLD_SQUARED:
		_stick_hold += delta
	else:
		_stick_hold = 0.0
	var magnitude := _filtered_stick.length()
	var moving := _filtered_stick.length_squared() >= STICK_THRESHOLD_SQUARED
	var next_state := choose_state(moving, walk_modifier)
	var entering := next_state != _state
	if entering:
		_blend_duration = transition_blend(_state, next_state)
		_outgoing_clip = _clips[_clip_name] if _blend_duration > 0.0 else {}
		_outgoing_time = _clip_time
		_outgoing_loop = _clip_name != "idle_to_walk"
		_state = next_state
		_state_elapsed = 0.0
		_enter_clip(_state)

	_input_speed = magnitude if moving else 0.0
	var target_yaw := FORWARD_HEADING + atan2(_filtered_stick.x, _filtered_stick.y)
	var yaw_gain := 2.0 if _state == "walk" else 3.0
	var yaw_step := 0.0
	if _state != "idle_to_walk" and moving and magnitude >= 0.5:
		yaw_step = wrapf(target_yaw - _motion.rotation.y, -PI, PI) * yaw_gain * delta

	var clip: Dictionary = _clips[_clip_name]
	var sample := advance_clip(clip, _clip_time, 0.0 if entering else delta, _clip_name != "idle_to_walk")
	_clip_time = sample.time
	var root_delta: Transform3D = sample.delta
	var outgoing_weight := 0.0
	if not _outgoing_clip.is_empty():
		outgoing_weight = maxf(0.0, 1.0 - _state_elapsed / _blend_duration)
		if outgoing_weight > 0.0:
			var outgoing := advance_clip(_outgoing_clip, _outgoing_time, delta, _outgoing_loop)
			_outgoing_time = outgoing.time
			root_delta = root_delta.interpolate_with(outgoing.delta, outgoing_weight)
		else:
			_outgoing_clip = {}
	_apply_pose(clip, _clip_time, outgoing_weight)
	_state_elapsed += delta
	_motion.transform = _motion.transform * root_delta
	_motion.rotation.y += yaw_step
	_turning = not is_zero_approx(yaw_step)
	_facing_angle = _motion.rotation.y
	return _result(root_delta.origin)


func advance_clip(clip: Dictionary, time: float, delta: float, loop := true) -> Dictionary:
	var root_delta := Transform3D.IDENTITY
	var duration := float(clip.duration)
	var remaining := delta
	while remaining > 0.0 and duration > 0.0:
		var segment := minf(remaining, duration - time)
		var old_root := _sample_root(clip, time)
		time += segment
		remaining -= segment
		root_delta = root_delta * old_root.affine_inverse() * _sample_root(clip, time)
		if time >= duration:
			if not loop:
				break
			time = 0.0
	return {"time": time, "delta": root_delta}


static func transition_blend(previous: String, next: String) -> float:
	if next == "idle":
		return IDLE_BLEND_TIME
	# The reference still evaluates Walk Face 180 four ticks after entering Walking.
	if previous == "idle_to_walk" and next == "walk":
		return 0.13
	if previous == "walk" and next == "run":
		return 0.06
	if previous == "idle" and next == "idle_to_walk":
		return 0.06
	return 0.0


func choose_state(moving: bool, walk_modifier: bool) -> String:
	if _state == "idle":
		if moving and _stick_hold > START_HOLD:
			return "idle_to_walk" if walk_modifier else "run"
		return "idle"
	if not moving and _stick_hold > STOP_HOLD + 0.000001:
		return "idle"
	if moving and not walk_modifier:
		return "run"
	if _state == "idle_to_walk":
		return "walk" if _state_elapsed + 0.000001 >= WALK_ENTRY_TIME else "idle_to_walk"
	return "walk" if moving else _state


func _enter_clip(name: String) -> void:
	var chosen := "walk" if name == "idle_to_walk" and not _clips.has(name) else name
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


func _apply_pose(clip: Dictionary, time: float, outgoing_weight := 0.0) -> void:
	var previous := {}
	if outgoing_weight > 0.0:
		for track in _outgoing_clip.tracks:
			previous[int(track.bone)] = _sample_pose(track.keys, _outgoing_time)
	for track in clip.get("tracks", []):
		var bone := int(track.bone)
		var pose := _sample_pose(track.keys, time)
		if pose.is_empty():
			continue
		var position := pose_vector(pose.translation)
		var rotation := pose_rotation(pose.rotation)
		var scale := pose_vector(pose.scale)
		if previous.has(bone):
			var outgoing: Dictionary = previous[bone]
			position = position.lerp(pose_vector(outgoing.translation), outgoing_weight)
			rotation = rotation.slerp(pose_rotation(outgoing.rotation), outgoing_weight)
			scale = scale.lerp(pose_vector(outgoing.scale), outgoing_weight)
		_rig.set_bone_pose_position(bone, position)
		_rig.set_bone_pose_rotation(bone, rotation)
		_rig.set_bone_pose_scale(bone, scale)
	_rig.force_update_all_bone_transforms()


static func pose_vector(value: Variant) -> Vector3:
	return value if value is Vector3 else Vector3(value[0], value[1], value[2])


static func pose_rotation(value: Variant) -> Quaternion:
	return value.normalized() if value is Quaternion else Quaternion(value[0], value[1], value[2], value[3]).normalized()


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
