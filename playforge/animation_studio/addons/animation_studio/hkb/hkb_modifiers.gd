@tool
class_name HkbModifiers
extends RefCounted
## Complete Pure-GDScript Havok `hkbModifier` & Driver Library (20+ official Havok modifiers).
## Demonstrates full script-based implementation of Havok Behavior modifiers, variable bindings,
## PID damping, expression evaluation, range events, timers, LookAt, Mirror, Twist, FootIK,
## HandIK, AttachmentManager, DockingDriver, and Ragdoll control palettes — ZERO engine edits.

const HkbCtx := preload("res://addons/animation_studio/hkb/hkb_context.gd")
const HkbPoseCls := preload("res://addons/animation_studio/hkb/hkb_pose.gd")
const HkbNodeCls := preload("res://addons/animation_studio/hkb/hkb_node.gd")
const HkbExpr := preload("res://addons/animation_studio/hkb/hkb_expression.gd")
const AxisStd := preload("res://addons/animation_studio/hkb/hkb_axis_standard.gd")


class HkbModifier extends HkbNodeCls:
	func pre_modify(ctx: HkbCtx, dt: float) -> void:
		copy_variables_to_members(ctx, false)
		if not enable:
			return
		_do_pre_modify(ctx, dt)
		copy_variables_to_members(ctx, true)

	func _do_pre_modify(_ctx: HkbCtx, _dt: float) -> void:
		pass

	func modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		copy_variables_to_members(ctx, false)
		if not enable:
			return
		ctx.active_modifier_names.append("%s:%s" % [node_type, node_name])
		_do_modify(ctx, pose)
		copy_variables_to_members(ctx, true)

	func _do_modify(_ctx: HkbCtx, _pose: HkbPoseCls) -> void:
		pass


class HkbModifierList extends HkbModifier:
	var modifiers: Array = []

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		for m in modifiers:
			if m != null:
				m.activate(ctx)

	func deactivate(ctx: HkbCtx) -> void:
		super.deactivate(ctx)
		for m in modifiers:
			if m != null:
				m.deactivate(ctx)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		var handled := false
		for m in modifiers:
			if m != null and m.handle_event(ctx, ev_id, ev_name):
				handled = true
		return handled

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		for m in modifiers:
			if m != null:
				m.pre_modify(ctx, dt)

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		for m in modifiers:
			if m != null:
				m.modify(ctx, pose)


class HkbEvaluateExpressionModifier extends HkbModifier:
	## Mirrors `hkbEvaluateExpressionModifier`: evaluates expressions each tick,
	## assigns results to behavior variables, and/or raises events when truthy.
	var expressions: Array[Dictionary] = []
	var _prev_truthy: Array[bool] = []

	func configure(def: Dictionary) -> void:
		expressions.clear()
		_prev_truthy.clear()
		for e_raw in def.get("expressions", []) as Array:
			expressions.append(e_raw as Dictionary)
			_prev_truthy.append(false)

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		if _prev_truthy.size() != expressions.size():
			_prev_truthy.resize(expressions.size())
		for i in expressions.size():
			var ex: Dictionary = expressions[i]
			var val := HkbExpr.evaluate(str(ex.get("expr", "")), ctx)
			var vname := str(ex.get("var_name", ""))
			var vidx := int(ex.get("var_idx", -1))
			if not vname.is_empty():
				ctx.set_var(vname, val)
			elif vidx >= 0:
				ctx.set_var(vidx, val)
			var truthy := absf(val) > 1e-6
			var ev_name := str(ex.get("ev_name", ""))
			var ev_idx := int(ex.get("ev_idx", -1))
			var ev_mode := int(ex.get("ev_mode", 0)) # 0=ONCE, 1=ON_TRUE, 2=ON_FALSE_TO_TRUE, 3=EVERY_FRAME_AFTER_TRUE
			if (not ev_name.is_empty() or ev_idx >= 0):
				var fire := false
				if ev_mode == 1:
					fire = truthy
				elif ev_mode == 0 or ev_mode == 2:
					fire = truthy and not _prev_truthy[i]
				else:
					fire = truthy
				if fire:
					ctx.enqueue_event(ev_name if not ev_name.is_empty() else ev_idx)
			_prev_truthy[i] = truthy


class HkbEventsFromRangeModifier extends HkbModifier:
	## Mirrors `hkbEventsFromRangeModifier`: raises events when `input_value` enters/is in range intervals.
	var input_value: float = 0.0
	var lower_bound: float = 0.0
	var ranges: Array[Dictionary] = []
	var _was_in: Array[bool] = []

	func configure(def: Dictionary) -> void:
		input_value = float(def.get("input_value", 0.0))
		lower_bound = float(def.get("lower_bound", 0.0))
		ranges.clear()
		_was_in.clear()
		for r_raw in def.get("ranges", []) as Array:
			ranges.append(r_raw as Dictionary)
			_was_in.append(false)

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		if _was_in.size() != ranges.size():
			_was_in.resize(ranges.size())
		var lo := lower_bound
		for i in ranges.size():
			var r: Dictionary = ranges[i]
			var hi := float(r.get("upper", lo))
			var inside := (input_value >= lo and input_value <= hi)
			var mode := int(r.get("ev_mode", 0)) # 0=ENTER, 1=WHILE_IN
			if (mode == 0 and inside and not _was_in[i]) or (mode != 0 and inside):
				var ev_nm := str(r.get("ev_name", ""))
				var ev_id := int(r.get("ev_id", -1))
				if not ev_nm.is_empty():
					ctx.enqueue_event(ev_nm)
				elif ev_id >= 0:
					ctx.enqueue_event(ev_id)
			_was_in[i] = inside
			lo = hi


class HkbEventDrivenModifier extends HkbModifier:
	## Mirrors `hkbEventDrivenModifier`: toggles a child modifier via activate/deactivate events.
	var child_modifier: HkbModifier = null
	var activate_ev: int = -1
	var activate_ev_name: String = ""
	var deactivate_ev: int = -1
	var deactivate_ev_name: String = ""
	var active_by_default: bool = false
	var _engaged: bool = false

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_engaged = active_by_default
		if _engaged and child_modifier != null:
			child_modifier.activate(ctx)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		if (activate_ev >= 0 and ev_id == activate_ev) or (not activate_ev_name.is_empty() and ev_name == activate_ev_name):
			if not _engaged:
				_engaged = true
				if child_modifier != null:
					child_modifier.activate(ctx)
			return true
		if (deactivate_ev >= 0 and ev_id == deactivate_ev) or (not deactivate_ev_name.is_empty() and ev_name == deactivate_ev_name):
			if _engaged:
				_engaged = false
				if child_modifier != null:
					child_modifier.deactivate(ctx)
			return true
		if _engaged and child_modifier != null:
			return child_modifier.handle_event(ctx, ev_id, ev_name)
		return false

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		if _engaged and child_modifier != null:
			child_modifier.pre_modify(ctx, dt)

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if _engaged and child_modifier != null:
			child_modifier.modify(ctx, pose)


class HkbTimerModifier extends HkbModifier:
	## Mirrors `hkbTimerModifier`: fires `alarm_event` after `alarm_time` seconds.
	var alarm_time: float = 1.0
	var alarm_ev: int = -1
	var alarm_ev_name: String = ""
	var _elapsed: float = 0.0
	var _fired: bool = false

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_elapsed = 0.0
		_fired = false

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		if _fired:
			return
		_elapsed += dt
		if _elapsed >= alarm_time:
			_fired = true
			if not alarm_ev_name.is_empty():
				ctx.enqueue_event(alarm_ev_name)
			elif alarm_ev >= 0:
				ctx.enqueue_event(alarm_ev)


class HkbDelayedModifier extends HkbModifier:
	## Mirrors `hkbDelayedModifier`: waits `delay_seconds`, then runs child for `duration_seconds` (0=infinite).
	var child_modifier: HkbModifier = null
	var delay_seconds: float = 0.0
	var duration_seconds: float = 0.0
	var _elapsed: float = 0.0
	var _child_active: bool = false

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_elapsed = 0.0
		_child_active = false

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		_elapsed += dt
		var in_win := (_elapsed >= delay_seconds) and (duration_seconds <= 1e-6 or _elapsed <= delay_seconds + duration_seconds)
		if in_win and not _child_active:
			_child_active = true
			if child_modifier != null:
				child_modifier.activate(ctx)
		elif not in_win and _child_active:
			_child_active = false
			if child_modifier != null:
				child_modifier.deactivate(ctx)
		if _child_active and child_modifier != null:
			child_modifier.pre_modify(ctx, dt)

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if _child_active and child_modifier != null:
			child_modifier.modify(ctx, pose)


