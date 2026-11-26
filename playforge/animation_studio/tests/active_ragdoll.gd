extends SceneTree
## Stage 3 single-joint active ragdoll verification using public APIs:
## 1) PhysicalBone3D public API inspection
## 2) Target angle tracking via PD torque control on Generic6DOFJoint3D
## 3) Strict torque clamping verification
## 4) Teleport reset without velocity explosion or positional drift

const ActiveRagdollJoint = preload("res://addons/animation_studio/active_ragdoll_joint.gd")

var failures := 0


func _initialize() -> void:
	run.call_deferred()


func report(label: String, valid: bool, details: Dictionary = {}) -> void:
	if not valid:
		failures += 1
	print("PFTEST ", JSON.stringify({"test": label, "status": "PASS" if valid else "FAIL", "detail": JSON.stringify(details)}))


func info(label: String, details: Dictionary) -> void:
	print("PFTEST ", JSON.stringify({"status": "INFO", "test": label, "data": details}))


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))

	# 1. Inspect PhysicalBone3D public API capability.
	var pb_api := ActiveRagdollJoint.probe_physical_bone_public_api()
	info("physical_bone_api", pb_api)
	report("PhysicalBone3D public API limits documented",
		pb_api.has_joint_type and not pb_api.exposes_internal_joint_getter,
		pb_api)

	var rig := ActiveRagdollJoint.new()
	root.add_child(rig)
	rig.build_rig()
	await physics_frame
	await physics_frame

	# 2. Target tracking: 0 deg -> +45 deg (0.785 rad) with generous max_torque.
	rig.target_angle_rad = deg_to_rad(45.0)
	rig.max_torque = 20.0
	for _i in 90:
		rig.step_control()
		await physics_frame
	var tracked_angle := rig.get_joint_angle_z()
	var track_err := absf(tracked_angle - rig.target_angle_rad)
	report("single joint tracks +45 deg target via public API",
		track_err < 0.05,
		{"target_deg": 45.0, "actual_deg": rad_to_deg(tracked_angle), "err_rad": track_err})

	# 3. Torque limit: reset to 0, compare initial angular velocity under low vs high torque cap.
	rig.teleport_reset(Transform3D.IDENTITY, 0.0)
	await physics_frame
	rig.target_angle_rad = deg_to_rad(90.0)
	rig.max_torque = 0.4
	var low_peak_torque := 0.0
	for _i in 10:
		low_peak_torque = maxf(low_peak_torque, absf(rig.step_control()))
		await physics_frame
	var low_omega := absf(rig.limb.angular_velocity.z)

	rig.teleport_reset(Transform3D.IDENTITY, 0.0)
	await physics_frame
	rig.target_angle_rad = deg_to_rad(90.0)
	rig.max_torque = 20.0
	var high_peak_torque := 0.0
	for _i in 10:
		high_peak_torque = maxf(high_peak_torque, absf(rig.step_control()))
		await physics_frame
	var high_omega := absf(rig.limb.angular_velocity.z)

	report("torque limit strictly caps applied torque and angular acceleration",
		low_peak_torque <= 0.4001 and high_peak_torque > low_peak_torque * 5.0 and low_omega < high_omega * 0.35,
		{"low_torque": low_peak_torque, "high_torque": high_peak_torque, "low_omega": low_omega, "high_omega": high_omega})

	# 4. Teleport reset while spinning at high speed.
	var dest := Transform3D(Basis.IDENTITY, Vector3(50.0, 10.0, -30.0))
	rig.teleport_reset(dest, 0.0)
	await physics_frame
	var post_tp_pos_err := rig.limb.global_position.distance_to(dest.origin + Vector3(0.0, -0.5, 0.0))
	var post_tp_lin_vel := rig.limb.linear_velocity.length()
	var post_tp_ang_vel := rig.limb.angular_velocity.length()
	for _i in 20:
		rig.step_control()
		await physics_frame
	var settled_pos_err := rig.limb.global_position.distance_to(dest.origin + Vector3(0.0, -0.5, 0.0))
	var settled_angle_err := absf(rig.get_joint_angle_z())
	report("teleport reset clears momentum and stays stable without explosion",
		post_tp_pos_err < 0.02 and post_tp_lin_vel < 0.05 and post_tp_ang_vel < 0.05
			and settled_pos_err < 0.02 and settled_angle_err < 0.02,
		{
			"post_tp_pos_err": post_tp_pos_err, "post_tp_lin_vel": post_tp_lin_vel,
			"post_tp_ang_vel": post_tp_ang_vel, "settled_pos_err": settled_pos_err,
			"settled_angle_err": settled_angle_err,
		})

	rig.queue_free()
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)
