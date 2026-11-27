extends Node3D
## Complete Godot runtime reproductions for all 138 Havok 2015.1.0-r1 Behavior
## demos using internalized original Havok SDK characters (Hero 85b, Soldier 114b,
## SiegeFiend 34b, OrcCaptain 73b, Firefighter/DesertDan/JungleJoe/SnowSam 38b,
## FlyingImp 66b, HiveQueen 14b, NinjaBlue 69b, Boy/Girl, FemaleDress/Ponytail,
## MaleCape/NoCape) aligned strictly to Godot Standard coordinates (-Z forward,
## +Y up, SI meters, 9.81 m/s² gravity, Havok LOOP_LINEAR/PINGPONG/SINGLE defaults).

const Standards := preload("res://catalog/havok_demo_standards.gd")
const Store := preload("res://characters/character_store.gd")
const HeroScene := preload("res://hero/hero.tscn")
const HeroMotionData := preload("res://hero/hero_motion_data.gd")
const PoseBuffer := preload("res://addons/animation_studio/pose_buffer.gd")
const PoseGraph := preload("res://addons/animation_studio/pose_graph.gd")
const RewindRecorder := preload("res://addons/animation_studio/rewind_recorder.gd")
const ActiveRagdollJoint := preload("res://addons/animation_studio/active_ragdoll_joint.gd")
const CrowdEvaluator := preload("res://addons/animation_studio/crowd_evaluator.gd")

const FIREFIGHTER_SKIN_ROSTER := ["firefighter", "desert_dan", "jungle_joe", "snow_sam"]

var family := ""
var case_path := ""
var case_variant := ""
var _spec: Dictionary = {}
var elapsed := 0.0
var ticks := 0

# Shared actor / graph state
var actor: Node3D
var actor_b: Node3D
var actor_skel: Skeleton3D
var actor_b_skel: Skeleton3D
var actor_player: AnimationPlayer
var hero_instance: Node3D
var graph: PoseGraph
var graph_b: PoseGraph
var recorder: RewindRecorder
var upper_mask: PackedFloat32Array = PackedFloat32Array()
var idle_anim: Animation
var move_anim: Animation
var action_anim: Animation

# Docking & platform state (motion warping along Godot Standard -Z)
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

# Built-in C++ IK & LookAt modifiers on real internalized Havok skeletons
var ik_rig: Skeleton3D
var ik_mod: TwoBoneIK3D
var ik_target: Node3D
var ik_pole: Node3D
var ik_end_bone := -1
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
var attach_hand_bone := -1
var attach_err_mm := 0.0
var aim_yaw_deg := 0.0
var blend_tree_node: AnimationTree
var generator_mode := "loop"
var ping_pong_reversals := 0
var last_pp_dir := 1.0

# State machine / sync / return-to-prev / save state / determinism / skins / crowd
var state_transitions := 0
var returned_to_prev := false
var sync_phase_err := 0.0
var last_state := ""
var restore_err_rad := 0.0
var determinism_diff_rad := 0.0
var skin_swaps := 0
var active_skin_id := "firefighter"
var crowd_evaluator: CrowdEvaluator
var crowd_skels: Array[Skeleton3D] = []
var crowd_count := 16
var crowd_using_native := false
var crowd_main_ms := 0.0
var retarget_source: Skeleton3D
var retarget_target: Skeleton3D
var retarget_mod: RetargetModifier3D
var _retarget_src_pack: Dictionary = {}
var _retarget_dst_pack: Dictionary = {}
var _retarget_pairs: Array[Array] = []


func start_case(path: String, variant_name: String) -> void:
	case_path = path.to_lower()
	case_variant = variant_name
	_spec = Standards.resolve_demo_spec(path, variant_name)
	elapsed = 0.0
	ticks = 0

	if "/showcase/hero/" in case_path and HeroMotionData.has_motion_data():
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


func _spawn_havok_graph_actor(char_id: String, pos := Vector3.ZERO, loop_override: int = -1) -> Dictionary:
	var cid := char_id if not char_id.is_empty() else str(_spec.get("primary_char", "soldier"))
	var eff_loop := loop_override if loop_override >= 0 else int(_spec.get("loop_mode", Animation.LOOP_LINEAR))
	var pack := Standards.spawn_aligned_character(cid, "BehActor_" + cid, eff_loop)
	var outer: Node3D = pack["outer"] as Node3D
	outer.position = pos
	add_child(outer)
	var skel: Skeleton3D = pack["skeleton"] as Skeleton3D
	var player: AnimationPlayer = pack["player"] as AnimationPlayer
	player.active = false

	var lib: AnimationLibrary = pack["library"] as AnimationLibrary
	var move_key := Standards.pick_clip(pack, str(_spec.get("primary_clip", "walk")))
	var idle_key := Standards.pick_clip(pack, "idle" if lib.has_animation("idle") else str(_spec.get("secondary_clip", move_key)))
	var act_key := Standards.pick_clip(pack, str(_spec.get("secondary_clip", move_key)))
	for cand in ["vault", "slash", "kick", "jump", "wave", "run", "jog"]:
		if lib.has_animation(cand) and cand != idle_key:
			act_key = cand
			break

	var move_a: Animation = lib.get_animation(move_key)
	var idle_a: Animation = lib.get_animation(idle_key)
	var act_a: Animation = lib.get_animation(act_key)

	var pg := PoseGraph.new()
	# All internalized Havok clips already have root motion extracted separately from bone tracks;
	# passing Pelvis / Root_M as root_motion_bone would freeze hip bob/rotation (and strip Soldier's -90° Root_M yaw).
	pg.configure(&"")
	var loop_flag := eff_loop != Animation.LOOP_NONE
	var mode_str := "ping_pong" if eff_loop == Animation.LOOP_PINGPONG else ("loop" if loop_flag else "single")
	pg.add_state(&"idle", idle_a, true, "loop")
	pg.add_state(&"move", move_a, loop_flag, mode_str)
	pg.add_state(&"action", act_a, false, "single")
	pg.reset(&"move")
	return {
		"pack": pack,
		"actor": outer,
		"inner": pack["root"] as Node3D,
		"skel": skel,
		"player": player,
		"graph": pg,
		"idle": idle_a,
		"move": move_a,
		"action": act_a,
		"move_key": move_key,
		"idle_key": idle_key,
		"char_id": cid,
	}