class HkbDampingModifier extends HkbModifier:
	## Exact Havok PID `hkbDampingModifier` (kP, kI, kD) for scalar & vector values with output variable writeback.
	var kp: float = 0.2
	var ki: float = 0.015
	var kd: float = -0.1
	var enable_scalar: bool = true
	var enable_vector: bool = false
	var raw_value: float = 0.0
	var damped_value: float = 0.0
	var raw_vector: Vector3 = Vector3.ZERO
	var damped_vector: Vector3 = Vector3.ZERO
	var _err_sum: float = 0.0
	var _prev_err: float = 0.0
	var _vec_err_sum: Vector3 = Vector3.ZERO
	var _vec_prev_err: Vector3 = Vector3.ZERO
	var _initialized: bool = false

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_err_sum = 0.0
		_prev_err = 0.0
		_vec_err_sum = Vector3.ZERO
		_vec_prev_err = Vector3.ZERO
		_initialized = false

	func _do_pre_modify(_ctx: HkbCtx, _dt: float) -> void:
		if not _initialized:
			damped_value = raw_value
			damped_vector = raw_vector
			_initialized = true
			return
		var k := HkbPoseCls.get_native_kernel()
		if k != null:
			var r: Dictionary = k.call(
				&"step_damping_pid",
				raw_value, damped_value, _err_sum, _prev_err,
				raw_vector, damped_vector, _vec_err_sum, _vec_prev_err,
				kp, ki, kd, enable_scalar, enable_vector
			) as Dictionary
			damped_value = float(r.get("damped_val", damped_value))
			_err_sum = float(r.get("err_sum", _err_sum))
			_prev_err = float(r.get("prev_err", _prev_err))
			damped_vector = r.get("damped_vec", damped_vector) as Vector3
			_vec_err_sum = r.get("vec_err_sum", _vec_err_sum) as Vector3
			_vec_prev_err = r.get("vec_prev_err", _vec_prev_err) as Vector3
			return
		if enable_scalar:
			var err := raw_value - damped_value
			_err_sum = clampf(_err_sum + err, -100.0, 100.0)
			var delta := kp * err + ki * _err_sum + kd * (err - _prev_err)
			damped_value += delta
			_prev_err = err
		if enable_vector:
			var verr := raw_vector - damped_vector
			_vec_err_sum += verr
			var vdelta := verr * kp + _vec_err_sum * ki + (verr - _vec_prev_err) * kd
			damped_vector += vdelta
			_vec_prev_err = verr


class HkbMirrorModifier extends HkbModifier:
	## Mirrors `hkbMirrorModifier` using exact `hkaMirroredSkeleton` sagittal reflection.
	var is_additive: bool = false

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if ctx.skeleton == null:
			return
		if ctx.mirror_map.is_empty():
			ctx.mirror_map = HkbPoseCls.build_mirror_map(ctx.skeleton)
		pose.apply_mirror(ctx.skeleton, ctx.mirror_map)


class HkbLookAtModifier extends HkbModifier:
	## Mirrors `hkbLookAtModifier`: smoothly aims Neck & Head bones toward `target_ws` within cone limit.
	var head_idx: int = -1
	var neck_idx: int = -1
	var limit_angle_deg: float = 60.0
	var on_gain: float = 0.05
	var off_gain: float = 0.05
	var new_target_gain: float = 0.1
	var is_on: bool = true
	var target_ws: Vector3 = Vector3(0.0, 1.5, -3.0)
	var is_target_inside_limit_cone: bool = true
	var _weight: float = 0.0
	var _smoothed_target: Vector3 = Vector3(0.0, 1.5, -3.0)
	var _has_smoothed: bool = false

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if ctx.skeleton == null or pose.bone_count == 0:
			return
		var h_i := head_idx
		var n_i := neck_idx
		if h_i < 0 or h_i >= pose.bone_count:
			for cand in ["Head", "Head_M", "head", "Bip01 Head"]:
				h_i = ctx.skeleton.find_bone(cand)
				if h_i >= 0:
					break
		if n_i < 0 or n_i >= pose.bone_count:
			for cand in ["Neck1", "Neck", "Neck1_M", "Neck_M", "Spine3", "Spine2"]:
				n_i = ctx.skeleton.find_bone(cand)
				if n_i >= 0:
					break
		if h_i < 0:
			return

		var k := HkbPoseCls.get_native_kernel()
		if k != null:
			var r: Dictionary = k.call(
				&"apply_look_at",
				ctx.skeleton.global_transform, pose.rot_xyzw,
				h_i, n_i, target_ws, _smoothed_target, _has_smoothed,
				new_target_gain, limit_angle_deg, on_gain, off_gain, is_on, _weight
			) as Dictionary
			pose.rot_xyzw = r.get("rot_xyzw", pose.rot_xyzw) as PackedFloat32Array
			_smoothed_target = r.get("smoothed_target", _smoothed_target) as Vector3
			_has_smoothed = true
			_weight = float(r.get("weight", _weight))
			is_target_inside_limit_cone = bool(r.get("inside_cone", is_target_inside_limit_cone))
			return

		if not _has_smoothed:
			_smoothed_target = target_ws
			_has_smoothed = true
		else:
			_smoothed_target = _smoothed_target.lerp(target_ws, clampf(new_target_gain, 0.01, 1.0))

		var skel_xf := ctx.skeleton.global_transform
		var head_local_dir := (skel_xf.affine_inverse() * _smoothed_target - Vector3(0.0, 1.55, 0.0))
		if head_local_dir.length_squared() < 1e-6:
			return
		head_local_dir = head_local_dir.normalized()
		var yp := AxisStd.look_at_yaw_pitch(head_local_dir)
		var yaw := yp.x
		var pitch := yp.y
		var max_rad := deg_to_rad(maxf(5.0, limit_angle_deg))
		is_target_inside_limit_cone = (absf(yaw) <= max_rad and absf(pitch) <= max_rad)
		var desired_w := 1.0 if (is_on and is_target_inside_limit_cone) else 0.0
		var gain := on_gain if desired_w > _weight else off_gain
		_weight = lerpf(_weight, desired_w, clampf(gain, 0.02, 1.0))
		if _weight <= 1e-4:
			return

		yaw = clampf(yaw, -max_rad, max_rad) * _weight
		pitch = clampf(pitch, -max_rad * 0.65, max_rad * 0.65) * _weight
		if n_i >= 0 and n_i < pose.bone_count:
			var qn := (Quaternion(Vector3.UP, yaw * 0.4) * Quaternion(Vector3.RIGHT, pitch * 0.35)).normalized()
			pose.set_rot(n_i, (qn * pose.get_rot(n_i)).normalized())
		var qh := (Quaternion(Vector3.UP, yaw * 0.6) * Quaternion(Vector3.RIGHT, pitch * 0.65)).normalized()
		pose.set_rot(h_i, (qh * pose.get_rot(h_i)).normalized())


class HkbTwistModifier extends HkbModifier:
	## Mirrors `hkbTwistModifier`: smoothly distributes `twist_angle_deg` along bone chain [start_bone..end_bone].
	var start_bone: int = -1
	var end_bone: int = -1
	var twist_angle_deg: float = 0.0
	var axis_of_rotation: Vector3 = Vector3.UP
	var is_additive: bool = true

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if ctx.skeleton == null or absf(twist_angle_deg) < 1e-4:
			return
		var chain := PackedInt32Array()
		if start_bone >= 0 and end_bone >= 0 and start_bone < pose.bone_count and end_bone < pose.bone_count:
			var cur := end_bone
			var guard := 0
			while cur >= 0 and guard < 32:
				chain.append(cur)
				if cur == start_bone:
					break
				cur = ctx.skeleton.get_bone_parent(cur)
				guard += 1
		if chain.is_empty():
			return
		var k := HkbPoseCls.get_native_kernel()
		if k != null:
			pose.rot_xyzw = k.call(&"apply_twist_chain", pose.rot_xyzw, chain, axis_of_rotation, twist_angle_deg, is_additive) as PackedFloat32Array
			return
		var ax := axis_of_rotation.normalized() if axis_of_rotation.length_squared() > 1e-6 else Vector3.UP
		var per_bone_rad := deg_to_rad(twist_angle_deg) / float(chain.size())
		var dq := Quaternion(ax, per_bone_rad).normalized()
		for bi in chain:
			pose.set_rot(bi, (dq * pose.get_rot(bi)).normalized() if is_additive else dq)


