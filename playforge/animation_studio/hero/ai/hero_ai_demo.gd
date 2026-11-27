@tool
extends Control
## AI Pathfinding-Driven Hero Full-Map Demo
## Reference: Havok AI (SpatialAnalysis, TraversalAnalysis, UserEdges,
## PreferHighPlacesCostModifier, Gdc2009AiTactical, DynamicSilhouette,
## PathFollowing + BehaviorBlockedDetector) + Havok Behavior (Hero 10 Lua scripts).
## 100% Native Godot (zero .hkt / zero SDK runtime dependencies).

const Store := preload("res://characters/character_store.gd")
const EnvNodeScript := preload("res://hero/arena/hero_environment_node.gd")
const ControllerScript := preload("res://hero/arena/hero_lua_controller.gd")
const SpatialScript := preload("res://hero/ai/hero_spatial_analysis.gd")
const PathfinderScript := preload("res://hero/ai/hero_ai_pathfinder.gd")
const DriverScript := preload("res://hero/ai/hero_ai_behavior_driver.gd")

const HERO_ARENA_MOTION_RES := "res://hero/assets/hero_arena_motion.res"
const HERO_SKIN_GLB := "res://hero/assets/hero_skin.glb"

var _world: Node3D
var _env_node: Node3D
var _hero_root: Node3D
var _skeleton: Skeleton3D
var _player: AnimationPlayer
var _library: AnimationLibrary
var _cam: Camera3D

var _navmesh_mi: MeshInstance3D
var _annot_mi: MeshInstance3D
var _path_mi: MeshInstance3D
var _goal_beacon: MeshInstance3D
var _dyn_obs_mi: MeshInstance3D

var controller: ControllerScript = ControllerScript.new()
var spatial: SpatialScript = SpatialScript.new()
var pathfinder: PathfinderScript = PathfinderScript.new()
var driver: DriverScript = DriverScript.new()

var playing: bool = true
var sim_speed: float = 1.0
var camera_mode: String = "follow" # "follow" | "overview" | "skybridge"
var show_navmesh: bool = true
var show_annotations: bool = true
var show_path: bool = true
var show_docking_lines: bool = false
var enable_dynamic_obstacle: bool = false

var _last_clip: String = ""
var _hud_accum: float = 0.0
var _dyn_obs_phase: float = 0.0

# HUD refs
var _status_lbl: Label
var _spatial_lbl: Label
var _path_lbl: Label
var _coverage_lbl: Label
var _cost_opt: OptionButton
var _flag_cbs: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_3d_scene()
	_build_hud()
	driver.start_mission("grand_tour", true)
	_sync_visual_overlays()
	_sync_hero_transform_and_anim(0.016)
	_refresh_hud()