func _setup_hero_showcase() -> void:
	hero_instance = HeroScene.instantiate()
	# Wrap in an outer Node3D because hero.gd defines static func rotation() shadowing Node3D.rotation
	var align_holder := Node3D.new()
	align_holder.name = "HeroStandardAlign"
	align_holder.rotation.y = PI
	add_child(align_holder)
	align_holder.add_child(hero_instance)
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
	dock_start_pos = Vector3(-0.7, 0.0, 1.35)
	dock_start_yaw = -0.45
	dock_target_yaw = 0.25
	var pack := _spawn_havok_graph_actor("hero", dock_start_pos)
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	actor.rotation.y = dock_start_yaw
	graph = pack["graph"] as PoseGraph

	var target_pos := Vector3(0.45, 0.85 if "hanging" in case_path else 0.0, -1.15)
	target_marker = _make_sphere(0.14, Color("#f2a93b"), target_pos)
	target_marker.add_child(_make_box(Vector3(0.06, 0.04, 0.45), Color("#ffe082"), Vector3(0.0, 0.0, -0.22)))
	target_marker.rotation.y = dock_target_yaw
	add_child(target_marker)
	if "hanging" in case_path:
		add_child(_make_box(Vector3(1.4, 0.12, 0.5), Color("#637d75"), Vector3(0.45, 1.55, -1.25)))
		_attach_actor_ik(actor_skel, true, Vector3(0.45, 1.50, -1.20))

	dock_start_dist = actor.position.distance_to(Vector3(target_pos.x, 0.0, target_pos.z))
	dock_dist = dock_start_dist
	dock_yaw_err_deg = absf(rad_to_deg(angle_difference(dock_start_yaw, dock_target_yaw)))
	dock_rerooted = false


func _setup_quadruped() -> void:
	platform = Node3D.new()
	add_child(platform)
	if "rotatingplatform" in case_path:
		var disc := _make_box(Vector3(4.2, 0.14, 4.2), Color("#647871"), Vector3(0.0, 0.07, 0.0))
		platform.add_child(disc)
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(4.2, 0.14, 4.2)
		cs.shape = bs
		cs.position = Vector3(0.0, 0.07, 0.0)
		sb.add_child(cs)
		platform.add_child(sb)
	else:
		var mound := _make_box(Vector3(3.4, 0.22, 3.0), Color("#6a8076"), Vector3(0.0, 0.10, 0.0))
		mound.rotation.x = deg_to_rad(-6.0)
		platform.add_child(mound)
		var sb := StaticBody3D.new()
		sb.position = mound.position
		sb.rotation = mound.rotation
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(3.4, 0.22, 3.0)
		cs.shape = bs
		sb.add_child(cs)
		platform.add_child(sb)

	# Real 34-bone Havok SiegeFiend quadruped aligned to Godot -Z on the terrain!
	var pack := _spawn_havok_graph_actor("siege_fiend", Vector3(0.0, 0.22, 0.0))
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph
	actor_skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS

	# Bind 4 real TwoBoneIK3D modifiers onto SiegeFiend's actual 4 legs
	var leg_chains := [
		["Bip01 L UpperArm", "Bip01 L Forearm", "Bip01 L Hand", Vector3(-0.42, 0.65, -0.58)],
		["Bip01 R UpperArm", "Bip01 R Forearm", "Bip01 R Hand", Vector3(0.42, 0.65, -0.58)],
		["Bip01 L Thigh", "Bip01 L Calf", "Bip01 L Foot", Vector3(-0.40, 0.65, 0.58)],
		["Bip01 R Thigh", "Bip01 R Calf", "Bip01 R Foot", Vector3(0.40, 0.65, 0.58)],
	]
	legs.clear()
	for i in leg_chains.size():
		var c: Array = leg_chains[i]
		var hip_offset: Vector3 = c[3] as Vector3
		var tgt := Node3D.new()
		tgt.name = "QuadTarget_%d" % i
		tgt.position = Vector3(hip_offset.x, 0.22, hip_offset.z)
		tgt.add_child(_make_sphere(0.075, Color("#f2a93b")))
		add_child(tgt)
		var pole := Node3D.new()
		pole.name = "QuadPole_%d" % i
		pole.position = hip_offset + Vector3(0.0, 0.15, -0.55 if i < 2 else 0.55)
		add_child(pole)
		var ik := TwoBoneIK3D.new()
		ik.name = "QuadTwoBoneIK_%d" % i
		ik.setting_count = 1
		actor_skel.add_child(ik)
		ik.set_root_bone_name(0, str(c[0]))
		ik.set_middle_bone_name(0, str(c[1]))
		ik.set_end_bone_name(0, str(c[2]))
		ik.set_target_node(0, ik.get_path_to(tgt))
		ik.set_pole_node(0, ik.get_path_to(pole))
		ik.active = true
		legs.append({"hip": hip_offset, "rig": actor_skel, "target": tgt, "ik": ik, "phase": float(i) * PI * 0.5})