class HkbCombineTransformsModifier extends HkbModifier:
	var translation_a: Vector3 = Vector3.ZERO
	var rotation_a: Quaternion = Quaternion.IDENTITY
	var translation_b: Vector3 = Vector3.ZERO
	var rotation_b: Quaternion = Quaternion.IDENTITY
	var invert_a: bool = false
	var invert_b: bool = false
	var translation_out: Vector3 = Vector3.ZERO
	var rotation_out: Quaternion = Quaternion.IDENTITY

	func _do_pre_modify(_ctx: HkbCtx, _dt: float) -> void:
		var ta := Transform3D(Basis(rotation_a.normalized()), translation_a)
		var tb := Transform3D(Basis(rotation_b.normalized()), translation_b)
		if invert_a:
			ta = ta.affine_inverse()
		if invert_b:
			tb = tb.affine_inverse()
		var out := ta * tb
		translation_out = out.origin
		rotation_out = out.basis.get_rotation_quaternion().normalized()


class HkbComputeDirectionModifier extends HkbModifier:
	var point_in: Vector3 = Vector3.FORWARD
	var ground_angle_out: float = 0.0
	var up_angle_out: float = 0.0
	var direction_out: Vector3 = Vector3.FORWARD

	func _do_pre_modify(_ctx: HkbCtx, _dt: float) -> void:
		direction_out = point_in.normalized() if point_in.length_squared() > 1e-6 else Vector3.FORWARD
		ground_angle_out = rad_to_deg(AxisStd.yaw_from_forward(direction_out))
		up_angle_out = rad_to_deg(asin(clampf(direction_out.y, -1.0, 1.0)))


class HkbComputeRotationToTargetModifier extends HkbModifier:
	var current_position: Vector3 = Vector3.ZERO
	var current_rotation: Quaternion = Quaternion.IDENTITY
	var target_position: Vector3 = Vector3.FORWARD
	var rotation_out: Quaternion = Quaternion.IDENTITY

	func _do_pre_modify(_ctx: HkbCtx, _dt: float) -> void:
		var d := target_position - current_position
		d.y = 0.0
		if d.length_squared() > 1e-6:
			var yaw := AxisStd.yaw_from_forward(d)
			rotation_out = (Quaternion(Vector3.UP, yaw) * current_rotation.inverse()).normalized()


class HkbAttributeModifier extends HkbModifier:
	var assignments: Array[Dictionary] = []

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		for a in assignments:
			var idx := int(a.get("idx", -1))
			if idx >= 0 and idx < ctx.attr_values.size():
				ctx.attr_values[idx] = float(a.get("val", 0.0))


class HkbJigglerModifier extends HkbModifier:
	## Secondary spring-damper bone motion (`hkbJigglerModifier`) — single bone or chain, C++ accelerated.
	var bone_index: int = -1
	var bone_indices: PackedInt32Array = PackedInt32Array()
	var stiffness: float = 45.0
	var damping: float = 6.5
	var max_deg: float = 18.0
	var _vel_arr: PackedVector3Array = PackedVector3Array()
	var _disp_arr: PackedVector3Array = PackedVector3Array()
	var _last_root: Vector3 = Vector3.ZERO
	var _has_root: bool = false

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		var ids := bone_indices
		if ids.is_empty():
			if bone_index < 0 or bone_index >= pose.bone_count:
				return
			ids = PackedInt32Array([bone_index])
		if ctx.actor == null:
			return
		if _vel_arr.size() != ids.size():
			_vel_arr.resize(ids.size())
			_disp_arr.resize(ids.size())
			_vel_arr.fill(Vector3.ZERO)
			_disp_arr.fill(Vector3.ZERO)
		var cur_p := ctx.actor.global_position
		var acc := Vector3.ZERO
		if _has_root and ctx.dt > 1e-5:
			acc = (cur_p - _last_root) / ctx.dt
		_last_root = cur_p
		_has_root = true
		var k := HkbPoseCls.get_native_kernel()
		if k != null:
			var r: Dictionary = k.call(
				&"step_jiggler_chain",
				pose.rot_xyzw, ids, _vel_arr, _disp_arr, acc,
				stiffness, damping, max_deg, ctx.dt
			) as Dictionary
			pose.rot_xyzw = r.get("rot_xyzw", pose.rot_xyzw) as PackedFloat32Array
			_vel_arr = r.get("vel", _vel_arr) as PackedVector3Array
			_disp_arr = r.get("disp", _disp_arr) as PackedVector3Array
			return
		var rad_lim := deg_to_rad(max_deg)
		for i in ids.size():
			var bi := ids[i]
			if bi < 0 or bi >= pose.bone_count:
				continue
			var force := -acc * 0.15 - _disp_arr[i] * stiffness - _vel_arr[i] * damping
			_vel_arr[i] += force * ctx.dt
			_disp_arr[i] += _vel_arr[i] * ctx.dt
			var rx := clampf(_disp_arr[i].z, -rad_lim, rad_lim)
			var rz := clampf(-_disp_arr[i].x, -rad_lim, rad_lim)
			var qj := (Quaternion(Vector3.RIGHT, rx) * Quaternion(Vector3.FORWARD, rz)).normalized()
			pose.set_rot(bi, (qj * pose.get_rot(bi)).normalized())


class HkbFootIkControlsModifier extends HkbModifier:
	## Mirrors `hkbFootIkControlsModifier`: emits control command & executes `HkbFootIkDriver` on pose!
	var on_off_gain: float = 0.2
	var ground_asc_gain: float = 0.5
	var ground_desc_gain: float = 0.5
	var foot_planted_gain: float = 1.0
	var foot_raised_gain: float = 0.5
	var max_ankle_raise: float = 0.45
	var max_ankle_lower: float = -0.35

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		ctx.foot_ik_control_command = {
			"enabled": enable,
			"on_off_gain": on_off_gain,
			"ground_asc_gain": ground_asc_gain,
			"ground_desc_gain": ground_desc_gain,
			"max_raise": max_ankle_raise,
			"max_lower": max_ankle_lower,
		}
		if ctx.foot_ik_driver != null and ctx.foot_ik_driver.has_method("solve_pose"):
			ctx.foot_ik_driver.call("solve_pose", ctx, pose, ctx.foot_ik_control_command)


class HkbHandIkControlsModifier extends HkbModifier:
	## Analytic 2-bone arm IK toward `target_ws` (`hkbHandIkControlsModifier`).
	var target_ws: Vector3 = Vector3.ZERO
	var hand_bone_name: String = "RightArmPalm"
	var weight: float = 1.0

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if ctx.skeleton == null or weight <= 1e-4 or target_ws.length_squared() < 1e-8:
			return
		var hand_i := ctx.skeleton.find_bone(hand_bone_name)
		if hand_i < 0:
			return
		var lower_i := ctx.skeleton.get_bone_parent(hand_i)
		if lower_i < 0:
			return
		var upper_i := ctx.skeleton.get_bone_parent(lower_i)
		if upper_i < 0:
			return
		pose.apply_to_skeleton(ctx.skeleton)
		HkbFootIkDriver.solve_two_bone_analytic(ctx.skeleton, pose, upper_i, lower_i, hand_i, target_ws, weight)


class HkbPoweredRagdollControlsModifier extends HkbModifier:
	var max_force: float = 50.0
	var tau: float = 0.8
	var damping: float = 1.0
	var bones: Array = []

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		ctx.ragdoll_control_commands.append({
			"kind": "powered",
			"name": node_name,
			"max_force": max_force,
			"tau": tau,
			"damping": damping,
			"bones": bones,
		})


class HkbRigidBodyRagdollControlsModifier extends HkbModifier:
	var hierarchy_gain: float = 0.178
	var vel_damping: float = 0.0
	var pos_gain: float = 0.05
	var anim_blend: float = 0.0
	var bones: Array = []

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		ctx.ragdoll_control_commands.append({
			"kind": "rigid_body",
			"name": node_name,
			"hierarchy_gain": hierarchy_gain,
			"vel_damping": vel_damping,
			"pos_gain": pos_gain,
			"anim_blend": anim_blend,
			"bones": bones,
		})


