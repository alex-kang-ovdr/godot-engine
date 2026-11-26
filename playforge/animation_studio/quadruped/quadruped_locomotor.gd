@tool
extends RefCounted
## Unreal Engine 5.6 Control Rig Locomotor + Full Body IK (FBIK) style
## 100% Procedural Quadruped Locomotion Solver (zero animation clips).
##
## Architecture mirrors UE's RigUnit_Locomotor:
##   1. Movement / Velocity Integrator (spring-damped root position & yaw)
##   2. Foot Set Gait Scheduler (Walk / Trot / Pace / Gallop phase offsets,
##      predictive stride targets, zero-slide planted world-lock, parabolic step arc)
##   3. Pelvis & Spine Procedural Dynamics (ride height, front-hind terrain pitch,
##      left-right terrain roll + turn banking, lateral S-wave, head stabilization, tail wave)
##   4. 4-Limb Pole-Constrained Two-Bone IK (front backward-elbow / hind forward-stifle)

const QuadrupedRig := preload("res://quadruped/quadruped_rig.gd")

const GAIT_PRESETS := {
	"walk": {
		"label": "Walk (4-Beat Lateral)",
		"phases": {"FL": 0.50, "FR": 0.00, "HL": 0.25, "HR": 0.75},
		"duty_factor": 0.72,
		"freq_hz": 1.05,
		"step_height": 0.14,
		"stride_scale": 0.46,
		"bob_amp": 0.020,
		"spine_pitch_amp": 0.03,
	},
	"trot": {
		"label": "Trot (Diagonal Pairs)",
		"phases": {"FL": 0.00, "FR": 0.50, "HL": 0.50, "HR": 0.00},
		"duty_factor": 0.54,
		"freq_hz": 1.65,
		"step_height": 0.20,
		"stride_scale": 0.56,
		"bob_amp": 0.034,
		"spine_pitch_amp": 0.05,
	},
	"pace": {
		"label": "Pace (Ipsilateral Pairs)",
		"phases": {"FL": 0.00, "FR": 0.50, "HL": 0.00, "HR": 0.50},
		"duty_factor": 0.54,
		"freq_hz": 1.55,
		"step_height": 0.18,
		"stride_scale": 0.52,
		"bob_amp": 0.028,
		"spine_pitch_amp": 0.04,
	},
	"gallop": {
		"label": "Gallop (Rotary Sprint)",
		"phases": {"FL": 0.00, "FR": 0.18, "HL": 0.55, "HR": 0.72},
		"duty_factor": 0.40,
		"freq_hz": 2.25,
		"step_height": 0.26,
		"stride_scale": 0.62,
		"bob_amp": 0.052,
		"spine_pitch_amp": 0.14,
	},
}

# Tunable Locomotor parameters (exposed to Inspector / Attribute Editor)
var ride_height: float = QuadrupedRig.PELVIS_REST_Y
var stride_scale_mul: float = 1.0
var step_height_mul: float = 1.0
var enable_pelvis_dynamics: bool = true
var enable_terrain_ik: bool = true
var forced_gait: String = "auto" # "auto", "walk", "trot", "pace", "gallop"

# Live solver state
var _rig: Skeleton3D
var _root_node: Node3D
var _bone_ids: Dictionary = {}
var _pos: Vector3 = Vector3.ZERO
var _vel: Vector3 = Vector3.ZERO
var _yaw: float = 0.0
var _yaw_rate: float = 0.0
var _cycle_phase: float = 0.0
var _active_gait: String = "idle"
var _pelvis_y: float = QuadrupedRig.PELVIS_REST_Y
var _pelvis_pitch: float = 0.0
var _pelvis_roll: float = 0.0
var _tail_phase: float = 0.0

# Per-foot Locomotor state (world space)
var _feet: Dictionary = {} # leg_id -> {planted, world_pos, lift_pos, target_pos, swing_u, normal, slide_err_mm}