func _attach_actor_ik(skel: Skeleton3D, is_hand: bool, target_pos: Vector3) -> void:
	ik_rig = skel
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	var r_idx := Standards.find_semantic_bone(skel, "l_upper_arm" if is_hand else "l_thigh")
	var m_idx := Standards.find_semantic_bone(skel, "l_lower_arm" if is_hand else "l_calf")
	var e_idx := Standards.find_semantic_bone(skel, "l_hand" if is_hand else "l_foot")
	ik_end_bone = e_idx
	ik_target = Node3D.new()
	ik_target.name = "IKTarget"
	ik_target.position = target_pos
	ik_target.add_child(_make_sphere(0.09, Color("#f2a93b")))
	add_child(ik_target)
	ik_pole = Node3D.new()
	ik_pole.name = "IKPole"
	ik_pole.position = target_pos + (Vector3(-0.55, 0.0, 0.65) if is_hand else Vector3(0.0, 0.35, -0.75))
	add_child(ik_pole)
	ik_mod = TwoBoneIK3D.new()
	ik_mod.name = "TwoBoneIK"
	ik_mod.setting_count = 1
	skel.add_child(ik_mod)
	ik_mod.set_root_bone_name(0, skel.get_bone_name(r_idx))
	ik_mod.set_middle_bone_name(0, skel.get_bone_name(m_idx))
	ik_mod.set_end_bone_name(0, skel.get_bone_name(e_idx))
	ik_mod.set_target_node(0, ik_mod.get_path_to(ik_target))
	ik_mod.set_pole_node(0, ik_mod.get_path_to(ik_pole))
	ik_mod.active = true


func _setup_driver_ik() -> void:
	if "charactercontroller" in case_path:
		# Solid collision floor at Y = 0.0 so CharacterBody3D never falls under 9.81 m/s² gravity
		var floor_body := StaticBody3D.new()
		floor_body.name = "BehaviorControllerFloor"
		var floor_col := CollisionShape3D.new()
		var floor_box := BoxShape3D.new()
		floor_box.size = Vector3(60.0, 0.4, 60.0)
		floor_col.shape = floor_box
		floor_col.position = Vector3(0.0, -0.2, 0.0)
		floor_body.add_child(floor_col)
		var step_col := CollisionShape3D.new()
		var step_box := BoxShape3D.new()
		step_box.size = Vector3(1.8, 0.14, 1.4)
		step_col.shape = step_box
		step_col.position = Vector3(0.0, 0.07, -1.6)
		floor_body.add_child(step_col)
		add_child(floor_body)

		controller = CharacterBody3D.new()
		controller.name = "BehaviorController"
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.28
		cap.height = 1.72
		cs.shape = cap
		cs.position.y = 0.86
		controller.add_child(cs)
		add_child(controller)
		var pack := _spawn_havok_graph_actor("hero", Vector3.ZERO)
		actor = pack["actor"] as Node3D
		actor_skel = pack["skel"] as Skeleton3D
		graph = pack["graph"] as PoseGraph
		actor.reparent(controller)
		add_child(_make_box(Vector3(1.8, 0.14, 1.4), Color("#6c8078"), Vector3(0.0, 0.07, -1.6)))
	else:
		var is_hand := "handik" in case_path
		var pack := _spawn_havok_graph_actor("hero", Vector3.ZERO)
		actor = pack["actor"] as Node3D
		actor_skel = pack["skel"] as Skeleton3D
		graph = pack["graph"] as PoseGraph
		var init_pos := Vector3(-0.42, 1.25, -0.62) if is_hand else Vector3(-0.18, 0.22, -0.25)
		_attach_actor_ik(actor_skel, is_hand, init_pos)
		if not is_hand:
			add_child(_make_box(Vector3(1.2, 0.18, 0.9), Color("#6c8078"), Vector3(0.0, 0.09, -0.25)))


