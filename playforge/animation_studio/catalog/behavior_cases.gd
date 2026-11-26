extends Node3D
## Godot runtime reproductions for all Havok 2015.1.0-r1 Behavior demos
## (Api/Docking, Api/Drivers, Api/Generators, Api/Modifiers, Api/Sequence,
## Api/StateMachine, ShowCase, Test, UseCase).

const Character := preload("res://demo/character/character.tscn")
const PoseBuffer := preload("res://addons/animation_studio/pose_buffer.gd")
const PoseGraph := preload("res://addons/animation_studio/pose_graph.gd")
const RewindRecorder := preload("res://addons/animation_studio/rewind_recorder.gd")
const ActiveRagdollJoint := preload("res://addons/animation_studio/active_ragdoll_joint.gd")

var family := ""
var case_path := ""
var case_variant := ""
var elapsed := 0.0
var ticks := 0

# Shared actor / graph state
var actor: Node3D
var actor_b: Node3D
var graph: PoseGraph
var graph_b: PoseGraph
var recorder: RewindRecorder
var upper_mask: PackedFloat32Array = PackedFloat32Array()
var idle_anim: Animation
var move_anim: Animation
var action_anim: Animation

# Docking & platform state
var target_marker: MeshInstance3D
var dock_start_dist := 0.0
var dock_dist := 0.0
var dock_progress := 0.0
var platform: Node3D
var platform_angle := 0.0

# IK & quadruped state
var legs: Array[Dictionary] = []
var foot_hits := 0
var hand_err_m := 0.0
var controller: CharacterBody3D
var traveled := 0.0

# Active ragdoll state
var ragdoll_joint: ActiveRagdollJoint
var ragdoll_angle_deg := 0.0
var ragdoll_torque := 0.0

# Modifiers / attachment / aim state
var attached_obj: Node3D
var attach_err_mm := 0.0
var aim_yaw_deg := 0.0

# State machine / save state / determinism / skins / crowd
var state_transitions := 0
var last_state := ""
var restore_err_rad := 0.0
var determinism_diff_rad := 0.0
var skin_swaps := 0
var crowd_mesh: MultiMesh
var crowd_count := 24
var crowd_transforms: Array[Transform3D] = []
var crowd_worker_usec := 0
var retarget_source: Skeleton3D
var retarget_target: Skeleton3D
var retarget_mod: RetargetModifier3D


func start_case(path: String, variant_name: String) -> void:
	case_path = path.to_lower()
	case_variant = variant_name
	elapsed = 0.0
	ticks = 0

	if "/docking/" in case_path:
		family = "docking"
		_setup_docking()
	elif "quadruped" in case_path:
		family = "quadruped_ik"
		_setup_quadruped()
	elif "/drivers/ragdolldriver/" in case_path:
		family = "ragdoll_driver"
		_setup_ragdoll_driver()
	elif "/drivers/" in case_path:
		family = "driver_ik"
		_setup_driver_ik()
	elif "/modifiers/" in case_path or "gunsweep" in case_path:
		family = "modifier"
		_setup_modifier()
	elif "animationretargeting" in case_path:
		family = "retargeting"
		_setup_retargeting()
	elif "movingplatforms" in case_path:
		family = "moving_platform"
		_setup_moving_platform()
	elif "savebehaviorstate" in case_path:
		family = "save_state"
		_setup_save_state()
	elif "partialanimation" in case_path or "stagger" in case_path:
		family = "partial_stagger"
		_setup_partial_stagger()
	elif "determinism" in case_path:
		family = "determinism"
		_setup_determinism()
	elif "swapskins" in case_path:
		family = "swap_skins"
		_setup_swap_skins()
	elif "orcs" in case_path or "performance" in case_path or "asynchronousstepping" in case_path:
		family = "crowd"
		_setup_crowd()
	elif "/generators/" in case_path or "animationtest" in case_path or "auxiliaryanimationtracks" in case_path or "animationsets" in case_path or "ondemandassetloading" in case_path:
		family = "generator"
		_setup_generator()
	else:
		# StateMachine, Sequence, NestedBehaviors, TransitionTest, SyncPoints, Hero, Gdc2005, Viewers, EditBehavior, SymbolLinking
		family = "state_machine"
		_setup_state_machine()