static func terrain_height(x: float, z: float) -> float:
	# Shared procedural quadruped test course:
	# LevelGround (y=0.0) -> FirstStep (+0.18m) -> SecondStep (+0.32m) -> Slope Ramp -> Ridge Bump
	var y := 0.0
	# First step at z in [-4.0 .. -2.4]
	if absf(x) <= 2.2 and z <= -2.4 and z >= -4.0:
		y = maxf(y, 0.18)
	# Second elevated terrace at z in [-5.8 .. -4.0]
	if absf(x) <= 2.2 and z < -4.0 and z >= -5.8:
		y = maxf(y, 0.32)
	# Smooth down-ramp returning from terrace back to ground z in [-7.6 .. -5.8]
	if absf(x) <= 2.2 and z < -5.8 and z >= -7.6:
		var u := clampf((z - (-7.6)) / 1.8, 0.0, 1.0)
		y = maxf(y, 0.32 * u)
	# Lateral bank/ridge along the turn lane (x > 1.8, z in [-10.0 .. -4.0])
	if x >= 1.5 and x <= 5.5 and z <= -4.5 and z >= -10.5:
		var bump := sin(clampf((x - 1.5) / 4.0, 0.0, 1.0) * PI) * 0.24
		y = maxf(y, bump)
	return y


static func terrain_normal(x: float, z: float) -> Vector3:
	var eps := 0.06
	var hx := terrain_height(x + eps, z) - terrain_height(x - eps, z)
	var hz := terrain_height(x, z + eps) - terrain_height(x, z - eps)
	return Vector3(-hx, 2.0 * eps, -hz).normalized()


static func demo_course_command(tick: int) -> Dictionary:
	# 300-tick (5.0 s @ 60 Hz) showcase course:
	# 0..24: Idle stance | 25..94: Walk over flat + FirstStep | 95..169: Trot across SecondStep & down-ramp
	# 170..219: Banking right turn onto lateral ridge | 220..269: Gallop sprint | 270..299: Smooth settle to Idle
	if tick < 25:
		return {"dir": Vector3(0.0, 0.0, -1.0), "speed": 0.0, "gait_hint": "idle"}
	if tick < 95:
		return {"dir": Vector3(0.0, 0.0, -1.0), "speed": 1.35, "gait_hint": "walk"}
	if tick < 170:
		return {"dir": Vector3(0.0, 0.0, -1.0), "speed": 2.85, "gait_hint": "trot"}
	if tick < 220:
		var u := float(tick - 170) / 50.0
		var ang := lerpf(0.0, -PI * 0.55, u)
		return {"dir": Vector3(-sin(ang), 0.0, -cos(ang)), "speed": 3.10, "gait_hint": "trot"}
	if tick < 270:
		return {"dir": Vector3(0.98, 0.0, 0.18).normalized(), "speed": 4.90, "gait_hint": "gallop"}
	return {"dir": Vector3(0.98, 0.0, 0.18).normalized(), "speed": 0.0, "gait_hint": "idle"}


func setup(rig: Skeleton3D, root_node: Node3D, bone_ids: Dictionary) -> void:
	_rig = rig
	_root_node = root_node
	_bone_ids = bone_ids
	_pos = Vector3.ZERO
	_vel = Vector3.ZERO
	_yaw = 0.0
	_yaw_rate = 0.0
	_cycle_phase = 0.0
	_active_gait = "idle"
	_pelvis_y = ride_height
	_pelvis_pitch = 0.0
	_pelvis_roll = 0.0
	_tail_phase = 0.0
	_root_node.transform = Transform3D.IDENTITY

	_feet.clear()
	for leg_id in QuadrupedRig.LEG_NAMES:
		var rest_w := _rest_paw_world(leg_id)
		var gy := terrain_height(rest_w.x, rest_w.z) if enable_terrain_ik else 0.0
		rest_w.y = gy
		_feet[leg_id] = {
			"planted": true,
			"world_pos": rest_w,
			"lift_pos": rest_w,
			"target_pos": rest_w,
			"swing_u": 0.0,
			"normal": terrain_normal(rest_w.x, rest_w.z) if enable_terrain_ik else Vector3.UP,
			"slide_err_mm": 0.0,
		}
	_apply_pose(0.0, GAIT_PRESETS["walk"])


