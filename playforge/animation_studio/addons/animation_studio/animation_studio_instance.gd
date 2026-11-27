@tool
class_name AnimationStudioInstance
extends Node3D
## Standard @tool 3D scene component placed directly inside Godot's native 3D Viewport.
## Connects any placed character instance (Hero Arena + 10 Lua scripts, 28-bone Quadruped
## Procedural Locomotor, or any of the 28 internalized Havok characters) to the standard
## Animation Studio Editor docks (Hierarchy, State & Parameters, and Animation Flow).

const Store := preload("res://characters/character_store.gd")
const CrowdEval := preload("res://addons/animation_studio/crowd_evaluator.gd")
const ControllerScript := preload("res://hero/arena/hero_lua_controller.gd")
const LinesScript := preload("res://hero/arena/hero_lua_lines.gd")
const SpatialScript := preload("res://hero/ai/hero_spatial_analysis.gd")
const PathfinderScript := preload("res://hero/ai/hero_ai_pathfinder.gd")
const AiDriverScript := preload("res://hero/ai/hero_ai_behavior_driver.gd")
const QuadRigScript := preload("res://quadruped/quadruped_rig.gd")
const QuadLocomotorScript := preload("res://quadruped/quadruped_locomotor.gd")

const HERO_ARENA_MOTION_RES := "res://hero/assets/hero_arena_motion.res"
const HERO_SKIN_GLB := "res://hero/assets/hero_skin.glb"

@export_enum("hero_arena", "quadruped", "character") var role: String = "character":
	set(v):
		if role != v:
			role = v
			if is_inside_tree():
				rebuild_instance()

@export var character_id: String = "soldier":
	set(v):
		if character_id != v:
			character_id = v
			if is_inside_tree() and role == "character":
				rebuild_instance()

@export var playing: bool = true
@export var auto_demo: bool = true
@export var ai_driven: bool = false
@export var use_quantized_16bit: bool = false
@export_range(0.1, 2.0, 0.05) var playback_speed: float = 1.0

var runtime_root: Node3D = null
var skeleton: Skeleton3D = null
var player: AnimationPlayer = null
var library: AnimationLibrary = null
var motion_dict: Dictionary = {}
var skin_stats: Dictionary = {}

# Role: hero_arena
var hero_ctrl: ControllerScript = null
var _hero_tour_clock: float = 0.0
var _hero_tour_step: int = -1
var _hero_last_clip: String = ""
var _hero_last_driven_pos: Vector3 = Vector3.ZERO
var _hero_has_driven: bool = false
var ai_spatial: SpatialScript = null
var ai_pathfinder: PathfinderScript = null
var ai_driver: AiDriverScript = null
var _ai_overlay_root: Node3D = null
var _ai_annot_mi: MeshInstance3D = null
var _ai_path_mi: MeshInstance3D = null

# Role: quadruped
var quad_actor_root: Node3D = null
var quad_bone_ids: Dictionary = {}
var quad_locomotor = null
var quad_speed: float = 2.6
var quad_gait: String = "auto"
var _quad_orbit_angle: float = 0.0
var _quad_last_snap: Dictionary = {}

# Role: character (28 roster)
var active_clip: String = ""
var clip_duration: float = 1.0
var play_time: float = 0.0
var quantized_clips: Dictionary = {}
var _ref_skeleton: Skeleton3D = null
var _last_compare_metrics: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		set_meta("_edit_group_", true)
	rebuild_instance()


func rebuild_instance() -> void:
	if is_instance_valid(runtime_root):
		runtime_root.queue_free()
	runtime_root = Node3D.new()
	runtime_root.name = "_RuntimeActor"
	add_child(runtime_root)

	skeleton = null
	player = null
	library = null
	motion_dict.clear()
	quantized_clips.clear()
	hero_ctrl = null
	ai_spatial = null
	ai_pathfinder = null
	ai_driver = null
	if is_instance_valid(_ai_overlay_root):
		_ai_overlay_root.queue_free()
	_ai_overlay_root = null
	_ai_annot_mi = null
	_ai_path_mi = null
	quad_actor_root = null
	quad_bone_ids.clear()
	quad_locomotor = null
	_quad_last_snap.clear()
	_ref_skeleton = null
	_hero_last_clip = ""
	_hero_has_driven = false

	match role:
		"hero_arena":
			_build_hero_arena()
		"quadruped":
			_build_quadruped()
		_:
			_build_roster_character()

	_add_selection_proxy()