func _make_box(size: Vector3, color: Color, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	box.material = mat
	mi.mesh = box
	mi.position = pos
	return mi


func _make_sphere(radius: float, color: Color, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = radius
	sp.height = radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	sp.material = mat
	mi.mesh = sp
	mi.position = pos
	return mi


func _spawn_graph_actor(pos := Vector3.ZERO) -> Dictionary:
	var ch := Character.instantiate()
	ch.position = pos
	add_child(ch)
	ch.pose.active = false
	ch.player.active = false
	var skel: Skeleton3D = ch.rig
	var move_a: Animation = ch.player.get_animation(&"stride").duplicate(true)
	var idle_a := _build_idle_anim()
	var act_a := _build_action_anim()
	var pg := PoseGraph.new()
	pg.configure(&"Root")
	pg.add_state(&"idle", idle_a, true)
	pg.add_state(&"move", move_a, true)
	pg.add_state(&"action", act_a, true)
	pg.reset(&"move")
	return {"actor": ch, "skel": skel, "graph": pg, "idle": idle_a, "move": move_a, "action": act_a}


func _build_idle_anim() -> Animation:
	var a := Animation.new()
	a.length = 1.2
	a.loop_mode = Animation.LOOP_LINEAR
	_add_rot_keys(a, ^"Rig:Spine", Vector3.RIGHT, [0.0, 0.6, 1.2], [0.0, 0.06, 0.0])
	_add_rot_keys(a, ^"Rig:ShoulderLeft", Vector3.FORWARD, [0.0, 0.6, 1.2], [0.08, 0.14, 0.08])
	_add_rot_keys(a, ^"Rig:ShoulderRight", Vector3.FORWARD, [0.0, 0.6, 1.2], [-0.08, -0.14, -0.08])
	return a


func _build_action_anim() -> Animation:
	var a := Animation.new()
	a.length = 0.6
	a.loop_mode = Animation.LOOP_NONE
	_add_rot_keys(a, ^"Rig:Spine", Vector3.UP, [0.0, 0.2, 0.45, 0.6], [0.0, -0.45, 0.55, 0.0])
	_add_rot_keys(a, ^"Rig:ShoulderRight", Vector3.FORWARD, [0.0, 0.2, 0.4, 0.6], [0.0, -1.1, 1.0, 0.0])
	_add_rot_keys(a, ^"Rig:Hand.R", Vector3.RIGHT, [0.0, 0.3, 0.6], [0.0, -0.7, 0.0])
	return a


static func _add_rot_keys(anim: Animation, path: NodePath, axis: Vector3, times: Array[float], angles: Array[float]) -> void:
	var t := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t, path)
	for i in times.size():
		anim.rotation_track_insert_key(t, times[i], Quaternion(axis, angles[i]))


func _setup_docking() -> void:
	var pack := _spawn_graph_actor(Vector3(-1.4, 0.0, 0.0))
	actor = pack.actor
	graph = pack.graph
	var target_pos := Vector3(1.2, 0.9 if "hanging" in case_path else 0.0, 0.3)
	target_marker = _make_sphere(0.16, Color("#f2a93b"), target_pos)
	add_child(target_marker)
	if "hanging" in case_path:
		add_child(_make_box(Vector3(0.6, 0.12, 1.4), Color("#637d75"), Vector3(1.35, 1.55, 0.3)))
	dock_start_dist = actor.position.distance_to(target_marker.position)
	dock_dist = dock_start_dist


func _setup_quadruped() -> void:
	platform = Node3D.new()
	add_child(platform)
	var body_vis := _make_box(Vector3(1.2, 0.32, 0.6), Color("#4bb7aa"), Vector3(0.0, 0.72, 0.0))
	add_child(body_vis)
	if "rotatingplatform" in case_path:
		var disc := _make_box(Vector3(3.4, 0.14, 3.4), Color("#647871"), Vector3(0.0, 0.07, 0.0))
		platform.add_child(disc)
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(3.4, 0.14, 3.4)
		cs.shape = bs
		cs.position = Vector3(0.0, 0.07, 0.0)
		sb.add_child(cs)
		platform.add_child(sb)
	else:
		var mound := _make_box(Vector3(2.2, 0.24, 1.8), Color("#6a8076"), Vector3(0.3, 0.12, 0.0))
		mound.rotation.z = deg_to_rad(-8.0)
		platform.add_child(mound)
		var sb := StaticBody3D.new()
		sb.position = mound.position
		sb.rotation = mound.rotation
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(2.2, 0.24, 1.8)
		cs.shape = bs
		sb.add_child(cs)
		platform.add_child(sb)

	var offsets := [
		Vector3(0.45, 0.65, 0.28), Vector3(0.45, 0.65, -0.28),
		Vector3(-0.45, 0.65, 0.28), Vector3(-0.45, 0.65, -0.28),
	]
	legs.clear()
	for i in 4:
		var foot_vis := _make_sphere(0.08, Color("#f2a93b"), Vector3(offsets[i].x, 0.15, offsets[i].z))
		var upper := _make_box(Vector3(0.09, 0.36, 0.09), Color("#d8ebe2"), offsets[i] + Vector3(0, -0.18, 0))
		add_child(upper)
		add_child(foot_vis)
		legs.append({"hip": offsets[i], "upper": upper, "foot": foot_vis, "phase": float(i) * PI * 0.5})


func _setup_driver_ik() -> void:
	if "charactercontroller" in case_path:
		controller = CharacterBody3D.new()
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.28
		cap.height = 1.6
		cs.shape = cap
		cs.position.y = 0.8
		controller.add_child(cs)
		add_child(controller)
		var pack := _spawn_graph_actor(Vector3.ZERO)
		actor = pack.actor
		graph = pack.graph
		actor.reparent(controller)
		add_child(_make_box(Vector3(1.6, 0.16, 1.4), Color("#6c8078"), Vector3(1.2, 0.08, 0.0)))
	else:
		var pack := _spawn_graph_actor(Vector3.ZERO)
		actor = pack.actor
		graph = pack.graph
		var is_hand := "handik" in case_path
		target_marker = _make_sphere(0.11, Color("#f2a93b"), Vector3(0.55, 1.25 if is_hand else 0.22, 0.25))
		add_child(target_marker)
		if not is_hand:
			add_child(_make_box(Vector3(1.2, 0.20, 1.0), Color("#6c8078"), Vector3(0.0, 0.10, 0.0)))


func _setup_ragdoll_driver() -> void:
	ragdoll_joint = ActiveRagdollJoint.new()
	ragdoll_joint.position = Vector3(0.0, 1.4, 0.0)
	add_child(ragdoll_joint)
	ragdoll_joint.build_rig()
	ragdoll_joint.target_angle_rad = deg_to_rad(42.0)
	ragdoll_joint.max_torque = 6.0 if "palette" in case_path else 18.0
	ragdoll_joint.anchor.add_child(_make_sphere(0.11, Color("#e8a245")))
	ragdoll_joint.limb.add_child(_make_box(Vector3(0.16, 1.0, 0.16), Color("#4bb7aa")))


func _setup_modifier() -> void:
	var pack := _spawn_graph_actor(Vector3.ZERO)
	actor = pack.actor
	graph = pack.graph
	if "attachment" in case_path:
		var attach := BoneAttachment3D.new()
		attach.bone_name = &"Hand.R"
		actor.rig.add_child(attach)
		if "charactertocharacter" in case_path:
			var sub := _spawn_graph_actor(Vector3.ZERO)
			actor_b = sub.actor
			graph_b = sub.graph
			actor_b.scale = Vector3(0.45, 0.45, 0.45)
			actor_b.reparent(attach)
			attached_obj = actor_b
		else:
			attached_obj = _make_box(Vector3(0.24, 0.24, 0.24), Color("#f2a93b"))
			attach.add_child(attached_obj)
	else:
		# LookAtModifier / GunSweep
		target_marker = _make_sphere(0.13, Color("#f2a93b"), Vector3(1.5, 1.35, 0.8))
		add_child(target_marker)
		upper_mask = PoseBuffer.build_branch_mask(actor.rig, &"Spine")


func _setup_retargeting() -> void:
	retarget_source = _build_chain_skeleton("SourceRig", 0.35, Vector3(-0.9, 0.1, 0.0), Color("#4bb7aa"))
	retarget_target = _build_chain_skeleton("TargetRig", 0.50, Vector3(0.9, 0.1, 0.0), Color("#f2a93b"))
	retarget_mod = RetargetModifier3D.new()
	retarget_mod.profile = SkeletonProfileHumanoid.new()
	retarget_source.add_child(retarget_mod)
	retarget_target.reparent(retarget_mod)
	retarget_target.position = Vector3(1.8, 0.0, 0.0)


func _build_chain_skeleton(n: String, seg_len: float, pos: Vector3, color: Color) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = n
	skel.position = pos
	add_child(skel)
	var names := ["Hips", "Spine", "LeftUpperArm", "LeftLowerArm"]
	for i in names.size():
		skel.add_bone(names[i])
		if i > 0:
			skel.set_bone_parent(i, i - 1)
			skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, Vector3(0.0, seg_len, 0.0)))
		var att := BoneAttachment3D.new()
		att.bone_name = names[i]
		att.add_child(_make_box(Vector3(0.14, seg_len * 0.85, 0.14), color, Vector3(0.0, seg_len * 0.4, 0.0)))
		skel.add_child(att)
	skel.reset_bone_poses()
	return skel