func _setup_ragdoll_driver() -> void:
	var pack := _spawn_havok_graph_actor(str(_spec.get("primary_char", "soldier")), Vector3(0.0, 0.0, 0.45))
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph

	ragdoll_joints.clear()
	var count := 2 if ("multiple" in case_path or "palette" in case_path) else 1
	for i in count:
		var j := ActiveRagdollJoint.new()
		j.position = Vector3((float(i) - 0.5 * float(count - 1)) * 1.25 + 0.95, 1.35, -0.25)
		add_child(j)
		j.build_rig()
		j.target_angle_rad = deg_to_rad(42.0 if i == 0 else -35.0)
		j.kp = 20.0 if i == 0 else 8.0
		j.kd = 3.5 if i == 0 else 1.6
		j.max_torque = 18.0 if i == 0 else 4.0
		j.anchor.add_child(_make_sphere(0.10, Color("#e8a245")))
		j.limb.add_child(_make_box(Vector3(0.14, 0.90, 0.14), Color("#4bb7aa") if i == 0 else Color("#5398e6")))
		ragdoll_joints.append(j)
	ragdoll_palette = "High-Gain / Low-Gain" if count > 1 else "High-Gain"


func _setup_modifier() -> void:
	var cid := str(_spec.get("primary_char", "hero"))
	var pack := _spawn_havok_graph_actor(cid, Vector3.ZERO)
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph

	if "attachment" in case_path:
		attach_hand_bone = Standards.find_semantic_bone(actor_skel, "r_hand")
		var attach := BoneAttachment3D.new()
		attach.name = "HavokHandAttachment"
		attach.bone_name = actor_skel.get_bone_name(attach_hand_bone)
		actor_skel.add_child(attach)
		if "charactertocharacter" in case_path:
			var sub_id := str(_spec.get("secondary_char", "hivequeen"))
			var sub := _spawn_havok_graph_actor(sub_id, Vector3.ZERO)
			actor_b = sub["actor"] as Node3D
			actor_b_skel = sub["skel"] as Skeleton3D
			graph_b = sub["graph"] as PoseGraph
			actor_b.reparent(attach)
			actor_b.position = Vector3.ZERO
			attached_obj = actor_b
		else:
			attached_obj = _make_box(Vector3(0.20, 0.20, 0.20), Color("#f2a93b"))
			attach.add_child(attached_obj)
	else:
		look_target = Node3D.new()
		look_target.name = "LookTarget"
		look_target.position = Vector3(0.4, 1.48, -1.6)
		look_target.add_child(_make_sphere(0.12, Color("#f2a93b")))
		add_child(look_target)

		var head_idx := Standards.find_semantic_bone(actor_skel, "head")
		look_at_mod = LookAtModifier3D.new()
		look_at_mod.name = "LookAtMod"
		look_at_mod.bone = head_idx
		look_at_mod.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_X if cid == "soldier" else SkeletonModifier3D.BONE_AXIS_PLUS_Z
		look_at_mod.primary_rotation_axis = Vector3.AXIS_Y
		look_at_mod.use_secondary_rotation = true
		actor_skel.add_child(look_at_mod)
		look_at_mod.target_node = look_at_mod.get_path_to(look_target)
		look_at_mod.active = true
		actor_skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE


func _setup_retargeting() -> void:
	var src_id := str(_spec.get("primary_char", "boy"))
	var dst_id := str(_spec.get("secondary_char", "girl"))
	if dst_id.is_empty():
		dst_id = "male_nocape"
	_retarget_src_pack = Standards.spawn_aligned_character(src_id, "BehRetargetSrc", Animation.LOOP_LINEAR)
	_retarget_dst_pack = Standards.spawn_aligned_character(dst_id, "BehRetargetDst", Animation.LOOP_LINEAR)
	(_retarget_src_pack["outer"] as Node3D).position = Vector3(-0.90, 0.0, 0.0)
	(_retarget_dst_pack["outer"] as Node3D).position = Vector3(0.90, 0.0, 0.0)
	add_child(_retarget_src_pack["outer"] as Node3D)
	add_child(_retarget_dst_pack["outer"] as Node3D)

	var src_player: AnimationPlayer = _retarget_src_pack["player"] as AnimationPlayer
	src_player.play(StringName(Standards.pick_clip(_retarget_src_pack, str(_spec.get("primary_clip", "walk")))))
	(_retarget_dst_pack["player"] as AnimationPlayer).active = false
	_retarget_pairs = Standards.build_semantic_retarget_pairs(_retarget_src_pack["skeleton"] as Skeleton3D, _retarget_dst_pack["skeleton"] as Skeleton3D)

	retarget_source = _build_humanoid_proxy("SourceHumanoid")
	retarget_target = _build_humanoid_proxy("TargetHumanoid")
	retarget_mod = RetargetModifier3D.new()
	retarget_mod.profile = SkeletonProfileHumanoid.new()
	retarget_source.add_child(retarget_mod)
	retarget_target.reparent(retarget_mod)


func _build_humanoid_proxy(n: String) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = n
	add_child(skel)
	var names := ["Hips", "Spine", "LeftUpperArm", "LeftLowerArm"]
	for i in names.size():
		skel.add_bone(names[i])
		if i > 0:
			skel.set_bone_parent(i, i - 1)
			skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.35, 0.0)))
	skel.reset_bone_poses()
	return skel


