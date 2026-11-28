@tool
class_name HkbAxisStandard
extends RefCounted
## Godot Standard Coordinate System Authority for Animation Studio HKB Runtime.
##
## Godot Standard Basis (Right-Handed):
##   - Up      : +Y  Vector3(0, 1, 0)
##   - Forward : -Z  Vector3(0, 0, -1)
##   - Right   : +X  Vector3(1, 0, 0)
##   - Yaw     : Right-hand CCW rotation around +Y (yaw = 0 -> facing -Z)
##   - Sagittal Mirror Plane : X = 0 (Left <-> Right reflection)
##
## Provides deterministic basis conversion from Havok Z-up (3ds Max: +X right, +Y fwd, +Z up)
## and Havok Maya Y-up (+X left, +Y up, +Z fwd) into Godot standard axes.

const UP := Vector3.UP
const FORWARD := Vector3.FORWARD
const RIGHT := Vector3.RIGHT
const AXIS_STANDARD_ID := "godot_y_up_neg_z_forward"


static func havok_zup_vec_to_godot(v: Vector3) -> Vector3:
	## Right-handed -90 deg rotation about +X: (x, y, z)_Zup -> (x, z, -y)_GodotYup.
	return Vector3(v.x, v.z, -v.y)


static func havok_zup_quat_to_godot(q: Quaternion) -> Quaternion:
	## Basis conjugation of a Havok Z-up quaternion into Godot Y-up.
	var out := Quaternion(q.x, q.z, -q.y, q.w)
	return out.normalized() if out.length_squared() > 1e-8 else Quaternion.IDENTITY


static func havok_zup_scale_to_godot(s: Vector3) -> Vector3:
	return Vector3(s.x, s.z, s.y)


static func havok_maya_yup_vec_to_godot(v: Vector3) -> Vector3:
	## 180 deg rotation about +Y mapping Maya +Z-forward -> Godot -Z-forward.
	return Vector3(-v.x, v.y, -v.z)


static func havok_maya_yup_quat_to_godot(q: Quaternion) -> Quaternion:
	var out := Quaternion(-q.x, q.y, -q.z, q.w)
	return out.normalized() if out.length_squared() > 1e-8 else Quaternion.IDENTITY


static func normalize_rotation_axis_to_godot(raw_axis: Vector3, source_is_zup: bool = true) -> Vector3:
	## Converts an extracted Havok rotation axis (e.g. Z-up (0,0,1)) to Godot standard axis (+Y).
	if raw_axis.length_squared() < 1e-6:
		return UP
	var v := havok_zup_vec_to_godot(raw_axis) if source_is_zup else raw_axis
	if v.length_squared() < 1e-6:
		return UP
	return v.normalized()


static func normalize_offset_to_godot(raw_offset: Vector3, source_is_zup: bool = true) -> Vector3:
	## Converts an extracted Havok model-space offset/velocity into Godot standard (+X right, +Y up, -Z fwd).
	return havok_zup_vec_to_godot(raw_offset) if source_is_zup else raw_offset


static func forward_from_yaw(yaw_rad: float) -> Vector3:
	## Godot standard forward vector (-Z at yaw=0, CCW positive rotation around +Y).
	return Vector3(-sin(yaw_rad), 0.0, -cos(yaw_rad))


static func yaw_from_forward(dir_ws: Vector3) -> float:
	## Godot standard yaw angle around +Y where dir = (0, 0, -1) -> 0.0 rad,
	## dir = (-1, 0, 0) -> +PI/2 rad (CCW left), dir = (+1, 0, 0) -> -PI/2 rad (CW right).
	return atan2(-dir_ws.x, -dir_ws.z)


static func look_at_yaw_pitch(local_dir: Vector3) -> Vector2:
	## Returns Vector2(yaw_rad, pitch_rad) in Godot standard local space (-Z forward, +Y up, +X right)
	## such that Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch) * Vector3.FORWARD == local_dir.normalized().
	if local_dir.length_squared() < 1e-6:
		return Vector2.ZERO
	var d := local_dir.normalized()
	var yaw := atan2(-d.x, -d.z)
	var pitch := asin(clampf(d.y, -0.95, 0.95))
	return Vector2(yaw, pitch)


static func is_rig_zup_source(rig_id: String) -> bool:
	## Soldier rig in Havok SDK is Maya Y-up; Hero/Firefighter/Ninja/Orc/Boar/SiegeFiend are Z-up.
	var low := rig_id.to_lower()
	return not ("soldier" in low or "us_leader" in low)