func _build_3d_scene() -> void:
	var svc := SubViewportContainer.new()
	svc.name = "ViewportHost"
	svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	svc.stretch = true
	svc.gui_input.connect(_on_viewport_gui_input)
	add_child(svc)

	var vp := SubViewport.new()
	vp.name = "WorldViewport"
	vp.size = Vector2i(1280, 720)
	vp.msaa_3d = Viewport.MSAA_2X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svc.add_child(vp)

	_world = Node3D.new()
	_world.name = "HeroAiWorld"
	vp.add_child(_world)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#24436b")
	sky_mat.sky_horizon_color = Color("#7da0c4")
	sky_mat.ground_bottom_color = Color("#1e2530")
	sky_mat.ground_horizon_color = Color("#4a5d73")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.34
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
	sun.light_energy = 0.68
	sun.shadow_enabled = true
	_world.add_child(sun)

	_env_node = EnvNodeScript.new()
	_env_node.name = "HeroEnvironment"
	_env_node.set("show_docking_lines", show_docking_lines)
	_world.add_child(_env_node)

	# Build Hero 85-bone rig + 31 clips
	controller.init_world()
	_build_hero_actor()

	# Run Havok-style Spatial Analysis + Multi-Layer NavGraph + Traversal UserEdges
	spatial.analyze(controller.line_world.lines)
	pathfinder.setup(spatial)
	driver.setup(spatial, pathfinder, controller)

	# 3D Debug Overlays (NavMesh, Spatial Analysis Annotations, Active A* Path, Goal Beacon, Dynamic Obstacle)
	_navmesh_mi = MeshInstance3D.new()
	_navmesh_mi.name = "NavMeshOverlay"
	_navmesh_mi.mesh = spatial.build_navmesh_mesh()
	var nm_mat := StandardMaterial3D.new()
	nm_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	nm_mat.vertex_color_use_as_albedo = true
	nm_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	nm_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	nm_mat.no_depth_test = false
	_navmesh_mi.material_override = nm_mat
	_world.add_child(_navmesh_mi)

	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.vertex_color_use_as_albedo = true

	_annot_mi = MeshInstance3D.new()
	_annot_mi.name = "SpatialAnalysisAnnotations"
	_annot_mi.material_override = line_mat
	_world.add_child(_annot_mi)

	_path_mi = MeshInstance3D.new()
	_path_mi.name = "ActiveAStarPath"
	var path_mat := StandardMaterial3D.new()
	path_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	path_mat.vertex_color_use_as_albedo = true
	path_mat.no_depth_test = true
	_path_mi.material_override = path_mat
	_world.add_child(_path_mi)

	_goal_beacon = MeshInstance3D.new()
	_goal_beacon.name = "GoalBeacon"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.08
	cyl.bottom_radius = 0.45
	cyl.height = 2.4
	_goal_beacon.mesh = cyl
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.albedo_color = Color(1.0, 0.85, 0.2, 0.65)
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_goal_beacon.material_override = bm
	_world.add_child(_goal_beacon)

	_dyn_obs_mi = MeshInstance3D.new()
	_dyn_obs_mi.name = "DynamicObstacleSilhouette"
	var obs_cyl := CylinderMesh.new()
	obs_cyl.top_radius = 1.9
	obs_cyl.bottom_radius = 1.9
	obs_cyl.height = 2.2
	_dyn_obs_mi.mesh = obs_cyl
	var om := StandardMaterial3D.new()
	om.albedo_color = Color(0.95, 0.25, 0.25, 0.55)
	om.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dyn_obs_mi.material_override = om
	_dyn_obs_mi.visible = false
	_world.add_child(_dyn_obs_mi)

	_cam = Camera3D.new()
	_cam.name = "DemoCamera"
	_cam.fov = 52.0
	_cam.far = 350.0
	_cam.current = true
	_world.add_child(_cam)


func _build_hero_actor() -> void:
	_hero_root = Node3D.new()
	_hero_root.name = "HeroActor"
	_world.add_child(_hero_root)

	if not FileAccess.file_exists(HERO_ARENA_MOTION_RES):
		return
	var res = ResourceLoader.load(HERO_ARENA_MOTION_RES)
	if res == null or not res.has_method("to_motion_dict"):
		return
	var motion_dict: Dictionary = res.call("to_motion_dict")

	_skeleton = Skeleton3D.new()
	_skeleton.name = "Skeleton3D"
	_hero_root.add_child(_skeleton)
	Store.populate_skeleton(_skeleton, motion_dict)
	_attach_hero_glb(_skeleton)

	_library = AnimationLibrary.new()
	var clips_dict: Dictionary = motion_dict.get("clips", {})
	for ck in clips_dict.keys():
		_library.add_animation(str(ck), Store.build_animation_from_clip(motion_dict, str(ck), "Skeleton3D"))

	_player = AnimationPlayer.new()
	_player.name = "AnimationPlayer"
	_hero_root.add_child(_player)
	_player.add_animation_library("", _library)
	_player.root_node = _player.get_path_to(_hero_root)


func _attach_hero_glb(rig: Skeleton3D) -> void:
	if not FileAccess.file_exists(HERO_SKIN_GLB):
		return
	var bytes := FileAccess.get_file_as_bytes(HERO_SKIN_GLB)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.use_named_skin_binds = true
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if doc.append_from_buffer(bytes, "", st) != OK:
		return
	var scene := doc.generate_scene(st)
	if scene == null:
		return
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
	scene.free()