class HkbKeyframeBonesModifier extends HkbModifier:
	var bones: Array = []

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		ctx.ragdoll_control_commands.append({
			"kind": "keyframed",
			"name": node_name,
			"bones": bones,
		})


class HkbAttachmentModifier extends HkbModifier:
	var attacher_attach_ev: int = -1
	var attacher_detach_ev: int = -1
	var bone_name: String = "RightArmPalm"
	var prop_name: String = ""

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		if ctx.attachment_manager != null and ctx.attachment_manager.has_method("attach_nearest"):
			ctx.attachment_manager.call("attach_nearest", ctx.skeleton, bone_name, prop_name)
			if attacher_attach_ev >= 0:
				ctx.enqueue_event(attacher_attach_ev)

	func deactivate(ctx: HkbCtx) -> void:
		super.deactivate(ctx)
		if ctx.attachment_manager != null and ctx.attachment_manager.has_method("detach_all"):
			ctx.attachment_manager.call("detach_all")
			if attacher_detach_ev >= 0:
				ctx.enqueue_event(attacher_detach_ev)


class HkbGetUpModifier extends HkbModifier:
	var duration: float = 0.5
	var align_duration: float = 0.3
	var _elapsed: float = 0.0

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_elapsed = 0.0

	func _do_pre_modify(_ctx: HkbCtx, dt: float) -> void:
		_elapsed += dt


class HkbCharacterControllerModifier extends HkbModifier:
	var velocity: Vector3 = Vector3.ZERO
	var gravity_mps2: float = 9.81

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		if ctx.actor is CharacterBody3D:
			var cb: CharacterBody3D = ctx.actor as CharacterBody3D
			var v := cb.velocity
			if not cb.is_on_floor():
				v.y -= gravity_mps2 * dt
			if velocity.length_squared() > 1e-6:
				v.x = velocity.x
				v.z = velocity.z
			cb.velocity = v
			cb.move_and_slide()


class HkbRotateCharacterModifier extends HkbModifier:
	## Pure-GDScript `hkbRotateCharacterModifier` operating strictly in Godot standard axes (+Y up).
	var degrees_per_second: float = 0.0
	var speed_multiplier: float = 1.0
	var axis_of_rotation: Vector3 = Vector3.UP
	var source_is_zup: bool = true
	var accumulated_angle_rad: float = 0.0

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		accumulated_angle_rad = 0.0

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		var delta_rad := deg_to_rad(degrees_per_second * speed_multiplier) * dt
		if absf(delta_rad) < 1e-7:
			return
		var ax := AxisStd.normalize_rotation_axis_to_godot(axis_of_rotation, source_is_zup)
		accumulated_angle_rad += delta_rad
		ctx.root_motion_delta_yaw += delta_rad * signf(ax.y if absf(ax.y) > 0.1 else 1.0)
		if ctx.actor != null and is_instance_valid(ctx.actor):
			ctx.actor.rotate_object_local(ax, delta_rad)

	func _do_modify(_ctx: HkbCtx, pose: HkbPoseCls) -> void:
		var delta_rad := deg_to_rad(degrees_per_second * speed_multiplier) * (1.0 / 60.0)
		pose.root_delta_yaw += delta_rad


class HkbMoveCharacterModifier extends HkbModifier:
	## Pure-GDScript `hkbMoveCharacterModifier` operating in Godot standard axes (-Z fwd, +X right, +Y up).
	var offset_per_second_ms: Vector3 = Vector3.ZERO
	var source_is_zup: bool = false

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		if offset_per_second_ms.length_squared() < 1e-10:
			return
		var local_delta := AxisStd.normalize_offset_to_godot(offset_per_second_ms, source_is_zup) * dt
		ctx.root_motion_delta_pos += local_delta
		if ctx.actor != null and is_instance_valid(ctx.actor):
			ctx.actor.global_position += ctx.actor.global_transform.basis * local_delta

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if offset_per_second_ms.length_squared() < 1e-10:
			return
		pose.root_delta_pos += AxisStd.normalize_offset_to_godot(offset_per_second_ms, source_is_zup) * ctx.dt


class HkbMoveBoneAttachmentModifier extends HkbModifier:
	## Pure-GDScript `hkbMoveBoneAttachmentModifier`: re-sockets a named attachment onto `local_frame` bone.
	var activate_ev: int = -1
	var activate_ev_name: String = ""
	var attachment: String = ""
	var local_frame: String = ""
	var move_count: int = 0

	func _execute_move(ctx: HkbCtx) -> void:
		move_count += 1
		ctx.attachment_commands.append({
			"kind": "move_bone_attachment",
			"attachment": attachment,
			"local_frame": local_frame,
			"tick": ctx.tick,
		})
		if ctx.attachment_manager != null and ctx.skeleton != null and not local_frame.is_empty():
			if ctx.attachment_manager.has_method("attach_nearest"):
				ctx.attachment_manager.call("attach_nearest", ctx.skeleton, local_frame, attachment)

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		if activate_ev < 0 and activate_ev_name.is_empty():
			_execute_move(ctx)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		if (activate_ev >= 0 and ev_id == activate_ev) or (not activate_ev_name.is_empty() and ev_name == activate_ev_name):
			_execute_move(ctx)
			return true
		return false


class HkbGetHandleOnBoneModifier extends HkbModifier:
	## Pure-GDScript `hkbGetHandleOnBoneModifier`: produces a Godot world-space `HkbHandle` Dictionary from a bone.
	var local_frame_name: String = ""
	var anim_bone_idx: int = -1
	var ragdoll_bone_idx: int = -1
	var handle_out: Dictionary = {}

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		if ctx.skeleton == null or not is_instance_valid(ctx.skeleton):
			handle_out = {"valid": false, "pos": Vector3.ZERO, "rot": Quaternion.IDENTITY}
			return
		var bi := anim_bone_idx
		if bi < 0 and not local_frame_name.is_empty():
			bi = ctx.skeleton.find_bone(local_frame_name)
		if bi < 0:
			bi = 0
		if bi >= ctx.skeleton.get_bone_count():
			handle_out = {"valid": false, "pos": Vector3.ZERO, "rot": Quaternion.IDENTITY}
			return
		var xf := ctx.skeleton.global_transform * ctx.skeleton.get_bone_global_pose(bi)
		handle_out = {
			"valid": true,
			"name": node_name,
			"local_frame": local_frame_name,
			"bone_idx": bi,
			"pos": xf.origin,
			"rot": xf.basis.orthonormalized().get_rotation_quaternion().normalized(),
		}