func _add_selection_proxy() -> void:
	# Provides reliable click-selection inside Godot's standard 3D Viewport
	var sb := StaticBody3D.new()
	sb.name = "_ViewportPickProxy"
	sb.collision_layer = 0
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.45
	cap.height = 1.85
	col.shape = cap
	col.position = Vector3(0.0, 0.95, 0.0)
	sb.add_child(col)
	runtime_root.add_child(sb)


func _build_hero_arena() -> void:
	if not FileAccess.file_exists(HERO_ARENA_MOTION_RES):
		return
	var res = ResourceLoader.load(HERO_ARENA_MOTION_RES)
	if res == null or not res.has_method("to_motion_dict"):
		return
	motion_dict = res.call("to_motion_dict")

	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	runtime_root.add_child(skeleton)
	Store.populate_skeleton(skeleton, motion_dict)
	skin_stats = _attach_glb_skin(HERO_SKIN_GLB, skeleton)

	library = AnimationLibrary.new()
	var clips_dict: Dictionary = motion_dict.get("clips", {})
	for ck in clips_dict.keys():
		library.add_animation(str(ck), Store.build_animation_from_clip(motion_dict, str(ck), "Skeleton3D"))

	player = AnimationPlayer.new()
	player.name = "AnimationPlayer"
	runtime_root.add_child(player)
	player.add_animation_library("", library)
	player.root_node = player.get_path_to(runtime_root)

	hero_ctrl = ControllerScript.new()
	hero_ctrl.init_world()
	hero_ctrl.teleport_hero(global_position, rotation.y)
	_hero_last_driven_pos = hero_ctrl.hero_pos
	_hero_has_driven = true
	_hero_tour_clock = 0.0
	_hero_tour_step = -1
	active_clip = "idle"
	clip_duration = 2.833


func _build_quadruped() -> void:
	quad_actor_root = Node3D.new()
	quad_actor_root.name = "QuadrupedActor"
	runtime_root.add_child(quad_actor_root)

	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	quad_actor_root.add_child(skeleton)
	quad_bone_ids = QuadRigScript.build_skeleton(skeleton)
	var visual_nodes: Array[Node3D] = QuadRigScript.build_visual_body(skeleton)

	quad_locomotor = QuadLocomotorScript.new()
	quad_locomotor.enable_terrain_ik = false
	quad_locomotor.forced_gait = quad_gait
	quad_locomotor.setup(skeleton, quad_actor_root, quad_bone_ids)
	_quad_orbit_angle = 0.0
	_quad_last_snap = quad_locomotor.step(Vector3(0.0, 0.0, -1.0), 0.0, 1.0 / 60.0, 5)
	skin_stats = {"meshes": visual_nodes.size(), "bones": skeleton.get_bone_count()}
	active_clip = "procedural_locomotor"
	clip_duration = 2.0


func _build_roster_character() -> void:
	var rig := Store.build_rig(character_id, "RosterActor")
	if rig.is_empty():
		return
	runtime_root.add_child(rig["root"])
	skeleton = rig["skeleton"]
	player = rig["player"]
	library = rig["library"]
	motion_dict = rig["data"]
	skin_stats = rig["skin_info"]

	_ref_skeleton = Skeleton3D.new()
	_ref_skeleton.name = "_RefCompareSkeleton"
	_ref_skeleton.visible = false
	runtime_root.add_child(_ref_skeleton)
	Store.populate_skeleton(_ref_skeleton, motion_dict)

	var clips: Array = rig["clips"]
	if not clips.is_empty():
		select_clip(str(clips[0]))


