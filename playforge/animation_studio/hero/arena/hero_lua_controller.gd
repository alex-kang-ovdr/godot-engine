@tool
class_name HeroLuaController
extends RefCounted
## Unified 1:1 restoration of Havok Hero's 10 Lua behavior scripts in Godot GDScript:
##   - hero.lua (root update, foot forward, ground support raycast, front wall push, event dispatch, jumpActions)
##   - hero_locomotion.lua (radialSelectAnimation, computeDifference, 115deg Turn180, run/walk/strafe/fall)
##   - hero_vaulting.lua (g_lowVaultDock, g_lowVaultDockFromBehind, bidirectional vaultLowWall, landing raycast)
##   - hero_climbing.lua (g_jumpToPlatformDock, g_dropFromPlatformDock, shimmy, climb up, undockPlatform)
##   - hero_cover.lua (g_wallDock, g_coverToCoverDock, takeCover, cover walk, coverToCover, comeOutOfCover)
##   - hero_leaping.lua (g_leapToPlatformDock, drop-ahead raycast, leapToPlatform)
##   - hero_lines.lua & hero_docking.lua (via HeroLuaLines)
##   - hero_camera.lua (via HeroLuaCamera)
##   - hero_gamepad.lua (via HeroLuaGamepad)

const GamepadScript := preload("res://hero/arena/hero_lua_gamepad.gd")
const LinesScript := preload("res://hero/arena/hero_lua_lines.gd")
const CameraScript := preload("res://hero/arena/hero_lua_camera.gd")

const JUMP_ACTION_JUMP_TO_PLATFORM := 0
const JUMP_ACTION_LEAP_TO_PLATFORM := 1
const JUMP_ACTION_VAULT := 2

var gamepad: GamepadScript = GamepadScript.new()
var line_world: LinesScript = LinesScript.new()
var cam: CameraScript = CameraScript.new()

# Restored Havok Behavior Variables (1:1 naming with hero*.lua)
var variables: Dictionary = {
	"IsRightFootForward": 0,
	"AnimationIndex": 0,
	"FallingSelector": 0,
	"GravityFactor": 1.0,
	"WalkSpeed": 0.0,
	"WalkDirection": 0.0,
	"WeaponType": 0, # 0 = unarmed, 1 = sword drawn
	"VaultFromLeft": 0,
	"VaultingSelector": 0,
	"PlatformStartState": 0,
	"ClimbAnimationIndex": 0,
	"LocomotionStartState": 0,
	"DockingHeightSelector": 0,
	"DockingSpeedSelector": 0,
	"IntoCoverStartState": 0,
	"LeapSelector": 0,
	"ShowDockingLines": true,
}

# Restored g_characterState (hero.lua lines 39-79)
var state: Dictionary = {
	"active_state": "Idle",
	"active_clip": "idle",
	"last_event": "Init",
	"timestep": 0.0166,
	"angle": 0.0,
	"forward": Vector3(0.0, 0.0, 1.0),
	"current_pos": Vector3.ZERO,
	"last_pos": Vector3.ZERO,
	"velocity": Vector3.ZERO,
	"is_supported": true,
	"is_supported_counter": 0,
	"check_for_falling": false,
	"pushing_into_wall": false,
	"docked_speed": 0.0,
	"docked_max_speed": 1.0,
	"docked_acceleration": 0.1,
	"line_length": 0.0,
	"distance_on_line": 0.0,
	"line_param": 0.0,
	"docked_move_direction": 0.0,
	"stick_direction": Vector3.ZERO,
	"cover_to_cover": false,
	"aim_target_camera_angle_x": 0.0,
	"aim_target_camera_angle_y": -0.14,
	"event_log": [],
}

var hero_pos: Vector3 = Vector3(-10.0, 0.0, 10.0)
var hero_yaw: float = 0.0
var vertical_vel: float = 0.0
var state_timer: float = 0.0
var state_duration: float = 0.0
var action_start_pos: Vector3 = Vector3.ZERO
var action_end_pos: Vector3 = Vector3.ZERO
var action_start_yaw: float = 0.0
var action_end_yaw: float = 0.0
var action_arc_height: float = 0.0


static func angle_diff(diff: float) -> float:
	var d := fmod(diff, TAU)
	if d > PI:
		d -= TAU
	elif d < -PI:
		d += TAU
	return d


func init_world() -> int:
	return line_world.load_lines()


func teleport_hero(pos: Vector3, yaw: float, clear_dock: bool = true) -> void:
	hero_pos = pos
	hero_yaw = yaw
	vertical_vel = 0.0
	if clear_dock:
		line_world.clear_docking_target()
	state["current_pos"] = pos
	state["last_pos"] = pos
	state["velocity"] = Vector3.ZERO
	state["active_state"] = "Idle"
	state["active_clip"] = "sword_idle" if int(variables["WeaponType"]) == 1 else "idle"
	state["is_supported"] = true
	state["is_supported_counter"] = 0
	state["docked_speed"] = 0.0
	state["cover_to_cover"] = false
	cam.reset_behind(pos, get_hero_forward())


func get_hero_forward() -> Vector3:
	return Vector3(sin(hero_yaw), 0.0, cos(hero_yaw)).normalized()


func _log_event(ev: String) -> void:
	state["last_event"] = ev
	var log_arr: Array = state["event_log"]
	log_arr.append(ev)
	if log_arr.size() > 14:
		log_arr.pop_front()


