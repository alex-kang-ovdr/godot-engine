extends Node3D
## Complete Godot runtime reproductions for all Havok 2015.1.0-r1 Behavior demos
## using Godot built-in C++ modifiers (TwoBoneIK3D, LookAtModifier3D,
## RetargetModifier3D, BoneAttachment3D, AnimationTree), C++ GDExtension
## (AnimationStudioCrowdEvaluator), PoseGraph/InertialBlender/RewindRecorder,
## ActiveRagdollJoint, and original Hero assets when generated locally.

const Character := preload("res://demo/character/character.tscn")
const HeroScene := preload("res://hero/hero.tscn")
const PoseBuffer := preload("res://addons/animation_studio/pose_buffer.gd")
const PoseGraph := preload("res://addons/animation_studio/pose_graph.gd")
const RewindRecorder := preload("res://addons/animation_studio/rewind_recorder.gd")
const ActiveRagdollJoint := preload("res://addons/animation_studio/active_ragdoll_joint.gd")
const CrowdEvaluator := preload("res://addons/animation_studio/crowd_evaluator.gd")

const HERO_MOTION_FILE := "res://hero/generated/motion.json"

var family := ""
var case_path := ""
var case_variant := ""
var elapsed := 0.0
var ticks := 0

# Shared actor / graph state
var actor: Node3D
var actor_b: Node3D
var hero_instance: Node3D
var graph: PoseGraph
var graph_b: PoseGraph
var recorder: RewindRecorder
var upper_mask: PackedFloat32Array = PackedFloat32Array()
var idle_anim: Animation
var move_anim: Animation
var action_anim: Animation

# Docking & platform state (motion warping: position + yaw convergence)
var target_marker: MeshInstance3D
var dock_start_pos := Vector3.ZERO
var dock_start_yaw := 0.0
var dock_target_yaw := 0.0
var dock_start_dist := 0.0
var dock_dist := 0.0
var dock_yaw_err_deg := 0.0
var dock_progress := 0.0
var dock_rerooted := false
var platform: Node3D
var platform_angle := 0.0

# Built-in C++ IK & LookAt modifiers
var ik_rig: Skeleton3D
var ik_mod: TwoBoneIK3D
var ik_target: Node3D
var ik_pole: Node3D
var look_at_mod: LookAtModifier3D
var look_target: Node3D
var legs: Array[Dictionary] = []
var foot_hits := 0
var hand_err_m := 0.0
var controller: CharacterBody3D
var traveled := 0.0

# Active ragdoll 2-joint / control palette state
var ragdoll_joints: Array[ActiveRagdollJoint] = []
var ragdoll_angle_deg := 0.0
var ragdoll_torque := 0.0
var ragdoll_palette := "Stiff"

# Modifiers / attachment / blender tree
var attached_obj: Node3D
var attach_err_mm := 0.0
var aim_yaw_deg := 0.0
var blend_tree_node: AnimationTree
var generator_mode := "loop"
var ping_pong_reversals := 0
var last_pp_dir := 1.0

# State machine / sync start / return-to-prev / save state / determinism / skins / crowd
var state_transitions := 0
var returned_to_prev := false
var sync_phase_err := 0.0
var last_state := ""
var restore_err_rad := 0.0
var determinism_diff_rad := 0.0
var skin_swaps := 0
var crowd_evaluator: CrowdEvaluator
var crowd_skels: Array[Skeleton3D] = []
var crowd_count := 16
var crowd_using_native := false
var crowd_main_ms := 0.0
var retarget_source: Skeleton3D
var retarget_target: Skeleton3D
var retarget_mod: RetargetModifier3D


func start_case(path: String, variant_name: String) -> void:
	case_path = path.to_lower()
	case_variant = variant_name
	elapsed = 0.0
	ticks = 0

	if "/showcase/hero/" in case_path and FileAccess.file_exists(HERO_MOTION_FILE):
		family = "hero_showcase"
		_setup_hero_showcase()
	elif "/docking/" in case_path:
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


