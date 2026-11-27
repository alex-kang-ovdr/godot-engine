extends Node3D
## Rig demonstrations for the Animation Studio catalog using internalized
## original Havok 2015.1.0-r1 SDK assets (HavokGirl 50b, Crabby 18b, Zombie 89b,
## Firefighter 38b, Shulgoth/Male/Singer/Gingerbread/BigBad/Boy/FemaleDress)
## aligned to Godot Standard coordinates (-Z forward, +Y up, SI meters).

const Standards := preload("res://catalog/havok_demo_standards.gd")

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
var _spec: Dictionary = {}
var _status := "Choose a rig case."
var _time := 0.0
var _src_pack: Dictionary = {}
var _dst_pack: Dictionary = {}
var _retarget_pairs: Array[Array] = []
var _proxy_driver: Skeleton3D
var _proxy_target: Skeleton3D
var _ik_target: Node3D
var _ik_pole: Node3D
var _ik_target_b: Node3D
var _ik_pole_b: Node3D
var _physics_simulator: PhysicalBoneSimulator3D
var _ik_modifier: TwoBoneIK3D
var _look_at_modifier: LookAtModifier3D
var _ik_skeleton: Skeleton3D
var _ragdoll_root: Node3D
var _controller_clock := 0.0
var _controller_simulating := true
var _pose_probe: PoseProbe


func start_case(path: String, case_name: String) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_case_name = case_name
	set_meta("case_path", path)
	_spec = Standards.resolve_demo_spec(path, case_name)
	_time = 0.0
	_src_pack = {}
	_dst_pack = {}
	_retarget_pairs.clear()
	_proxy_driver = null
	_proxy_target = null
	_ik_target = null
	_ik_pole = null
	_ik_target_b = null
	_ik_pole_b = null
	_physics_simulator = null
	_ik_modifier = null
	_look_at_modifier = null
	_ik_skeleton = null
	_ragdoll_root = null
	_pose_probe = null
	_controller_clock = 0.0
	_controller_simulating = true

	var key := case_name.to_lower().replace(" ", "")
	var route := path.to_lower().replace("\\", "/")
	if "/ragdoll/" in route or "ragdoll" in key:
		_build_ragdoll()
	elif "/inversekinematics/lookat/" in route or "lookat" in key:
		_build_look_at()
	elif "/inversekinematics/footik/" in route or "footik" in key:
		_build_foot_ik()
	elif "/inversekinematics/" in route or "inverse" in key or key == "ik" or "reaching" in key or "crabby" in route:
		_build_ik(route)
	elif "/skeletalmapping/" in route or "skeletal" in key or "mapping" in key:
		_build_mapping()
	elif "/retargeting/" in route or "retarget" in key:
		_build_retarget()
	else:
		_status = "Unsupported rig case '%s' (%s)." % [case_name, path]
		push_error(_status)


func status_text() -> String:
	return _status