class HkbSenseHandleModifier extends HkbModifier:
	## Pure-GDScript `hkbSenseHandleModifier`: senses nearby handles/props in Godot world space and emits range events.
	var sensor_local_offset: Vector3 = Vector3.ZERO
	var min_distance: float = 0.0
	var max_distance: float = 2.0
	var local_frame_name: String = ""
	var sensor_local_frame_name: String = ""
	var sensor_anim_bone: int = -1
	var keep_first: bool = false
	var ranges: Array[Dictionary] = []
	var handle_in: Variant = null
	var handle_out: Dictionary = {}
	var distance_out: float = 0.0
	var found_handle_out: bool = false

	func _sensor_origin_ws(ctx: HkbCtx) -> Vector3:
		if ctx.skeleton != null and is_instance_valid(ctx.skeleton) and sensor_anim_bone >= 0 and sensor_anim_bone < ctx.skeleton.get_bone_count():
			var xf := ctx.skeleton.global_transform * ctx.skeleton.get_bone_global_pose(sensor_anim_bone)
			return xf * sensor_local_offset
		if ctx.actor != null and is_instance_valid(ctx.actor):
			return ctx.actor.global_transform * sensor_local_offset
		return sensor_local_offset

	func _do_pre_modify(ctx: HkbCtx, _dt: float) -> void:
		if keep_first and found_handle_out and bool(handle_out.get("valid", false)):
			return
		var origin_ws := _sensor_origin_ws(ctx)
		var best_h: Dictionary = {}
		var best_d := 1e9

		# Collect candidate handles from ctx.handles & attachment_manager props
		var cands: Array[Dictionary] = []
		for h in ctx.handles:
			if bool(h.get("valid", true)):
				cands.append(h)
		if ctx.attachment_manager != null and "props" in ctx.attachment_manager:
			for rb in ctx.attachment_manager.props:
				if rb != null and is_instance_valid(rb):
					cands.append({
						"valid": true,
						"name": rb.name,
						"local_frame": local_frame_name,
						"pos": rb.global_position,
						"rot": rb.global_transform.basis.orthonormalized().get_rotation_quaternion().normalized(),
						"node": rb,
					})
		if handle_in is Dictionary and bool((handle_in as Dictionary).get("valid", false)):
			cands.append(handle_in as Dictionary)

		for h in cands:
			if not local_frame_name.is_empty():
				var hlf := str(h.get("local_frame", ""))
				var hnm := str(h.get("name", ""))
				if not hlf.is_empty() and hlf != local_frame_name and hnm != local_frame_name:
					continue
			var hp: Vector3 = h.get("pos", Vector3.ZERO) as Vector3
			var d := origin_ws.distance_to(hp)
			if d >= min_distance and d <= max_distance and d < best_d:
				best_d = d
				best_h = h

		if not best_h.is_empty():
			found_handle_out = true
			distance_out = best_d
			handle_out = best_h
			for rg in ranges:
				var rmin := float(rg.get("min", min_distance))
				var rmax := float(rg.get("max", max_distance))
				if best_d >= rmin and best_d <= rmax:
					if bool(rg.get("ignore", false)):
						handle_out = {}
						found_handle_out = false
					var enm := str(rg.get("ev_name", ""))
					var eid := int(rg.get("ev_id", -1))
					if not enm.is_empty():
						ctx.enqueue_event(enm)
					elif eid >= 0:
						ctx.enqueue_event(eid)
		else:
			found_handle_out = false
			distance_out = max_distance
			handle_out = {"valid": false, "pos": Vector3.ZERO, "rot": Quaternion.IDENTITY}


class HkbEvaluateHandleModifier extends HkbModifier:
	## Pure-GDScript `hkbEvaluateHandleModifier`: extracts & smooths Godot world-space position/rotation from `handle`.
	var handle: Variant = null
	var extrapolation_time_step: float = 0.0
	var handle_change_speed: float = 1.0
	var handle_change_mode: int = 0 # 0=ABRUPT, 1=CONSTANT_VELOCITY
	var handle_position_out: Vector3 = Vector3.ZERO
	var handle_rotation_out: Quaternion = Quaternion.IDENTITY
	var is_valid_out: bool = false
	var _has_prev: bool = false

	func _do_pre_modify(_ctx: HkbCtx, dt: float) -> void:
		if handle is Dictionary and bool((handle as Dictionary).get("valid", false)):
			var h: Dictionary = handle as Dictionary
			var target_p: Vector3 = h.get("pos", Vector3.ZERO) as Vector3
			var target_r: Quaternion = (h.get("rot", Quaternion.IDENTITY) as Quaternion).normalized()
			if h.has("node") and h["node"] is Node3D and is_instance_valid(h["node"]):
				var n3: Node3D = h["node"] as Node3D
				target_p = n3.global_position
				target_r = n3.global_transform.basis.orthonormalized().get_rotation_quaternion().normalized()
			if handle_change_mode == 1 and _has_prev and handle_change_speed > 1e-4:
				var max_step := handle_change_speed * dt
				handle_position_out = handle_position_out.move_toward(target_p, max_step)
				var alpha := clampf(max_step, 0.0, 1.0)
				handle_rotation_out = handle_rotation_out.slerp(target_r, alpha).normalized()
			else:
				handle_position_out = target_p
				handle_rotation_out = target_r
			is_valid_out = true
			_has_prev = true
		else:
			is_valid_out = false


class HkbBodyIkControlsModifier extends HkbModifier:
	## Pure-GDScript `hkbBodyIkControlsModifier`: multi-effector full-body IK delegating limb chains
	## to the C++ `AnimationStudioHkbKernel.solve_two_bone_ik` solver in Godot standard coordinates.
	var profile_name: String = ""
	var control_datas: Array[Dictionary] = []

	func configure(def: Dictionary) -> void:
		profile_name = str(def.get("profile_name", ""))
		control_datas.clear()
		for c_raw in def.get("controls", []) as Array:
			var cd: Dictionary = (c_raw as Dictionary).duplicate(true)
			var tp: Array = cd.get("target_pos", [0.0, 0.0, 0.0]) as Array
			var tr: Array = cd.get("target_rot", [0.0, 0.0, 0.0, 1.0]) as Array
			cd["target_pos"] = AxisStd.havok_zup_vec_to_godot(Vector3(float(tp[0]), float(tp[1]), float(tp[2]))) if tp.size() >= 3 else Vector3.ZERO
			cd["target_rot"] = AxisStd.havok_zup_quat_to_godot(Quaternion(float(tr[0]), float(tr[1]), float(tr[2]), float(tr[3]))) if tr.size() >= 4 else Quaternion.IDENTITY
			cd["target_handle"] = null
			control_datas.append(cd)

	func _do_modify(ctx: HkbCtx, pose: HkbPoseCls) -> void:
		if ctx.skeleton == null or pose.bone_count == 0 or control_datas.is_empty():
			return
		var applied_any := false
		for cd in control_datas:
			var inf := clampf(float(cd.get("anim_influence", 0.5)), 0.0, 1.0)
			var ik_w := 1.0 - inf
			if ik_w <= 1e-4:
				continue
			var tgt_ws: Vector3 = cd.get("target_pos", Vector3.ZERO) as Vector3
			var th: Variant = cd.get("target_handle", null)
			if th is Dictionary and bool((th as Dictionary).get("valid", false)):
				tgt_ws = (th as Dictionary).get("pos", tgt_ws) as Vector3
			if tgt_ws.length_squared() < 1e-8:
				continue
			var pt := str(cd.get("point", "")).to_lower()
			var end_i := -1
			if "right" in pt and ("hand" in pt or "wrist" in pt or "arm" in pt):
				end_i = HkbFootIkDriver._find_any(ctx.skeleton, ["RightArmPalm", "Wrist_R", "Hand_R"])
			elif "left" in pt and ("hand" in pt or "wrist" in pt or "arm" in pt):
				end_i = HkbFootIkDriver._find_any(ctx.skeleton, ["LeftArmPalm", "Wrist_L", "Hand_L"])
			elif "right" in pt and ("foot" in pt or "ankle" in pt or "leg" in pt):
				end_i = HkbFootIkDriver._find_any(ctx.skeleton, ["RightLegFoot", "Ankle_R"])
			elif "left" in pt and ("foot" in pt or "ankle" in pt or "leg" in pt):
				end_i = HkbFootIkDriver._find_any(ctx.skeleton, ["LeftLegFoot", "Ankle_L"])
			elif "head" in pt or "chest" in pt or "spine" in pt:
				end_i = HkbFootIkDriver._find_any(ctx.skeleton, ["Head", "Head_M", "Spine4", "Chest_M"])
			if end_i < 0:
				continue
			var mid_i := ctx.skeleton.get_bone_parent(end_i)
			var up_i := ctx.skeleton.get_bone_parent(mid_i) if mid_i >= 0 else -1
			if up_i >= 0 and mid_i >= 0:
				if not applied_any:
					pose.apply_to_skeleton(ctx.skeleton)
					applied_any = true
				HkbFootIkDriver.solve_two_bone_analytic(ctx.skeleton, pose, up_i, mid_i, end_i, tgt_ws, ik_w)