func _attach_glb_skin(glb_path: String, rig: Skeleton3D) -> Dictionary:
	var out := {"meshes": 0, "vertices": 0}
	if not FileAccess.file_exists(glb_path):
		return out
	var bytes := FileAccess.get_file_as_bytes(glb_path)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.use_named_skin_binds = true
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if doc.append_from_buffer(bytes, "", st) != OK:
		return out
	var scene := doc.generate_scene(st)
	if scene == null:
		return out
	var mesh_nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	mesh_nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))
	var fallback_skels := scene.find_children("*", "Skeleton3D", true, false)
	var fallback_rig: Skeleton3D = fallback_skels[0] as Skeleton3D if not fallback_skels.is_empty() else null
	for src in mesh_nodes:
		var src_mesh: Mesh = null
		var src_skin: Skin = null
		var src_skel_path := NodePath()
		if src is MeshInstance3D:
			src_mesh = src.mesh
			src_skin = src.skin
			src_skel_path = src.skeleton
		elif src.is_class("ImporterMeshInstance3D"):
			var imp = src.get("mesh")
			if imp != null and imp.has_method("get_mesh"):
				src_mesh = imp.call("get_mesh")
			src_skin = src.get("skin") as Skin
			src_skel_path = src.get("skeleton_path") as NodePath
		if src_mesh == null or src_skin == null:
			continue
		var src_rig := src.get_node_or_null(src_skel_path) as Skeleton3D
		if src_rig == null:
			src_rig = fallback_rig
		var skin := src_skin.duplicate() as Skin
		var valid := true
		for i in skin.get_bind_count():
			var bname := skin.get_bind_name(i)
			if bname.is_empty() and src_rig != null:
				bname = src_rig.get_bone_name(skin.get_bind_bone(i))
			var bidx := rig.find_bone(bname)
			if bidx < 0:
				valid = false
				break
			skin.set_bind_name(i, bname)
			skin.set_bind_bone(i, bidx)
		if not valid:
			continue
		var vis := MeshInstance3D.new()
		vis.name = src.name
		vis.mesh = src_mesh
		vis.skin = skin
		vis.skeleton = ^".."
		vis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		rig.add_child(vis)
		out["meshes"] = int(out["meshes"]) + 1
		for s in src_mesh.get_surface_count():
			out["vertices"] = int(out["vertices"]) + src_mesh.surface_get_array_len(s)
	scene.free()
	return out


func _raycast_world(from_p: Vector3, to_p: Vector3) -> Dictionary:
	var w := get_world_3d()
	if w == null or w.direct_space_state == null:
		return {"hit": false}
	var res := w.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from_p, to_p))
	if res.is_empty():
		return {"hit": false}
	var p: Vector3 = res["position"]
	return {
		"hit": true,
		"position": p,
		"normal": res["normal"],
		"fraction": from_p.distance_to(p) / maxf(1e-5, from_p.distance_to(to_p)),
	}


func _find_env_node() -> Node:
	var root_n := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	if root_n == null:
		return null
	for c in root_n.find_children("*", "", true, false):
		if c.has_method("refresh_docking_lines"):
			return c
	return null


func _process(delta: float) -> void:
	if not visible or not playing:
		return
	var dt := clampf(delta * playback_speed, 0.001, 0.05)
	step_once(dt)


func step_once(dt: float) -> void:
	match role:
		"hero_arena":
			_step_hero_arena(dt)
		"quadruped":
			_step_quadruped(dt)
		_:
			_step_roster_character(dt)


func _step_hero_arena(dt: float) -> void:
	if hero_ctrl == null or skeleton == null or player == null:
		return
	# Respect manual 3D Viewport gizmo drags by syncing hero_ctrl to user-moved position
	if _hero_has_driven and global_position.distance_to(_hero_last_driven_pos) > 0.05:
		hero_ctrl.teleport_hero(global_position, rotation.y)
		_hero_last_driven_pos = hero_ctrl.hero_pos

	if ai_driven:
		_ensure_ai_stack()
		ai_driver.step(dt, skeleton, _raycast_world)
		if ai_driver.path_dirty:
			ai_driver.path_dirty = false
			_refresh_ai_overlays()
	else:
		if auto_demo:
			_hero_tour_clock += dt
			var phase := int(floor(fmod(_hero_tour_clock, 24.0) / 4.0))
			if phase != _hero_tour_step:
				_hero_tour_step = phase
				match phase:
					0: trigger_hero_scenario("locomotion")
					1: raise_hero_event("Attack")
					2: trigger_hero_scenario("cover")
					3: trigger_hero_scenario("vault")
					4: trigger_hero_scenario("climb")
					5: trigger_hero_scenario("leap")
			if phase == 0 and str(hero_ctrl.state["active_state"]) in ["Idle", "Run"]:
				hero_ctrl.gamepad.set_raw_input(0.0, 0.85, 0.0, 0.0, 0.0)
			elif phase == 2 and str(hero_ctrl.state["active_state"]) == "Cover":
				hero_ctrl.gamepad.set_raw_input(0.85, 0.0, 0.0, 0.0, 0.0)
			elif phase == 4 and str(hero_ctrl.state["active_state"]) == "Hanging":
				if fmod(_hero_tour_clock, 4.0) > 2.2:
					hero_ctrl.gamepad.set_raw_input(0.0, 0.95, 0.0, 0.0, 0.0)
				else:
					hero_ctrl.gamepad.set_raw_input(0.85, 0.0, 0.0, 0.0, 0.0)
			else:
				hero_ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
		hero_ctrl.step(dt, skeleton, _raycast_world)

	global_position = hero_ctrl.hero_pos
	rotation = Vector3(0.0, hero_ctrl.hero_yaw, 0.0)
	_hero_last_driven_pos = global_position
	_hero_has_driven = true

	var cname: String = str(hero_ctrl.state["active_clip"])
	active_clip = cname
	if cname != _hero_last_clip:
		if player.has_animation(cname):
			player.play(cname, 0.14)
			clip_duration = maxf(0.1, library.get_animation(cname).length)
		_hero_last_clip = cname
	if player.is_playing():
		player.advance(dt)
		play_time = player.current_animation_position

	var env_n := _find_env_node()
	if env_n != null:
		env_n.call("refresh_docking_lines", int(hero_ctrl.line_world.docking_target.get("index", -1)))