func _build_two_bone_ik_arm(base_pos: Vector3, limb_len := 0.55) -> void:
	ik_rig = Skeleton3D.new()
	ik_rig.name = "IKRig"
	ik_rig.position = base_pos
	add_child(ik_rig)
	var names := ["Base", "Upper", "Lower", "End"]
	for i in names.size():
		ik_rig.add_bone(names[i])
		if i > 0:
			ik_rig.set_bone_parent(i, i - 1)
			ik_rig.set_bone_rest(i, Transform3D(Basis.IDENTITY, Vector3(0.0, limb_len if i > 1 else 0.15, 0.0)))
		if i == 1 or i == 2:
			var att := BoneAttachment3D.new()
			att.bone_name = names[i]
			att.add_child(_make_box(Vector3(0.11, limb_len, 0.11), Color("#4bb7aa") if i == 1 else Color("#7cd8c8"), Vector3(0.0, limb_len * 0.5, 0.0)))
			ik_rig.add_child(att)
	ik_rig.reset_bone_poses()

	ik_target = Node3D.new()
	ik_target.name = "IKTarget"
	ik_target.position = base_pos + Vector3(0.45, 0.85, 0.2)
	ik_target.add_child(_make_sphere(0.10, Color("#f2a93b")))
	add_child(ik_target)

	ik_pole = Node3D.new()
	ik_pole.name = "IKPole"
	ik_pole.position = base_pos + Vector3(0.0, 0.7, -0.8)
	add_child(ik_pole)

	ik_mod = TwoBoneIK3D.new()
	ik_mod.name = "TwoBoneIK"
	ik_mod.setting_count = 1
	ik_mod.set_root_bone(0, 1)
	ik_mod.set_middle_bone(0, 2)
	ik_mod.set_end_bone(0, 3)
	ik_mod.set_target_node(0, ik_mod.get_path_to(ik_target) if ik_mod.is_inside_tree() else NodePath("../../IKTarget"))
	ik_mod.set_pole_node(0, ik_mod.get_path_to(ik_pole) if ik_mod.is_inside_tree() else NodePath("../../IKPole"))
	ik_rig.add_child(ik_mod)
	ik_mod.set_target_node(0, ik_mod.get_path_to(ik_target))
	ik_mod.set_pole_node(0, ik_mod.get_path_to(ik_pole))
	ik_mod.active = true


func _setup_hero_showcase() -> void:
	hero_instance = HeroScene.instantiate()
	add_child(hero_instance)
	# Hide Hero's own HUD & Camera so the gallery viewport controls framing cleanly.
	var ui := hero_instance.get_node_or_null("UI")
	if ui:
		ui.visible = false
	var cam := hero_instance.get_node_or_null("Camera")
	if cam is Camera3D:
		cam.current = false
	var ground := hero_instance.get_node_or_null("MeshInstance3D")
	if ground:
		ground.visible = false
	if hero_instance.has_method("select_clip"):
		hero_instance.call("select_clip", "run")


func _setup_docking() -> void:
	dock_start_pos = Vector3(-1.4, 0.0, -0.4)
	dock_start_yaw = -0.55
	dock_target_yaw = 0.65
	var pack := _spawn_graph_actor(dock_start_pos)
	actor = pack.actor
	actor.rotation.y = dock_start_yaw
	graph = pack.graph
	var target_pos := Vector3(1.1, 0.85 if "hanging" in case_path else 0.0, 0.80 if "movingtarget" in case_path else 0.35)
	target_marker = _make_sphere(0.15, Color("#f2a93b"), target_pos)
	target_marker.add_child(_make_box(Vector3(0.45, 0.04, 0.06), Color("#ffe082"), Vector3(0.22, 0.0, 0.0)))
	target_marker.rotation.y = dock_target_yaw
	add_child(target_marker)
	if "hanging" in case_path:
		add_child(_make_box(Vector3(0.6, 0.12, 1.4), Color("#637d75"), Vector3(1.25, 1.45, 0.35)))
		_build_two_bone_ik_arm(Vector3(0.85, 0.55, 0.35), 0.52)
		ik_target.position = Vector3(1.15, 1.42, 0.35)
	dock_start_dist = actor.position.distance_to(Vector3(target_pos.x, 0.0, target_pos.z))
	dock_dist = dock_start_dist
	dock_yaw_err_deg = absf(rad_to_deg(angle_difference(dock_start_yaw, dock_target_yaw)))
	dock_rerooted = false


