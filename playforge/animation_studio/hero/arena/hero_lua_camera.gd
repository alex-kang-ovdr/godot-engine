@tool
class_name HeroLuaCamera
extends RefCounted
## 1:1 restoration of Havok Hero `hero_camera.lua` in Godot GDScript (Y-up).
## Supports CAMERA_MODE_DEFAULT (follow=5.0m), CAMERA_MODE_STRAFE (over-the-shoulder),
## CAMERA_MODE_CLIMBING_LEDGE (follow=3.5m targeting Ribcage), velocity look-ahead,
## follow-cam blending, pitch clamp [-0.1, 0.7], and physics wall-occlusion raycast.

const CAMERA_MODE_DEFAULT := 0
const CAMERA_MODE_STRAFE := 1
const CAMERA_MODE_CLIMBING_LEDGE := 2

const NORMAL_FOLLOW_DISTANCE := 5.0
const CLIMBING_FOLLOW_DISTANCE := 3.5

var from_pos: Vector3 = Vector3(0.0, 2.5, 4.0)
var to_pos: Vector3 = Vector3(0.0, 1.75, 0.0)
var forward_xz: Vector3 = Vector3(0.0, 0.0, -1.0)
var angle: float = 0.0
var mode: int = CAMERA_MODE_DEFAULT
var follow_cam: bool = true

var target_lead_amount: Vector3 = Vector3.ZERO
var camera_follow_distance: float = NORMAL_FOLLOW_DISTANCE

var orbit_max_speed_x: float = 1.75
var orbit_max_speed_y: float = 1.0
var orbit_speed_x: float = 0.0
var orbit_speed_y: float = 0.0
var camera_arm_local: Vector3 = Vector3(0.0, 0.28, 0.96).normalized()


func reset_behind(char_pos: Vector3, char_forward: Vector3) -> void:
	var back := Vector3(-char_forward.x, 0.0, -char_forward.z)
	if back.length_squared() < 1e-6:
		back = Vector3(0.0, 0.0, 1.0)
	back = back.normalized()
	var right := Vector3.UP.cross(back).normalized()
	camera_arm_local = (back * 0.84 + right * 0.36 + Vector3(0.0, 0.42, 0.0)).normalized()
	to_pos = char_pos + Vector3(0.0, 1.45, 0.0)
	from_pos = to_pos + camera_arm_local * NORMAL_FOLLOW_DISTANCE
	target_lead_amount = Vector3.ZERO
	orbit_speed_x = 0.0
	orbit_speed_y = 0.0
	_recompute_forward()


func _recompute_forward() -> void:
	var f := Vector3(to_pos.x - from_pos.x, 0.0, to_pos.z - from_pos.z)
	if f.length_squared() > 1e-6:
		forward_xz = f.normalized()
	angle = atan2(forward_xz.x, -forward_xz.z)


func add_mouse_orbit(delta_px: Vector2) -> void:
	var side := Vector3.UP.cross(camera_arm_local)
	if side.length_squared() < 1e-6:
		side = Vector3.RIGHT
	side = side.normalized()
	var qx := Quaternion(Vector3.UP, -delta_px.x * 0.006)
	camera_arm_local = (qx * camera_arm_local).normalized()
	var next_arm := (Quaternion(side, delta_px.y * 0.005) * camera_arm_local).normalized()
	if next_arm.y >= -0.1 and next_arm.y <= 0.72:
		camera_arm_local = next_arm


func update(
	timestep: float,
	gamepad,
	state: Dictionary,
	char_pos: Vector3,
	char_last_pos: Vector3,
	char_forward: Vector3,
	char_velocity: Vector3,
	ribcage_world: Vector3,
	head_world: Vector3,
	raycast_fn: Callable
) -> void:
	var active_state: String = str(state.get("active_state", "Idle"))
	mode = CAMERA_MODE_DEFAULT
	if active_state == "Strafe":
		mode = CAMERA_MODE_STRAFE
	elif active_state in ["Climbing", "ClimbUp", "Hanging", "Leaping"]:
		mode = CAMERA_MODE_CLIMBING_LEDGE

	_recompute_forward()

	if gamepad.is_right_stick_in_dead_zone():
		orbit_speed_x -= orbit_speed_x * 0.1
		orbit_speed_y -= orbit_speed_y * 0.1
	else:
		orbit_speed_x = clampf(orbit_speed_x + gamepad.right_stick_x * 0.05, -orbit_max_speed_x, orbit_max_speed_x)
		orbit_speed_y = clampf(orbit_speed_y + gamepad.right_stick_y * 0.05, -orbit_max_speed_y, orbit_max_speed_y)

	if mode == CAMERA_MODE_STRAFE:
		_update_over_the_shoulder(timestep, state, char_pos, head_world)
	else:
		_update_3rd_person(timestep, state, char_pos, char_last_pos, char_forward, char_velocity, ribcage_world, raycast_fn)
	_recompute_forward()