func _build_hud() -> void:
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = Color(0.08, 0.10, 0.14, 0.86)
	panel_sb.border_color = Color(0.22, 0.30, 0.42, 0.9)
	panel_sb.set_border_width_all(1)
	panel_sb.set_corner_radius_all(8)
	panel_sb.set_content_margin_all(10)

	# Left Control Panel (placed cleanly below PlayForge fork HUD pill bar)
	var left_panel := PanelContainer.new()
	left_panel.add_theme_stylebox_override("panel", panel_sb)
	left_panel.position = Vector2(12, 54)
	left_panel.custom_minimum_size = Vector2(288, 0)
	add_child(left_panel)

	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 6)
	left_panel.add_child(lv)

	var title := Label.new()
	title.text = "◆ AI Pathfinding · Spatial Analysis Hero"
	title.modulate = Color("#f6b44d")
	lv.add_child(title)

	var tip := Label.new()
	tip.text = "3D 맵 아무 곳이나 클릭 → A* 3D 경로 + 파쿠르 자율 주행"
	tip.modulate = Color("#7fd6cc")
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lv.add_child(tip)

	var m_lbl := Label.new()
	m_lbl.text = "AI 미션 프리셋 (전체 맵 기능 커버)"
	lv.add_child(m_lbl)

	var m_grid := GridContainer.new()
	m_grid.columns = 2
	m_grid.add_theme_constant_override("h_separation", 4)
	m_grid.add_theme_constant_override("v_separation", 4)
	lv.add_child(m_grid)

	var missions := [
		["풀코스 100%", "grand_tour"],
		["정상 10.25m 등정", "summit_ascent"],
		["전술 엄폐 돌파", "tactical_cover"],
		["난간 넘기 코스", "vault_slalom"],
		["지하 참호 탈출", "trench_escape"],
		["고지대 선호", "high_road"],
	]
	for m in missions:
		var b := Button.new()
		b.text = m[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mid: String = m[1]
		b.pressed.connect(func():
			driver.start_mission(mid, true)
			_sync_visual_overlays()
			_refresh_hud()
		)
		m_grid.add_child(b)

	var c_row := HBoxContainer.new()
	lv.add_child(c_row)
	var c_lbl := Label.new()
	c_lbl.text = "CostModifier:"
	c_row.add_child(c_lbl)

	_cost_opt = OptionButton.new()
	_cost_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var modes := [
		["Shortest (최단)", PathfinderScript.COST_SHORTEST],
		["PreferHigh (고지대 선호)", PathfinderScript.COST_PREFER_HIGH],
		["TacticalCover (엄폐 선호)", PathfinderScript.COST_TACTICAL_COVER],
		["ParkourExpress (파쿠르 우선)", PathfinderScript.COST_PARKOUR_EXPRESS],
	]
	for mo in modes:
		_cost_opt.add_item(mo[0])
	_cost_opt.select(3)
	_cost_opt.item_selected.connect(func(idx: int):
		pathfinder.cost_mode = modes[idx][1]
		driver.replan_now()
		_sync_visual_overlays()
	)
	c_row.add_child(_cost_opt)

	var f_lbl := Label.new()
	f_lbl.text = "Spatial Analysis UserEdge 필터"
	lv.add_child(f_lbl)

	var f_grid := GridContainer.new()
	f_grid.columns = 3
	lv.add_child(f_grid)
	var flag_defs := [
		["Vault", SpatialScript.FLAG_VAULT],
		["Climb", SpatialScript.FLAG_CLIMB],
		["Leap", SpatialScript.FLAG_LEAP],
		["Drop", SpatialScript.FLAG_DROP],
		["Cover", SpatialScript.FLAG_COVER],
	]
	for fd in flag_defs:
		var cb := CheckBox.new()
		cb.text = fd[0]
		cb.button_pressed = true
		var bit: int = fd[1]
		cb.toggled.connect(func(v: bool):
			if v:
				pathfinder.allowed_flags |= bit
			else:
				pathfinder.allowed_flags &= ~bit
			driver.replan_now()
			_sync_visual_overlays()
		)
		f_grid.add_child(cb)
		_flag_cbs[bit] = cb

	var o_lbl := Label.new()
	o_lbl.text = "시각화 & 동적 장애물"
	lv.add_child(o_lbl)

	var o_grid := GridContainer.new()
	o_grid.columns = 2
	lv.add_child(o_grid)

	var cb_nm := CheckBox.new(); cb_nm.text = "NavMesh"; cb_nm.button_pressed = show_navmesh
	cb_nm.toggled.connect(func(v: bool): show_navmesh = v; _sync_visual_overlays())
	o_grid.add_child(cb_nm)

	var cb_an := CheckBox.new(); cb_an.text = "UserEdges"; cb_an.button_pressed = show_annotations
	cb_an.toggled.connect(func(v: bool): show_annotations = v; _sync_visual_overlays())
	o_grid.add_child(cb_an)

	var cb_pt := CheckBox.new(); cb_pt.text = "A* Path"; cb_pt.button_pressed = show_path
	cb_pt.toggled.connect(func(v: bool): show_path = v; _sync_visual_overlays())
	o_grid.add_child(cb_pt)

	var cb_obs := CheckBox.new(); cb_obs.text = "동적 장애물"; cb_obs.button_pressed = enable_dynamic_obstacle
	cb_obs.toggled.connect(func(v: bool):
		enable_dynamic_obstacle = v
		_update_dynamic_obstacle(0.0)
		driver.replan_now()
		_sync_visual_overlays()
	)
	o_grid.add_child(cb_obs)

	var cam_row := HBoxContainer.new()
	cam_row.add_theme_constant_override("separation", 4)
	lv.add_child(cam_row)
	for cm in [["추적", "follow"], ["전체 조감도", "overview"], ["고지대", "skybridge"]]:
		var b := Button.new()
		b.text = cm[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cid: String = cm[1]
		b.pressed.connect(func(): camera_mode = cid)
		cam_row.add_child(b)

	var spd_row := HBoxContainer.new()
	spd_row.add_theme_constant_override("separation", 4)
	lv.add_child(spd_row)
	var btn_play := Button.new(); btn_play.text = "일시정지"
	btn_play.pressed.connect(func():
		playing = not playing
		btn_play.text = "일시정지" if playing else "재생"
	)
	spd_row.add_child(btn_play)
	for sp in [1.0, 2.0, 4.0]:
		var b := Button.new()
		b.text = "%.0fx" % sp
		var sv: float = sp
		b.pressed.connect(func(): sim_speed = sv)
		spd_row.add_child(b)

	# Right Telemetry & Coverage Panel
	var right_panel := PanelContainer.new()
	right_panel.add_theme_stylebox_override("panel", panel_sb)
	right_panel.anchor_left = 1.0
	right_panel.anchor_right = 1.0
	right_panel.offset_left = -320
	right_panel.offset_top = 12
	right_panel.offset_right = -12
	add_child(right_panel)

	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 6)
	right_panel.add_child(rv)

	_status_lbl = Label.new()
	_status_lbl.modulate = Color("#f6b44d")
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rv.add_child(_status_lbl)

	rv.add_child(HSeparator.new())

	_spatial_lbl = Label.new()
	_spatial_lbl.modulate = Color("#7fd6cc")
	_spatial_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rv.add_child(_spatial_lbl)

	_path_lbl = Label.new()
	_path_lbl.modulate = Color("#dce7f5")
	_path_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rv.add_child(_path_lbl)

	rv.add_child(HSeparator.new())

	_coverage_lbl = Label.new()
	_coverage_lbl.modulate = Color("#b8f5c8")
	_coverage_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rv.add_child(_coverage_lbl)


func _raycast_world(from_p: Vector3, to_p: Vector3) -> Dictionary:
	var w := _world.get_world_3d()
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


func _on_viewport_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _cam == null:
			return
		var origin := _cam.project_ray_origin(event.position)
		var dir := _cam.project_ray_normal(event.position)
		var hit := _raycast_world(origin, origin + dir * 240.0)
		if bool(hit.get("hit", false)):
			var hp: Vector3 = hit["position"]
			driver.command_move_to(hp, "클릭 목표 (%.1f, %.1f, %.1f)" % [hp.x, hp.y, hp.z])
			_sync_visual_overlays()
			_refresh_hud()


func _process(delta: float) -> void:
	if not playing:
		_update_camera(delta)
		return
	var substeps := int(maxf(1.0, round(sim_speed)))
	var step_dt := clampf(delta, 0.005, 0.033)
	for _s in substeps:
		_update_dynamic_obstacle(step_dt)
		driver.step(step_dt, _skeleton, _raycast_world)
		_sync_hero_transform_and_anim(step_dt)

	if driver.path_dirty:
		driver.path_dirty = false
		_sync_visual_overlays()

	_update_camera(delta)
	_hud_accum += delta
	if _hud_accum >= 0.12:
		_hud_accum = 0.0
		_refresh_hud()


func _update_dynamic_obstacle(dt: float) -> void:
	if not enable_dynamic_obstacle:
		pathfinder.dynamic_obstacles.clear()
		if is_instance_valid(_dyn_obs_mi):
			_dyn_obs_mi.visible = false
		return
	_dyn_obs_phase += dt * 0.55
	var pos := Vector3(-16.0 + sin(_dyn_obs_phase) * 7.5, 0.0, 4.0 + cos(_dyn_obs_phase) * 5.0)
	pathfinder.dynamic_obstacles = [{"pos": pos, "radius": 2.0}]
	if is_instance_valid(_dyn_obs_mi):
		_dyn_obs_mi.visible = true
		_dyn_obs_mi.position = pos + Vector3(0.0, 1.1, 0.0)


func _sync_hero_transform_and_anim(dt: float) -> void:
	if is_instance_valid(_hero_root):
		_hero_root.global_position = controller.hero_pos
		_hero_root.rotation = Vector3(0.0, controller.hero_yaw, 0.0)
	if is_instance_valid(_player):
		var cname := str(controller.state["active_clip"])
		if cname != _last_clip and _player.has_animation(cname):
			_player.play(cname, 0.12)
			_last_clip = cname
		if _player.is_playing():
			_player.advance(dt)


func _sync_visual_overlays() -> void:
	if is_instance_valid(_navmesh_mi):
		_navmesh_mi.visible = show_navmesh
	if is_instance_valid(_annot_mi):
		_annot_mi.visible = show_annotations
		if show_annotations:
			_annot_mi.mesh = spatial.build_annotations_mesh(pathfinder.allowed_flags)
	if is_instance_valid(_path_mi):
		_path_mi.visible = show_path
		if show_path:
			_path_mi.mesh = pathfinder.build_path_mesh(driver.active_path)
	if is_instance_valid(_goal_beacon):
		_goal_beacon.position = driver.current_goal + Vector3(0.0, 1.2, 0.0)
	if is_instance_valid(_env_node):
		_env_node.set("show_docking_lines", show_docking_lines)


func _update_camera(dt: float) -> void:
	if not is_instance_valid(_cam):
		return
	var target_pos: Vector3
	var look_at_p: Vector3
	match camera_mode:
		"overview":
			target_pos = Vector3(-18.0, 38.0, -34.0)
			look_at_p = Vector3(-18.0, 2.0, 20.0)
		"skybridge":
			target_pos = Vector3(-16.0, 17.5, 22.0)
			look_at_p = Vector3(-15.0, 6.2, 48.0)
		_:
			var hp := controller.hero_pos
			var back := -controller.get_hero_forward()
			target_pos = hp + back * 6.5 + Vector3(2.2, 4.2, 0.0)
			look_at_p = hp + Vector3(0.0, 1.3, 0.0)
	_cam.global_position = _cam.global_position.lerp(target_pos, clampf(dt * 4.5, 0.0, 1.0)) if _cam.global_position.length() > 0.1 else target_pos
	_cam.look_at(look_at_p, Vector3.UP)


func _refresh_hud() -> void:
	var tel := driver.get_telemetry()
	var st := spatial.stats
	if _cost_opt != null:
		var mode_map: Dictionary = {
			PathfinderScript.COST_SHORTEST: 0,
			PathfinderScript.COST_PREFER_HIGH: 1,
			PathfinderScript.COST_TACTICAL_COVER: 2,
			PathfinderScript.COST_PARKOUR_EXPRESS: 3,
		}
		var mode_idx: int = int(mode_map.get(str(tel["cost_mode"]), 0))
		if _cost_opt.selected != mode_idx:
			_cost_opt.select(mode_idx)
	_status_lbl.text = "미션: %s (%d/%d)\n목표: %s\nHero 상태: %s | 클립: %s\n위치: (%.1f, %.2f, %.1f)" % [
		str(tel["mission"]), int(tel["waypoint_idx"]), int(tel["waypoint_total"]),
		str(tel["goal_label"]),
		str(controller.state["active_state"]), str(controller.state["active_clip"]),
		controller.hero_pos.x, controller.hero_pos.y, controller.hero_pos.z,
	]
	_spatial_lbl.text = "Spatial Analysis (%.1f ms)\n• NavNodes: %d | WalkEdges: %d\n• UserEdges: %d (Vault:%d Climb:%d Leap:%d\n  Drop:%d CoverWalk:%d CoverRoll:%d)" % [
		float(st.get("bake_ms", 0.0)), int(st.get("nav_nodes", 0)), int(st.get("walk_edges", 0)),
		int(st.get("user_edges", 0)), int(st.get("vault_edges", 0)), int(st.get("climb_edges", 0)),
		int(st.get("leap_edges", 0)), int(st.get("drop_edges", 0)),
		int(st.get("cover_walk_edges", 0)), int(st.get("cover_roll_edges", 0)),
	]
	_path_lbl.text = "A* Pathfinding (%s · %.2f ms)\n• 구간: %d/%d [%s] | 거리: %.1fm | 평균고도: %.2fm\n• 최저Y: %.2fm ~ 최고Y: %.2fm | 재탐색: %d" % [
		str(tel["cost_mode"]), float(tel["path_ms"]),
		int(tel["seg_idx"]) + 1, int(tel["seg_total"]), str(tel["seg_type"]),
		float(tel["path_len_m"]), float(tel["path_avg_y"]),
		float(tel["lowest_y"]), float(tel["highest_y"]), int(tel["replan_count"]),
	]
	var cov: Dictionary = tel["coverage"]
	var items := [
		["로코모션", "locomotion"], ["180°턴", "turn180"],
		["낮음엄폐", "cover_low"], ["높음엄폐", "cover_high"],
		["엄폐구르기", "cover_roll"], ["난간넘기", "vault"],
		["등반(Climb)", "climb_up"], ["도약(Leap)", "leap"],
		["하강(Drop)", "drop_down"], ["지하참호(-3m)", "trench_pit"],
		["정상(+10.25m)", "summit_10m"], ["전투·Strafe", "combat_strafe"],
	]
	var lines := PackedStringArray(["전체 맵 기능 커버리지 (%d / %d)" % [int(tel["covered_count"]), int(tel["coverage_total"])]])
	for i in range(0, items.size(), 2):
		var a = items[i]
		var b = items[i + 1]
		var ca := "[✓]" if bool(cov.get(a[1], false)) else "[ ]"
		var cb := "[✓]" if bool(cov.get(b[1], false)) else "[ ]"
		lines.append("%s %-10s  %s %s" % [ca, a[0], cb, b[0]])
	_coverage_lbl.text = "\n".join(lines)


func set_playing(v: bool) -> void:
	playing = v