# --- hero_locomotion.lua: radialSelectAnimation & computeDifference ---
func radial_select_animation(num_slices: int) -> int:
	var a := cam.angle + gamepad.pad_angle + hero_yaw + (TAU / float(num_slices * num_slices))
	a = fposmod(a, TAU)
	return int(floor(a / TAU * float(num_slices))) % num_slices


func compute_difference() -> float:
	if gamepad.pad_magnitude < 0.5:
		return 0.0
	var desired_dir := gamepad.left_direction
	if desired_dir.length_squared() < 1e-6:
		return 0.0
	var desired_yaw := atan2(desired_dir.x, desired_dir.z)
	return angle_diff(desired_yaw - hero_yaw)


# --- hero.lua: onUpdateRoot ---
func step(dt: float, skeleton: Skeleton3D, raycast_fn: Callable) -> void:
	dt = clampf(dt, 0.001, 0.05)
	state["timestep"] = dt

	gamepad.update(dt, cam.forward_xz)

	var fwd := get_hero_forward()
	state["angle"] = hero_yaw
	state["forward"] = fwd

	# Foot-forward detection from LeftLegCalf / RightLegCalf (hero.lua lines 102-116)
	if skeleton != null:
		var l_idx := skeleton.find_bone("LeftLegCalf")
		var r_idx := skeleton.find_bone("RightLegCalf")
		if l_idx >= 0 and r_idx >= 0:
			var l_fwd := skeleton.get_bone_global_pose(l_idx).origin.z
			var r_fwd := skeleton.get_bone_global_pose(r_idx).origin.z
			variables["IsRightFootForward"] = 1 if r_fwd > l_fwd else 0

	state["last_pos"] = state["current_pos"]
	state["current_pos"] = hero_pos

	# Ground-support look-ahead raycast + 3-frame counter (hero.lua lines 122-192)
	var vel_xz := Vector3(state["velocity"].x, 0.0, state["velocity"].z)
	var cast_ahead := vel_xz * (dt * 8.0)
	if cast_ahead.length() > 0.7:
		cast_ahead = cast_ahead.normalized() * 0.7
	var ray_from := hero_pos + cast_ahead + Vector3(0.0, 0.45, 0.0)
	var ray_to := ray_from + Vector3(0.0, -1.2, 0.0)
	var hit_info: Dictionary = raycast_fn.call(ray_from, ray_to) if raycast_fn.is_valid() else {"hit": true, "position": Vector3(hero_pos.x, 0.0, hero_pos.z)}
	var hit_ground: bool = bool(hit_info.get("hit", false))

	if hit_ground:
		state["is_supported_counter"] = 0
		state["is_supported"] = true
	else:
		state["is_supported_counter"] = int(state["is_supported_counter"]) + 1
		state["is_supported"] = int(state["is_supported_counter"]) < 3

	var act: String = str(state["active_state"])
	if not bool(state["is_supported"]):
		var busy := act in ["Jumping", "Falling", "Climbing", "ClimbUp", "Hanging", "Vaulting", "Leaping", "Strafe", "Cover", "CoverRoll", "Drop"]
		if bool(state["check_for_falling"]) or not busy:
			if gamepad.left_trigger > 0.5:
				try_catch_platform()
			var long_hit: Dictionary = raycast_fn.call(ray_from, ray_from + Vector3(0.0, -5.0, 0.0)) if raycast_fn.is_valid() else {"hit": true}
			variables["FallingSelector"] = 0 if bool(long_hit.get("hit", false)) else 1
			if not (str(state["active_state"]) in ["Climbing", "ClimbUp", "Hanging"]):
				_enter_falling()

	# Front wall push detection (hero.lua lines 194-207)
	var w_from := hero_pos + Vector3(0.0, 0.5, 0.0)
	var w_to := w_from + fwd * 1.0
	var wall_hit: Dictionary = raycast_fn.call(w_from, w_to) if raycast_fn.is_valid() else {"hit": false}
	state["pushing_into_wall"] = false
	if bool(wall_hit.get("hit", false)) and gamepad.left_direction.length_squared() > 0.01:
		var wn: Vector3 = wall_hit.get("normal", Vector3.ZERO)
		if wn.dot(gamepad.left_direction) < -0.7:
			state["pushing_into_wall"] = true

	# Active docking line projection (hero.lua lines 209-226)
	if not line_world.docking_target.is_empty():
		var dtgt := line_world.docking_target
		var line_vec: Vector3 = (dtgt["b"] as Vector3) - (dtgt["a"] as Vector3)
		var to_line: Vector3 = hero_pos - (dtgt["a"] as Vector3)
		var llen := maxf(1e-5, line_vec.length())
		state["line_length"] = llen
		state["distance_on_line"] = line_vec.dot(to_line) / llen
		state["line_param"] = clampf(float(state["distance_on_line"]) / llen, 0.0, 1.0)
		state["stick_direction"] = gamepad.left_direction
		state["docked_move_direction"] = gamepad.left_direction.dot(line_vec.normalized())

	# Step current behavior state
	_update_active_state(dt, raycast_fn)

	state["velocity"] = (hero_pos - (state["last_pos"] as Vector3)) / dt

	# Update restored hero_camera.lua
	var rib_w := hero_pos + Vector3(0.0, 1.35, 0.0)
	var head_w := hero_pos + Vector3(0.0, 1.68, 0.0)
	if skeleton != null:
		var rib_i := skeleton.find_bone("Ribcage")
		var head_i := skeleton.find_bone("Head")
		if rib_i >= 0:
			rib_w = hero_pos + Quaternion(Vector3.UP, hero_yaw) * skeleton.get_bone_global_pose(rib_i).origin
		if head_i >= 0:
			head_w = hero_pos + Quaternion(Vector3.UP, hero_yaw) * skeleton.get_bone_global_pose(head_i).origin
	cam.update(dt, gamepad, state, hero_pos, state["last_pos"], get_hero_forward(), state["velocity"], rib_w, head_w, raycast_fn)


