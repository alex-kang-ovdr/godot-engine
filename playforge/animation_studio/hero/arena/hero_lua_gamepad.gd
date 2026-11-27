@tool
class_name HeroLuaGamepad
extends RefCounted
## 1:1 restoration of Havok Hero `hero_gamepad.lua` in Godot GDScript.
## Preserves stick interpolation (0.9), deadzone (mag^2 < 0.1), hold timer,
## padAngle/padMagnitude, and camera-relative world-space left/right directions.

var previous_left_stick_x: float = 0.0
var previous_left_stick_y: float = 0.0
var left_stick_x: float = 0.0
var left_stick_y: float = 0.0
var left_stick_hold_time: float = 0.0
var right_stick_x: float = 0.0
var right_stick_y: float = 0.0
var left_trigger: float = 0.0
var right_trigger: float = 0.0

var pad_angle: float = 0.0
var pad_magnitude: float = 0.0
var left_direction: Vector3 = Vector3.ZERO
var right_direction: Vector3 = Vector3.ZERO

# Raw inputs fed either from keyboard/gamepad or scripted demo autopilot
var raw_left_x: float = 0.0
var raw_left_y: float = 0.0
var raw_right_x: float = 0.0
var raw_right_y: float = 0.0
var raw_left_trigger: float = 0.0


static func _interpolate(a: float, b: float, t: float) -> float:
	return (1.0 - t) * a + t * b


func set_raw_input(lx: float, ly: float, rx: float = 0.0, ry: float = 0.0, lt: float = 0.0) -> void:
	raw_left_x = clampf(lx, -1.0, 1.0)
	raw_left_y = clampf(ly, -1.0, 1.0)
	raw_right_x = clampf(rx, -1.0, 1.0)
	raw_right_y = clampf(ry, -1.0, 1.0)
	raw_left_trigger = clampf(lt, 0.0, 1.0)


func update(timestep: float, camera_forward_xz: Vector3) -> void:
	previous_left_stick_x = left_stick_x
	previous_left_stick_y = left_stick_y

	left_stick_x = _interpolate(left_stick_x, raw_left_x, 0.9)
	left_stick_y = _interpolate(left_stick_y, raw_left_y, 0.9)
	right_stick_x = _interpolate(right_stick_x, raw_right_x, 0.9)
	right_stick_y = _interpolate(right_stick_y, raw_right_y, 0.9)
	left_trigger = raw_left_trigger

	pad_angle = atan2(left_stick_x, -left_stick_y)
	pad_magnitude = sqrt(left_stick_x * left_stick_x + left_stick_y * left_stick_y)

	var dx := previous_left_stick_x - left_stick_x
	var dy := previous_left_stick_y - left_stick_y
	if dx * dx + dy * dy < 0.1:
		left_stick_hold_time += timestep
	else:
		left_stick_hold_time = 0.0

	left_direction = Vector3.ZERO
	right_direction = Vector3.ZERO

	# Camera-relative world XZ direction (Godot Y-up equivalent of hero_gamepad.lua lines 42-56)
	var fwd := Vector3(camera_forward_xz.x, 0.0, camera_forward_xz.z)
	if fwd.length_squared() < 1e-6:
		fwd = Vector3(0.0, 0.0, -1.0)
	else:
		fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()

	if left_stick_x * left_stick_x + left_stick_y * left_stick_y > 0.1:
		left_direction = (fwd * left_stick_y + right * left_stick_x).normalized()

	if right_stick_x * right_stick_x + right_stick_y * right_stick_y > 0.1:
		right_direction = (fwd * right_stick_y + right * right_stick_x).normalized()


func is_left_stick_stationary() -> bool:
	return left_stick_hold_time > 0.01


func has_left_stick_been_stationary(value: float) -> bool:
	return left_stick_hold_time > value


func in_left_stick_in_dead_zone() -> bool:
	return (left_stick_x * left_stick_x + left_stick_y * left_stick_y) < 0.1


func is_right_stick_in_dead_zone() -> bool:
	return (right_stick_x * right_stick_x + right_stick_y * right_stick_y) < 0.1