func step(desired_dir: Vector3, desired_speed: float, delta: float, stage: int = 5) -> Dictionary:
	if _rig == null or _root_node == null or delta <= 0.0:
		return {}

	# 1. Spring-damped root velocity & yaw steering
	var target_vel := Vector3.ZERO
	if desired_speed > 0.02 and desired_dir.length_squared() > 1e-4:
		var flat_dir := Vector3(desired_dir.x, 0.0, desired_dir.z).normalized()
		target_vel = flat_dir * desired_speed
		var desired_yaw := atan2(-flat_dir.x, -flat_dir.z)
		var yaw_diff := wrapf(desired_yaw - _yaw, -PI, PI)
		var max_turn := 4.2 * delta
		var dyaw := clampf(yaw_diff * 5.0 * delta, -max_turn, max_turn)
		_yaw = wrapf(_yaw + dyaw, -PI, PI)
		_yaw_rate = dyaw / delta
	else:
		_yaw_rate = lerpf(_yaw_rate, 0.0, clampf(delta * 8.0, 0.0, 1.0))

	var accel_rate := 5.5 if target_vel.length() > _vel.length() else 7.5
	_vel = _vel.lerp(target_vel, 1.0 - exp(-delta * accel_rate))
	_pos += _vel * delta
	var ground_under_root := terrain_height(_pos.x, _pos.z) if (enable_terrain_ik and stage >= 4) else 0.0
	_pos.y = ground_under_root
	_root_node.position = _pos
	_root_node.rotation = Vector3(0.0, _yaw, 0.0)

	# 2. Gait selection (auto by speed or forced preset)
	var speed := Vector2(_vel.x, _vel.z).length()
	var gait_key := _choose_gait(speed, stage)
	_active_gait = gait_key
	var preset: Dictionary = GAIT_PRESETS.get(gait_key, GAIT_PRESETS["walk"])

	# Advance master gait cycle phase proportional to speed
	if speed > 0.08:
		var freq: float = float(preset.freq_hz) * clampf(0.55 + speed / 3.2, 0.65, 1.45)
		_cycle_phase = fposmod(_cycle_phase + delta * freq, 1.0)
	_tail_phase += delta * (2.4 + speed * 1.1)

	# 3. Foot Set Scheduler: Planted World-Lock vs Parabolic Swing Arc
	var duty: float = float(preset.duty_factor)
	var swing_frac := maxf(0.15, 1.0 - duty)
	var step_h: float = float(preset.step_height) * step_height_mul
	var stride_s: float = float(preset.stride_scale) * stride_scale_mul
	var use_terrain := enable_terrain_ik and stage >= 4
	var planted_count := 0
	var max_slide_mm := 0.0
	var foot_states: Dictionary = {}

	for leg_id in QuadrupedRig.LEG_NAMES:
		var f: Dictionary = _feet[leg_id]
		var phase_off: float = float(preset.phases[leg_id])
		var leg_phase := fposmod(_cycle_phase + phase_off, 1.0)
		var ideal_w := _predict_paw_target(leg_id, stride_s, preset, use_terrain)

		var prev_pos: Vector3 = f.world_pos
		var was_planted: bool = f.planted
		var dist_to_ideal := Vector2(prev_pos.x - ideal_w.x, prev_pos.z - ideal_w.z).length()

		var want_swing := false
		if speed > 0.12:
			want_swing = leg_phase >= duty
		else:
			# Settle step when stopping if foot is stranded far from rest stance
			want_swing = (not was_planted) or (dist_to_ideal > 0.16)

		if want_swing:
			if was_planted:
				f.planted = false
				f.lift_pos = prev_pos
				f.swing_u = 0.0
			var swing_rate := (float(preset.freq_hz) / swing_frac) if speed > 0.12 else 3.8
			f.swing_u = minf(1.0, float(f.swing_u) + delta * swing_rate)
			f.target_pos = ideal_w
			var u: float = f.swing_u
			var su := u * u * (3.0 - 2.0 * u) # Smoothstep horizontal travel
			var p: Vector3 = (f.lift_pos as Vector3).lerp(ideal_w, su)
			# Parabolic clearance arc above max(lift_y, target_y) so paws clear stairs cleanly!
			var base_y := lerpf((f.lift_pos as Vector3).y, ideal_w.y, su)
			var clear_boost := maxf(0.0, maxf((f.lift_pos as Vector3).y, ideal_w.y) - base_y)
			p.y = base_y + (step_h + clear_boost * 0.5) * sin(u * PI)
			f.world_pos = p
			f.normal = terrain_normal(p.x, p.z) if use_terrain else Vector3.UP
			f.slide_err_mm = 0.0
			if f.swing_u >= 1.0:
				f.planted = true
				f.world_pos = ideal_w
				f.swing_u = 0.0
		else:
			# Strictly world-locked stance -> 0.0 mm foot sliding!
			f.planted = true
			f.swing_u = 0.0
			var locked_pos: Vector3 = f.world_pos
			if use_terrain:
				locked_pos.y = terrain_height(locked_pos.x, locked_pos.z)
				f.normal = terrain_normal(locked_pos.x, locked_pos.z)
			f.slide_err_mm = Vector2(locked_pos.x - prev_pos.x, locked_pos.z - prev_pos.z).length() * 1000.0
			f.world_pos = locked_pos

		if f.planted:
			planted_count += 1
			max_slide_mm = maxf(max_slide_mm, float(f.slide_err_mm))

		foot_states[leg_id] = {
			"planted": bool(f.planted),
			"swing_u": float(f.swing_u),
			"world_pos": Vector3(f.world_pos),
			"target_pos": Vector3(f.target_pos),
			"slide_err_mm": float(f.slide_err_mm),
		}

	# 4. Pelvis & Spine Dynamics + 4-Limb IK
	_apply_pose(delta, preset, speed, stage)

	return {
		"root_transform": _root_node.transform,
		"speed": speed,
		"yaw_deg": rad_to_deg(_yaw),
		"gait": gait_key,
		"cycle_phase": _cycle_phase,
		"pelvis_y": _pelvis_y,
		"pelvis_pitch_deg": rad_to_deg(_pelvis_pitch),
		"pelvis_roll_deg": rad_to_deg(_pelvis_roll),
		"planted_count": planted_count,
		"max_slide_mm": max_slide_mm,
		"feet": foot_states,
	}