# --- hero.lua: onRootEventRaised ---
func raise_event(event_name: String, raycast_fn: Callable = Callable()) -> bool:
	_log_event("Event:" + event_name)
	var act: String = str(state["active_state"])

	if event_name == "Action":
		if act == "Hanging":
			return undock_platform(raycast_fn)
		elif act == "Cover":
			if cover_to_cover():
				return true
			return come_out_of_cover()
		elif not (act in ["Vaulting", "Cover", "CoverRoll"]):
			return take_cover()

	elif event_name == "JumpButton":
		if not (act in ["DrawSword", "Climbing", "Hanging", "Leaping", "Cover", "Vaulting", "Jumping", "Falling", "Strafe"]):
			if jump_actions(raycast_fn):
				return true
			if act == "Idle":
				_start_jump("jump_spot", 0.84, 0.4, 0.95)
			else:
				_start_jump("jump_run", 1.15, 3.6, 1.1)
			return true

	elif event_name == "Strafe":
		state["aim_target_camera_angle_x"] = cam.angle
		state["aim_target_camera_angle_y"] = -0.14
		state["active_state"] = "Strafe"
		state["active_clip"] = "strafe_f"
		return true

	elif event_name == "StrafeEnd" or event_name == "ToIdle":
		if act == "Strafe":
			state["active_state"] = "Idle"
			state["active_clip"] = "sword_idle" if int(variables["WeaponType"]) == 1 else "idle"
			return true

	elif event_name == "WeaponToggle":
		var is_hanging := act in ["Hanging", "Climbing"]
		if int(variables["WeaponType"]) == 1:
			variables["WeaponType"] = 0
			_log_event("SheathSword")
			state["active_state"] = "Idle"
			state["active_clip"] = "idle"
			return true
		elif not is_hanging:
			state["active_state"] = "DrawSword"
			state["active_clip"] = "draw_sword"
			state_timer = 0.0
			state_duration = 1.15
			_log_event("DrawSword")
			return true

	elif event_name == "Attack":
		if act in ["Idle", "Walk", "Run", "Sprint", "Strafe"]:
			state["active_state"] = "Attack"
			state["active_clip"] = "sword_attack" if int(variables["WeaponType"]) == 1 else "melee_kick"
			state_timer = 0.0
			state_duration = 1.12 if int(variables["WeaponType"]) == 1 else 1.20
			_log_event("SwordAttack" if int(variables["WeaponType"]) == 1 else "MeleeKick")
			return true

	return false


# --- hero.lua: jumpActions() priority competition across Climbing / Leaping / Vaulting ---
func jump_actions(raycast_fn: Callable) -> bool:
	var best_line: Dictionary = {}
	var best_dist := 10000000.0
	var jump_action := -1
	var fwd := get_hero_forward()

	# 1. Jump to Platform / Ledge (hero_climbing.lua: g_jumpToPlatformDock)
	var r_climb := line_world.find_line_to_dock_to(
		PackedInt32Array([LinesScript.LINE_TYPE_LEDGE, LinesScript.LINE_TYPE_PLATFORM]),
		0.0, 3.0, _cond_jump_to_platform, hero_pos, fwd, best_dist
	)
	if not (r_climb["line"] as Dictionary).is_empty():
		best_line = r_climb["line"]
		best_dist = float(r_climb["distance"])
		jump_action = JUMP_ACTION_JUMP_TO_PLATFORM

	# 2. Leap across gap to Platform / Ledge (hero_leaping.lua: g_leapToPlatformDock)
	var r_leap := line_world.find_line_to_dock_to(
		PackedInt32Array([LinesScript.LINE_TYPE_LEDGE, LinesScript.LINE_TYPE_PLATFORM]),
		2.0, 7.0, _cond_leap_to_platform, hero_pos, fwd, best_dist
	)
	if not (r_leap["line"] as Dictionary).is_empty():
		best_line = r_leap["line"]
		best_dist = float(r_leap["distance"])
		jump_action = JUMP_ACTION_LEAP_TO_PLATFORM

	# 3. Vault low wall / railing (hero_vaulting.lua: g_lowVaultDock)
	var r_vault := line_world.find_line_to_dock_to(
		PackedInt32Array([LinesScript.LINE_TYPE_RAILING]),
		0.0, 4.0, _cond_low_vault, hero_pos, fwd, best_dist
	)
	if not (r_vault["line"] as Dictionary).is_empty():
		best_line = r_vault["line"]
		best_dist = float(r_vault["distance"])
		jump_action = JUMP_ACTION_VAULT

	match jump_action:
		JUMP_ACTION_JUMP_TO_PLATFORM:
			return jump_to_platform(best_line)
		JUMP_ACTION_LEAP_TO_PLATFORM:
			return leap_to_platform(best_line, raycast_fn)
		JUMP_ACTION_VAULT:
			return vault_low_wall(best_line, best_dist, raycast_fn)
	return false