func _step_quadruped(dt: float) -> void:
	if quad_locomotor == null or quad_actor_root == null:
		return
	quad_locomotor.forced_gait = quad_gait
	var spd := quad_speed if auto_demo else 0.0
	var radius := 0.85
	if spd > 0.05:
		_quad_orbit_angle = wrapf(_quad_orbit_angle + dt * (spd / radius), -PI, PI)
	var target_local := Vector3(cos(_quad_orbit_angle) * radius, 0.0, sin(_quad_orbit_angle) * radius)
	var to_target := target_local - quad_actor_root.position
	to_target.y = 0.0
	var desired_dir := to_target.normalized() if to_target.length() > 0.05 else Vector3(-sin(_quad_orbit_angle), 0.0, cos(_quad_orbit_angle))
	_quad_last_snap = quad_locomotor.step(desired_dir, spd, dt, 5)
	play_time = float(_quad_last_snap.get("cycle_phase", 0.0)) * clip_duration


func _step_roster_character(dt: float) -> void:
	if skeleton == null or player == null or active_clip.is_empty():
		return
	play_time = fposmod(play_time + dt, maxf(0.05, clip_duration))
	sample_roster_at(play_time)


func sample_roster_at(t: float) -> void:
	if skeleton == null or player == null or library == null or not library.has_animation(active_clip):
		return
	play_time = clampf(t, 0.0, clip_duration)
	if not quantized_clips.has(active_clip):
		quantized_clips[active_clip] = CrowdEval.QuantizedClip.bake_from_animation(library.get_animation(active_clip), skeleton, 60.0)
	var qclip = quantized_clips[active_clip]

	skeleton.reset_bone_poses()
	player.assigned_animation = active_clip
	player.seek(play_time, true)
	player.advance(0.0)

	if _ref_skeleton != null:
		Store.apply_quantized_to_skeleton(qclip, _ref_skeleton, play_time)
		var max_pos_mm := 0.0
		var max_rot_deg := 0.0
		var max_world_mm := 0.0
		for i in skeleton.get_bone_count():
			max_pos_mm = maxf(max_pos_mm, skeleton.get_bone_pose_position(i).distance_to(_ref_skeleton.get_bone_pose_position(i)) * 1000.0)
			var lr := skeleton.get_bone_pose_rotation(i).normalized()
			var rr := _ref_skeleton.get_bone_pose_rotation(i).normalized()
			max_rot_deg = maxf(max_rot_deg, rad_to_deg(2.0 * acos(clampf(absf(lr.dot(rr)), 0.0, 1.0))))
			max_world_mm = maxf(max_world_mm, skeleton.get_bone_global_pose(i).origin.distance_to(_ref_skeleton.get_bone_global_pose(i).origin) * 1000.0)
		var rb: int = qclip.resident_bytes()
		var ub: int = CrowdEval.QuantizedClip.uncompressed_bytes(qclip.bone_count, qclip.key_count)
		_last_compare_metrics = {
			"max_pos_mm": max_pos_mm,
			"max_rot_deg": max_rot_deg,
			"max_world_mm": max_world_mm,
			"saving_pct": (1.0 - float(rb) / maxf(1.0, float(ub))) * 100.0,
			"resident_kb": float(rb) / 1024.0,
		}
		if use_quantized_16bit:
			Store.apply_quantized_to_skeleton(qclip, skeleton, play_time)