func _process(delta: float) -> void:
	_time += delta
	if not _src_pack.is_empty() and not _dst_pack.is_empty() and not _retarget_pairs.is_empty():
		var s_skel: Skeleton3D = _src_pack["skeleton"] as Skeleton3D
		var d_skel: Skeleton3D = _dst_pack["skeleton"] as Skeleton3D
		if is_instance_valid(s_skel) and is_instance_valid(d_skel):
			var blend_w := 0.5 + 0.5 * sin(_time * 1.6) if ("blend" in _case_path()) else 1.0
			Standards.apply_semantic_retarget(s_skel, d_skel, _retarget_pairs, blend_w, float(_src_pack.get("align_yaw", PI)), float(_dst_pack.get("align_yaw", PI)))
			d_skel.force_update_all_bone_transforms()

	if is_instance_valid(_proxy_driver):
		var upper := _proxy_driver.find_bone("LeftUpperArm")
		if upper >= 0:
			_proxy_driver.set_bone_pose_rotation(upper, Quaternion(Vector3.FORWARD, sin(_time * 1.7) * 0.62))
			_proxy_driver.force_update_all_bone_transforms()
			_proxy_driver.advance(0.0)

	if is_instance_valid(_ik_target):
		if str(_spec.get("primary_char", "")) == "crabby":
			_ik_target.position = Vector3(1.15 + sin(_time * 1.5) * 0.25, 0.25 + absf(cos(_time * 1.8)) * 0.35, -0.95)
			if is_instance_valid(_ik_target_b):
				_ik_target_b.position = Vector3(-1.15 + cos(_time * 1.5) * 0.25, 0.25 + absf(sin(_time * 1.8)) * 0.35, -0.95)
		elif _ik_modifier != null and _ik_modifier.name == "FootTwoBoneIK3D":
			_ik_target.position = Vector3(-0.18, 0.16 + absf(cos(_time * 1.6)) * 0.20, -0.22 + sin(_time * 1.4) * 0.25)
		elif _look_at_modifier != null:
			_ik_target.position = Vector3(sin(_time * 1.4) * 0.95, 1.42 + cos(_time * 1.1) * 0.22, -1.45)
		else:
			_ik_target.position = Vector3(-0.42 + sin(_time * 1.3) * 0.20, 1.18 + cos(_time * 0.9) * 0.16, -0.58)

	if _ik_modifier != null:
		_status = "TwoBoneIK3D [%s %db] · end-to-goal %.2f m" % [
			str(_spec.get("primary_char", "")),
			_ik_skeleton.get_bone_count() if is_instance_valid(_ik_skeleton) else 0,
			_ik_error(),
		]
	elif _look_at_modifier != null:
		_status = "LookAtModifier3D [%s %db] · head tracking within limit: %s" % [
			str(_spec.get("primary_char", "")),
			_ik_skeleton.get_bone_count() if is_instance_valid(_ik_skeleton) else 0,
			str(_look_at_modifier.is_target_within_limitation()),
		]
	elif _physics_simulator != null:
		var bodies := 0
		var active_bodies := 0
		for child in _physics_simulator.get_children():
			if child is PhysicalBone3D:
				bodies += 1
				if child.is_simulating_physics():
					active_bodies += 1
		var cid := str(_spec.get("primary_char", ""))
		if _has_case_token("controller"):
			_controller_clock += delta
			if _controller_clock >= 1.25:
				_controller_clock = 0.0
				_controller_simulating = not _controller_simulating
				if _controller_simulating:
					_physics_simulator.physical_bones_start_simulation()
				else:
					_physics_simulator.physical_bones_stop_simulation()
			_status = "Ragdoll controller [%s] · active/pose handoff %d/%d · %s" % [
				cid, active_bodies, bodies, "simulating" if _controller_simulating else "animated"]
		elif _has_case_token("constraints"):
			_status = "Ragdoll constraints [%s] · %s joints · %d/%d bodies (g=9.81 m/s²)" % [
				cid, "cone" if _has_case_token("soft") else "pin", active_bodies, bodies]
		elif _has_case_token("scaling") and is_instance_valid(_ragdoll_root):
			_status = "Scaled ragdoll [%s] · scale %.2fx · %d/%d bodies" % [cid, _ragdoll_root.scale.x, active_bodies, bodies]
		elif _has_case_token("powered"):
			_status = "Powered ragdoll proxy [%s] · gravity suppressed · %d/%d bodies" % [cid, active_bodies, bodies]
		else:
			_status = "PhysicalBoneSimulator3D [%s] · active bodies %d/%d (SI g=9.81 m/s²)" % [cid, active_bodies, bodies]
	elif not _src_pack.is_empty() and not _dst_pack.is_empty():
		var s_cid := str(_src_pack["char_id"])
		var d_cid := str(_dst_pack["char_id"])
		var s_skel: Skeleton3D = _src_pack["skeleton"] as Skeleton3D
		var d_skel: Skeleton3D = _dst_pack["skeleton"] as Skeleton3D
		if "/skeletalmapping/" in _case_path():
			_status = "Skeletal mapping [%s %db -> %s %db] · %d semantic bones mapped on Godot -Z" % [
				s_cid, s_skel.get_bone_count(), d_cid, d_skel.get_bone_count(), _retarget_pairs.size()]
		else:
			var angle_deg := 0.0
			if is_instance_valid(_proxy_target):
				var b := _proxy_target.find_bone("LeftUpperArm")
				if b >= 0:
					angle_deg = rad_to_deg(_proxy_target.get_bone_pose_rotation(b).get_angle())
			_status = "RetargetModifier3D [%s %db -> %s %db] · %d bones · humanoid profile %.0f°" % [
				s_cid, s_skel.get_bone_count(), d_cid, d_skel.get_bone_count(), _retarget_pairs.size(), angle_deg]