# --- Exact Lua Docking Conditions ---
func _cond_low_vault(pos_minus_pt: Vector3, _pos: Vector3, fwd: Vector3, _edge_normal: Vector3) -> bool:
	var h := pos_minus_pt.y
	var p := Vector3(pos_minus_pt.x, 0.0, pos_minus_pt.z)
	if p.length_squared() < 1e-6:
		return false
	return p.normalized().dot(fwd) < -0.4 and h < 0.0 and h > -1.75


func _cond_low_vault_from_behind(pos_minus_pt: Vector3, _pos: Vector3, fwd: Vector3, _edge_normal: Vector3) -> bool:
	var h := pos_minus_pt.y
	var p := Vector3(pos_minus_pt.x, 0.0, pos_minus_pt.z)
	if p.length_squared() < 1e-6:
		return false
	return p.normalized().dot(fwd) > 0.4 and h < 0.0 and h > -1.75


func _cond_jump_to_platform(pos_minus_pt: Vector3, _pos: Vector3, fwd: Vector3, edge_normal: Vector3) -> bool:
	var h := pos_minus_pt.y
	var p := Vector3(pos_minus_pt.x, 0.0, pos_minus_pt.z)
	if p.length_squared() < 1e-6:
		return false
	return h < -1.0 and h > -4.0 and absf(p.normalized().dot(fwd)) > 0.8 and edge_normal.dot(fwd) < 0.1


func _cond_drop_from_platform(pos_minus_pt: Vector3, _pos: Vector3, _fwd: Vector3, _edge_normal: Vector3) -> bool:
	return pos_minus_pt.length() < 0.5


func _cond_leap_to_platform(pos_minus_pt: Vector3, _pos: Vector3, fwd: Vector3, edge_normal: Vector3) -> bool:
	var h := pos_minus_pt.y
	var p := Vector3(pos_minus_pt.x, 0.0, pos_minus_pt.z)
	if p.length_squared() < 1e-6:
		return false
	return edge_normal.dot(fwd) < -0.5 and p.normalized().dot(fwd) < -0.8 and h >= -3.0 and h <= 2.0


func _cond_wall_dock(pos_minus_pt: Vector3, _pos: Vector3, fwd: Vector3, _edge_normal: Vector3) -> bool:
	return pos_minus_pt.dot(fwd) < 0.5 and absf(pos_minus_pt.y) < 0.35


func _cond_cover_to_cover(pos_minus_pt: Vector3, _pos: Vector3, fwd: Vector3, _edge_normal: Vector3) -> bool:
	var right := fwd.cross(Vector3.UP).normalized()
	var right_dist := pos_minus_pt.dot(right)
	var s := int(variables["IntoCoverStartState"])
	return absf(fwd.dot(pos_minus_pt)) < 0.25 and ((right_dist < 0.0 and s == 0) or (right_dist > 0.0 and s == 1))


# --- hero_vaulting.lua ---
func vault_low_wall(line: Dictionary, distance: float, raycast_fn: Callable) -> bool:
	if line.is_empty() or str(state["active_state"]) == "DrawSword":
		return false
	var vault_from_right := int(variables["IsRightFootForward"])
	if distance < 0.0:
		vault_from_right = 1 - vault_from_right
	variables["VaultFromLeft"] = 0 if vault_from_right == 0 else 1
	variables["VaultingSelector"] = 2 if distance < 0.0 else (1 if distance < 2.5 else 0)

	line_world.set_line_docking_target(line)
	if int(variables["WeaponType"]) == 1:
		variables["WeaponType"] = 0
		_log_event("SheathSwordFast")

	var closest := LinesScript.closest_point_on_line(line, hero_pos)
	var cross_dir := Vector3(closest.x - hero_pos.x, 0.0, closest.z - hero_pos.z)
	if cross_dir.length_squared() < 1e-4:
		cross_dir = get_hero_forward()
	else:
		cross_dir = cross_dir.normalized()

	var land_probe := closest + cross_dir * 1.55 + Vector3(0.0, 0.35, 0.0)
	var land_y := hero_pos.y
	if raycast_fn.is_valid():
		var hit: Dictionary = raycast_fn.call(land_probe, land_probe + Vector3(0.0, -20.0, 0.0))
		if bool(hit.get("hit", false)):
			land_y = (hit["position"] as Vector3).y
			line_world.set_plane_docking_target(Vector3.UP, hit["position"])

	action_start_pos = hero_pos
	action_end_pos = Vector3(closest.x + cross_dir.x * 1.45, land_y, closest.z + cross_dir.z * 1.45)
	action_start_yaw = hero_yaw
	action_end_yaw = atan2(cross_dir.x, cross_dir.z)
	# vault_idle / vault_low already animate pelvis upward by ~0.5m over a 1.06m railing;
	# only add extra vertical lift if railing exceeds 1.15m above ground!
	var barrier_h := closest.y - minf(hero_pos.y, land_y)
	action_arc_height = maxf(0.0, barrier_h - 1.15)
	state["active_state"] = "Vaulting"
	state["active_clip"] = "vault_idle" if distance < 2.5 else "vault_low"
	state_timer = 0.0
	state_duration = 1.0 if distance < 2.5 else 1.55
	_log_event("Vault(sel=%d)" % int(variables["VaultingSelector"]))
	return true


