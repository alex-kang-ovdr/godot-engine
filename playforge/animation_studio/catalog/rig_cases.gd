extends Node3D
## Small, self-contained rig demonstrations for the Animation Studio catalog.
## These are Godot built-in/runtime examples, not imports of Havok SDK assets.

const CASE_RETARGET := "Retargeting"
const CASE_MAPPING := "SkeletalMapping"
const CASE_IK := "InverseKinematics"
const CASE_RAGDOLL := "Ragdoll"

class PoseProbe extends SkeletonModifier3D:
	var watched_bone: StringName
	var sampled_origin := Vector3.ZERO
	var samples := 0

	func _process_modification_with_delta(_delta: float) -> void:
		var skeleton := get_skeleton()
		if skeleton == null:
			return
		var bone := skeleton.find_bone(watched_bone)
		if bone >= 0:
			sampled_origin = skeleton.get_bone_global_pose(bone).origin
			samples += 1

var _case_name := ""
var _status := "Choose a rig case."
var _time := 0.0
var _driver: Skeleton3D
var _mapped_target: Skeleton3D
var _retarget_target: Skeleton3D
var _ik_target: Node3D
var _ik_pole: Node3D
var _physics_simulator: PhysicalBoneSimulator3D
var _ik_modifier: TwoBoneIK3D
var _look_at_modifier: LookAtModifier3D
var _ik_skeleton: Skeleton3D
var _controller_clock := 0.0
var _controller_simulating := true
var _pose_probe: PoseProbe


func start_case(path: String, name: String) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_case_name = name
	set_meta("case_path", path)
	_time = 0.0
	_driver = null
	_mapped_target = null
	_retarget_target = null
	_ik_target = null
	_ik_pole = null
	_physics_simulator = null
	_ik_modifier = null
	_look_at_modifier = null
	_ik_skeleton = null
	_pose_probe = null
	_controller_clock = 0.0
	_controller_simulating = true
	var key := name.to_lower().replace(" ", "")
	var route := path.to_lower().replace("\\", "/")
	if "/ragdoll/" in route or "ragdoll" in key:
		_build_ragdoll()
	elif "/inversekinematics/lookat/" in route or "lookat" in key:
		_build_look_at()
	elif "/inversekinematics/footik/" in route or "footik" in key:
		_build_foot_ik()
	elif "/inversekinematics/" in route or "inverse" in key or key == "ik" or "reaching" in key:
		_build_ik()
	elif "/skeletalmapping/" in route or "skeletal" in key or "mapping" in key:
		_build_mapping()
	elif "/retargeting/" in route or "retarget" in key:
		_build_retarget()
	else:
		_status = "Unsupported rig case '%s' (%s)." % [name, path]
		push_error(_status)


func status_text() -> String:
	return _status