func _build_retarget() -> void:
	var src_id := str(_spec.get("primary_char", "shulgoth"))
	var dst_id := str(_spec.get("secondary_char", "male_nocape"))
	if dst_id.is_empty():
		dst_id = "male_nocape"
	_src_pack = Standards.spawn_aligned_character(src_id, "RetargetSource", Animation.LOOP_LINEAR)
	_dst_pack = Standards.spawn_aligned_character(dst_id, "RetargetTarget", Animation.LOOP_LINEAR)
	var src_outer: Node3D = _src_pack["outer"] as Node3D
	var dst_outer: Node3D = _dst_pack["outer"] as Node3D
	src_outer.position = Vector3(-0.95, 0.0, 0.0)
	dst_outer.position = Vector3(0.95, 0.0, 0.0)
	add_child(src_outer)
	add_child(dst_outer)

	var src_player: AnimationPlayer = _src_pack["player"] as AnimationPlayer
	src_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	var clip_a := Standards.pick_clip(_src_pack, str(_spec.get("primary_clip", "walk")))
	src_player.play(StringName(clip_a))

	var dst_player: AnimationPlayer = _dst_pack["player"] as AnimationPlayer
	dst_player.active = false
	var s_skel: Skeleton3D = _src_pack["skeleton"] as Skeleton3D
	var d_skel: Skeleton3D = _dst_pack["skeleton"] as Skeleton3D
	_retarget_pairs = Standards.build_semantic_retarget_pairs(s_skel, d_skel)

	# Native Godot C++ RetargetModifier3D humanoid bridge (non-visual logical driver)
	_proxy_driver = _make_humanoid_bridge_skeleton("HumanoidBridgeSource")
	add_child(_proxy_driver)
	_proxy_target = _make_humanoid_bridge_skeleton("HumanoidBridgeTarget")
	var retarget := RetargetModifier3D.new()
	retarget.name = "RetargetModifier3D"
	retarget.profile = SkeletonProfileHumanoid.new()
	retarget.use_global_pose = false
	_proxy_driver.add_child(retarget)
	retarget.add_child(_proxy_target)
	_status = "RetargetModifier3D [%s -> %s]: live semantic + humanoid retarget on Godot -Z" % [src_id, dst_id]


func _build_mapping() -> void:
	var src_id := str(_spec.get("primary_char", "havok_girl_sdk"))
	var dst_id := str(_spec.get("secondary_char", "firefighter"))
	if dst_id.is_empty():
		dst_id = "firefighter"
	_src_pack = Standards.spawn_aligned_character(src_id, "MapSource", Animation.LOOP_LINEAR)
	_dst_pack = Standards.spawn_aligned_character(dst_id, "MapTarget", Animation.LOOP_LINEAR)
	(_src_pack["outer"] as Node3D).position = Vector3(-0.90, 0.0, 0.0)
	(_dst_pack["outer"] as Node3D).position = Vector3(0.90, 0.0, 0.0)
	add_child(_src_pack["outer"] as Node3D)
	add_child(_dst_pack["outer"] as Node3D)
	var src_player: AnimationPlayer = _src_pack["player"] as AnimationPlayer
	src_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	src_player.play(StringName(Standards.pick_clip(_src_pack, str(_spec.get("primary_clip", "walk")))))
	(_dst_pack["player"] as AnimationPlayer).active = false
	_retarget_pairs = Standards.build_semantic_retarget_pairs(_src_pack["skeleton"] as Skeleton3D, _dst_pack["skeleton"] as Skeleton3D)
	_status = "Skeletal mapping [%s -> %s]: %d paired bones" % [src_id, dst_id, _retarget_pairs.size()]