# --- hero_climbing.lua ---
func jump_to_platform(line: Dictionary) -> bool:
	if line.is_empty() or str(state["active_state"]) == "DrawSword":
		return false
	line_world.set_line_docking_target(line)
	variables["PlatformStartState"] = 0
	variables["ClimbAnimationIndex"] = 1 if int(line["line_type"]) == LinesScript.LINE_TYPE_LEDGE else 0
	if int(variables["WeaponType"]) == 1:
		variables["WeaponType"] = 0
		_log_event("SheathSwordFast")

	var closest := LinesScript.closest_point_on_line(line, hero_pos)
	var n: Vector3 = line["edge_normal"]
	# In jump_grab_platform, frame 0 has feet at local Y = -2.82 and final frame has hands at local Y = +0.02, Z = 0.00!
	# Therefore, origin (0,0,0) IS the exact ledge lip (closest.y) — zero -1.55m sinking!
	# Start origin at max(ground_y + 2.80, closest.y) so feet begin cleanly on the ground and hands lock onto the exact lip.
	action_start_pos = Vector3(hero_pos.x, hero_pos.y + 2.80, hero_pos.z)
	action_end_pos = closest + n * 0.04
	action_start_yaw = hero_yaw
	action_end_yaw = atan2(-n.x, -n.z)
	action_arc_height = 0.0
	state["active_state"] = "Climbing"
	state["active_clip"] = "jump_grab_platform"
	state_timer = 0.0
	state_duration = 0.65
	_log_event("Platform(type=%d)" % int(line["line_type"]))
	return true


func try_catch_platform() -> bool:
	if not line_world.docking_target.is_empty() or int(variables["WeaponType"]) == 1:
		return false
	var res := line_world.find_line_to_dock_to(
		PackedInt32Array([LinesScript.LINE_TYPE_LEDGE, LinesScript.LINE_TYPE_PLATFORM]),
		0.0, 2.0, _cond_drop_from_platform, hero_pos, get_hero_forward()
	)
	var line: Dictionary = res["line"]
	if line.is_empty():
		return false
	line_world.set_line_docking_target(line)
	variables["PlatformStartState"] = 1
	variables["ClimbAnimationIndex"] = 1 if int(line["line_type"]) == LinesScript.LINE_TYPE_LEDGE else 0
	var closest := LinesScript.closest_point_on_line(line, hero_pos)
	var n: Vector3 = line["edge_normal"]
	hero_pos = closest + n * 0.04
	hero_yaw = atan2(-n.x, -n.z)
	state["active_state"] = "Hanging"
	state["active_clip"] = "platform_idle"
	_log_event("CatchPlatform")
	return true


func undock_platform(raycast_fn: Callable) -> bool:
	if line_world.docking_target.is_empty():
		return false
	var from := hero_pos - get_hero_forward() * 0.75 + Vector3(0.0, -0.5, 0.0)
	var to := from + Vector3(0.0, -8.0, 0.0)
	var hit: Dictionary = raycast_fn.call(from, to) if raycast_fn.is_valid() else {"hit": true, "position": Vector3(from.x, 0.0, from.z)}
	if not bool(hit.get("hit", false)):
		return false
	line_world.set_plane_docking_target(Vector3.UP, hit["position"])
	action_start_pos = Vector3(hero_pos.x, maxf((hit["position"] as Vector3).y, hero_pos.y - 2.1), hero_pos.z)
	action_end_pos = hit["position"]
	action_start_yaw = hero_yaw
	action_end_yaw = hero_yaw
	action_arc_height = 0.05
	state["active_state"] = "Drop"
	state["active_clip"] = "platform_drop"
	state_timer = 0.0
	state_duration = 0.95
	_log_event("Drop")
	return true


# --- hero_cover.lua ---
func take_cover() -> bool:
	var res := line_world.find_line_to_dock_to(
		PackedInt32Array([LinesScript.LINE_TYPE_LOW_WALL, LinesScript.LINE_TYPE_HIGH_WALL]),
		0.0, 3.0, _cond_wall_dock, hero_pos, get_hero_forward()
	)
	var line: Dictionary = res["line"]
	if line.is_empty():
		return false
	var dist := float(res["distance"])
	line_world.set_line_docking_target(line)
	variables["DockingHeightSelector"] = 1 if int(line["line_type"]) == LinesScript.LINE_TYPE_HIGH_WALL else 0
	var spd := (state["velocity"] as Vector3).length()
	variables["DockingSpeedSelector"] = 1 if (spd > 2.5 and dist > 1.0) else 0
	var line_dir := ((line["b"] as Vector3) - (line["a"] as Vector3)).normalized()
	variables["IntoCoverStartState"] = 1 if line_dir.dot(get_hero_forward()) > 0.0 else 0

	# Geometric audit of Environment.glb: cover wall solid sits on +n (+0.06m..+0.56m), open air is on -n!
	# In cover_low_idle / cover_high_idle, Hero's back is at local Z = 0 and knees/feet extend into +Z (+0.00..+0.65m).
	# Place Hero flush on the open-air face (-n * 0.04) facing -n (away from wall into open air)!
	var closest := LinesScript.closest_point_on_line(line, hero_pos)
	var n: Vector3 = line["edge_normal"]
	hero_pos = Vector3(closest.x - n.x * 0.04, closest.y, closest.z - n.z * 0.04)
	hero_yaw = atan2(-n.x, -n.z)
	state["active_state"] = "Cover"
	state["active_clip"] = "cover_high_idle" if int(variables["DockingHeightSelector"]) == 1 else "cover_low_idle"
	state["docked_speed"] = 0.0
	_log_event("IntoCover(h=%d)" % int(variables["DockingHeightSelector"]))
	return true


