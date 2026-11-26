extends RefCounted
## Single-slot masked pose graph with inertialized state transitions.
## Evaluates strictly 1 base clip even during transitions, plus 1 optional
## masked slot clip when active.

const PoseBuffer = preload("pose_buffer.gd")
const InertialBlender = preload("inertial_blender.gd")

var _states: Dictionary = {} # StringName -> {animation, loop}
var _current_state: StringName = &""
var _state_time := 0.0
var _transition_from: StringName = &""
var _pending_inertial := false
var _pending_inertial_duration := 0.0
var _blender := InertialBlender.new()
var _root_motion_bone: StringName = &""

# Single masked overlay slot
var _slot_active := false
var _slot_name: StringName = &""
var _slot_anim: Animation = null
var _slot_mask: PackedFloat32Array = PackedFloat32Array()
var _slot_time := 0.0
var _slot_blend_in := 0.08
var _slot_blend_out := 0.12
var _slot_cancelling := false
var _slot_cancel_elapsed := 0.0
var _slot_cancel_duration := 0.08
var _slot_cancel_start_weight := 0.0

var last_snapshot: Dictionary = {}


func configure(root_motion_bone: StringName = &"") -> void:
	_root_motion_bone = root_motion_bone


func add_state(state_name: StringName, animation: Animation, loop: bool = true) -> void:
	_states[state_name] = {"animation": animation, "loop": loop}


func reset(initial_state: StringName) -> void:
	_current_state = initial_state
	_state_time = 0.0
	_transition_from = &""
	_pending_inertial = false
	_pending_inertial_duration = 0.0
	_blender.reset()
	_clear_slot()
	last_snapshot = {}


func transition_to(state_name: StringName, inertial_duration: float = 0.2) -> bool:
	if not _states.has(state_name) or state_name == _current_state:
		return false
	_transition_from = _current_state
	_current_state = state_name
	_state_time = 0.0
	_pending_inertial = inertial_duration > 0.0
	_pending_inertial_duration = inertial_duration
	return true


func play_slot(slot_name: StringName, animation: Animation, mask: PackedFloat32Array, blend_in: float = 0.08, blend_out: float = 0.12) -> bool:
	if animation == null or mask.is_empty():
		return false
	_slot_active = true
	_slot_name = slot_name
	_slot_anim = animation
	_slot_mask = mask.duplicate()
	_slot_time = 0.0
	_slot_blend_in = maxf(0.0, blend_in)
	_slot_blend_out = maxf(0.0, blend_out)
	_slot_cancelling = false
	_slot_cancel_elapsed = 0.0
	return true


func cancel_slot(blend_out: float = 0.08) -> void:
	if not _slot_active or _slot_cancelling:
		return
	_slot_cancel_start_weight = _compute_slot_weight()
	_slot_cancelling = true
	_slot_cancel_elapsed = 0.0
	_slot_cancel_duration = maxf(0.001, blend_out)


func is_slot_active() -> bool:
	return _slot_active


func get_current_state() -> StringName:
	return _current_state


func evaluate(delta: float, skeleton: Skeleton3D) -> Dictionary:
	if not _states.has(_current_state) or not is_instance_valid(skeleton):
		return {}

	var entry: Dictionary = _states[_current_state]
	var base_anim: Animation = entry.animation
	var loop: bool = entry.loop
	if delta > 0.0 and base_anim.length > 0.0:
		if _pending_inertial:
			# Sample at t=0 on the transition tick so inertial offset starts cleanly.
			_state_time = 0.0
		else:
			_state_time += delta
			if loop:
				_state_time = fposmod(_state_time, base_anim.length)
			else:
				_state_time = minf(_state_time, base_anim.length)

	# Strictly 1 base clip evaluated, even while inertializing.
	var base_pose := PoseBuffer.new()
	base_pose.sample_animation(base_anim, skeleton, _state_time, false, _root_motion_bone)
	var base_clips_evaluated := 1

	if _pending_inertial:
		_blender.trigger(base_pose, _pending_inertial_duration)
		_pending_inertial = false

	var blended_base := _blender.apply(base_pose, delta)
	_blender.record_output(blended_base, delta)

	var final_pose := blended_base.duplicate_buffer()
	var slot_clips_evaluated := 0
	var slot_weight := 0.0
	var active_slot_name: StringName = &""

	if _slot_active and _slot_anim != null:
		if _slot_cancelling:
			_slot_cancel_elapsed += maxf(0.0, delta)
			var u := clampf(_slot_cancel_elapsed / _slot_cancel_duration, 0.0, 1.0)
			slot_weight = _slot_cancel_start_weight * (1.0 - _smoothstep(u))
			if u >= 1.0:
				_clear_slot()
		else:
			_slot_time += maxf(0.0, delta)
			if _slot_time >= _slot_anim.length:
				_clear_slot()
			else:
				slot_weight = _compute_slot_weight()

		if _slot_active and slot_weight > 0.0001:
			var slot_pose := PoseBuffer.new()
			slot_pose.sample_animation(_slot_anim, skeleton, minf(_slot_time, _slot_anim.length), false, _root_motion_bone)
			slot_clips_evaluated = 1
			active_slot_name = _slot_name
			final_pose.blend_masked(slot_pose, _slot_mask, slot_weight)

	final_pose.apply_to_skeleton(skeleton)

	var inertial_active := _blender.is_active()
	if not inertial_active:
		_transition_from = &""

	var active_nodes: Array[String] = [String(_current_state)]
	if inertial_active:
		active_nodes.append("Inertialize")
	if slot_clips_evaluated > 0:
		active_nodes.append("Slot:" + String(active_slot_name))

	last_snapshot = {
		"state": String(_current_state),
		"state_time": _state_time,
		"transition_from": String(_transition_from),
		"inertial_active": inertial_active,
		"inertial_remaining": _blender.remaining_time(),
		"inertial_progress": _blender.progress(),
		"slot_name": String(active_slot_name),
		"slot_weight": slot_weight,
		"slot_time": _slot_time if _slot_active else 0.0,
		"base_clips_evaluated": base_clips_evaluated,
		"slot_clips_evaluated": slot_clips_evaluated,
		"total_clips_evaluated": base_clips_evaluated + slot_clips_evaluated,
		"active_nodes": active_nodes,
	}
	return last_snapshot


func _compute_slot_weight() -> float:
	if not _slot_active or _slot_anim == null:
		return 0.0
	var length := _slot_anim.length
	var w_in := 1.0
	if _slot_blend_in > 0.0 and _slot_time < _slot_blend_in:
		w_in = _smoothstep(clampf(_slot_time / _slot_blend_in, 0.0, 1.0))
	var w_out := 1.0
	var time_left := length - _slot_time
	if _slot_blend_out > 0.0 and time_left < _slot_blend_out:
		w_out = _smoothstep(clampf(time_left / _slot_blend_out, 0.0, 1.0))
	return minf(w_in, w_out)


func _clear_slot() -> void:
	_slot_active = false
	_slot_name = &""
	_slot_anim = null
	_slot_mask = PackedFloat32Array()
	_slot_time = 0.0
	_slot_cancelling = false
	_slot_cancel_elapsed = 0.0


static func _smoothstep(u: float) -> float:
	return u * u * (3.0 - 2.0 * u)