func _process(delta: float) -> void:
	_time += delta
	if is_instance_valid(_driver):
		var angle := sin(_time * 1.7) * 0.62
		var upper := _driver.find_bone("LeftUpperArm")
		if upper < 0:
			upper = _driver.find_bone("DriverUpper")
		if upper >= 0:
			_driver.set_bone_pose_rotation(upper, Quaternion(Vector3.FORWARD, angle))
			_driver.force_update_all_bone_transforms()
	if is_instance_valid(_mapped_target):
		# Reduced example: explicit name-pair mapping performed in script.
		# This intentionally does not claim to cover a production retarget profile.
		for pair in [["DriverUpper", "MappedUpper"], ["DriverForearm", "MappedForearm"], ["DriverHand", "MappedHand"]]:
			var from := _driver.find_bone(pair[0])
			var to := _mapped_target.find_bone(pair[1])
			if from >= 0 and to >= 0:
				_mapped_target.set_bone_pose_rotation(to, _driver.get_bone_pose_rotation(from))
		_mapped_target.force_update_all_bone_transforms()
	if is_instance_valid(_ik_target):
		if _ik_modifier != null and _ik_modifier.name == "FootTwoBoneIK3D":
			_ik_target.position = Vector3(0.32 + sin(_time * 1.2) * 0.28, 0.12 + absf(cos(_time * 1.6)) * 0.28, 0.30)
		else:
			_ik_target.position = Vector3(-0.62 + sin(_time * 1.2) * 0.18, 1.40 + cos(_time * 0.8) * 0.10, 0.18)
	if is_instance_valid(_driver) and _driver.modifier_callback_mode_process == Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL:
		_driver.advance(0.0)
	if is_instance_valid(_mapped_target) and _mapped_target.modifier_callback_mode_process == Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL:
		_mapped_target.advance(0.0)
	if is_instance_valid(_ik_skeleton) and _ik_skeleton.modifier_callback_mode_process == Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL:
		_ik_skeleton.advance(0.0)
	if _ik_modifier != null:
		_status = "TwoBoneIK3D live reach · end-to-goal %.2f m" % _ik_error()
	elif _look_at_modifier != null:
		_status = "LookAtModifier3D live head aim · target %s" % str(_look_at_modifier.is_target_within_limitation())
	elif _physics_simulator != null:
		var bodies := 0
		var active_bodies := 0
		for child in _physics_simulator.get_children():
			if child is PhysicalBone3D:
				bodies += 1
				if child.is_simulating_physics():
					active_bodies += 1
		if _has_case_token("controller"):
			_controller_clock += delta
			if _controller_clock >= 1.25:
				_controller_clock = 0.0
				_controller_simulating = not _controller_simulating
				if _controller_simulating:
					_physics_simulator.physical_bones_start_simulation()
				else:
					_physics_simulator.physical_bones_stop_simulation()
			_status = "Reduced active/free physics handoff · bodies %d/%d · %s" % [active_bodies, bodies, "simulating" if _controller_simulating else "pose-held"]
		elif _has_case_token("constraints"):
			_status = "Reduced constraint probe · %s joints · %d/%d bodies active" % ["cone" if _has_case_token("soft") else "pin", active_bodies, bodies]
		elif _has_case_token("penetration"):
			_status = "Contact probe · enlarged collision capsules against the gallery floor · %d/%d bodies" % [active_bodies, bodies]
		elif _has_case_token("scaling"):
			_status = "Scaled physical chain · factor %.2f · %d/%d bodies" % [get_node("Physics chain").scale.x, active_bodies, bodies]
		elif _has_case_token("powered"):
			_status = "Reduced powered-follow proxy · gravity suppressed and damping raised · %d/%d bodies" % [active_bodies, bodies]
		else:
			_status = "Reduced PhysicalBoneSimulator3D chain · active bodies %d/%d" % [active_bodies, bodies]
	elif _case_name.to_lower().contains("skeletal") or _case_name.to_lower().contains("mapping") or "/skeletalmapping/" in _case_path():
		var mapped_angle := 0.0
		if is_instance_valid(_mapped_target):
			var mapped_upper := _mapped_target.find_bone("MappedUpper")
			if mapped_upper >= 0:
				mapped_angle = rad_to_deg(_mapped_target.get_bone_pose_rotation(mapped_upper).get_angle())
		_status = "Reduced explicit local bone map · target angle %.0f° · no full Havok mapping coverage" % mapped_angle
	else:
		var mapped_angle := 0.0
		if is_instance_valid(_retarget_target):
			mapped_angle = rad_to_deg(_retarget_target.get_bone_pose_rotation(_retarget_target.find_bone("LeftUpperArm")).get_angle())
		_status = "RetargetModifier3D humanoid map · target arm angle %.0f°" % mapped_angle


func _build_retarget() -> void:
	var source_root := _rig_root("Source rig", Vector3(-0.9, 0, 0), Color("#42c6b5"))
	_driver = _make_arm_rig(source_root, "SourceSkeleton", "humanoid", 0.62)
	var target_root := _rig_root("Retargeted rig", Vector3(0.9, 0, 0), Color("#f2a64a"))
	var target := _make_arm_rig(target_root, "TargetSkeleton", "humanoid", 0.48)
	_retarget_target = target
	target_root.remove_child(target)
	target_root.queue_free()
	var retarget := RetargetModifier3D.new()
	retarget.name = "RetargetModifier3D"
	retarget.profile = SkeletonProfileHumanoid.new()
	retarget.use_global_pose = false
	_driver.add_child(retarget)
	target.position = Vector3(1.8, 0, 0)
	retarget.add_child(target)
	_status = "Built-in RetargetModifier3D transfers humanoid profile bones between rigs."


func _build_mapping() -> void:
	var source_root := _rig_root("Source", Vector3(-0.85, 0, 0), Color("#42c6b5"))
	_driver = _make_arm_rig(source_root, "SourceSkeleton", "driver", 0.58)
	var target_root := _rig_root("Mapped target", Vector3(0.85, 0, 0), Color("#b59aff"))
	_mapped_target = _make_arm_rig(target_root, "MappedSkeleton", "mapped", 0.48)
	_status = "Reduced example: explicit local bone-pair mapping in GDScript; not a full retarget profile."