# --- Public Dock Control API ---
func get_skeleton() -> Skeleton3D:
	return skeleton


func get_display_title() -> String:
	match role:
		"hero_arena": return "%s  [Hero 85본 · 10 Lua]" % name
		"quadruped": return "%s  [4족 Locomotor · 28본]" % name
		_:
			var e := Store.get_entry(character_id)
			return "%s  [%s · %d본]" % [name, str(e.get("name", character_id)), int(e.get("bones", 0))]


func get_clip_names() -> PackedStringArray:
	var out := PackedStringArray()
	if library != null:
		for n in library.get_animation_list():
			out.append(str(n))
	elif role == "quadruped":
		out.append("procedural_locomotor")
	return out


func select_clip(clip_name: String) -> void:
	if role == "hero_arena" and player != null and player.has_animation(clip_name):
		auto_demo = false
		active_clip = clip_name
		hero_ctrl.state["active_clip"] = clip_name
		player.play(clip_name, 0.1)
		clip_duration = maxf(0.1, library.get_animation(clip_name).length)
		_hero_last_clip = clip_name
	elif role == "character" and library != null and library.has_animation(clip_name):
		active_clip = clip_name
		clip_duration = maxf(0.05, library.get_animation(clip_name).length)
		play_time = 0.0
		sample_roster_at(0.0)


func seek_time(t: float) -> void:
	if role == "character":
		sample_roster_at(t)
	elif role == "hero_arena" and player != null and player.has_animation(active_clip):
		play_time = clampf(t, 0.0, clip_duration)
		player.assigned_animation = active_clip
		player.seek(play_time, true)
		player.advance(0.0)


func _find_first_line(line_type: int, min_y: float, max_y: float, min_len: float, flat_only: bool = true) -> Dictionary:
	if hero_ctrl == null:
		return {}
	for line in hero_ctrl.line_world.lines:
		if int(line["line_type"]) != line_type:
			continue
		var a: Vector3 = line["a"]
		var b: Vector3 = line["b"]
		if flat_only and absf(a.y - b.y) > 0.05:
			continue
		if a.y >= min_y and a.y <= max_y and a.distance_to(b) >= min_len:
			return line
	return {}


func trigger_hero_scenario(scenario_id: String) -> void:
	if role != "hero_arena" or hero_ctrl == null:
		return
	ai_driven = false
	_set_ai_overlays_visible(false)
	hero_ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
	match scenario_id:
		"locomotion":
			hero_ctrl.teleport_hero(Vector3(-11.8, 0.0, 15.2), 0.15)
			hero_ctrl.raise_event("WeaponToggle", _raycast_world)
		"cover":
			var cov := _find_first_line(LinesScript.LINE_TYPE_LOW_WALL, -0.5, 0.5, 2.0, true)
			if not cov.is_empty():
				var mid := ((cov["a"] as Vector3) + (cov["b"] as Vector3)) * 0.5
				var n: Vector3 = cov["edge_normal"]
				hero_ctrl.teleport_hero(mid - n * 1.35, atan2(n.x, n.z))
				hero_ctrl.raise_event("Action", _raycast_world)
		"vault":
			var rail := _find_first_line(LinesScript.LINE_TYPE_RAILING, 0.85, 1.35, 3.0, true)
			if not rail.is_empty():
				var mid := ((rail["a"] as Vector3) + (rail["b"] as Vector3)) * 0.5
				var n: Vector3 = rail["edge_normal"]
				hero_ctrl.teleport_hero(Vector3(mid.x + n.x * 1.85, 0.0, mid.z + n.z * 1.85), atan2(-n.x, -n.z))
				hero_ctrl.raise_event("JumpButton", _raycast_world)
		"climb":
			var ledge := _find_first_line(LinesScript.LINE_TYPE_LEDGE, 2.8, 3.2, 2.0, true)
			if not ledge.is_empty():
				var mid := ((ledge["a"] as Vector3) + (ledge["b"] as Vector3)) * 0.5
				var n: Vector3 = ledge["edge_normal"]
				hero_ctrl.teleport_hero(Vector3(mid.x + n.x * 1.45, 0.0, mid.z + n.z * 1.45), atan2(-n.x, -n.z))
				hero_ctrl.raise_event("JumpButton", _raycast_world)
		"leap":
			var ledge := _find_first_line(LinesScript.LINE_TYPE_LEDGE, 4.8, 5.2, 3.0, true)
			if not ledge.is_empty():
				var mid := ((ledge["a"] as Vector3) + (ledge["b"] as Vector3)) * 0.5
				var n: Vector3 = ledge["edge_normal"]
				hero_ctrl.teleport_hero(Vector3(mid.x + n.x * 4.2, ledge["a"].y - 0.5, mid.z + n.z * 4.2), atan2(-n.x, -n.z))
				hero_ctrl.raise_event("JumpButton", _raycast_world)
		"strafe":
			hero_ctrl.teleport_hero(Vector3(-12.0, 0.0, 14.0), 0.3)
			hero_ctrl.raise_event("Strafe", _raycast_world)
	global_position = hero_ctrl.hero_pos
	rotation = Vector3(0.0, hero_ctrl.hero_yaw, 0.0)
	_hero_last_driven_pos = global_position
	_hero_has_driven = true