func cover_to_cover() -> bool:
	if bool(state["cover_to_cover"]) or line_world.docking_target.is_empty():
		return false
	var lp := float(state["line_param"])
	if not (lp < 0.05 or lp > 0.95):
		return false
	var res := line_world.find_line_to_dock_to(
		PackedInt32Array([LinesScript.LINE_TYPE_LOW_WALL, LinesScript.LINE_TYPE_HIGH_WALL]),
		1.0, 6.0, _cond_cover_to_cover, hero_pos, get_hero_forward(), -1.0, int(line_world.docking_target["index"])
	)
	var line: Dictionary = res["line"]
	if line.is_empty():
		return false
	line_world.set_line_docking_target(line)
	state["docked_speed"] = 0.0
	state["cover_to_cover"] = true
	var closest := LinesScript.closest_point_on_line(line, hero_pos)
	var n: Vector3 = line["edge_normal"]
	action_start_pos = hero_pos
	action_end_pos = Vector3(closest.x - n.x * 0.04, closest.y, closest.z - n.z * 0.04)
	action_start_yaw = hero_yaw
	action_end_yaw = atan2(-n.x, -n.z)
	action_arc_height = 0.12
	state["active_state"] = "CoverRoll"
	state["active_clip"] = "cover_roll"
	state_timer = 0.0
	state_duration = 0.90
	_log_event("CoverToCover")
	return true


func come_out_of_cover() -> bool:
	line_world.clear_docking_target()
	state["docked_speed"] = 0.0
	state["cover_to_cover"] = false
	state["active_state"] = "Idle"
	state["active_clip"] = "sword_idle" if int(variables["WeaponType"]) == 1 else "idle"
	_log_event("ComeOutOfCover")
	return true


# --- hero_leaping.lua ---
func leap_to_platform(line: Dictionary, raycast_fn: Callable) -> bool:
	if line.is_empty() or str(state["active_state"]) == "DrawSword":
		return false
	var drop_from := hero_pos + get_hero_forward() * 2.0 + Vector3(0.0, 0.35, 0.0)
	var drop_to := drop_from + Vector3(0.0, -1.35, 0.0)
	var hit_ahead := bool((raycast_fn.call(drop_from, drop_to) if raycast_fn.is_valid() else {"hit": false}).get("hit", false))
	if hit_ahead:
		return false

	line_world.set_line_docking_target(line)
	var closest := LinesScript.closest_point_on_line(line, hero_pos)
	var height_diff := closest.y - hero_pos.y
	variables["ClimbAnimationIndex"] = 1 if int(line["line_type"]) == LinesScript.LINE_TYPE_LEDGE else 0
	variables["LeapSelector"] = 1 if height_diff > 0.25 else 0
	if int(variables["WeaponType"]) == 1:
		variables["WeaponType"] = 0
		_log_event("SheathSwordFast")

	var n: Vector3 = line["edge_normal"]
	action_start_pos = hero_pos
	action_end_pos = closest + n * 0.04
	action_start_yaw = hero_yaw
	action_end_yaw = atan2(-n.x, -n.z)
	action_arc_height = maxf(0.45, height_diff * 0.5 + 0.55)
	state["active_state"] = "Leaping"
	state["active_clip"] = "leap_ledge"
	state_timer = 0.0
	state_duration = 1.45
	_log_event("Leap(sel=%d)" % int(variables["LeapSelector"]))
	return true


func _start_jump(clip: String, dur: float, forward_dist: float, arc_h: float) -> void:
	action_start_pos = hero_pos
	action_end_pos = hero_pos + get_hero_forward() * forward_dist
	action_start_yaw = hero_yaw
	action_end_yaw = hero_yaw
	action_arc_height = arc_h
	state["active_state"] = "Jumping"
	state["active_clip"] = clip
	state_timer = 0.0
	state_duration = dur
	_log_event("Jump:" + clip)


func _enter_falling() -> void:
	variables["GravityFactor"] = 3.38 # hero_locomotion.lua onActivateFalling
	vertical_vel = -1.0
	state["active_state"] = "Falling"
	state["active_clip"] = "in_air"
	_log_event("Fall(sel=%d)" % int(variables["FallingSelector"]))


func _snap_to_ground(raycast_fn: Callable) -> void:
	if not raycast_fn.is_valid():
		return
	var hit: Dictionary = raycast_fn.call(hero_pos + Vector3(0.0, 0.75, 0.0), hero_pos + Vector3(0.0, -1.25, 0.0))
	if bool(hit.get("hit", false)):
		hero_pos.y = lerpf(hero_pos.y, (hit["position"] as Vector3).y, 0.45)