func _setup_moving_platform() -> void:
	platform = Node3D.new()
	add_child(platform)
	platform.add_child(_make_box(Vector3(2.8, 0.16, 2.2), Color("#637d75"), Vector3(0.0, 0.08, 0.0)))
	var pack := _spawn_graph_actor(Vector3(0.0, 0.16, 0.0))
	actor = pack.actor
	graph = pack.graph
	actor.reparent(platform)


func _setup_save_state() -> void:
	var pack := _spawn_graph_actor(Vector3.ZERO)
	actor = pack.actor
	graph = pack.graph
	recorder = RewindRecorder.new(60)
	recorder.attach(actor.rig, actor)


func _setup_partial_stagger() -> void:
	var pack := _spawn_graph_actor(Vector3.ZERO)
	actor = pack.actor
	graph = pack.graph
	action_anim = pack.action
	upper_mask = PoseBuffer.build_branch_mask(actor.rig, &"Spine")
	graph.play_slot(&"stagger" if "stagger" in case_path else &"partial", action_anim, upper_mask, 0.06, 0.10)


func _setup_determinism() -> void:
	var p1 := _spawn_graph_actor(Vector3(-0.7, 0.0, 0.0))
	var p2 := _spawn_graph_actor(Vector3(0.7, 0.0, 0.0))
	actor = p1.actor
	graph = p1.graph
	actor_b = p2.actor
	graph_b = p2.graph