func set_quad_speed(v: float) -> void:
	quad_speed = clampf(v, 0.0, 5.5)


func set_quad_gait(g: String) -> void:
	quad_gait = g
	if quad_locomotor != null:
		quad_locomotor.forced_gait = g


func set_use_quantized_16bit(v: bool) -> void:
	use_quantized_16bit = v
	if role == "character":
		sample_roster_at(play_time)


func raise_hero_event(event_name: String) -> bool:
	if role != "hero_arena" or hero_ctrl == null:
		return false
	ai_driven = false
	_set_ai_overlays_visible(false)
	return hero_ctrl.raise_event(event_name, _raycast_world)


func _ensure_ai_stack() -> void:
	if ai_driver != null:
		return
	ai_spatial = SpatialScript.new()
	ai_spatial.analyze(hero_ctrl.line_world.lines)
	ai_pathfinder = PathfinderScript.new()
	ai_pathfinder.setup(ai_spatial)
	ai_driver = AiDriverScript.new()
	ai_driver.setup(ai_spatial, ai_pathfinder, hero_ctrl)
	ai_driver.start_mission("grand_tour", false)
	_build_ai_overlays()
	_refresh_ai_overlays()


func _build_ai_overlays() -> void:
	var host := get_parent() if get_parent() is Node3D else runtime_root
	if host == null:
		return
	if is_instance_valid(_ai_overlay_root):
		_ai_overlay_root.queue_free()
	_ai_overlay_root = Node3D.new()
	_ai_overlay_root.name = "_AiSpatialOverlays"
	host.add_child(_ai_overlay_root)

	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.vertex_color_use_as_albedo = true
	_ai_annot_mi = MeshInstance3D.new()
	_ai_annot_mi.material_override = line_mat
	_ai_overlay_root.add_child(_ai_annot_mi)

	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.vertex_color_use_as_albedo = true
	pmat.no_depth_test = true
	_ai_path_mi = MeshInstance3D.new()
	_ai_path_mi.material_override = pmat
	_ai_overlay_root.add_child(_ai_path_mi)


func _refresh_ai_overlays() -> void:
	if ai_spatial == null or ai_pathfinder == null or ai_driver == null:
		return
	if is_instance_valid(_ai_annot_mi):
		_ai_annot_mi.mesh = ai_spatial.build_annotations_mesh(ai_pathfinder.allowed_flags)
	if is_instance_valid(_ai_path_mi):
		_ai_path_mi.mesh = ai_pathfinder.build_path_mesh(ai_driver.active_path)
	_set_ai_overlays_visible(ai_driven)


func _set_ai_overlays_visible(v: bool) -> void:
	if is_instance_valid(_ai_overlay_root):
		_ai_overlay_root.visible = v


func set_ai_driven(enabled: bool) -> void:
	if role != "hero_arena" or hero_ctrl == null:
		return
	ai_driven = enabled
	if enabled:
		auto_demo = false
		_ensure_ai_stack()
		_refresh_ai_overlays()
	else:
		_set_ai_overlays_visible(false)