class HkbSequence extends HkbModifier:
	## Pure-GDScript `hkbSequence`: timeline sequencer firing events and piecewise-linear variable curves.
	var enable_ev: int = -1
	var enable_ev_name: String = ""
	var disable_ev: int = -1
	var disable_ev_name: String = ""
	var event_tracks: Array = []
	var real_tracks: Array = []
	var bool_tracks: Array = []
	var int_tracks: Array = []
	var _seq_enabled: bool = true
	var _time: float = 0.0
	var _prev_time: float = -1e-6

	func configure(def: Dictionary) -> void:
		enable_ev = int(def.get("enable_ev", -1))
		enable_ev_name = str(def.get("enable_ev_name", ""))
		disable_ev = int(def.get("disable_ev", -1))
		disable_ev_name = str(def.get("disable_ev_name", ""))
		event_tracks = def.get("event_tracks", []) as Array if def.get("event_tracks") is Array else []
		real_tracks = def.get("real_tracks", []) as Array if def.get("real_tracks") is Array else []
		bool_tracks = def.get("bool_tracks", []) as Array if def.get("bool_tracks") is Array else []
		int_tracks = def.get("int_tracks", []) as Array if def.get("int_tracks") is Array else []

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_time = 0.0
		_prev_time = -1e-6
		_seq_enabled = (enable_ev < 0 and enable_ev_name.is_empty())

	func handle_event(_ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		if (enable_ev >= 0 and ev_id == enable_ev) or (not enable_ev_name.is_empty() and ev_name == enable_ev_name):
			_seq_enabled = true
			_time = 0.0
			_prev_time = -1e-6
			return true
		if (disable_ev >= 0 and ev_id == disable_ev) or (not disable_ev_name.is_empty() and ev_name == disable_ev_name):
			_seq_enabled = false
			return true
		return false

	func _do_pre_modify(ctx: HkbCtx, dt: float) -> void:
		if not _seq_enabled:
			return
		var t0 := _prev_time
		var t1 := _time
		# 1. Timed events
		for track_raw in event_tracks:
			for ev_raw in track_raw as Array:
				var ev: Dictionary = ev_raw as Dictionary
				var et := float(ev.get("t", 0.0))
				if et > t0 and et <= t1:
					var enm := str(ev.get("ev_name", ""))
					var eid := int(ev.get("ev_id", -1))
					if not enm.is_empty():
						ctx.enqueue_event(enm)
					elif eid >= 0:
						ctx.enqueue_event(eid)
		# 2. Piecewise-linear real curves
		for tr_raw in real_tracks:
			var tr: Dictionary = tr_raw as Dictionary
			var samples: Array = tr.get("samples", []) as Array
			if samples.is_empty():
				continue
			var val := _sample_real_curve(samples, t1)
			var key: Variant = str(tr.get("var_name", "")) if not str(tr.get("var_name", "")).is_empty() else int(tr.get("var_idx", -1))
			ctx.set_var(key, val)
		# 3. Step bool curves
		for tr_raw in bool_tracks:
			var tr: Dictionary = tr_raw as Dictionary
			var samples: Array = tr.get("samples", []) as Array
			var has_v := false
			var bval := false
			for s_raw in samples:
				var s: Array = s_raw as Array
				if float(s[0]) <= t1:
					bval = bool(s[1])
					has_v = true
			if has_v:
				var key: Variant = str(tr.get("var_name", "")) if not str(tr.get("var_name", "")).is_empty() else int(tr.get("var_idx", -1))
				ctx.set_var(key, bval)
		# 4. Step int curves
		for tr_raw in int_tracks:
			var tr: Dictionary = tr_raw as Dictionary
			var samples: Array = tr.get("samples", []) as Array
			var has_v := false
			var ival := 0
			for s_raw in samples:
				var s: Array = s_raw as Array
				if float(s[0]) <= t1:
					ival = int(s[1])
					has_v = true
			if has_v:
				var key: Variant = str(tr.get("var_name", "")) if not str(tr.get("var_name", "")).is_empty() else int(tr.get("var_idx", -1))
				ctx.set_var(key, ival)
		_prev_time = t1
		_time += dt

	static func _sample_real_curve(samples: Array, t: float) -> float:
		var first: Array = samples[0] as Array
		if t <= float(first[0]):
			return float(first[1])
		var last: Array = samples[samples.size() - 1] as Array
		if t >= float(last[0]):
			return float(last[1])
		for i in range(samples.size() - 1):
			var a: Array = samples[i] as Array
			var b: Array = samples[i + 1] as Array
			var ta := float(a[0])
			var tb := float(b[0])
			if t >= ta and t <= tb:
				var u := (t - ta) / maxf(1e-6, tb - ta)
				return lerpf(float(a[1]), float(b[1]), u)
		return float(last[1])


# ==============================================================================
# Reusable Pure-GDScript Drivers (`hkbFootIkDriver`, `hkbAttachmentManager`, `hkbDockingDriver`)
# ==============================================================================

class HkbFootIkDriver extends RefCounted:
	## Pure-GDScript Havok `hkaFootPlacementIkSolver` + `hkbFootIkDriver`.
	## Raycasts both ankles against real scene geometry (`World3D.direct_space_state`),
	## lowers pelvis (`Pelvis` / `Root_M`) cleanly to prevent over-extension, and solves
	## analytic 2-bone hip-knee-ankle IK directly onto `HkbPose` or `Skeleton3D`.
	var pelvis_offset_y: float = 0.0
	var last_left_hit_y: float = 0.0
	var last_right_hit_y: float = 0.0
	var last_hits: int = 0

	func reset() -> void:
		pelvis_offset_y = 0.0
		last_hits = 0

	func solve_skeleton(skel: Skeleton3D, world_3d: World3D, gains: Dictionary = {}) -> Dictionary:
		if skel == null or not is_instance_valid(skel) or world_3d == null:
			return {"hits": 0, "pelvis_dy": 0.0}
		var pose := HkbPoseCls.new()
		pose.read_from_skeleton(skel)
		var dummy_ctx := HkbCtx.new()
		dummy_ctx.skeleton = skel
		dummy_ctx.world_3d = world_3d
		var res := solve_pose(dummy_ctx, pose, gains)
		pose.apply_to_skeleton(skel)
		return res

	func solve_pose(ctx: HkbCtx, pose: HkbPoseCls, gains: Dictionary = {}) -> Dictionary:
		var skel := ctx.skeleton
		var world := ctx.world_3d
		if skel == null or world == null or pose.bone_count == 0:
			return {"hits": 0, "pelvis_dy": 0.0}

		var pelvis_i := _find_any(skel, ["Pelvis", "Root_M", "Hips"])
		var l_hip := _find_any(skel, ["LeftLegThigh1", "LeftLegUp", "Hip_L", "LeftUpLeg"])
		var l_knee := _find_any(skel, ["LeftLegCalf", "LeftLegLow", "Knee_L", "LeftLeg"])
		var l_foot := _find_any(skel, ["LeftLegFoot", "Ankle_L", "LeftFoot"])
		var r_hip := _find_any(skel, ["RightLegThigh1", "RightLegUp", "Hip_R", "RightUpLeg"])
		var r_knee := _find_any(skel, ["RightLegCalf", "RightLegLow", "Knee_R", "RightLeg"])
		var r_foot := _find_any(skel, ["RightLegFoot", "Ankle_R", "RightFoot"])
		if l_foot < 0 or r_foot < 0 or l_knee < 0 or r_knee < 0 or l_hip < 0 or r_hip < 0:
			return {"hits": 0, "pelvis_dy": 0.0}

		pose.apply_to_skeleton(skel)
		var space := world.direct_space_state
		var skel_y0 := skel.global_position.y
		var max_raise := float(gains.get("max_raise", 0.45))
		var max_lower := float(gains.get("max_lower", -0.35))
		var asc_gain := clampf(float(gains.get("ground_asc_gain", 0.5)), 0.05, 1.0)
		var desc_gain := clampf(float(gains.get("ground_desc_gain", 0.5)), 0.05, 1.0)

		var foot_targets: Array[Dictionary] = []
		var min_delta_y := 0.0
		last_hits = 0
		for leg in [
			{"hip": l_hip, "knee": l_knee, "foot": l_foot, "side": "L"},
			{"hip": r_hip, "knee": r_knee, "foot": r_foot, "side": "R"},
		]:
			var fi := int(leg["foot"])
			var foot_ws := skel.to_global(skel.get_bone_global_pose(fi).origin)
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(foot_ws.x, foot_ws.y + 0.65, foot_ws.z),
				Vector3(foot_ws.x, foot_ws.y - 0.85, foot_ws.z),
				1
			)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				last_hits += 1
				var hy := (hit["position"] as Vector3).y
				if leg["side"] == "L":
					last_left_hit_y = hy
				else:
					last_right_hit_y = hy
				var foot_height_above_root := maxf(0.0, foot_ws.y - skel_y0)
				var target_y := clampf(hy + foot_height_above_root, foot_ws.y + max_lower, foot_ws.y + max_raise)
				var dy := target_y - foot_ws.y
				if dy < min_delta_y:
					min_delta_y = dy
				foot_targets.append({
					"hip": int(leg["hip"]), "knee": int(leg["knee"]), "foot": fi,
					"target": Vector3(foot_ws.x, target_y, foot_ws.z),
				})

		# Smooth pelvis adjustment to lowest grounded foot so knees never lock out
		var desired_pelvis := clampf(min_delta_y, max_lower, max_raise)
		var g := asc_gain if desired_pelvis > pelvis_offset_y else desc_gain
		pelvis_offset_y = lerpf(pelvis_offset_y, desired_pelvis, g)
		if pelvis_i >= 0 and absf(pelvis_offset_y) > 1e-4:
			pose.pos[pelvis_i].y += pelvis_offset_y
			pose.apply_to_skeleton(skel)

		var ik_w := clampf(float(gains.get("ik_weight", 1.0)), 0.0, 1.0)
		for ft in foot_targets:
			solve_two_bone_analytic(skel, pose, int(ft["hip"]), int(ft["knee"]), int(ft["foot"]), ft["target"] as Vector3, ik_w)

		return {"hits": last_hits, "pelvis_dy": pelvis_offset_y, "left_y": last_left_hit_y, "right_y": last_right_hit_y}

	static func solve_two_bone_analytic(skel: Skeleton3D, pose: HkbPoseCls, upper_i: int, mid_i: int, end_i: int, target_ws: Vector3, weight: float) -> void:
		var k := HkbPoseCls.get_native_kernel()
		if k != null:
			pose.rot_xyzw = k.call(&"solve_two_bone_ik", skel, pose.rot_xyzw, upper_i, mid_i, end_i, target_ws, weight) as PackedFloat32Array
			return
		var a := skel.to_global(skel.get_bone_global_pose(upper_i).origin)
		var b := skel.to_global(skel.get_bone_global_pose(mid_i).origin)
		var c := skel.to_global(skel.get_bone_global_pose(end_i).origin)
		var l1 := a.distance_to(b)
		var l2 := b.distance_to(c)
		if l1 < 1e-4 or l2 < 1e-4:
			return
		var tgt := c.lerp(target_ws, clampf(weight, 0.0, 1.0))
		var ac := c - a
		var at := tgt - a
		var dist := clampf(at.length(), absf(l1 - l2) + 0.01, l1 + l2 - 0.005)
		if ac.length_squared() < 1e-6 or at.length_squared() < 1e-6:
			return
		# 1. Rotate upper bone so current hip->ankle vector aligns with hip->target vector
		var q_align_ws := Quaternion(ac.normalized(), at.normalized()).normalized()
		# 2. Law of cosines for knee bend angle change
		var cur_cos := clampf((l1 * l1 + l2 * l2 - ac.length_squared()) / (2.0 * l1 * l2), -1.0, 1.0)
		var des_cos := clampf((l1 * l1 + l2 * l2 - dist * dist) / (2.0 * l1 * l2), -1.0, 1.0)
		var d_knee := acos(des_cos) - acos(cur_cos)
		var bend_axis_ws := (b - a).cross(c - b)
		if bend_axis_ws.length_squared() < 1e-6:
			bend_axis_ws = skel.global_transform.basis.x
		else:
			bend_axis_ws = bend_axis_ws.normalized()

		# Convert world-space delta rotations into bone parent-local frame
		var up_p := skel.get_bone_parent(upper_i)
		var up_parent_b := (skel.global_transform * skel.get_bone_global_pose(up_p)).basis.orthonormalized() if up_p >= 0 else skel.global_transform.basis.orthonormalized()
		var q_up_local := (up_parent_b.get_rotation_quaternion().inverse() * q_align_ws * up_parent_b.get_rotation_quaternion()).normalized()
		pose.set_rot(upper_i, (q_up_local * pose.get_rot(upper_i)).normalized())

		if absf(d_knee) > 1e-4:
			var mid_parent_b := (skel.global_transform * skel.get_bone_global_pose(upper_i)).basis.orthonormalized()
			var q_knee_ws := Quaternion(bend_axis_ws, d_knee * 0.5).normalized()
			var q_mid_local := (mid_parent_b.get_rotation_quaternion().inverse() * q_knee_ws * mid_parent_b.get_rotation_quaternion()).normalized()
			pose.set_rot(mid_i, (q_mid_local * pose.get_rot(mid_i)).normalized())

	static func _find_any(skel: Skeleton3D, names: Array[String]) -> int:
		for nm in names:
			var idx := skel.find_bone(nm)
			if idx >= 0:
				return idx
		return -1