func _setup_quadruped() -> void:
	platform = Node3D.new()
	add_child(platform)
	add_child(_make_box(Vector3(1.2, 0.32, 0.6), Color("#4bb7aa"), Vector3(0.0, 0.72, 0.0)))
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
		Vector3(0.45, 0.68, 0.28), Vector3(0.45, 0.68, -0.28),
		Vector3(-0.45, 0.68, 0.28), Vector3(-0.45, 0.68, -0.28),
	]
	legs.clear()
	for i in 4:
		var leg_rig := Skeleton3D.new()
		leg_rig.position = offsets[i]
		add_child(leg_rig)
		for bname in ["Hip", "Knee", "Ankle"]:
			leg_rig.add_bone(bname)
		leg_rig.set_bone_parent(1, 0)
		leg_rig.set_bone_parent(2, 1)
		leg_rig.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0.0, -0.34, 0.0)))
		leg_rig.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0.0, -0.34, 0.0)))
		leg_rig.reset_bone_poses()
		for bi in [0, 1]:
			var att := BoneAttachment3D.new()
			att.bone_name = leg_rig.get_bone_name(bi)
			att.add_child(_make_box(Vector3(0.08, 0.32, 0.08), Color("#d8ebe2"), Vector3(0.0, -0.16, 0.0)))
			leg_rig.add_child(att)
		var tgt := Node3D.new()
		tgt.position = Vector3(offsets[i].x, 0.12, offsets[i].z)
		tgt.add_child(_make_sphere(0.07, Color("#f2a93b")))
		add_child(tgt)
		var pole := Node3D.new()
		pole.position = offsets[i] + Vector3(0.4, -0.25, 0.0)
		add_child(pole)
		var ik := TwoBoneIK3D.new()
		ik.setting_count = 1
		ik.set_root_bone(0, 0)
		ik.set_middle_bone(0, 1)
		ik.set_end_bone(0, 2)
		leg_rig.add_child(ik)
		ik.set_target_node(0, ik.get_path_to(tgt))
		ik.set_pole_node(0, ik.get_path_to(pole))
		ik.active = true
		legs.append({"hip": offsets[i], "rig": leg_rig, "target": tgt, "ik": ik, "phase": float(i) * PI * 0.5})


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
		# Real Godot built-in C++ TwoBoneIK3D driver for HandIkDriver & FootIkDriver
		var is_hand := "handik" in case_path
		_build_two_bone_ik_arm(Vector3(0.0, 0.85 if is_hand else 0.1, 0.0), 0.52)
		if not is_hand:
			add_child(_make_box(Vector3(1.2, 0.20, 1.0), Color("#6c8078"), Vector3(0.35, 0.10, 0.0)))