func _update_active_state(dt: float, raycast_fn: Callable) -> void:
	var act: String = str(state["active_state"])

	match act:
		"Idle":
			if not gamepad.in_left_stick_in_dead_zone() and gamepad.is_left_stick_stationary() and not bool(state["pushing_into_wall"]):
				var should_walk := gamepad.left_trigger > 0.5
				variables["AnimationIndex"] = radial_select_animation(4 if should_walk else 8)
				state["active_state"] = "Walk" if should_walk else "Run"
				state["active_clip"] = "walk" if should_walk else ("sword_run" if int(variables["WeaponType"]) == 1 else "run")
				_log_event("StartWalking" if should_walk else "StartRunning")
			else:
				state["active_clip"] = "sword_idle" if int(variables["WeaponType"]) == 1 else "idle"
			_snap_to_ground(raycast_fn)

		"Walk", "Run", "Sprint":
			var wants_walk := gamepad.left_trigger > 0.5
			if (gamepad.in_left_stick_in_dead_zone() and gamepad.has_left_stick_been_stationary(0.1)) or bool(state["pushing_into_wall"]):
				state["active_state"] = "Idle"
				state["active_clip"] = "sword_idle" if int(variables["WeaponType"]) == 1 else "idle"
				_log_event("Stop")
				return
			if act == "Run" and wants_walk:
				state["active_state"] = "Walk"
				state["active_clip"] = "walk"
				_log_event("StartWalking")
			elif act == "Walk" and not wants_walk:
				state["active_state"] = "Run"
				state["active_clip"] = "sword_run" if int(variables["WeaponType"]) == 1 else "run"
				_log_event("StartRunning")

			# 115 deg Turn180 threshold (hero_locomotion.lua lines 76-81)
			var diff := compute_difference()
			if absf(diff) > deg_to_rad(115.0) and gamepad.is_left_stick_stationary():
				action_start_pos = hero_pos
				action_end_pos = hero_pos + get_hero_forward() * 0.35
				action_start_yaw = hero_yaw
				action_end_yaw = hero_yaw + PI
				action_arc_height = 0.0
				state["active_state"] = "Turn180"
				state["active_clip"] = "turn_180"
				state_timer = 0.0
				state_duration = 0.65
				_log_event("Turn180")
				return

			var turn_speed := 2.0 if state["active_state"] == "Walk" else 3.0
			hero_yaw = wrapf(hero_yaw + diff * turn_speed * dt, -PI, PI)
			var move_speed := 1.75 if state["active_state"] == "Walk" else 4.35
			var next_pos := hero_pos + get_hero_forward() * (move_speed * dt)
			if not bool(state["pushing_into_wall"]):
				hero_pos.x = next_pos.x
				hero_pos.z = next_pos.z
			_snap_to_ground(raycast_fn)

		"Strafe":
			# hero_locomotion.lua onUpdateStrafing & onGenerateStrafing
			var new_spd := clampf(gamepad.pad_magnitude, 0.0, 1.0)
			variables["WalkSpeed"] = lerpf(float(variables["WalkSpeed"]), new_spd, 0.2)
			var new_ang := gamepad.pad_angle / PI
			variables["WalkDirection"] = lerpf(float(variables["WalkDirection"]), new_ang, 0.2)
			var target_yaw := -float(state["aim_target_camera_angle_x"])
			hero_yaw = wrapf(hero_yaw + angle_diff(target_yaw - hero_yaw) * 5.0 * dt, -PI, PI)
			if new_spd > 0.15:
				var move_v := gamepad.left_direction * (2.3 * new_spd * dt)
				hero_pos.x += move_v.x
				hero_pos.z += move_v.z
				var local_f := gamepad.left_direction.dot(get_hero_forward())
				var local_r := gamepad.left_direction.dot(get_hero_forward().cross(Vector3.UP))
				if absf(local_f) >= absf(local_r):
					state["active_clip"] = "strafe_f" if local_f >= 0.0 else "strafe_b"
				else:
					state["active_clip"] = "strafe_r" if local_r >= 0.0 else "strafe_l"
			else:
				state["active_clip"] = "sword_idle" if int(variables["WeaponType"]) == 1 else "idle"
			_snap_to_ground(raycast_fn)

		"Hanging":
			# hero_climbing.lua onDockedPlatformUpdated
			if not gamepad.in_left_stick_in_dead_zone() and gamepad.left_direction.dot(get_hero_forward()) > 0.8:
				var line := line_world.docking_target
				var top_pt := LinesScript.closest_point_on_line(line, hero_pos)
				var n: Vector3 = line["edge_normal"]
				# platform_climb animates Hero from hanging (Y=-2.32) up to standing (Y=0.0, Z=+0.28) relative to the lip!
				# Keep root anchored at the exact lip during the clip; bake forward offset upon completion.
				action_start_pos = top_pt + n * 0.04
				action_end_pos = top_pt + n * 0.04
				action_start_yaw = hero_yaw
				action_end_yaw = hero_yaw
				action_arc_height = 0.0
				state["active_state"] = "ClimbUp"
				state["active_clip"] = "platform_climb"
				state["docked_speed"] = 0.0
				state_timer = 0.0
				state_duration = 1.15
				_log_event("Climb")
			else:
				var spd := _step_docked_line_speed(dt)
				if absf(spd) > 0.12:
					var line := line_world.docking_target
					var dir := ((line["b"] as Vector3) - (line["a"] as Vector3)).normalized()
					hero_pos += dir * (spd * 1.15 * dt)
					var clamped := LinesScript.closest_point_on_line(line, hero_pos)
					var n: Vector3 = line["edge_normal"]
					hero_pos = clamped + n * 0.04
					state["active_clip"] = "platform_shuffle"
				else:
					state["active_clip"] = "platform_idle"

		"Cover":
			# hero_cover.lua onUpdateInCover
			if not gamepad.in_left_stick_in_dead_zone():
				var dot_f := gamepad.left_direction.dot(get_hero_forward())
				if dot_f > 0.8:
					come_out_of_cover()
					return
				elif dot_f < -0.8:
					var r_v := line_world.find_line_to_dock_to(
						PackedInt32Array([LinesScript.LINE_TYPE_RAILING]),
						0.0, 4.0, _cond_low_vault_from_behind, hero_pos, get_hero_forward()
					)
					if not (r_v["line"] as Dictionary).is_empty():
						vault_low_wall(r_v["line"], -1.0, raycast_fn)
						return
			var spd := _step_docked_line_speed(dt)
			var is_high := int(variables["DockingHeightSelector"]) == 1
			if absf(spd) > 0.12 and not line_world.docking_target.is_empty():
				var line := line_world.docking_target
				var dir := ((line["b"] as Vector3) - (line["a"] as Vector3)).normalized()
				hero_pos += dir * (spd * 1.55 * dt)
				var clamped := LinesScript.closest_point_on_line(line, hero_pos)
				var n: Vector3 = line["edge_normal"]
				hero_pos = Vector3(clamped.x - n.x * 0.04, clamped.y, clamped.z - n.z * 0.04)
				state["active_clip"] = "cover_high_walk" if is_high else "cover_low_walk"
			else:
				state["active_clip"] = "cover_high_idle" if is_high else "cover_low_idle"

		"Falling":
			vertical_vel -= 9.81 * float(variables["GravityFactor"]) * dt
			hero_pos.y += vertical_vel * dt
			if bool(state["is_supported"]):
				variables["GravityFactor"] = 1.0
				vertical_vel = 0.0
				_snap_to_ground(raycast_fn)
				state["active_state"] = "Land"
				state["active_clip"] = "land"
				state_timer = 0.0
				state_duration = 0.55
				_log_event("LandStop" if gamepad.in_left_stick_in_dead_zone() else "LandMove")

		"Vaulting", "Climbing", "ClimbUp", "Drop", "Leaping", "Jumping", "Turn180", "CoverRoll", "DrawSword", "Attack", "Land":
			state_timer += dt
			var u := clampf(state_timer / maxf(0.05, state_duration), 0.0, 1.0)
			if act in ["Vaulting", "Climbing", "ClimbUp", "Drop", "Leaping", "Jumping", "Turn180", "CoverRoll"]:
				var p := action_start_pos.lerp(action_end_pos, u)
				p.y += sin(u * PI) * action_arc_height
				hero_pos = p
				hero_yaw = wrapf(action_start_yaw + angle_diff(action_end_yaw - action_start_yaw) * u, -PI, PI)
			if u >= 1.0:
				_finish_timed_state(act)


