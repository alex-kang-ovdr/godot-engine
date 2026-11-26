extends Node3D
## Stage 3 single-joint active ragdoll probe using public Godot Physics APIs.
## Drives a RigidBody3D limb attached to a StaticBody3D anchor via Generic6DOFJoint3D
## with PD torque control, strict torque clamping, and clean teleport reset.

var anchor: StaticBody3D
var limb: RigidBody3D
var joint: Generic6DOFJoint3D

var target_angle_rad: float = 0.0
var kp: float = 18.0
var kd: float = 3.2
var max_torque: float = 20.0
var last_applied_torque: float = 0.0


func build_rig() -> void:
	anchor = StaticBody3D.new()
	anchor.name = "Anchor"
	add_child(anchor)

	limb = RigidBody3D.new()
	limb.name = "Limb"
	limb.mass = 1.0
	limb.gravity_scale = 0.0
	limb.linear_damp = 0.0
	limb.angular_damp = 0.0
	limb.position = Vector3(0.0, -0.5, 0.0)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.15, 1.0, 0.15)
	col.shape = shape
	limb.add_child(col)
	add_child(limb)

	joint = Generic6DOFJoint3D.new()
	joint.name = "Joint"
	joint.position = Vector3.ZERO
	add_child(joint)
	joint.node_a = joint.get_path_to(anchor)
	joint.node_b = joint.get_path_to(limb)
	joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
	joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)

	# Lock X/Y rotations; allow Z hinge rotation within [-120, +120] degrees.
	joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, 0.0)
	joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, 0.0)
	joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, 0.0)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, 0.0)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -deg_to_rad(120.0))
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, deg_to_rad(120.0))


func get_joint_angle_z() -> float:
	var local_q := (global_basis.get_rotation_quaternion().inverse() * limb.global_basis.get_rotation_quaternion()).normalized()
	return local_q.get_euler().z


func step_control() -> float:
	var angle := get_joint_angle_z()
	var local_omega := global_basis.inverse() * limb.angular_velocity
	var err := wrapf(target_angle_rad - angle, -PI, PI)
	var raw_torque := kp * err - kd * local_omega.z
	last_applied_torque = clampf(raw_torque, -max_torque, max_torque)
	var world_torque := global_basis * Vector3(0.0, 0.0, last_applied_torque)
	limb.apply_torque(world_torque)
	return last_applied_torque


func teleport_reset(new_root_transform: Transform3D, reset_angle_z: float = 0.0) -> void:
	global_transform = new_root_transform
	var rot_z := Basis(Vector3.BACK, reset_angle_z)
	var limb_local := Transform3D(rot_z, rot_z * Vector3(0.0, -0.5, 0.0))
	var limb_world := new_root_transform * limb_local
	PhysicsServer3D.body_set_state(limb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, limb_world)
	PhysicsServer3D.body_set_state(limb.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(limb.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	limb.global_transform = limb_world
	limb.linear_velocity = Vector3.ZERO
	limb.angular_velocity = Vector3.ZERO
	target_angle_rad = reset_angle_z
	last_applied_torque = 0.0


static func probe_physical_bone_public_api() -> Dictionary:
	var pb := PhysicalBone3D.new()
	var props := {}
	for p in pb.get_property_list():
		var name_str: String = p.name
		if "joint" in name_str or "motor" in name_str or "spring" in name_str or "6dof" in name_str:
			props[name_str] = true
	var methods := {}
	for m in pb.get_method_list():
		var name_str: String = m.name
		if "joint" in name_str or "motor" in name_str or "target" in name_str:
			methods[name_str] = true
	pb.free()
	return {
		"has_joint_type": props.has("joint_type"),
		"exposes_motor_api": methods.has("set_joint_motor") or props.has("joint_motor_enabled"),
		"exposes_internal_joint_getter": methods.has("get_joint") or methods.has("get_joint_rid"),
	}