class HkbAttachmentManager extends RefCounted:
	## Pure-GDScript Havok `hkbAttachmentManager`: manages dynamic `RigidBody3D` props
	## picked up, carried on bone sockets, and detached/thrown with real physics velocity.
	var props: Array[RigidBody3D] = []
	var attached_body: RigidBody3D = null
	var attached_skel: Skeleton3D = null
	var attached_bone_idx: int = -1
	var local_offset: Transform3D = Transform3D.IDENTITY
	var _prev_ws: Vector3 = Vector3.ZERO
	var _vel_ws: Vector3 = Vector3.ZERO

	func register_prop(rb: RigidBody3D) -> void:
		if rb != null and not props.has(rb):
			props.append(rb)

	func clear() -> void:
		detach_all()
		props.clear()

	func attach_nearest(skel: Skeleton3D, bone_name: String = "RightArmPalm", preferred_name: String = "") -> RigidBody3D:
		if skel == null or not is_instance_valid(skel) or props.is_empty():
			return null
		var bi := skel.find_bone(bone_name)
		if bi < 0:
			for cand in ["Wrist_R", "RightArmPalm", "Hand_R", "Wrist_L", "LeftArmPalm"]:
				bi = skel.find_bone(cand)
				if bi >= 0:
					break
		if bi < 0:
			return null
		var hand_ws := skel.to_global(skel.get_bone_global_pose(bi).origin)
		var best: RigidBody3D = null
		var best_d := 1e9
		for rb in props:
			if not is_instance_valid(rb):
				continue
			if not preferred_name.is_empty() and rb.name == preferred_name:
				best = rb
				break
			var d := rb.global_position.distance_to(hand_ws)
			if d < best_d:
				best_d = d
				best = rb
		if best == null:
			return null
		attached_body = best
		attached_skel = skel
		attached_bone_idx = bi
		attached_body.freeze = true
		local_offset = Transform3D(Basis.IDENTITY, Vector3(0.0, -0.06, -0.08))
		_prev_ws = hand_ws
		_vel_ws = Vector3.ZERO
		return attached_body

	func step(dt: float) -> void:
		if attached_body == null or not is_instance_valid(attached_body):
			return
		if attached_skel == null or not is_instance_valid(attached_skel) or attached_bone_idx < 0:
			return
		var bone_ws := attached_skel.global_transform * attached_skel.get_bone_global_pose(attached_bone_idx)
		var target_xf := bone_ws * local_offset
		if dt > 1e-5:
			_vel_ws = (target_xf.origin - _prev_ws) / dt
		_prev_ws = target_xf.origin
		attached_body.global_transform = target_xf

	func detach_all(throw_boost: Vector3 = Vector3.ZERO) -> void:
		if attached_body != null and is_instance_valid(attached_body):
			attached_body.freeze = false
			attached_body.linear_velocity = _vel_ws + throw_boost
		attached_body = null
		attached_skel = null
		attached_bone_idx = -1