func _build_ik(route: String) -> void:
	var is_crabby := "/crabby/" in route
	var cid := "crabby" if is_crabby else str(_spec.get("primary_char", "havok_girl_sdk"))
	_src_pack = Standards.spawn_aligned_character(cid, "IKActor", Animation.LOOP_LINEAR)
	add_child(_src_pack["outer"] as Node3D)
	var skel: Skeleton3D = _src_pack["skeleton"] as Skeleton3D
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	_ik_skeleton = skel
	var player: AnimationPlayer = _src_pack["player"] as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	player.play(StringName(Standards.pick_clip(_src_pack, str(_spec.get("primary_clip", "idle")))))

	if is_crabby:
		_ik_target = _marker("CrabbyRightTarget", Color("#ffbd52"), 0.14)
		_ik_target.position = Vector3(1.15, 0.30, -0.95)
		add_child(_ik_target)
		_ik_pole = _marker("CrabbyRightPole", Color("#73a9ff"), 0.09)
		_ik_pole.position = Vector3(1.4, 2.2, -0.7)
		add_child(_ik_pole)
		_ik_modifier = _add_two_bone_ik(skel, "TwoBoneIK3D", "frontRight1", "frontRight2", "frontRight3", _ik_target, _ik_pole)
		_ik_target_b = _marker("CrabbyLeftTarget", Color("#ffbd52"), 0.14)
		_ik_target_b.position = Vector3(-1.15, 0.30, -0.95)
		add_child(_ik_target_b)
		_ik_pole_b = _marker("CrabbyLeftPole", Color("#73a9ff"), 0.09)
		_ik_pole_b.position = Vector3(-1.4, 2.2, -0.7)
		add_child(_ik_pole_b)
		_add_two_bone_ik(skel, "TwoBoneIK3D_Left", "frontLeft1", "frontLeft2", "frontLeft3", _ik_target_b, _ik_pole_b)
		_attach_pose_probe(skel, &"frontRight3")
		_status = "Crabby IK [crabby 18b]: dual TwoBoneIK3D chains on original 6-legged SpiderCrab"
	else:
		var root_b := Standards.find_semantic_bone(skel, "l_upper_arm")
		var mid_b := Standards.find_semantic_bone(skel, "l_lower_arm")
		var end_b := Standards.find_semantic_bone(skel, "l_hand")
		_ik_target = _marker("ReachTarget", Color("#ffbd52"), 0.08)
		_ik_target.position = Vector3(-0.42, 1.18, -0.58)
		add_child(_ik_target)
		_ik_pole = _marker("ReachPole", Color("#73a9ff"), 0.06)
		_ik_pole.position = Vector3(-0.95, 1.0, 0.35)
		add_child(_ik_pole)
		_ik_modifier = _add_two_bone_ik(skel, "TwoBoneIK3D", skel.get_bone_name(root_b), skel.get_bone_name(mid_b), skel.get_bone_name(end_b), _ik_target, _ik_pole)
		_attach_pose_probe(skel, StringName(skel.get_bone_name(end_b)))
		_status = "Reaching IK [%s %db]: TwoBoneIK3D on left arm chain toward -Z target" % [cid, skel.get_bone_count()]


func _build_foot_ik() -> void:
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	_src_pack = Standards.spawn_aligned_character(cid, "FootIKActor", Animation.LOOP_LINEAR)
	add_child(_src_pack["outer"] as Node3D)
	var skel: Skeleton3D = _src_pack["skeleton"] as Skeleton3D
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	_ik_skeleton = skel
	var player: AnimationPlayer = _src_pack["player"] as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	player.speed_scale = float(_spec.get("playback_speed", 0.80))
	player.play(StringName(Standards.pick_clip(_src_pack, "walk")))

	# Stepped terrain block in front of feet
	var step_box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.1, 0.18, 0.85)
	step_box.mesh = bm
	step_box.material_override = _material(Color("#607b72"))
	step_box.position = Vector3(0.0, 0.09, -0.22)
	add_child(step_box)

	var thigh_b := Standards.find_semantic_bone(skel, "l_thigh")
	var calf_b := Standards.find_semantic_bone(skel, "l_calf")
	var foot_b := Standards.find_semantic_bone(skel, "l_foot")
	_ik_target = _marker("FootPlantTarget", Color("#ffbd52"), 0.075)
	_ik_target.position = Vector3(-0.18, 0.20, -0.22)
	add_child(_ik_target)
	_ik_pole = _marker("KneePole", Color("#73a9ff"), 0.06)
	_ik_pole.position = Vector3(-0.22, 0.58, -0.95)
	add_child(_ik_pole)
	_ik_modifier = _add_two_bone_ik(skel, "FootTwoBoneIK3D", skel.get_bone_name(thigh_b), skel.get_bone_name(calf_b), skel.get_bone_name(foot_b), _ik_target, _ik_pole)
	_attach_pose_probe(skel, StringName(skel.get_bone_name(foot_b)))
	_status = "FootIk [%s %db @ %.2fx]: TwoBoneIK3D foot planting over terrain step" % [cid, skel.get_bone_count(), player.speed_scale]