func _setup_ragdoll_driver() -> void:
	ragdoll_joints.clear()
	var count := 2 if ("multiple" in case_path or "palette" in case_path) else 1
	for i in count:
		var j := ActiveRagdollJoint.new()
		j.position = Vector3((float(i) - 0.5 * float(count - 1)) * 1.1, 1.45, 0.0)
		add_child(j)
		j.build_rig()
		j.target_angle_rad = deg_to_rad(42.0 if i == 0 else -35.0)
		j.kp = 20.0 if i == 0 else 8.0
		j.kd = 3.5 if i == 0 else 1.6
		j.max_torque = 18.0 if i == 0 else 4.0
		j.anchor.add_child(_make_sphere(0.11, Color("#e8a245")))
		j.limb.add_child(_make_box(Vector3(0.16, 1.0, 0.16), Color("#4bb7aa") if i == 0 else Color("#5398e6")))
		ragdoll_joints.append(j)
	ragdoll_palette = "High-Gain / Low-Gain" if count > 1 else "High-Gain"


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
		# Real Godot built-in C++ LookAtModifier3D on Spine/Head for LookAtModifier & GunSweep
		look_target = Node3D.new()
		look_target.name = "LookTarget"
		look_target.position = Vector3(1.6, 1.35, 0.6)
		look_target.add_child(_make_sphere(0.13, Color("#f2a93b")))
		add_child(look_target)

		var head_idx: int = actor.rig.find_bone(&"Head")
		var spine_idx: int = actor.rig.find_bone(&"Spine")
		var target_bone := head_idx if head_idx >= 0 else spine_idx
		look_at_mod = LookAtModifier3D.new()
		look_at_mod.name = "LookAtMod"
		look_at_mod.bone = target_bone
		look_at_mod.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_X
		look_at_mod.primary_rotation_axis = Vector3.AXIS_Y
		look_at_mod.use_secondary_rotation = true
		actor.rig.add_child(look_at_mod)
		look_at_mod.target_node = look_at_mod.get_path_to(look_target)
		look_at_mod.active = true
		actor.rig.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE


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
	# Real C++ GDExtension AnimationStudioCrowdEvaluator driving 16 live skeletons!
	crowd_skels.clear()
	var template := Character.instantiate()
	add_child(template)
	var stride_anim: Animation = template.player.get_animation(&"stride").duplicate(true)
	var qclip := CrowdEvaluator.QuantizedClip.bake_from_animation(stride_anim, template.rig, 60.0)
	template.queue_free()

	for i in crowd_count:
		var row := i / 4
		var col := i % 4
		var ch := Character.instantiate()
		ch.position = Vector3((float(col) - 1.5) * 1.15, 0.0, (float(row) - 1.5) * 1.15)
		add_child(ch)
		ch.pose.active = false
		ch.player.active = false
		crowd_skels.append(ch.rig)

	crowd_evaluator = CrowdEvaluator.new()
	crowd_evaluator.setup(qclip, crowd_count, true)
	crowd_using_native = crowd_evaluator.is_using_native()


func _setup_generator() -> void:
	var pack := _spawn_graph_actor(Vector3.ZERO)
	actor = pack.actor
	graph = pack.graph
	idle_anim = pack.idle
	move_anim = pack.move
	action_anim = pack.action
	ping_pong_reversals = 0
	last_pp_dir = 1.0

	if "blender" in case_path:
		generator_mode = "blender_tree"
		# Real Godot AnimationTree + AnimationNodeBlend2
		var lib := AnimationLibrary.new()
		lib.add_animation(&"idle", idle_anim)
		lib.add_animation(&"move", move_anim)
		actor.player.active = true
		actor.player.add_animation_library(&"gen", lib)
		var tree_root := AnimationNodeBlendTree.new()
		var n_a := AnimationNodeAnimation.new()
		n_a.animation = &"gen/idle"
		var n_b := AnimationNodeAnimation.new()
		n_b.animation = &"gen/move"
		var blend := AnimationNodeBlend2.new()
		tree_root.add_node(&"A", n_a)
		tree_root.add_node(&"B", n_b)
		tree_root.add_node(&"Mix", blend)
		tree_root.connect_node(&"Mix", 0, &"A")
		tree_root.connect_node(&"Mix", 1, &"B")
		tree_root.connect_node(&"output", 0, &"Mix")
		blend_tree_node = AnimationTree.new()
		blend_tree_node.tree_root = tree_root
		blend_tree_node.anim_player = blend_tree_node.get_path_to(actor.player) if blend_tree_node.is_inside_tree() else NodePath("")
		actor.add_child(blend_tree_node)
		blend_tree_node.anim_player = blend_tree_node.get_path_to(actor.player)
		blend_tree_node.active = true
	elif "pingpong" in case_path:
		generator_mode = "ping_pong"
		graph.add_state(&"pp", action_anim, true, "ping_pong", 2.0)
		graph.reset(&"pp")
	elif "enforcedduration" in case_path or "speed" in case_path:
		generator_mode = "enforced_duration"
		graph.add_state(&"enforced", move_anim, true, "loop", 1.0, 0.5)
		graph.reset(&"enforced")
	elif "referencepose" in case_path:
		generator_mode = "reference_pose"
		actor.rig.reset_bone_poses()
	elif "manualselector" in case_path:
		generator_mode = "manual_selector"
		graph.reset(&"idle")
	else:
		generator_mode = "clip_modes"
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
	returned_to_prev = false
	sync_phase_err = 0.0