func start_ai_mission(mission_id: String) -> void:
	if role != "hero_arena" or hero_ctrl == null:
		return
	ai_driven = true
	auto_demo = false
	_ensure_ai_stack()
	ai_driver.start_mission(mission_id, true)
	global_position = hero_ctrl.hero_pos
	rotation = Vector3(0.0, hero_ctrl.hero_yaw, 0.0)
	_hero_last_driven_pos = global_position
	_hero_has_driven = true
	_refresh_ai_overlays()


func set_ai_cost_mode(mode: String) -> void:
	if role != "hero_arena" or hero_ctrl == null:
		return
	_ensure_ai_stack()
	ai_pathfinder.cost_mode = mode
	ai_driver.replan_now()
	_refresh_ai_overlays()


func run_crowd_benchmark_200() -> Dictionary:
	if skeleton == null or library == null or not library.has_animation(active_clip):
		return {}
	if not quantized_clips.has(active_clip):
		quantized_clips[active_clip] = CrowdEval.QuantizedClip.bake_from_animation(library.get_animation(active_clip), skeleton, 60.0)
	var qclip = quantized_clips[active_clip]
	var agents := 200
	var skels: Array[Skeleton3D] = []
	var tmp := Node3D.new()
	add_child(tmp)
	for _i in agents:
		var s := Skeleton3D.new()
		tmp.add_child(s)
		Store.populate_skeleton(s, motion_dict)
		skels.append(s)
	var ev := CrowdEval.new()
	ev.setup(qclip, agents, true, 0)
	ev.step_parallel(1.0 / 60.0, skels)
	var last_s: Dictionary = {}
	var sum_ms := 0.0
	for _it in 5:
		last_s = ev.step_parallel(1.0 / 60.0, skels)
		sum_ms += float(last_s.get("main_total_ms", 0.0))
	tmp.queue_free()
	return {
		"agents": agents,
		"bones_per_tick": skeleton.get_bone_count() * agents,
		"ms": sum_ms / 5.0,
		"native": bool(last_s.get("native", false)),
	}


func get_state_snapshot() -> Dictionary:
	var base := {
		"name": name,
		"role": role,
		"character_id": character_id,
		"active_clip": active_clip,
		"play_time": play_time,
		"duration": clip_duration,
		"playing": playing,
		"auto_demo": auto_demo,
		"bones": skeleton.get_bone_count() if skeleton != null else 0,
		"world_pos": global_position,
	}
	if role == "hero_arena" and hero_ctrl != null:
		base["active_state"] = hero_ctrl.state["active_state"]
		base["last_event"] = hero_ctrl.state["last_event"]
		base["variables"] = hero_ctrl.variables.duplicate()
		base["hero_state"] = hero_ctrl.state.duplicate()
		base["dock_target"] = hero_ctrl.line_world.docking_target.duplicate()
		base["cam_mode"] = hero_ctrl.cam.mode
		base["ai_driven"] = ai_driven
		if ai_driver != null:
			base["ai_telemetry"] = ai_driver.get_telemetry()
			base["ai_stats"] = ai_spatial.stats.duplicate() if ai_spatial != null else {}
	elif role == "quadruped" and quad_locomotor != null:
		base["active_state"] = str(_quad_last_snap.get("gait", "idle"))
		base["quad_speed"] = quad_speed
		base["quad_gait"] = quad_gait
		base["actual_speed"] = float(_quad_last_snap.get("speed", 0.0))
		base["pelvis_y"] = float(_quad_last_snap.get("pelvis_y", 0.78))
		base["pelvis_pitch_deg"] = float(_quad_last_snap.get("pelvis_pitch_deg", 0.0))
		base["pelvis_roll_deg"] = float(_quad_last_snap.get("pelvis_roll_deg", 0.0))
		base["planted_count"] = int(_quad_last_snap.get("planted_count", 4))
		base["foot_slip_mm"] = float(_quad_last_snap.get("max_slide_mm", 0.0))
		base["feet"] = _quad_last_snap.get("feet", {})
	else:
		base["active_state"] = "16-bit C++" if use_quantized_16bit else "Float32 Player"
		base["compare"] = _last_compare_metrics.duplicate()
		base["use_quantized_16bit"] = use_quantized_16bit
	return base