func _update_3rd_person(
	timestep: float,
	state: Dictionary,
	char_pos: Vector3,
	char_last_pos: Vector3,
	char_forward: Vector3,
	char_velocity: Vector3,
	ribcage_world: Vector3,
	raycast_fn: Callable
) -> void:
	var active_state: String = str(state.get("active_state", "Idle"))
	if follow_cam:
		var vel_dir := char_pos - char_last_pos
		vel_dir.y = 0.0
		if active_state == "Cover":
			vel_dir = -char_forward
		elif camera_arm_local.dot(char_forward) > 0.0 and not (active_state in ["Idle", "Walk", "Run", "Sprint", "Hanging"]):
			vel_dir = char_forward
		if vel_dir.length_squared() > 1e-5:
			vel_dir = vel_dir.normalized()
			var char_right := vel_dir.cross(Vector3.UP).normalized()
			var dot_right := camera_arm_local.dot(char_right)
			var max_dot := 0.5
			var max_spd := orbit_max_speed_x * 1.4
			var blend_in := clampf(dot_right / max_dot, -1.0, 1.0) * max_spd
			orbit_speed_x = lerpf(orbit_speed_x, blend_in, 0.1)

	if absf(orbit_speed_x) > 1e-4 or absf(orbit_speed_y) > 1e-4:
		var side := Vector3.UP.cross(camera_arm_local)
		if side.length_squared() > 1e-6:
			side = side.normalized()
		if (camera_arm_local.y > 0.7 and orbit_speed_y > 0.0) or (camera_arm_local.y < -0.1 and orbit_speed_y < 0.0):
			orbit_speed_y = 0.0
		camera_arm_local = (Quaternion(side, -orbit_speed_y * timestep) * camera_arm_local).normalized()
		camera_arm_local = (Quaternion(Vector3.UP, -orbit_speed_x * timestep) * camera_arm_local).normalized()

	var target_to := char_pos + Vector3(0.0, 1.6, 0.0)
	if mode == CAMERA_MODE_CLIMBING_LEDGE:
		target_to = ribcage_world
	var target_to_no_lead := target_to

	var scaled_vel := char_velocity * (10.0 * timestep)
	target_lead_amount = target_lead_amount.lerp(scaled_vel, clampf(5.0 * timestep, 0.0, 1.0))
	target_to += target_lead_amount

	var desired_dist := CLIMBING_FOLLOW_DISTANCE if mode == CAMERA_MODE_CLIMBING_LEDGE else NORMAL_FOLLOW_DISTANCE
	camera_follow_distance = lerpf(camera_follow_distance, desired_dist, 0.05)

	var target_from := Vector3(char_pos.x, target_to.y, char_pos.z) + camera_arm_local * camera_follow_distance

	# Wall-occlusion raycast (hero_camera.lua lines 179-196)
	if raycast_fn.is_valid():
		var hit: Dictionary = raycast_fn.call(target_to_no_lead, target_from)
		if bool(hit.get("hit", false)) and float(hit.get("fraction", 0.0)) > 0.1:
			var cam_dir := (target_from - target_to).normalized()
			target_from = (hit["position"] as Vector3) - cam_dir * 0.12

	to_pos = to_pos.lerp(target_to, 0.25)
	from_pos = from_pos.lerp(target_from, 0.33)


func _update_over_the_shoulder(timestep: float, state: Dictionary, char_pos: Vector3, head_world: Vector3) -> void:
	var aim_x := wrapf(float(state.get("aim_target_camera_angle_x", 0.0)) + orbit_speed_x * timestep, -PI, PI)
	var aim_y := clampf(float(state.get("aim_target_camera_angle_y", -0.14)) + orbit_speed_y * timestep, -0.7, 0.7)
	state["aim_target_camera_angle_x"] = aim_x
	state["aim_target_camera_angle_y"] = aim_y

	var dir := (Quaternion(Vector3.UP, -aim_x) * Vector3(0.0, 0.0, -1.0)).normalized()
	var side := dir.cross(Vector3.UP).normalized()
	dir = (Quaternion(side, aim_y) * dir).normalized()

	var target_to := char_pos + Vector3(0.0, 1.4, 0.0) + dir * 10.0
	var target_from := Vector3(head_world.x, char_pos.y + 1.95, head_world.z) - dir * 2.5 + side * 0.75 + Vector3(0.0, 0.1, 0.0)
	to_pos = to_pos.lerp(target_to, 0.30)
	from_pos = from_pos.lerp(target_from, 0.50)