func _setup_moving_platform() -> void:
	platform = Node3D.new()
	add_child(platform)
	platform.add_child(_make_box(Vector3(2.8, 0.16, 2.2), Color("#637d75"), Vector3(0.0, 0.08, 0.0)))
	var pack := _spawn_havok_graph_actor("hero", Vector3(0.0, 0.16, 0.0))
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph
	actor.reparent(platform)


func _setup_save_state() -> void:
	var pack := _spawn_havok_graph_actor(str(_spec.get("primary_char", "soldier")), Vector3.ZERO)
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph
	recorder = RewindRecorder.new(60)
	recorder.attach(actor_skel, actor)


func _setup_partial_stagger() -> void:
	var cid := "hero" if "partialanimation" in case_path else "soldier"
	var pack := _spawn_havok_graph_actor(cid, Vector3.ZERO)
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph
	action_anim = pack["action"] as Animation
	var spine_idx := Standards.find_semantic_bone(actor_skel, "spine")
	upper_mask = PoseBuffer.build_branch_mask(actor_skel, StringName(actor_skel.get_bone_name(spine_idx)))
	graph.play_slot(&"stagger" if "stagger" in case_path else &"partial", action_anim, upper_mask, 0.06, 0.10)


func _setup_determinism() -> void:
	var p1 := _spawn_havok_graph_actor("hero", Vector3(-0.75, 0.0, 0.0))
	var p2 := _spawn_havok_graph_actor("hero", Vector3(0.75, 0.0, 0.0))
	actor = p1["actor"] as Node3D
	actor_skel = p1["skel"] as Skeleton3D
	graph = p1["graph"] as PoseGraph
	actor_b = p2["actor"] as Node3D
	actor_b_skel = p2["skel"] as Skeleton3D
	graph_b = p2["graph"] as PoseGraph


func _setup_swap_skins() -> void:
	var pack := _spawn_havok_graph_actor("firefighter", Vector3.ZERO)
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph
	active_skin_id = "firefighter"
	skin_swaps = 0


func _setup_crowd() -> void:
	crowd_skels.clear()
	var cid := str(_spec.get("primary_char", "orc_captain"))
	var template := Standards.spawn_aligned_character(cid, "CrowdTemplate", Animation.LOOP_LINEAR)
	var tpl_skel: Skeleton3D = template["skeleton"] as Skeleton3D
	var tpl_lib: AnimationLibrary = template["library"] as AnimationLibrary
	var clip_key := Standards.pick_clip(template, str(_spec.get("primary_clip", "run")))
	var anim: Animation = tpl_lib.get_animation(clip_key)
	var qclip := CrowdEvaluator.QuantizedClip.bake_from_animation(anim, tpl_skel, 60.0)
	(template["outer"] as Node3D).free()

	for i in crowd_count:
		var row := i / 4
		var col := i % 4
		var spawn_id := cid
		if cid == "orc_captain" and i % 2 == 1:
			# Mix orc_grunt? No, orc_captain & orc_grunt share 73-bone rig; use same skeleton layout cleanly
			spawn_id = "orc_captain"
		var ch_pack := Standards.spawn_aligned_character(spawn_id, "Crowd_%d" % i, Animation.LOOP_LINEAR)
		var outer: Node3D = ch_pack["outer"] as Node3D
		outer.position = Vector3((float(col) - 1.5) * 1.35, 0.0, (float(row) - 1.5) * 1.35)
		add_child(outer)
		(ch_pack["player"] as AnimationPlayer).active = false
		crowd_skels.append(ch_pack["skeleton"] as Skeleton3D)

	crowd_evaluator = CrowdEvaluator.new()
	crowd_evaluator.setup(qclip, crowd_count, true)
	crowd_using_native = crowd_evaluator.is_using_native()