func _physics_process(delta: float) -> void:
	elapsed += delta
	ticks += 1
	match family:
		"hero_showcase":
			pass
		"docking":
			if "movingtarget" in case_path:
				target_marker.position = Vector3(1.1 + sin(elapsed * 0.9) * 0.30, 0.0, 0.35 + cos(elapsed * 0.9) * 0.45)
			elif "multipletargets" in case_path and ticks % 60 == 0:
				target_marker.position.z = -target_marker.position.z
			# Motion warping: warp remaining position and yaw error across clip progress.
			dock_progress = clampf(elapsed / 0.8, 0.0, 1.0)
			var u := lerpf(dock_progress, dock_progress * dock_progress * (3.0 - 2.0 * dock_progress), 0.35)
			var goal := Vector3(target_marker.position.x, 0.0, target_marker.position.z)
			actor.position = dock_start_pos.lerp(goal, u)
			actor.rotation.y = lerp_angle(dock_start_yaw, dock_target_yaw, u)
			dock_dist = actor.position.distance_to(goal)
			dock_yaw_err_deg = absf(rad_to_deg(angle_difference(actor.rotation.y, dock_target_yaw)))
			if "rerooting" in case_path and dock_progress >= 0.99 and not dock_rerooted:
				dock_rerooted = true
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
				leg.target.position = Vector3(hip.x, ground_y + 0.06 + lift, hip.z)
				leg.rig.force_update_all_bone_transforms()
		"driver_ik":
			if controller != null:
				controller.velocity = Vector3(1.1, -2.0, 0.0)
				controller.move_and_slide()
				traveled = controller.position.length()
				graph.evaluate(delta, actor.rig)
				actor.rig.force_update_all_bone_transforms()
			elif ik_target != null and ik_rig != null:
				var is_hand := "handik" in case_path
				ik_target.position = ik_rig.position + Vector3(
					0.42 + sin(elapsed * 2.4) * 0.20,
					(0.75 if is_hand else 0.35) + cos(elapsed * 2.4) * 0.15,
					0.15 + sin(elapsed * 1.6) * 0.15
				)
				ik_rig.force_update_all_bone_transforms()
				var end_pos := ik_rig.to_global(ik_rig.get_bone_global_pose(3).origin)
				hand_err_m = end_pos.distance_to(ik_target.global_position)
		"ragdoll_driver":
			if "palette" in case_path and ticks % 45 == 0 and ragdoll_joints.size() >= 2:
				var swap_high := (ticks / 45) % 2 == 0
				ragdoll_joints[0].max_torque = 18.0 if swap_high else 4.0
				ragdoll_joints[1].max_torque = 4.0 if swap_high else 18.0
				ragdoll_palette = "Palette A (Stiff/Soft)" if swap_high else "Palette B (Soft/Stiff)"
			for idx in ragdoll_joints.size():
				var j := ragdoll_joints[idx]
				j.target_angle_rad = deg_to_rad((38.0 if idx == 0 else -32.0) * sin(elapsed * 2.0 + 0.6))
				var tau := j.step_control()
				if idx == 0:
					ragdoll_torque = tau
					ragdoll_angle_deg = rad_to_deg(j.get_joint_angle_z())
		"modifier":
			graph.evaluate(delta, actor.rig)
			if look_target != null:
				look_target.position = Vector3(1.6, 1.35 + sin(elapsed * 2.0) * 0.25, sin(elapsed * 1.8) * 1.1)
				aim_yaw_deg = rad_to_deg(atan2(look_target.position.z, look_target.position.x))
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
			var st := crowd_evaluator.step_parallel(delta, crowd_skels)
			crowd_main_ms = float(st.get("main_total_ms", 0.0))
			for sk in crowd_skels:
				sk.force_update_all_bone_transforms()
		"generator":
			if generator_mode == "blender_tree" and blend_tree_node != null:
				blend_tree_node.set("parameters/Mix/blend_amount", 0.5 + 0.5 * sin(elapsed * 2.0))
			elif generator_mode == "reference_pose":
				actor.rig.reset_bone_poses()
				actor.rig.force_update_all_bone_transforms()
			else:
				if generator_mode == "manual_selector" and (ticks == 1 or ticks % 30 == 0):
					graph.transition_to(&"move" if graph.get_current_state() == &"idle" else &"idle", 0.12)
				var snap := graph.evaluate(delta, actor.rig)
				var d := float(snap.get("ping_pong_dir", 1.0))
				if d != last_pp_dir:
					ping_pong_reversals += 1
					last_pp_dir = d
				actor.rig.force_update_all_bone_transforms()
		"state_machine":
			if "synchronized" in case_path or "syncpoints" in case_path:
				if ticks == 1:
					var before_norm := float(graph.last_snapshot.get("normalized_time", 0.0))
					if graph.transition_to(&"move", 0.18, true):
						state_transitions += 1
					var snap := graph.evaluate(delta, actor.rig)
					sync_phase_err = absf(float(snap.get("normalized_time", 0.0)) - before_norm)
					last_state = str(snap.get("state", ""))
					actor.rig.force_update_all_bone_transforms()
					return
			elif "returntoprevious" in case_path:
				if ticks == 1:
					if graph.transition_to(&"move", 0.12):
						state_transitions += 1
				elif ticks == 2:
					if graph.return_to_previous(0.12):
						state_transitions += 1
						returned_to_prev = graph.get_current_state() == &"idle"
			elif ticks == 1 or ticks % 45 == 0:
				var next_s := &"move" if graph.get_current_state() == &"idle" else &"idle"
				if graph.transition_to(next_s, 0.18):
					state_transitions += 1
				if ("sequence" in case_path or "global" in case_path) and not graph.is_slot_active():
					graph.play_slot(&"action", action_anim, upper_mask, 0.06, 0.10)
			var snap := graph.evaluate(delta, actor.rig)
			last_state = str(snap.get("state", ""))
			actor.rig.force_update_all_bone_transforms()