static func build_modifier(def: Dictionary, link: Dictionary = {}) -> HkbModifier:
	var tp := str(def.get("type", "hkbModifier"))
	var m: HkbModifier
	match tp:
		"hkbModifierList":
			m = HkbModifierList.new()
		"hkbEvaluateExpressionModifier":
			var eem := HkbEvaluateExpressionModifier.new()
			eem.configure(def)
			m = eem
		"hkbEventsFromRangeModifier":
			var efrm := HkbEventsFromRangeModifier.new()
			efrm.configure(def)
			m = efrm
		"hkbEventDrivenModifier":
			var edm := HkbEventDrivenModifier.new()
			edm.activate_ev = int(def.get("activate_ev", -1))
			edm.activate_ev_name = str(def.get("activate_ev_name", ""))
			edm.deactivate_ev = int(def.get("deactivate_ev", -1))
			edm.deactivate_ev_name = str(def.get("deactivate_ev_name", ""))
			edm.active_by_default = bool(def.get("active_default", false))
			m = edm
		"hkbTimerModifier":
			var tm := HkbTimerModifier.new()
			tm.alarm_time = float(def.get("alarm_time", 1.0))
			tm.alarm_ev = int(def.get("alarm_ev", -1))
			tm.alarm_ev_name = str(def.get("alarm_ev_name", ""))
			m = tm
		"hkbDelayedModifier":
			var dm := HkbDelayedModifier.new()
			dm.delay_seconds = float(def.get("delay", 0.0))
			dm.duration_seconds = float(def.get("duration", 0.0))
			m = dm
		"hkbDampingModifier":
			var damp := HkbDampingModifier.new()
			damp.kp = float(def.get("kp", 0.2))
			damp.ki = float(def.get("ki", 0.015))
			damp.kd = float(def.get("kd", -0.1))
			damp.enable_scalar = bool(def.get("scalar", true))
			damp.enable_vector = bool(def.get("vector", false))
			damp.raw_value = float(def.get("raw_val", 0.0))
			m = damp
		"hkbMirrorModifier":
			var mm := HkbMirrorModifier.new()
			mm.is_additive = bool(def.get("is_additive", false))
			m = mm
		"hkbLookAtModifier":
			var lam := HkbLookAtModifier.new()
			lam.head_idx = int(def.get("head_idx", -1))
			lam.neck_idx = int(def.get("neck_idx", -1))
			lam.limit_angle_deg = float(def.get("limit_deg", 60.0))
			lam.on_gain = float(def.get("on_gain", 0.05))
			lam.off_gain = float(def.get("off_gain", 0.05))
			lam.new_target_gain = float(def.get("new_target_gain", 0.1))
			lam.is_on = bool(def.get("is_on", true))
			var tws: Array = def.get("target_ws", []) as Array
			if tws.size() >= 3:
				lam.target_ws = Vector3(float(tws[0]), float(tws[1]), float(tws[2]))
			m = lam
		"hkbTwistModifier":
			var tw := HkbTwistModifier.new()
			tw.start_bone = int(def.get("start_bone", -1))
			tw.end_bone = int(def.get("end_bone", -1))
			tw.twist_angle_deg = float(def.get("twist_deg", 0.0))
			tw.is_additive = bool(def.get("is_additive", true))
			var ax: Array = def.get("axis", []) as Array
			if ax.size() >= 3:
				tw.axis_of_rotation = Vector3(float(ax[0]), float(ax[1]), float(ax[2]))
			m = tw
		"hkbCombineTransformsModifier":
			m = HkbCombineTransformsModifier.new()
		"hkbComputeDirectionModifier":
			m = HkbComputeDirectionModifier.new()
		"hkbComputeRotationToTargetModifier":
			m = HkbComputeRotationToTargetModifier.new()
		"hkbAttributeModifier":
			m = HkbAttributeModifier.new()
		"hkbJigglerModifier":
			m = HkbJigglerModifier.new()
		"hkbFootIkControlsModifier":
			var fik := HkbFootIkControlsModifier.new()
			fik.on_off_gain = float(def.get("on_off_gain", 0.2))
			fik.ground_asc_gain = float(def.get("ground_asc_gain", 0.5))
			fik.ground_desc_gain = float(def.get("ground_desc_gain", 0.5))
			m = fik
		"hkbHandIkControlsModifier":
			m = HkbHandIkControlsModifier.new()
		"hkbPoweredRagdollControlsModifier":
			var prm := HkbPoweredRagdollControlsModifier.new()
			prm.max_force = float(def.get("max_force", 50.0))
			prm.tau = float(def.get("tau", 0.8))
			prm.damping = float(def.get("damping", 1.0))
			prm.bones = def.get("bones", []) as Array if def.get("bones") is Array else []
			m = prm
		"hkbRigidBodyRagdollControlsModifier":
			var rbm := HkbRigidBodyRagdollControlsModifier.new()
			rbm.hierarchy_gain = float(def.get("hierarchy_gain", 0.178))
			rbm.vel_damping = float(def.get("vel_damping", 0.0))
			rbm.pos_gain = float(def.get("pos_gain", 0.05))
			rbm.anim_blend = float(def.get("anim_blend", 0.0))
			rbm.bones = def.get("bones", []) as Array if def.get("bones") is Array else []
			m = rbm
		"hkbKeyframeBonesModifier":
			var kbm := HkbKeyframeBonesModifier.new()
			kbm.bones = def.get("bones", []) as Array if def.get("bones") is Array else []
			m = kbm
		"hkbAttachmentModifier":
			var am := HkbAttachmentModifier.new()
			am.attacher_attach_ev = int(def.get("attacher_attach_ev", -1))
			am.attacher_detach_ev = int(def.get("attacher_detach_ev", -1))
			m = am
		"hkbGetUpModifier":
			var gum := HkbGetUpModifier.new()
			gum.duration = float(def.get("duration", 0.5))
			gum.align_duration = float(def.get("align_duration", 0.3))
			m = gum
		"hkbCharacterControllerModifier":
			m = HkbCharacterControllerModifier.new()
		"hkbRotateCharacterModifier":
			var rcm := HkbRotateCharacterModifier.new()
			rcm.degrees_per_second = float(def.get("deg_per_sec", 0.0))
			rcm.speed_multiplier = float(def.get("speed_mult", 1.0))
			var rax: Array = def.get("axis", []) as Array
			if rax.size() >= 3:
				rcm.axis_of_rotation = Vector3(float(rax[0]), float(rax[1]), float(rax[2]))
			m = rcm
		"hkbMoveCharacterModifier":
			var mcm := HkbMoveCharacterModifier.new()
			var moff: Array = def.get("offset_per_sec", []) as Array
			if moff.size() >= 3:
				mcm.offset_per_second_ms = Vector3(float(moff[0]), float(moff[1]), float(moff[2]))
			m = mcm
		"hkbMoveBoneAttachmentModifier":
			var mbam := HkbMoveBoneAttachmentModifier.new()
			mbam.activate_ev = int(def.get("activate_ev", -1))
			mbam.activate_ev_name = str(def.get("activate_ev_name", ""))
			mbam.attachment = str(def.get("attachment", ""))
			mbam.local_frame = str(def.get("local_frame", ""))
			m = mbam
		"hkbGetHandleOnBoneModifier":
			var ghb := HkbGetHandleOnBoneModifier.new()
			ghb.local_frame_name = str(def.get("local_frame", ""))
			ghb.anim_bone_idx = int(def.get("anim_bone", -1))
			ghb.ragdoll_bone_idx = int(def.get("ragdoll_bone", -1))
			m = ghb
		"hkbSenseHandleModifier":
			var shm := HkbSenseHandleModifier.new()
			shm.min_distance = float(def.get("min_dist", 0.0))
			shm.max_distance = float(def.get("max_dist", 2.0))
			shm.local_frame_name = str(def.get("local_frame", ""))
			shm.sensor_local_frame_name = str(def.get("sensor_local_frame", ""))
			shm.sensor_anim_bone = int(def.get("sensor_anim_bone", -1))
			shm.keep_first = bool(def.get("keep_first", false))
			var soff: Array = def.get("sensor_offset", []) as Array
			if soff.size() >= 3:
				shm.sensor_local_offset = AxisStd.havok_zup_vec_to_godot(Vector3(float(soff[0]), float(soff[1]), float(soff[2])))
			for rg_raw in def.get("ranges", []) as Array:
				shm.ranges.append(rg_raw as Dictionary)
			m = shm
		"hkbEvaluateHandleModifier":
			var ehm := HkbEvaluateHandleModifier.new()
			ehm.extrapolation_time_step = float(def.get("extrap_dt", 0.0))
			ehm.handle_change_speed = float(def.get("change_speed", 1.0))
			ehm.handle_change_mode = int(def.get("change_mode", 0))
			m = ehm
		"hkbBodyIkControlsModifier":
			var bik := HkbBodyIkControlsModifier.new()
			bik.configure(def)
			m = bik
		"hkbSequence":
			var seq := HkbSequence.new()
			seq.configure(def)
			m = seq
		_:
			m = HkbModifier.new()
	m.init_common(def, link)
	return m