func _setup_generator() -> void:
	var cid := str(_spec.get("primary_char", "soldier"))
	var pack := _spawn_havok_graph_actor(cid, Vector3.ZERO)
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	actor_player = pack["player"] as AnimationPlayer
	graph = pack["graph"] as PoseGraph
	idle_anim = pack["idle"] as Animation
	move_anim = pack["move"] as Animation
	action_anim = pack["action"] as Animation
	ping_pong_reversals = 0
	last_pp_dir = 1.0

	var lmode := int(_spec.get("loop_mode", Animation.LOOP_LINEAR))
	if "blender" in case_path:
		generator_mode = "blender_tree"
		var inner: Node3D = pack["inner"] as Node3D
		actor_player.active = true
		var tree_root := AnimationNodeBlendTree.new()
		var n_a := AnimationNodeAnimation.new()
		n_a.animation = StringName(str(pack["idle_key"]))
		var n_b := AnimationNodeAnimation.new()
		n_b.animation = StringName(str(pack["move_key"]))
		var blend := AnimationNodeBlend2.new()
		tree_root.add_node(&"A", n_a)
		tree_root.add_node(&"B", n_b)
		tree_root.add_node(&"Mix", blend)
		tree_root.connect_node(&"Mix", 0, &"A")
		tree_root.connect_node(&"Mix", 1, &"B")
		tree_root.connect_node(&"output", 0, &"Mix")
		blend_tree_node = AnimationTree.new()
		blend_tree_node.tree_root = tree_root
		inner.add_child(blend_tree_node)
		blend_tree_node.anim_player = ^"../AnimationPlayer"
		blend_tree_node.root_node = ^".."
		blend_tree_node.active = true
	elif lmode == Animation.LOOP_PINGPONG or "pingpong" in case_path:
		generator_mode = "ping_pong"
		graph.add_state(&"pp", action_anim, true, "ping_pong", 2.0)
		graph.reset(&"pp")
	elif lmode == Animation.LOOP_NONE:
		generator_mode = "single_play"
		graph.add_state(&"single", move_anim, false, "single", 1.0)
		graph.reset(&"single")
	elif "enforcedduration" in case_path or "speed" in case_path:
		generator_mode = "enforced_duration"
		graph.add_state(&"enforced", move_anim, true, "loop", 1.0, 0.5)
		graph.reset(&"enforced")
	elif "referencepose" in case_path:
		generator_mode = "reference_pose"
		actor_skel.reset_bone_poses()
		if cid == "soldier":
			# Soldier GLB bind pose faces +Z (whereas animation tracks rotate Root_M to Maya +X).
			# Align inner yaw to PI so ReferencePose faces Godot -Z identically to Havok ReferencePoseGenerator.
			var inner_ref: Node3D = pack["inner"] as Node3D
			if inner_ref != null:
				inner_ref.rotation.y = PI
		actor_skel.force_update_all_bone_transforms()
	elif "manualselector" in case_path:
		generator_mode = "manual_selector"
		graph.reset(&"idle")
	else:
		generator_mode = "clip_modes"
		graph.reset(&"move")