func _build_look_at() -> void:
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	_src_pack = Standards.spawn_aligned_character(cid, "LookAtActor", Animation.LOOP_LINEAR)
	add_child(_src_pack["outer"] as Node3D)
	var skel: Skeleton3D = _src_pack["skeleton"] as Skeleton3D
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	_ik_skeleton = skel
	var player: AnimationPlayer = _src_pack["player"] as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	player.play(StringName(Standards.pick_clip(_src_pack, "idle")))

	_ik_target = _marker("LookTarget", Color("#ffbd52"), 0.09)
	_ik_target.position = Vector3(0.0, 1.42, -1.45)
	add_child(_ik_target)

	var head_idx := Standards.find_semantic_bone(skel, "head")
	_look_at_modifier = LookAtModifier3D.new()
	_look_at_modifier.name = "LookAtModifier3D"
	_look_at_modifier.bone_name = skel.get_bone_name(head_idx)
	_look_at_modifier.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_Z
	_look_at_modifier.primary_rotation_axis = Vector3.AXIS_Y
	_look_at_modifier.use_secondary_rotation = true
	skel.add_child(_look_at_modifier)
	_look_at_modifier.target_node = _look_at_modifier.get_path_to(_ik_target)
	_look_at_modifier.active = true
	_attach_pose_probe(skel, StringName(skel.get_bone_name(head_idx)))
	_status = "LookAt [%s %db]: LookAtModifier3D aims Head toward -Z moving target" % [cid, skel.get_bone_count()]


func _build_ragdoll() -> void:
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	_src_pack = Standards.spawn_aligned_character(cid, "RagdollActor", Animation.LOOP_LINEAR)
	_ragdoll_root = _src_pack["outer"] as Node3D
	if _has_case_token("scaling"):
		_ragdoll_root.scale = Vector3.ONE * (0.72 if "small" in _case_name.to_lower() else 1.18)
	add_child(_ragdoll_root)
	var skel: Skeleton3D = _src_pack["skeleton"] as Skeleton3D
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	var player: AnimationPlayer = _src_pack["player"] as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	player.play(StringName(Standards.pick_clip(_src_pack, str(_spec.get("primary_clip", "run")))))

	_physics_simulator = PhysicalBoneSimulator3D.new()
	_physics_simulator.name = "PhysicalBoneSimulator3D"
	skel.add_child(_physics_simulator)
	var spine_idx := Standards.find_semantic_bone(skel, "spine")
	var head_idx := Standards.find_semantic_bone(skel, "head")
	var used := {}
	for bidx in [spine_idx, head_idx]:
		if bidx > 0 and skel.get_bone_parent(bidx) >= 0 and not used.has(bidx):
			used[bidx] = true
			var bname := skel.get_bone_name(bidx)
			var sz := Vector3(0.30, 0.36, 0.22) if bidx == spine_idx else Vector3(0.20, 0.22, 0.20)
			_add_physical_bone(bname, sz)
	_physics_simulator.active = true
	_physics_simulator.physical_bones_start_simulation()
	_status = "PhysicalBoneSimulator3D [%s %db]: articulated physics simulation (SI g=9.81 m/s²)" % [cid, skel.get_bone_count()]


func _add_physical_bone(bone: String, box_size: Vector3) -> void:
	var physical := PhysicalBone3D.new()
	physical.name = "PhysicalBone_%s" % bone.validate_node_name()
	physical.bone_name = bone
	physical.joint_type = PhysicalBone3D.JOINT_TYPE_CONE if _has_case_token("soft") else PhysicalBone3D.JOINT_TYPE_PIN
	physical.mass = 1.2
	physical.can_sleep = false
	physical.gravity_scale = 0.0 if _has_case_token("powered") else 1.0
	physical.linear_damp = 2.5 if _has_case_token("powered") else 0.15
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = minf(box_size.x, box_size.z) * (0.88 if _has_case_token("penetration") else 0.5)
	capsule.height = maxf(box_size.y, capsule.radius * 2.1)
	shape.shape = capsule
	physical.add_child(shape)
	_physics_simulator.add_child(physical)


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


func _make_humanoid_bridge_skeleton(node_name: String) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = node_name
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	skel.add_bone("Hips")
	skel.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0)))
	skel.add_bone("LeftUpperArm")
	skel.set_bone_parent(1, 0)
	skel.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(-0.2, 0.35, 0.0)))
	skel.add_bone("LeftLowerArm")
	skel.set_bone_parent(2, 1)
	skel.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(-0.3, 0.0, 0.0)))
	skel.reset_bone_poses()
	return skel


func _case_path() -> String:
	return str(get_meta("case_path", "")).to_lower()


func _has_case_token(token: String) -> bool:
	return token in _case_path() or token in _case_name.to_lower()


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