func _build_ik() -> void:
	var arm_root := _rig_root("IK arm", Vector3.ZERO, Color("#52c7b8"))
	var skeleton := _make_arm_rig(arm_root, "Skeleton", "ik", 0.72)
	_ik_skeleton = skeleton
	_ik_target = _marker("Reach target", Color("#ffbd52"), 0.10)
	_ik_target.position = Vector3(0.35, 1.55, 0.42)
	add_child(_ik_target)
	_ik_pole = _marker("Pole", Color("#73a9ff"), 0.075)
	_ik_pole.position = Vector3(-0.8, 1.1, 0.4)
	add_child(_ik_pole)
	_ik_modifier = _add_two_bone_ik(skeleton, "TwoBoneIK3D", "LeftUpperArm", "LeftLowerArm", "LeftHand", _ik_target, _ik_pole)
	_attach_pose_probe(skeleton, "LeftHand")
	_status = "TwoBoneIK3D solves a live arm chain toward a moving target and pole."


func _build_foot_ik() -> void:
	var arm_root := _rig_root("Foot IK leg", Vector3.ZERO, Color("#70b7e8"))
	var skeleton := Skeleton3D.new()
	skeleton.name = "LegSkeleton"
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	arm_root.add_child(skeleton)
	_ik_skeleton = skeleton
	_add_bone(skeleton, "Hips", -1, Vector3(0, 1.4, 0))
	_add_bone(skeleton, "LeftUpperLeg", 0, Vector3(0, -0.15, 0))
	_add_bone(skeleton, "LeftLowerLeg", 1, Vector3(0, -0.55, 0))
	_add_bone(skeleton, "LeftFoot", 2, Vector3(0, -0.52, 0))
	skeleton.reset_bone_poses()
	_add_segment_visual(skeleton, "Hips", Vector3(0.36, 0.24, 0.24), Color("#354856"), Vector3.ZERO)
	_add_segment_visual(skeleton, "LeftUpperLeg", Vector3(0.16, 0.5, 0.14), Color("#70b7e8"), Vector3(0, -0.25, 0))
	_add_segment_visual(skeleton, "LeftLowerLeg", Vector3(0.13, 0.48, 0.12), Color("#5696c2"), Vector3(0, -0.23, 0))
	_add_segment_visual(skeleton, "LeftFoot", Vector3(0.32, 0.12, 0.18), Color("#e4d3ba"), Vector3(0.12, -0.01, 0))
	_ik_target = _marker("Foot plant target", Color("#ffbd52"), 0.09)
	_ik_target.position = Vector3(0.32, 0.18, 0.30)
	add_child(_ik_target)
	_ik_pole = _marker("Knee pole", Color("#73a9ff"), 0.07)
	_ik_pole.position = Vector3(-0.5, 0.75, 0.35)
	add_child(_ik_pole)
	_ik_modifier = _add_two_bone_ik(skeleton, "FootTwoBoneIK3D", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", _ik_target, _ik_pole)
	_attach_pose_probe(skeleton, "LeftFoot")
	_status = "FootIk approximation: TwoBoneIK3D plants one leg toward a moving ground target."


func _build_look_at() -> void:
	var root := _rig_root("Look-at rig", Vector3.ZERO, Color("#78c5b8"))
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	root.add_child(skeleton)
	_ik_skeleton = skeleton
	_add_bone(skeleton, "Root", -1, Vector3(0, 0.8, 0))
	_add_bone(skeleton, "Neck", 0, Vector3(0, 0.42, 0))
	_add_bone(skeleton, "Head", 1, Vector3(0, 0.2, 0))
	skeleton.reset_bone_poses()
	_add_segment_visual(skeleton, "Root", Vector3(0.32, 0.7, 0.24), Color("#344c59"), Vector3(0, -0.18, 0))
	_add_segment_visual(skeleton, "Neck", Vector3(0.12, 0.2, 0.12), Color("#d6b99a"), Vector3(0, 0.03, 0))
	_add_segment_visual(skeleton, "Head", Vector3(0.27, 0.27, 0.24), Color("#78c5b8"), Vector3(0, 0.02, 0))
	_ik_target = _marker("Look target", Color("#ffbd52"), 0.10)
	_ik_target.position = Vector3(0.8, 1.7, 0.5)
	add_child(_ik_target)
	_look_at_modifier = LookAtModifier3D.new()
	_look_at_modifier.name = "LookAtModifier3D"
	_look_at_modifier.bone_name = "Head"
	_look_at_modifier.forward_axis = SkeletonModifier3D.BONE_AXIS_MINUS_Z
	skeleton.add_child(_look_at_modifier)
	_look_at_modifier.target_node = _look_at_modifier.get_path_to(_ik_target)
	_attach_pose_probe(skeleton, "Head")
	_status = "LookAtModifier3D rotates the head toward a moving target."


func _add_two_bone_ik(skeleton: Skeleton3D, node_name: String, root_bone: String, middle_bone: String, end_bone: String, target: Node3D, pole: Node3D) -> TwoBoneIK3D:
	var ik := TwoBoneIK3D.new()
	ik.name = node_name
	ik.setting_count = 1
	skeleton.add_child(ik)
	ik.set_root_bone_name(0, root_bone)
	ik.set_middle_bone_name(0, middle_bone)
	ik.set_end_bone_name(0, end_bone)
	ik.set_target_node(0, ik.get_path_to(target))
	ik.set_pole_node(0, ik.get_path_to(pole))
	ik.active = true
	return ik


func _attach_pose_probe(skeleton: Skeleton3D, bone_name: StringName) -> void:
	_pose_probe = PoseProbe.new()
	_pose_probe.name = "SameFramePoseProbe"
	_pose_probe.watched_bone = bone_name
	skeleton.add_child(_pose_probe)


func _ik_error() -> float:
	if _ik_target == null or _ik_modifier == null:
		return 0.0
	var skeleton := _ik_modifier.get_parent() as Skeleton3D
	var end := _ik_modifier.get_end_bone(0)
	if skeleton == null or end < 0:
		return 0.0
	var end_pose_origin := skeleton.get_bone_global_pose(end).origin
	if _pose_probe != null and _pose_probe.samples > 0:
		end_pose_origin = _pose_probe.sampled_origin
	return (skeleton.global_transform * end_pose_origin).distance_to(_ik_target.global_position)


func _case_path() -> String:
	return str(get_meta("case_path", "")).to_lower()


func _has_case_token(token: String) -> bool:
	return token in _case_path() or token in _case_name.to_lower()


func _build_ragdoll() -> void:
	var ragdoll_root := _rig_root("Physics chain", Vector3.ZERO, Color("#e3a352"))
	if _has_case_token("scaling"):
		ragdoll_root.scale = Vector3.ONE * (0.72 if "small" in _case_name.to_lower() else 1.18)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	ragdoll_root.add_child(skeleton)
	_add_bone(skeleton, "Root", -1, Vector3(0, 1.55, 0))
	_add_bone(skeleton, "Chest", 0, Vector3(0, 0.32, 0))
	_add_bone(skeleton, "Head", 1, Vector3(0, 0.34, 0))
	skeleton.reset_bone_poses()
	_add_segment_visual(skeleton, "Root", Vector3(0.24, 0.52, 0.18), Color("#e3a352"), Vector3(0, -0.12, 0))
	_add_segment_visual(skeleton, "Chest", Vector3(0.38, 0.48, 0.24), Color("#f1c16c"), Vector3(0, 0.08, 0))
	_add_segment_visual(skeleton, "Head", Vector3(0.25, 0.25, 0.23), Color("#75c9bd"), Vector3(0, 0.02, 0))
	_physics_simulator = PhysicalBoneSimulator3D.new()
	_physics_simulator.name = "PhysicalBoneSimulator3D"
	skeleton.add_child(_physics_simulator)
	_add_physical_bone("Chest", Vector3(0.34, 0.44, 0.22))
	_add_physical_bone("Head", Vector3(0.22, 0.22, 0.20))
	_physics_simulator.active = true
	_physics_simulator.physical_bones_start_simulation()
	_status = "PhysicalBoneSimulator3D drives a short articulated physics chain; reduced ragdoll demo."


func _add_physical_bone(bone: String, box_size: Vector3) -> void:
	var physical := PhysicalBone3D.new()
	physical.name = "PhysicalBone_%s" % bone
	physical.bone_name = bone
	physical.joint_type = PhysicalBone3D.JOINT_TYPE_CONE if _has_case_token("soft") else PhysicalBone3D.JOINT_TYPE_PIN
	physical.mass = 1.2
	physical.can_sleep = false
	physical.gravity_scale = 0.0 if _has_case_token("powered") else 1.0
	physical.linear_damp = 2.5 if _has_case_token("powered") else 0.15
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = minf(box_size.x, box_size.z) * (0.88 if _has_case_token("penetration") else 0.5)
	capsule.height = box_size.y
	shape.shape = capsule
	physical.add_child(shape)
	_physics_simulator.add_child(physical)


func _make_arm_rig(parent: Node3D, rig_name: String, naming: String, length: float) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = rig_name
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	parent.add_child(skeleton)
	if naming == "humanoid" or naming == "ik":
		_add_bone(skeleton, "Hips", -1, Vector3(0, 1.0, 0))
		_add_bone(skeleton, "LeftUpperArm", 0, Vector3(-0.18, 0.35, 0))
		_add_bone(skeleton, "LeftLowerArm", 1, Vector3(-length * 0.56, 0, 0))
		_add_bone(skeleton, "LeftHand", 2, Vector3(-length * 0.44, 0, 0))
		_add_segment_visual(skeleton, "Hips", Vector3(0.32, 0.46, 0.24), Color("#354856"), Vector3(0, -0.03, 0))
		_add_segment_visual(skeleton, "LeftUpperArm", Vector3(length * 0.54, 0.11, 0.11), parent.get_meta("rig_color"), Vector3(-length * 0.27, 0, 0))
		_add_segment_visual(skeleton, "LeftLowerArm", Vector3(length * 0.43, 0.085, 0.085), parent.get_meta("rig_color").lightened(0.12), Vector3(-length * 0.22, 0, 0))
		_add_segment_visual(skeleton, "LeftHand", Vector3(0.15, 0.12, 0.13), Color("#e4d3ba"), Vector3(-0.045, 0, 0))
	else:
		_add_bone(skeleton, "DriverRoot" if naming == "driver" else "MappedRoot", -1, Vector3(0, 1.0, 0))
		var suffix := "Driver" if naming == "driver" else "Mapped"
		_add_bone(skeleton, suffix + "Upper", 0, Vector3(-0.18, 0.35, 0))
		_add_bone(skeleton, suffix + "Forearm", 1, Vector3(-length * 0.56, 0, 0))
		_add_bone(skeleton, suffix + "Hand", 2, Vector3(-length * 0.44, 0, 0))
		_add_segment_visual(skeleton, suffix + "Upper", Vector3(length * 0.54, 0.11, 0.11), parent.get_meta("rig_color"), Vector3(-length * 0.27, 0, 0))
		_add_segment_visual(skeleton, suffix + "Forearm", Vector3(length * 0.43, 0.085, 0.085), parent.get_meta("rig_color").lightened(0.12), Vector3(-length * 0.22, 0, 0))
		_add_segment_visual(skeleton, suffix + "Hand", Vector3(0.15, 0.12, 0.13), Color("#e4d3ba"), Vector3(-0.045, 0, 0))
	skeleton.reset_bone_poses()
	if naming == "driver":
		_driver = skeleton
	return skeleton


func _add_bone(skeleton: Skeleton3D, bone_name: String, parent: int, rest_origin: Vector3) -> int:
	var index := skeleton.get_bone_count()
	skeleton.add_bone(bone_name)
	skeleton.set_bone_parent(index, parent)
	skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, rest_origin))
	return index


func _add_segment_visual(skeleton: Skeleton3D, bone: String, size: Vector3, color: Color, local_position: Vector3) -> void:
	var attach := BoneAttachment3D.new()
	attach.name = "Attach_%s" % bone
	attach.bone_name = bone
	skeleton.add_child(attach)
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = minf(size.y, size.z) * 0.5
	capsule.height = maxf(size.x, size.y)
	mesh.mesh = capsule
	mesh.material_override = _material(color)
	mesh.position = local_position
	mesh.rotation.z = PI * 0.5 if size.x > size.y else 0.0
	attach.add_child(mesh)


func _rig_root(node_name: String, position: Vector3, color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.position = position
	root.set_meta("rig_color", color)
	add_child(root)
	return root


func _marker(node_name: String, color: Color, radius: float) -> Node3D:
	var marker := MeshInstance3D.new()
	marker.name = node_name
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	marker.mesh = sphere
	marker.material_override = _material(color, true)
	return marker


func _material(color: Color, emissive: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.42
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.4
	return material