func _choose_gait(speed: float, stage: int) -> String:
	if speed < 0.08:
		return "idle"
	if forced_gait != "auto" and GAIT_PRESETS.has(forced_gait):
		return forced_gait
	if stage <= 1:
		return "walk"
	if stage == 2:
		return "trot" if speed >= 2.0 else "walk"
	if speed >= 3.8:
		return "gallop"
	if speed >= 2.0:
		return "trot"
	return "walk"


func _rest_paw_world(leg_id: String) -> Vector3:
	var local_off: Vector3 = QuadrupedRig.PAW_REST_OFFSETS[leg_id]
	return _pos + Basis(Vector3.UP, _yaw) * local_off


func _predict_paw_target(leg_id: String, stride_s: float, preset: Dictionary, use_terrain: bool) -> Vector3:
	var rest_w := _rest_paw_world(leg_id)
	var freq := maxf(0.5, float(preset.freq_hz))
	var half_stance_t := (float(preset.duty_factor) * 0.5) / freq
	var lead := Vector3(_vel.x, 0.0, _vel.z) * half_stance_t * (1.0 + stride_s * 0.5)
	# Add slight rotational prediction when turning
	var rel := rest_w - _pos
	var rot_lead := Vector3(-rel.z * _yaw_rate, 0.0, rel.x * _yaw_rate) * half_stance_t * 0.55
	var p := rest_w + lead + rot_lead
	p.y = terrain_height(p.x, p.z) if use_terrain else 0.0
	return p