func _step_docked_line_speed(dt: float) -> float:
	var move_dir := float(state["docked_move_direction"])
	var spd := float(state["docked_speed"])
	var acc := float(state["docked_acceleration"])
	var max_s := float(state["docked_max_speed"])
	var lp := float(state["line_param"])
	if (lp <= 0.01 and move_dir < 0.0) or (lp >= 0.99 and move_dir > 0.0) or gamepad.pad_magnitude < 0.1:
		spd *= pow(0.95, dt * 60.0)
	else:
		spd += acc if move_dir > 0.0 else -acc
	spd = clampf(spd, -max_s, max_s)
	state["docked_speed"] = spd
	variables["WalkSpeed"] = spd
	return spd


func _finish_timed_state(act: String) -> void:
	match act:
		"Climbing", "Leaping":
			state["active_state"] = "Hanging"
			state["active_clip"] = "platform_idle"
			_log_event("DockedHanging")
		"ClimbUp":
			if not line_world.docking_target.is_empty():
				var n: Vector3 = line_world.docking_target["edge_normal"]
				var top_pt := LinesScript.closest_point_on_line(line_world.docking_target, hero_pos)
				hero_pos = Vector3(top_pt.x - n.x * 0.48, top_pt.y, top_pt.z - n.z * 0.48)
			line_world.clear_docking_target()
			variables["LocomotionStartState"] = 1 if gamepad.pad_magnitude > 0.5 else 0
			state["active_state"] = "Idle"
			state["active_clip"] = "idle"
			_log_event("ClimbFinished")
		"Drop":
			line_world.clear_docking_target()
			variables["LocomotionStartState"] = 1 if gamepad.pad_magnitude > 0.5 else 0
			state["active_state"] = "Idle"
			state["active_clip"] = "idle"
			_log_event("PlatformDropFinished")
		"Vaulting":
			line_world.clear_docking_target()
			state["active_state"] = "Idle"
			state["active_clip"] = "idle"
			_log_event("VaultOutEnd")
		"CoverRoll":
			state["cover_to_cover"] = false
			state["active_state"] = "Cover"
			state["active_clip"] = "cover_low_idle"
		"DrawSword":
			variables["WeaponType"] = 1
			state["active_state"] = "Idle"
			state["active_clip"] = "sword_idle"
			_log_event("SwordDrawn")
		_:
			state["active_state"] = "Idle"
			state["active_clip"] = "sword_idle" if int(variables["WeaponType"]) == 1 else "idle"