func _setup_swap_skins() -> void:
	var pack := _spawn_graph_actor(Vector3.ZERO)
	actor = pack.actor
	graph = pack.graph
	skin_swaps = 0


func _setup_crowd() -> void:
	var mmi := MultiMeshInstance3D.new()
	crowd_mesh = MultiMesh.new()
	crowd_mesh.transform_format = MultiMesh.TRANSFORM_3D
	crowd_mesh.use_colors = true
	crowd_mesh.instance_count = crowd_count
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.22
	capsule.height = 1.2
	crowd_mesh.mesh = capsule
	mmi.multimesh = crowd_mesh
	add_child(mmi)
	crowd_transforms.resize(crowd_count)
	for i in crowd_count:
		var col := Color.from_hsv(fmod(float(i) * 0.07, 1.0), 0.55, 0.85)
		crowd_mesh.set_instance_color(i, col)
		crowd_transforms[i] = Transform3D.IDENTITY


func _setup_generator() -> void:
	var pack := _spawn_graph_actor(Vector3.ZERO)
	actor = pack.actor
	graph = pack.graph
	idle_anim = pack.idle
	move_anim = pack.move
	if "referencepose" in case_path:
		graph.reset(&"idle")
	else:
		graph.reset(&"move")


func _setup_state_machine() -> void:
	var pack := _spawn_graph_actor(Vector3.ZERO)
	actor = pack.actor
	graph = pack.graph
	action_anim = pack.action
	upper_mask = PoseBuffer.build_branch_mask(actor.rig, &"Spine")
	graph.reset(&"idle")
	last_state = "idle"
	state_transitions = 0