func _apply_pose(delta: float, preset: Dictionary, speed := 0.0, stage := 5) -> void:
	_rig.reset_bone_poses()

	var fl_y: float = (_feet["FL"].world_pos as Vector3).y
	var fr_y: float = (_feet["FR"].world_pos as Vector3).y
	var hl_y: float = (_feet["HL"].world_pos as Vector3).y
	var hr_y: float = (_feet["HR"].world_pos as Vector3).y

	var front_y := (fl_y + fr_y) * 0.5
	var hind_y := (hl_y + hr_y) * 0.5
	var left_y := (fl_y + hl_y) * 0.5
	var right_y := (fr_y + hr_y) * 0.5
	var avg_foot_y := (front_y + hind_y) * 0.5

	# Pelvis vertical ride height + gait bob + terrain pitch/roll + turn banking
	var target_pelvis_y := (avg_foot_y - _pos.y) + ride_height
	var target_pitch := 0.0
	var target_roll := 0.0
	if enable_pelvis_dynamics and stage >= 3:
		var speed_fac := clampf(speed / 2.5, 0.0, 1.0)
		var bob_amp: float = float(preset.bob_amp) * speed_fac
		target_pelvis_y += sin(_cycle_phase * TAU * 2.0) * bob_amp
		# Pitch positive lifts nose up when front paws are higher than hind paws
		var terrain_pitch := atan2(front_y - hind_y, absf(QuadrupedRig.FRONT_Z - QuadrupedRig.HIND_Z))
		var gallop_pitch := sin(_cycle_phase * TAU) * float(preset.spine_pitch_amp) * speed_fac
		target_pitch = clampf(terrain_pitch * 0.85 + gallop_pitch, deg_to_rad(-28.0), deg_to_rad(28.0))
		var terrain_roll := atan2(left_y - right_y, QuadrupedRig.LEG_X * 2.0)
		var bank_roll := clampf(-_yaw_rate * speed * 0.032, deg_to_rad(-16.0), deg_to_rad(16.0))
		target_roll = clampf(terrain_roll * 0.65 + bank_roll, deg_to_rad(-20.0), deg_to_rad(20.0))

	var smooth := 1.0 if delta <= 0.0 else (1.0 - exp(-delta * 12.0))
	_pelvis_y = lerpf(_pelvis_y, target_pelvis_y, smooth)
	_pelvis_pitch = lerpf(_pelvis_pitch, target_pitch, smooth)
	_pelvis_roll = lerpf(_pelvis_roll, target_roll, smooth)

	var pelvis_idx: int = int(_bone_ids.get("Pelvis", -1))
	if pelvis_idx >= 0:
		var rest_p := _rig.get_bone_rest(pelvis_idx).origin
		_rig.set_bone_pose_position(pelvis_idx, Vector3(rest_p.x, _pelvis_y, rest_p.z))
		_rig.set_bone_pose_rotation(pelvis_idx, Quaternion.from_euler(Vector3(_pelvis_pitch, 0.0, _pelvis_roll)))

	# Procedural Spine S-wave, Head Horizon Stabilization, and Trailing Spring Tail
	if enable_pelvis_dynamics and stage >= 3:
		var sway := sin(_cycle_phase * TAU) * 0.045 * clampf(speed / 2.2, 0.0, 1.0)
		var turn_bend := clampf(_yaw_rate * 0.09, -0.22, 0.22)
		var flex := sin(_cycle_phase * TAU + 0.6) * float(preset.spine_pitch_amp) * 0.55 * clampf(speed / 3.0, 0.0, 1.0)
		_set_rot("Spine1", Vector3(flex, sway + turn_bend * 0.5, 0.0))
		_set_rot("Spine2", Vector3(-flex * 0.5, -sway * 0.6 + turn_bend * 0.5, 0.0))
		_set_rot("Chest", Vector3(0.0, turn_bend * 0.4, 0.0))
		# Counter-pitch Neck/Head to keep eyes level with horizon
		_set_rot("Neck", Vector3(-_pelvis_pitch * 0.45, turn_bend * 0.6, -_pelvis_roll * 0.35))
		_set_rot("Head", Vector3(-_pelvis_pitch * 0.35, turn_bend * 0.5, -_pelvis_roll * 0.35))
		# Trailing sinusoidal tail
		for t_i in 3:
			var t_wave := sin(_tail_phase - float(t_i) * 0.75) * (0.14 + float(t_i) * 0.06)
			var t_lift := 0.08 + clampf(speed / 6.0, 0.0, 0.20)
			_set_rot("Tail%d" % (t_i + 1), Vector3(t_lift, t_wave - turn_bend * 0.5, 0.0))

	_rig.force_update_all_bone_transforms()

	# 4-Limb Analytical Two-Bone IK (Front: backward elbow +Z, Hind: forward stifle -Z)
	if stage >= 4 or enable_terrain_ik:
		var inv_root := _root_node.transform.affine_inverse()
		for leg_id in QuadrupedRig.LEG_NAMES:
			var b: Array = QuadrupedRig.LEG_BONES[leg_id]
			var upper_i: int = int(_bone_ids.get(b[1], -1))
			var lower_i: int = int(_bone_ids.get(b[2], -1))
			var paw_i: int = int(_bone_ids.get(b[3], -1))
			var target_local := inv_root * (_feet[leg_id].world_pos as Vector3)
			# Pole vector in local rig space: front legs bend elbow backward (+Z), hind legs bend knee forward (-Z)
			var is_front: bool = leg_id.begins_with("F")
			var pole_dir := Vector3(0.0, 0.0, 1.0) if is_front else Vector3(0.0, 0.0, -1.0)
			_solve_two_bone_limb(upper_i, lower_i, paw_i, target_local, pole_dir)

	_rig.force_update_all_bone_transforms()