func _setup_state_machine() -> void:
	var cid := str(_spec.get("primary_char", "soldier"))
	var pack := _spawn_havok_graph_actor(cid, Vector3.ZERO)
	actor = pack["actor"] as Node3D
	actor_skel = pack["skel"] as Skeleton3D
	graph = pack["graph"] as PoseGraph
	action_anim = pack["action"] as Animation
	var spine_idx := Standards.find_semantic_bone(actor_skel, "spine")
	upper_mask = PoseBuffer.build_branch_mask(actor_skel, StringName(actor_skel.get_bone_name(spine_idx)))
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
				target_marker.position = Vector3(0.45 + sin(elapsed * 0.9) * 0.30, 0.0, -1.15 + cos(elapsed * 0.9) * 0.35)
			elif "multipletargets" in case_path and ticks % 60 == 0:
				target_marker.position.x = -target_marker.position.x
			dock_progress = clampf(elapsed / 0.8, 0.0, 1.0)
			var u := lerpf(dock_progress, dock_progress * dock_progress * (3.0 - 2.0 * dock_progress), 0.35)
			var goal := Vector3(target_marker.position.x, 0.0, target_marker.position.z)
			actor.position = dock_start_pos.lerp(goal, u)
			actor.rotation.y = lerp_angle(dock_start_yaw, dock_target_yaw, u)
			dock_dist = actor.position.distance_to(goal)
			dock_yaw_err_deg = absf(rad_to_deg(angle_difference(actor.rotation.y, dock_target_yaw)))
			if "rerooting" in case_path and dock_progress >= 0.99 and not dock_rerooted:
				dock_rerooted = true
			graph.evaluate(delta, actor_skel)
			actor_skel.force_update_all_bone_transforms()
		"quadruped_ik":
			if "rotatingplatform" in case_path:
				platform_angle += delta * 0.9
				platform.rotation.y = platform_angle
			graph.evaluate(delta, actor_skel)
			var space := get_world_3d().direct_space_state
			foot_hits = 0
			for leg in legs:
				var hip: Vector3 = leg["hip"] as Vector3
				var lift := maxf(0.0, sin(elapsed * 5.0 + float(leg["phase"]))) * 0.14
				var q := PhysicsRayQueryParameters3D.create(hip + Vector3.UP * 0.6, hip + Vector3.DOWN * 1.4)
				var hit := space.intersect_ray(q)
				var gy := 0.0
				if not hit.is_empty():
					foot_hits += 1
					gy = (hit["position"] as Vector3).y
				(leg["target"] as Node3D).position = Vector3(hip.x, gy + 0.06 + lift, hip.z)
			actor_skel.force_update_all_bone_transforms()
		"driver_ik":
			if controller != null:
				if controller.is_on_floor():
					controller.velocity.y = 0.0
					if "jump" in case_variant.to_lower() and ticks > 0 and ticks % 75 == 30:
						controller.velocity.y = 4.2
				controller.velocity = Vector3(0.0, controller.velocity.y - Standards.GRAVITY_MPS2 * delta, -1.15)
				controller.move_and_slide()
				traveled = controller.position.length()
				graph.evaluate(delta, actor_skel)
				actor_skel.force_update_all_bone_transforms()
			elif ik_target != null and ik_rig != null:
				graph.evaluate(delta, actor_skel)
				var is_hand := "handik" in case_path
				ik_target.position = Vector3(
					-0.40 + sin(elapsed * 2.2) * 0.18 if is_hand else -0.18,
					(1.22 if is_hand else 0.22) + cos(elapsed * 2.2) * 0.12,
					(-0.62 if is_hand else -0.25) + sin(elapsed * 1.6) * 0.14
				)
				actor_skel.force_update_all_bone_transforms()
				if ik_end_bone >= 0:
					var end_pos := actor_skel.to_global(actor_skel.get_bone_global_pose(ik_end_bone).origin)
					hand_err_m = end_pos.distance_to(ik_target.global_position)
		"ragdoll_driver":
			graph.evaluate(delta, actor_skel)
			actor_skel.force_update_all_bone_transforms()
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
			graph.evaluate(delta, actor_skel)
			if look_target != null:
				look_target.position = Vector3(sin(elapsed * 1.8) * 1.05, 1.48 + sin(elapsed * 2.0) * 0.22, -1.6)
				aim_yaw_deg = rad_to_deg(atan2(look_target.position.x, -look_target.position.z))
			actor_skel.force_update_all_bone_transforms()
			if actor_b != null and graph_b != null and actor_b_skel != null:
				graph_b.evaluate(delta, actor_b_skel)
				actor_b_skel.force_update_all_bone_transforms()
			if attached_obj != null and attach_hand_bone >= 0:
				var expected := actor_skel.to_global(actor_skel.get_bone_global_pose(attach_hand_bone).origin)
				attach_err_mm = attached_obj.global_position.distance_to(expected) * 1000.0
		"retargeting":
			if not _retarget_src_pack.is_empty() and not _retarget_dst_pack.is_empty():
				var s_skel: Skeleton3D = _retarget_src_pack["skeleton"] as Skeleton3D
				var d_skel: Skeleton3D = _retarget_dst_pack["skeleton"] as Skeleton3D
				Standards.apply_semantic_retarget(s_skel, d_skel, _retarget_pairs, 1.0, float(_retarget_src_pack.get("align_yaw", PI)), float(_retarget_dst_pack.get("align_yaw", PI)))
				d_skel.force_update_all_bone_transforms()
			var a := sin(elapsed * 3.0) * 0.55
			retarget_source.set_bone_pose_rotation(2, Quaternion(Vector3.FORWARD, a))
			retarget_source.force_update_all_bone_transforms()
		"moving_platform":
			platform_angle += delta * 0.7
			platform.position = Vector3(sin(elapsed * 1.2) * 0.8, 0.0, cos(elapsed * 1.2) * 0.4)
			platform.rotation.y = platform_angle
			graph.evaluate(delta, actor_skel)
			actor_skel.force_update_all_bone_transforms()
		"save_state":
			var snap := graph.evaluate(delta, actor_skel)
			recorder.queue_metadata(snap)
			actor_skel.force_update_all_bone_transforms()
			if recorder.get_total_recorded() < ticks:
				recorder._on_skeleton_updated()
			if ticks == 2 and recorder.get_frame_count() >= 1:
				var saved: Dictionary = recorder.get_frame(0)
				var expected: PoseBuffer = saved["pose"] as PoseBuffer
				recorder.apply_frame(0, actor_skel, actor)
				var restored := PoseBuffer.capture_from_skeleton(actor_skel)
				restore_err_rad = restored.max_diff(expected).max_rot_rad
		"partial_stagger":
			if not graph.is_slot_active() and ticks % 45 == 0:
				graph.play_slot(&"stagger", action_anim, upper_mask, 0.06, 0.10)
			graph.evaluate(delta, actor_skel)
			actor_skel.force_update_all_bone_transforms()
		"determinism":
			if ticks == 2:
				graph.transition_to(&"idle", 0.2)
				graph_b.transition_to(&"idle", 0.2)
			graph.evaluate(delta, actor_skel)
			graph_b.evaluate(delta, actor_b_skel)
			var p1 := PoseBuffer.capture_from_skeleton(actor_skel)
			var p2 := PoseBuffer.capture_from_skeleton(actor_b_skel)
			determinism_diff_rad = p1.max_diff(p2).max_rot_rad
			actor_skel.force_update_all_bone_transforms()
			actor_b_skel.force_update_all_bone_transforms()
		"swap_skins":
			graph.evaluate(delta, actor_skel)
			actor_skel.force_update_all_bone_transforms()
			if ticks == 1 or ticks % 45 == 0:
				skin_swaps += 1
				var next_id: String = str(FIREFIGHTER_SKIN_ROSTER[skin_swaps % FIREFIGHTER_SKIN_ROSTER.size()])
				for child in actor_skel.get_children():
					if child is MeshInstance3D:
						actor_skel.remove_child(child)
						child.queue_free()
				Store.attach_skin_to_skeleton(next_id, actor_skel)
				active_skin_id = next_id
		"crowd":
			var st := crowd_evaluator.step_parallel(delta, crowd_skels)
			crowd_main_ms = float(st.get("main_total_ms", 0.0))
			for sk in crowd_skels:
				sk.force_update_all_bone_transforms()
		"generator":
			if generator_mode == "blender_tree" and blend_tree_node != null:
				blend_tree_node.set("parameters/Mix/blend_amount", 0.5 + 0.5 * sin(elapsed * 2.0))
			elif generator_mode == "reference_pose":
				actor_skel.reset_bone_poses()
				actor_skel.force_update_all_bone_transforms()
			else:
				if generator_mode == "manual_selector" and (ticks == 1 or ticks % 30 == 0):
					graph.transition_to(&"move" if graph.get_current_state() == &"idle" else &"idle", 0.12)
				var snap := graph.evaluate(delta, actor_skel)
				var d := float(snap.get("ping_pong_dir", 1.0))
				if d != last_pp_dir:
					ping_pong_reversals += 1
					last_pp_dir = d
				actor_skel.force_update_all_bone_transforms()
		"state_machine":
			if "synchronized" in case_path or "syncpoints" in case_path:
				if ticks == 1:
					var before_norm := float(graph.last_snapshot.get("normalized_time", 0.0))
					if graph.transition_to(&"move", 0.18, true):
						state_transitions += 1
					var snap := graph.evaluate(delta, actor_skel)
					sync_phase_err = absf(float(snap.get("normalized_time", 0.0)) - before_norm)
					last_state = str(snap.get("state", ""))
					actor_skel.force_update_all_bone_transforms()
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
			var snap := graph.evaluate(delta, actor_skel)
			last_state = str(snap.get("state", ""))
			actor_skel.force_update_all_bone_transforms()