func status_text() -> String:
	match family:
		"hero_showcase":
			return "Behavior Hero 원본 쇼케이스 · 85본 리그 + 18,050정점 스킨 메시 실행 중"
		"docking":
			return "Behavior 도킹 워핑 · 거리 %.3f m (시작 %.2f m) · Yaw 오차 %.1f° · 진행 %.0f%%" % [
				dock_dist, dock_start_dist, dock_yaw_err_deg, dock_progress * 100.0]
		"quadruped_ik":
			return "Behavior 4족 TwoBoneIK3D · 접지 %d/4 · 플랫폼 %.1f°" % [foot_hits, rad_to_deg(platform_angle)]
		"driver_ik":
			if controller != null:
				return "Behavior CharacterBody3D 컨트롤러 · 이동 %.2f m" % traveled
			return "Behavior TwoBoneIK3D 드라이버 · 목표 거리 %.3f m" % hand_err_m
		"ragdoll_driver":
			return "Behavior 능동 랙돌 (%s) · 관절 %.1f° · 토크 %.2f N·m" % [ragdoll_palette, ragdoll_angle_deg, ragdoll_torque]
		"modifier":
			if attached_obj != null:
				return "Behavior BoneAttachment3D · 소켓 오차 %.3f mm" % attach_err_mm
			return "Behavior LookAtModifier3D · 목표 Yaw %.1f°" % aim_yaw_deg
		"retargeting":
			return "Behavior RetargetModifier3D · 프로파일 리타게팅 활성"
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
			return "Behavior 런타임 스킨 교체 · 교체 %d회" % skin_swaps
		"crowd":
			return "Behavior %s 군중 평가 · %d체 스켈레톤 %.3f ms" % [
				"C++ GDExtension" if crowd_using_native else "GDScript", crowd_count, crowd_main_ms]
		"generator":
			return "Behavior 생성기 (%s) · 상태 %s · 반전 %d회" % [
				generator_mode, graph.last_snapshot.get("state", "ref"), ping_pong_reversals]
		_:
			return "Behavior 상태 머신 · 상태 %s · 전이 %d회 · 복귀=%s · 위상차 %.4f" % [
				last_state if not last_state.is_empty() else "idle",
				state_transitions, str(returned_to_prev), sync_phase_err]