func _physics_process(delta: float) -> void:
	elapsed += delta
	ticks += 1
	match family:
		"docking":
			if "movingtarget" in case_path:
				target_marker.position = Vector3(1.2 + sin(elapsed * 1.4) * 0.45, 0.0, cos(elapsed * 1.4) * 0.55)
			elif "multipletargets" in case_path and ticks % 60 == 0:
				target_marker.position.z = -target_marker.position.z
			dock_progress = clampf(elapsed / 1.2, 0.0, 1.0)
			var goal := Vector3(target_marker.position.x, 0.0, target_marker.position.z)
			actor.position = actor.position.move_toward(goal, delta * 2.2)
			dock_dist = actor.position.distance_to(goal)
			graph.evaluate(delta, actor.rig)
			actor.rig.force_update_all_bone_transforms()
		"quadruped_ik":
			if "rotatingplatform" in case_path:
				platform_angle += delta * 0.9
				platform.rotation.y = platform_angle
			var space := get_world_3d().direct_space_state
			foot_hits = 0
			for leg in legs:
				var hip: Vector3 = leg.hip
				var lift := maxf(0.0, sin(elapsed * 5.0 + float(leg.phase))) * 0.14
				var q := PhysicsRayQueryParameters3D.create(hip + Vector3.UP * 0.3, hip + Vector3.DOWN * 1.2)
				var hit := space.intersect_ray(q)
				var ground_y := 0.0
				if not hit.is_empty():
					foot_hits += 1
					ground_y = hit.position.y
				var foot_pos := Vector3(hip.x, ground_y + 0.06 + lift, hip.z)
				leg.foot.position = foot_pos
				leg.upper.position = (hip + foot_pos) * 0.5
		"driver_ik":
			if controller != null:
				controller.velocity = Vector3(1.1, -2.0, 0.0)
				controller.move_and_slide()
				traveled = controller.position.length()
				graph.evaluate(delta, actor.rig)
				actor.rig.force_update_all_bone_transforms()
			else:
				graph.evaluate(delta, actor.rig)
				target_marker.position.x = 0.55 + sin(elapsed * 2.4) * 0.22
				target_marker.position.y = (1.25 if "handik" in case_path else 0.22) + cos(elapsed * 2.4) * 0.14
				var bone_name := &"ShoulderRight" if "handik" in case_path else &"HipRight"
				var bi: int = actor.rig.find_bone(bone_name)
				if bi >= 0:
					var angle := clampf(sin(elapsed * 2.4) * 0.65, -1.0, 1.0)
					actor.rig.set_bone_pose_rotation(bi, Quaternion(Vector3.FORWARD, angle))
				actor.rig.force_update_all_bone_transforms()
				var end_bone: int = actor.rig.find_bone(&"Hand.R" if "handik" in case_path else &"KneeRight")
				if end_bone >= 0:
					var end_pos: Vector3 = actor.rig.to_global(actor.rig.get_bone_global_pose(end_bone).origin)
					hand_err_m = end_pos.distance_to(target_marker.global_position)
		"ragdoll_driver":
			ragdoll_joint.target_angle_rad = deg_to_rad(38.0 * sin(elapsed * 2.0 + 0.6))
			ragdoll_torque = ragdoll_joint.step_control()
			ragdoll_angle_deg = rad_to_deg(ragdoll_joint.get_joint_angle_z())
		"modifier":
			graph.evaluate(delta, actor.rig)
			if target_marker != null:
				target_marker.position = Vector3(1.5, 1.35 + sin(elapsed * 2.0) * 0.25, sin(elapsed * 1.8) * 1.1)
				var yaw := clampf(atan2(target_marker.position.z, target_marker.position.x), -0.9, 0.9)
				aim_yaw_deg = rad_to_deg(yaw)
				var spine: int = actor.rig.find_bone(&"Spine")
				if spine >= 0:
					actor.rig.set_bone_pose_rotation(spine, Quaternion(Vector3.UP, -yaw))
			actor.rig.force_update_all_bone_transforms()
			if actor_b != null and graph_b != null:
				graph_b.evaluate(delta, actor_b.rig)
				actor_b.rig.force_update_all_bone_transforms()
			if attached_obj != null:
				var hand_idx: int = actor.rig.find_bone(&"Hand.R")
				if hand_idx >= 0:
					var expected: Vector3 = actor.rig.to_global(actor.rig.get_bone_global_pose(hand_idx).origin)
					attach_err_mm = attached_obj.global_position.distance_to(expected) * 1000.0
		"retargeting":
			var a := sin(elapsed * 3.0) * 0.55
			retarget_source.set_bone_pose_rotation(2, Quaternion(Vector3.FORWARD, a))
			retarget_source.force_update_all_bone_transforms()
		"moving_platform":
			platform_angle += delta * 0.7
			platform.position = Vector3(sin(elapsed * 1.2) * 0.8, 0.0, cos(elapsed * 1.2) * 0.4)
			platform.rotation.y = platform_angle
			graph.evaluate(delta, actor.rig)
			actor.rig.force_update_all_bone_transforms()
		"save_state":
			var snap := graph.evaluate(delta, actor.rig)
			recorder.queue_metadata(snap)
			actor.rig.force_update_all_bone_transforms()
			# Manually record into ring buffer when modifier is headless/direct.
			if recorder.get_total_recorded() < ticks:
				recorder._on_skeleton_updated()
			if ticks == 2 and recorder.get_frame_count() >= 1:
				var saved: Dictionary = recorder.get_frame(0)
				var expected: PoseBuffer = saved.pose
				recorder.apply_frame(0, actor.rig, actor)
				var restored := PoseBuffer.capture_from_skeleton(actor.rig)
				restore_err_rad = restored.max_diff(expected).max_rot_rad
		"partial_stagger":
			if not graph.is_slot_active() and ticks % 45 == 0:
				graph.play_slot(&"stagger", action_anim, upper_mask, 0.06, 0.10)
			graph.evaluate(delta, actor.rig)
			actor.rig.force_update_all_bone_transforms()
		"determinism":
			if ticks == 2:
				graph.transition_to(&"idle", 0.2)
				graph_b.transition_to(&"idle", 0.2)
			graph.evaluate(delta, actor.rig)
			graph_b.evaluate(delta, actor_b.rig)
			var p1 := PoseBuffer.capture_from_skeleton(actor.rig)
			var p2 := PoseBuffer.capture_from_skeleton(actor_b.rig)
			determinism_diff_rad = p1.max_diff(p2).max_rot_rad
			actor.rig.force_update_all_bone_transforms()
			actor_b.rig.force_update_all_bone_transforms()
		"swap_skins":
			graph.evaluate(delta, actor.rig)
			actor.rig.force_update_all_bone_transforms()
			if ticks == 1 or ticks % 30 == 0:
				skin_swaps += 1
				var tint := Color("#4bb7aa") if skin_swaps % 2 == 1 else Color("#e88c45")
				for mi: MeshInstance3D in actor.find_children("*", "MeshInstance3D", true, false):
					if mi.mesh != null and mi.mesh.get_surface_count() > 0:
						var mat := StandardMaterial3D.new()
						mat.albedo_color = tint
						mi.set_surface_override_material(0, mat)
		"crowd":
			var t0 := Time.get_ticks_usec()
			var job := WorkerThreadPool.add_group_task(_step_crowd_agent, crowd_count, 4, true)
			WorkerThreadPool.wait_for_group_task_completion(job)
			crowd_worker_usec = Time.get_ticks_usec() - t0
			for i in crowd_count:
				crowd_mesh.set_instance_transform(i, crowd_transforms[i])
		"generator":
			var dt := delta * (1.8 if "speed" in case_path else 1.0)
			graph.evaluate(dt, actor.rig)
			actor.rig.force_update_all_bone_transforms()
		"state_machine":
			if ticks == 1 or ticks % 45 == 0:
				var next_s := &"move" if graph.get_current_state() == &"idle" else &"idle"
				if graph.transition_to(next_s, 0.18):
					state_transitions += 1
				if ("hero" in case_path or "sequence" in case_path) and not graph.is_slot_active():
					graph.play_slot(&"action", action_anim, upper_mask, 0.06, 0.10)
			var snap := graph.evaluate(delta, actor.rig)
			last_state = str(snap.get("state", ""))
			actor.rig.force_update_all_bone_transforms()