func status_text() -> String:
	var cid := str(_spec.get("primary_char", "soldier"))
	match family:
		"hero_showcase":
			return "Behavior Hero 원본 쇼케이스 [hero 85b · -Z 표준 정렬] · 18,050정점 스킨 메시 실행 중"
		"docking":
			return "Behavior 도킹 워핑 [hero 85b] · 거리 %.3f m (시작 %.2f m) · Yaw 오차 %.1f° · 진행 %.0f%%" % [
				dock_dist, dock_start_dist, dock_yaw_err_deg, dock_progress * 100.0]
		"quadruped_ik":
			return "Behavior 4족 TwoBoneIK3D [siege_fiend 34b] · 접지 %d/4 · 플랫폼 %.1f°" % [foot_hits, rad_to_deg(platform_angle)]
		"driver_ik":
			if controller != null:
				return "Behavior CharacterBody3D [hero 85b · -Z 보행 · g=9.81 m/s²] · 이동 %.2f m" % traveled
			return "Behavior TwoBoneIK3D [hero 85b] · 목표 거리 %.3f m" % hand_err_m
		"ragdoll_driver":
			return "Behavior 능동 랙돌 [%s %s] · 관절 %.1f° · 토크 %.2f N·m" % [cid, ragdoll_palette, ragdoll_angle_deg, ragdoll_torque]
		"modifier":
			if attached_obj != null:
				return "Behavior BoneAttachment3D [%s] · 소켓 오차 %.3f mm" % [cid, attach_err_mm]
			return "Behavior LookAtModifier3D [%s] · 목표 Yaw %.1f°" % [cid, aim_yaw_deg]
		"retargeting":
			return "Behavior RetargetModifier3D [%s -> %s] · %d본 리타게팅 활성" % [
				cid, str(_spec.get("secondary_char", "girl")), _retarget_pairs.size()]
		"moving_platform":
			return "Behavior 이동 플랫폼 [hero 85b] · 회전 %.1f° · 위치 (%.2f, %.2f)" % [rad_to_deg(platform_angle), platform.position.x, platform.position.z]
		"save_state":
			return "Behavior 상태 저장·복원 [%s] · 버퍼 %d틱 · 복원 오차 %.5f rad" % [cid, recorder.get_frame_count(), restore_err_rad]
		"partial_stagger":
			var w: float = float(graph.last_snapshot.get("slot_weight", 0.0))
			return "Behavior 상체 마스크/충격 반응 [%s] · 슬롯 가중치 %.0f%%" % [cid, w * 100.0]
		"determinism":
			return "Behavior 결정성 대조 [hero 85b ×2] · 최대 차이 %.6f rad" % determinism_diff_rad
		"swap_skins":
			return "Behavior 런타임 GLB 스킨 교체 [38b 공용 리그 -> %s] · 교체 %d회" % [active_skin_id, skin_swaps]
		"crowd":
			return "Behavior %s 군중 평가 [%s ×%d] · %.3f ms" % [
				"C++ GDExtension" if crowd_using_native else "GDScript", cid, crowd_count, crowd_main_ms]
		"generator":
			return "Behavior 생성기 [%s · %s] · 상태 %s · 반전 %d회" % [
				cid, generator_mode, str(graph.last_snapshot.get("state", "ref")), ping_pong_reversals]
		_:
			return "Behavior 상태 머신 [%s] · 상태 %s · 전이 %d회 · 복귀=%s · 위상차 %.4f" % [
				cid, last_state if not last_state.is_empty() else "idle",
				state_transitions, str(returned_to_prev), sync_phase_err]