func _set_rot(bname: String, euler: Vector3) -> void:
	var idx: int = int(_bone_ids.get(bname, -1))
	if idx >= 0:
		_rig.set_bone_pose_rotation(idx, Quaternion.from_euler(euler))


func _solve_two_bone_limb(upper_i: int, lower_i: int, paw_i: int, target_local: Vector3, pole_dir: Vector3) -> void:
	if upper_i < 0 or lower_i < 0 or paw_i < 0:
		return
	var hip_pos := _rig.get_bone_global_pose(upper_i).origin
	var upper_len := QuadrupedRig.UPPER_LEN
	var lower_len := QuadrupedRig.LOWER_LEN

	var to_target := target_local - hip_pos
	var dist := to_target.length()
	var min_d := absf(upper_len - lower_len) + 0.03
	var max_d := upper_len + lower_len - 0.015
	dist = clampf(dist, min_d, max_d)
	var dir := to_target.normalized() if to_target.length_squared() > 1e-6 else Vector3.DOWN

	# Compute knee/elbow bend plane orthogonal to hip->target using pole_dir
	var bend_axis := pole_dir.slide(dir)
	if bend_axis.length_squared() < 1e-5:
		bend_axis = Vector3.RIGHT.slide(dir)
	bend_axis = bend_axis.normalized()

	var along := (upper_len * upper_len - lower_len * lower_len + dist * dist) / (2.0 * dist)
	var perp := sqrt(maxf(0.0, upper_len * upper_len - along * along))
	var knee_pos := hip_pos + dir * along + bend_axis * perp
	var foot_pos := hip_pos + dir * dist

	# Build global bases whose -Y points along each limb segment (matching capsule rest orientation)
	var upper_basis := _aim_neg_y(knee_pos - hip_pos, bend_axis)
	var lower_basis := _aim_neg_y(foot_pos - knee_pos, bend_axis)

	_rig.set_bone_global_pose(upper_i, Transform3D(upper_basis, hip_pos))
	_rig.force_update_all_bone_transforms()
	_rig.set_bone_global_pose(lower_i, Transform3D(lower_basis, knee_pos))
	_rig.force_update_all_bone_transforms()
	_rig.set_bone_global_pose(paw_i, Transform3D(Basis.IDENTITY, foot_pos))


func _aim_neg_y(segment: Vector3, hint_fwd: Vector3) -> Basis:
	var y_axis := -segment.normalized()
	var x_axis := y_axis.cross(hint_fwd)
	if x_axis.length_squared() < 1e-5:
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis).orthonormalized()