func _step_crowd_agent(idx: int) -> void:
	var row := idx / 6
	var col := idx % 6
	var x := (float(col) - 2.5) * 0.9
	var z := (float(row) - 1.5) * 0.9
	var bob := absf(sin(elapsed * 4.5 + float(idx) * 0.35)) * 0.12
	var yaw := sin(elapsed * 1.2 + float(idx) * 0.2) * 0.5
	crowd_transforms[idx] = Transform3D(Basis(Vector3.UP, yaw), Vector3(x, 0.65 + bob, z))


func status_text() -> String:
	match family:
		"docking":
			return "Behavior 도킹 · 거리 %.3f m (시작 %.2f m) · 진행 %.0f%%" % [dock_dist, dock_start_dist, dock_progress * 100.0]
		"quadruped_ik":
			return "Behavior 4족 발 IK · 접지 %d/4 · 플랫폼 회전 %.1f°" % [foot_hits, rad_to_deg(platform_angle)]
		"driver_ik":
			if controller != null:
				return "Behavior 캐릭터 컨트롤러 · 이동 %.2f m" % traveled
			return "Behavior 드라이버 IK · 목표 거리 %.3f m" % hand_err_m
		"ragdoll_driver":
			return "Behavior 능동 랙돌 드라이버 · 관절 %.1f° · 토크 %.2f N·m" % [ragdoll_angle_deg, ragdoll_torque]
		"modifier":
			if attached_obj != null:
				return "Behavior 부착 모디파이어 · 소켓 오차 %.3f mm" % attach_err_mm
			return "Behavior 시선/조준 모디파이어 · 회전 %.1f°" % aim_yaw_deg
		"retargeting":
			return "Behavior 리타게팅 · RetargetModifier3D 활성"
		"moving_platform":
			return "Behavior 이동 플랫폼 · 회전 %.1f° · 위치 (%.2f, %.2f)" % [rad_to_deg(platform_angle), platform.position.x, platform.position.z]
		"save_state":
			return "Behavior 상태 저장·복원 · 버퍼 %d틱 · 복원 오차 %.5f rad" % [recorder.get_frame_count(), restore_err_rad]
		"partial_stagger":
			var w: float = float(graph.last_snapshot.get("slot_weight", 0.0))
			return "Behavior 상체 마스크/충격 반응 · 슬롯 가중치 %.0f%%" % [w * 100.0]
		"determinism":
			return "Behavior 결정성 대조 · 2인스턴스 최대 차이 %.6f rad" % determinism_diff_rad
		"swap_skins":
			return "Behavior 런타임 스킨 교체 · 교체 횟수 %d회" % skin_swaps
		"crowd":
			return "Behavior 병렬 군중 · %d체 워커 %d us" % [crowd_count, crowd_worker_usec]
		"generator":
			return "Behavior 생성기 · 상태 %s · 평가 클립 %d개" % [graph.last_snapshot.get("state", "-"), int(graph.last_snapshot.get("total_clips_evaluated", 1))]
		_:
			return "Behavior 상태 머신 · 상태 %s · 전이 %d회 · 평가 클립 %d개" % [
				last_state if not last_state.is_empty() else "idle",
				state_transitions,
				int(graph.last_snapshot.get("total_clips_evaluated", 1))
			]
