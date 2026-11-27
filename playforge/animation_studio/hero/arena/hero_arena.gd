@tool
extends Control
## Playable Hero Test Map (`Environment.hkt` -> `hero_environment.glb`) & Restored
## Havok Lua Behavior Showcase (all 10 hero*.lua scripts restored in native GDScript).

const Hero := preload("res://hero/hero.gd")
const Store := preload("res://characters/character_store.gd")
const ControllerScript := preload("res://hero/arena/hero_lua_controller.gd")
const LinesScript := preload("res://hero/arena/hero_lua_lines.gd")

const ENV_GLB_PATH := "res://hero/assets/hero_environment.glb"
const ARENA_MOTION_RES := "res://hero/assets/hero_arena_motion.res"
const HERO_SKIN_GLB := "res://hero/assets/hero_skin.glb"

const BG_DARK := Color("#141820")
const PANEL_BG := Color("#1c222d")
const BAR_BG := Color("#212836")
const BORDER := Color("#323d4e")
const ACCENT := Color("#5cd3b0")
const WARN := Color("#f0a85a")
const TEXT_MAIN := Color("#e5ecf4")
const TEXT_DIM := Color("#99a8ba")

var controller: ControllerScript = ControllerScript.new()
var playing: bool = true
var auto_tour: bool = true
var show_docking_lines: bool = true
var active_scenario: String = "tour"
var _tour_clock: float = 0.0
var _tour_step: int = -1
var _last_clip_name: String = ""
var _last_hl_line: int = -2

var preview_viewport: SubViewport = null
var stage_root: Node3D = null
var env_holder: Node3D = null
var hero_root: Node3D = null
var hero_skeleton: Skeleton3D = null
var hero_player: AnimationPlayer = null
var camera: Camera3D = null
var debug_lines_mesh: MeshInstance3D = null

var env_stats: Dictionary = {"meshes": 0, "verts": 0, "tris": 0}
var hero_stats: Dictionary = {"bones": 0, "meshes": 0, "clips": 0}

var _state_label: RichTextLabel = null
var _vars_label: RichTextLabel = null
var _log_label: Label = null
var _tour_btn: Button = null
var _lines_btn: Button = null
var _play_btn: Button = null
var _dragging: bool = false
var _last_mouse: Vector2 = Vector2.ZERO


func _ready() -> void:
	_build_theme()
	_build_ui()
	_build_3d_world()
	controller.init_world()
	_load_environment_glb()
	_load_hero_arena_rig()
	_refresh_debug_lines()
	start_scenario("locomotion")
	_tour_clock = 0.0
	_tour_step = 0


func _build_theme() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans"])
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 13
	t.set_color("font_color", "Label", TEXT_MAIN)
	t.set_color("font_color", "Button", TEXT_MAIN)
	t.set_color("font_pressed_color", "Button", Color("#10171f"))
	t.set_stylebox("normal", "Button", _sb(Color("#2a3342"), 4, 8, 4))
	t.set_stylebox("hover", "Button", _sb(Color("#39465b"), 4, 8, 4))
	t.set_stylebox("pressed", "Button", _sb(ACCENT, 4, 8, 4))
	t.set_stylebox("panel", "PanelContainer", _sb(PANEL_BG, 6, 8, 8))
	theme = t


func _sb(col: Color, radius: int, px: int, py: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = col
	b.border_color = BORDER
	b.set_border_width_all(1)
	b.set_corner_radius_all(radius)
	b.content_margin_left = px
	b.content_margin_right = px
	b.content_margin_top = py
	b.content_margin_bottom = py
	return b


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = BG_DARK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# --- Top Bar ---
	var top_p := PanelContainer.new()
	top_p.add_theme_stylebox_override("panel", _sb(BAR_BG, 0, 10, 6))
	vbox.add_child(top_p)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top_p.add_child(top)

	if not Engine.is_editor_hint():
		var back := Button.new()
		back.text = "← 모션 실험실"
		back.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/motion_lab.tscn"))
		top.add_child(back)

	var title := Label.new()
	title.text = "◆ HERO TEST ARENA (Environment.glb) · 10 LUA SCRIPTS RESTORED"
	title.add_theme_color_override("font_color", WARN)
	top.add_child(title)

	_tour_btn = Button.new()
	_tour_btn.text = "자동 시연 투어"
	_tour_btn.toggle_mode = true
	_tour_btn.button_pressed = true
	_tour_btn.pressed.connect(func():
		auto_tour = _tour_btn.button_pressed
		if auto_tour:
			_tour_clock = 0.0
			_tour_step = -1
	)
	top.add_child(_tour_btn)

	_lines_btn = Button.new()
	_lines_btn.text = "도킹 라인 90개"
	_lines_btn.toggle_mode = true
	_lines_btn.button_pressed = true
	_lines_btn.pressed.connect(func():
		show_docking_lines = _lines_btn.button_pressed
		controller.variables["ShowDockingLines"] = show_docking_lines
		if debug_lines_mesh != null:
			debug_lines_mesh.visible = show_docking_lines
	)
	top.add_child(_lines_btn)

	_play_btn = Button.new()
	_play_btn.text = "일시정지"
	_play_btn.pressed.connect(func(): set_playing(not playing))
	top.add_child(_play_btn)

	# --- Body Split ---
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	vbox.add_child(body)

	# Left Control & Lua Telemetry Dock
	var left_p := PanelContainer.new()
	left_p.custom_minimum_size = Vector2(335, 0)
	left_p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(left_p)
	var lbox := VBoxContainer.new()
	lbox.add_theme_constant_override("separation", 6)
	left_p.add_child(lbox)

	var sec1 := Label.new()
	sec1.text = "복원 Lua 시나리오 즉시 시연 (Environment.hkt 실좌표)"
	sec1.add_theme_color_override("font_color", ACCENT)
	lbox.add_child(sec1)

	var presets := [
		["locomotion", "1. 로코모션 & 검술 (hero / hero_locomotion.lua)"],
		["cover", "2. 엄폐 & 엄폐이동 (hero_cover.lua · 빨강/초록)"],
		["vault", "3. 난간 뛰어넘기 (hero_vaulting.lua · 주황)"],
		["climb", "4. 난간 매달리기·등반 (hero_climbing.lua · 파랑)"],
		["leap", "5. 플랫폼 갭 도약 (hero_leaping.lua · 파랑/노랑)"],
		["strafe", "6. 오버더숄더 스트레이프 (hero_camera.lua)"],
	]
	for p in presets:
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = p[1]
		var pid: String = p[0]
		b.pressed.connect(func():
			auto_tour = false
			if is_instance_valid(_tour_btn):
				_tour_btn.set_pressed_no_signal(false)
			start_scenario(pid)
		)
		lbox.add_child(b)

	# Manual action triggers
	var act_row := HFlowContainer.new()
	act_row.add_theme_constant_override("h_separation", 4)
	act_row.add_theme_constant_override("v_separation", 4)
	lbox.add_child(act_row)
	for ev in [["JumpButton", "Jump/Vault/Climb (Space)"], ["Action", "Cover/Drop (E)"], ["WeaponToggle", "검 발도/납도 (R)"], ["Attack", "공격 (F)"]]:
		var ab := Button.new()
		ab.text = ev[1]
		var ev_name: String = ev[0]
		ab.pressed.connect(func():
			auto_tour = false
			if is_instance_valid(_tour_btn):
				_tour_btn.set_pressed_no_signal(false)
			controller.raise_event(ev_name, _raycast_world)
		)
		act_row.add_child(ab)

	# State readout
	var state_panel := PanelContainer.new()
	state_panel.add_theme_stylebox_override("panel", _sb(Color("#151a23"), 4, 8, 6))
	state_panel.custom_minimum_size = Vector2(0, 125)
	lbox.add_child(state_panel)
	_state_label = RichTextLabel.new()
	_state_label.bbcode_enabled = true
	_state_label.scroll_active = false
	state_panel.add_child(_state_label)

	# Restored Lua variables panel
	var vars_panel := PanelContainer.new()
	vars_panel.add_theme_stylebox_override("panel", _sb(Color("#151a23"), 4, 8, 6))
	vars_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lbox.add_child(vars_panel)
	_vars_label = RichTextLabel.new()
	_vars_label.bbcode_enabled = true
	_vars_label.scroll_active = true
	vars_panel.add_child(_vars_label)

	# Right 3D Viewport
	var vp_frame := PanelContainer.new()
	vp_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_frame.add_theme_stylebox_override("panel", _sb(Color("#0f141c"), 4, 2, 2))
	body.add_child(vp_frame)
	var vp_v := VBoxContainer.new()
	vp_v.add_theme_constant_override("separation", 2)
	vp_frame.add_child(vp_v)

	var vp_cont := SubViewportContainer.new()
	vp_cont.stretch = true
	vp_cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_cont.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_cont.gui_input.connect(_on_vp_input)
	vp_v.add_child(vp_cont)

	preview_viewport = SubViewport.new()
	preview_viewport.own_world_3d = true
	preview_viewport.msaa_3d = Viewport.MSAA_4X
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_cont.add_child(preview_viewport)

	_log_label = Label.new()
	_log_label.add_theme_color_override("font_color", TEXT_DIM)
	vp_v.add_child(_log_label)


func _build_3d_world() -> void:
	stage_root = Node3D.new()
	stage_root.name = "HeroArenaStage"
	preview_viewport.add_child(stage_root)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#3a639c")
	sky_mat.sky_horizon_color = Color("#9db8d4")
	sky_mat.ground_bottom_color = Color("#242b35")
	sky_mat.ground_horizon_color = Color("#5f7288")
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.36
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	stage_root.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.72
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-46.0, 34.0, 0.0)
	stage_root.add_child(sun)

	env_holder = Node3D.new()
	env_holder.name = "EnvironmentMap"
	stage_root.add_child(env_holder)

	debug_lines_mesh = MeshInstance3D.new()
	debug_lines_mesh.name = "DockingLines3D"
	var lmat := StandardMaterial3D.new()
	lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lmat.vertex_color_use_as_albedo = true
	lmat.no_depth_test = false
	debug_lines_mesh.material_override = lmat
	stage_root.add_child(debug_lines_mesh)

	camera = Camera3D.new()
	camera.fov = 52.0
	camera.near = 0.08
	camera.far = 250.0
	stage_root.add_child(camera)
	camera.make_current()


func _load_environment_glb() -> void:
	if not FileAccess.file_exists(ENV_GLB_PATH):
		return
	var bytes := FileAccess.get_file_as_bytes(ENV_GLB_PATH)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if doc.append_from_buffer(bytes, "", st) != OK:
		return
	var scene := doc.generate_scene(st)
	if scene == null:
		return

	var mesh_nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	mesh_nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))

	var body := StaticBody3D.new()
	body.name = "EnvironmentCollision"
	env_holder.add_child(body)

	var all_faces := PackedVector3Array()
	for src in mesh_nodes:
		var src_mesh: Mesh = null
		if src is MeshInstance3D:
			src_mesh = src.mesh
		elif src.is_class("ImporterMeshInstance3D"):
			var imp = src.get("mesh")
			if imp != null and imp.has_method("get_mesh"):
				src_mesh = imp.call("get_mesh")
		if src_mesh == null:
			continue
		var vis := MeshInstance3D.new()
		vis.name = src.name
		vis.mesh = src_mesh
		vis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		# Preserve baked CompleteMap AO shadows without clipping bright floor to pure white
		for si in src_mesh.get_surface_count():
			var mat := src_mesh.surface_get_material(si)
			if mat is BaseMaterial3D:
				var mcopy := mat.duplicate() as BaseMaterial3D
				mcopy.albedo_color = Color(0.84, 0.87, 0.91)
				mcopy.roughness = 0.94
				vis.set_surface_override_material(si, mcopy)
		env_holder.add_child(vis)

		var faces := src_mesh.get_faces()
		all_faces.append_array(faces)
		env_stats["meshes"] = int(env_stats["meshes"]) + 1
		for s in src_mesh.get_surface_count():
			env_stats["verts"] = int(env_stats["verts"]) + src_mesh.surface_get_array_len(s)
		env_stats["tris"] = int(env_stats["tris"]) + faces.size() / 3

	if not all_faces.is_empty():
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(all_faces)
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
	scene.free()


func _load_hero_arena_rig() -> void:
	if not FileAccess.file_exists(ARENA_MOTION_RES):
		return
	var res = ResourceLoader.load(ARENA_MOTION_RES)
	if res == null or not res.has_method("to_motion_dict"):
		return
	var motion_dict: Dictionary = res.call("to_motion_dict")

	hero_root = Node3D.new()
	hero_root.name = "HeroActor"
	stage_root.add_child(hero_root)

	hero_skeleton = Skeleton3D.new()
	hero_skeleton.name = "Skeleton3D"
	hero_root.add_child(hero_skeleton)
	Store.populate_skeleton(hero_skeleton, motion_dict)

	var skin_info := _attach_hero_skin(hero_skeleton)

	var library := AnimationLibrary.new()
	var clips_dict: Dictionary = motion_dict.get("clips", {})
	for clip_key in clips_dict.keys():
		var anim := Store.build_animation_from_clip(motion_dict, str(clip_key), "Skeleton3D")
		library.add_animation(str(clip_key), anim)

	hero_player = AnimationPlayer.new()
	hero_player.name = "AnimationPlayer"
	hero_root.add_child(hero_player)
	hero_player.add_animation_library("", library)
	hero_player.root_node = hero_player.get_path_to(hero_root)

	hero_stats = {
		"bones": hero_skeleton.get_bone_count(),
		"meshes": int(skin_info.get("meshes", 0)),
		"clips": clips_dict.size(),
	}


func _attach_hero_skin(rig: Skeleton3D) -> Dictionary:
	var out := {"meshes": 0}
	if not FileAccess.file_exists(HERO_SKIN_GLB):
		return out
	var bytes := FileAccess.get_file_as_bytes(HERO_SKIN_GLB)
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
	scene.free()
	return out


func _raycast_world(from_p: Vector3, to_p: Vector3) -> Dictionary:
	if stage_root == null or stage_root.get_world_3d() == null:
		return {"hit": false}
	var space := stage_root.get_world_3d().direct_space_state
	if space == null:
		return {"hit": false}
	var q := PhysicsRayQueryParameters3D.create(from_p, to_p)
	var res := space.intersect_ray(q)
	if res.is_empty():
		return {"hit": false}
	var p: Vector3 = res["position"]
	var dist := from_p.distance_to(to_p)
	return {
		"hit": true,
		"position": p,
		"normal": res["normal"],
		"fraction": from_p.distance_to(p) / maxf(1e-5, dist),
	}


func _find_first_line(line_type: int, min_y: float = -10.0, max_y: float = 20.0, min_len: float = 1.5) -> Dictionary:
	for line in controller.line_world.lines:
		if int(line["line_type"]) != line_type:
			continue
		var a: Vector3 = line["a"]
		var b: Vector3 = line["b"]
		if a.y >= min_y and a.y <= max_y and a.distance_to(b) >= min_len:
			return line
	return {}


func start_scenario(scenario_id: String) -> void:
	active_scenario = scenario_id
	controller.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
	match scenario_id:
		"locomotion":
			# Central open courtyard near cover walls on ground y=0
			controller.teleport_hero(Vector3(-11.0, 0.0, 12.0), -0.6)
			controller.raise_event("WeaponToggle", _raycast_world)
		"cover":
			var cov := _find_first_line(LinesScript.LINE_TYPE_LOW_WALL, -0.5, 0.5, 2.0)
			if not cov.is_empty():
				var mid := ((cov["a"] as Vector3) + (cov["b"] as Vector3)) * 0.5
				var n: Vector3 = cov["edge_normal"]
				var spawn := mid + n * 1.35
				var yaw := atan2(-n.x, -n.z)
				controller.teleport_hero(spawn, yaw)
				controller.raise_event("Action", _raycast_world)
		"vault":
			var rail := _find_first_line(LinesScript.LINE_TYPE_RAILING, 0.7, 1.5, 3.0)
			if not rail.is_empty():
				var mid := ((rail["a"] as Vector3) + (rail["b"] as Vector3)) * 0.5
				var n: Vector3 = rail["edge_normal"]
				var spawn := Vector3(mid.x + n.x * 1.9, 0.0, mid.z + n.z * 1.9)
				var yaw := atan2(-n.x, -n.z)
				controller.teleport_hero(spawn, yaw)
				controller.raise_event("JumpButton", _raycast_world)
		"climb":
			var ledge := _find_first_line(LinesScript.LINE_TYPE_LEDGE, 1.8, 2.3, 2.5)
			if not ledge.is_empty():
				var mid := ((ledge["a"] as Vector3) + (ledge["b"] as Vector3)) * 0.5
				var n: Vector3 = ledge["edge_normal"]
				var spawn := Vector3(mid.x + n.x * 1.45, 0.0, mid.z + n.z * 1.45)
				var yaw := atan2(-n.x, -n.z)
				controller.teleport_hero(spawn, yaw)
				controller.raise_event("JumpButton", _raycast_world)
		"leap":
			# High platform edge at y=5.0m facing opposite platform at y=6.0m/5.0m across gap
			var target_ledge := _find_first_line(LinesScript.LINE_TYPE_LEDGE, 4.8, 5.2, 3.0)
			if not target_ledge.is_empty():
				var mid := ((target_ledge["a"] as Vector3) + (target_ledge["b"] as Vector3)) * 0.5
				var n: Vector3 = target_ledge["edge_normal"]
				var spawn := Vector3(mid.x + n.x * 4.2, mid.y - 0.5, mid.z + n.z * 4.2)
				var yaw := atan2(-n.x, -n.z)
				controller.teleport_hero(spawn, yaw)
				controller.raise_event("JumpButton", _raycast_world)
		"strafe":
			controller.teleport_hero(Vector3(-12.0, 0.0, 14.0), 0.3)
			controller.raise_event("Strafe", _raycast_world)

	_sync_actor_and_camera(0.016)
	_refresh_debug_lines()
	_refresh_hud()


func set_playing(v: bool) -> void:
	playing = v
	if is_instance_valid(_play_btn):
		_play_btn.text = "일시정지" if playing else "재생"


func _process(delta: float) -> void:
	if not visible or not playing or hero_skeleton == null:
		return
	var dt := clampf(delta, 0.001, 0.04)
	if auto_tour:
		_drive_auto_tour(dt)
	else:
		_poll_manual_input()
	controller.step(dt, hero_skeleton, _raycast_world)
	_sync_actor_and_camera(dt)
	_refresh_debug_lines()
	_refresh_hud()


func _drive_auto_tour(dt: float) -> void:
	_tour_clock += dt
	# Cycle smoothly through every restored Lua behavior script on the real Environment map
	var phase := int(floor(fmod(_tour_clock, 24.0) / 4.0))
	if phase != _tour_step:
		_tour_step = phase
		match phase:
			0:
				start_scenario("locomotion")
			1:
				controller.raise_event("Attack", _raycast_world)
			2:
				start_scenario("cover")
			3:
				start_scenario("vault")
			4:
				start_scenario("climb")
			5:
				start_scenario("leap")
	# Provide subtle stick motion during locomotion & cover/hanging phases
	if phase == 0 and str(controller.state["active_state"]) in ["Idle", "Run"]:
		controller.gamepad.set_raw_input(0.0, 0.85, 0.25, 0.0, 0.0)
	elif phase == 2 and str(controller.state["active_state"]) == "Cover":
		controller.gamepad.set_raw_input(0.85, 0.0, 0.0, 0.0, 0.0)
	elif phase == 4 and str(controller.state["active_state"]) == "Hanging":
		if fmod(_tour_clock, 4.0) > 2.2:
			controller.gamepad.set_raw_input(0.0, 0.95, 0.0, 0.0, 0.0) # climb up!
		else:
			controller.gamepad.set_raw_input(0.85, 0.0, 0.0, 0.0, 0.0) # shimmy!
	else:
		controller.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)


func _poll_manual_input() -> void:
	if Engine.is_editor_hint():
		return
	var lx := Input.get_axis("ui_left", "ui_right")
	var ly := Input.get_axis("ui_down", "ui_up")
	if Input.is_key_pressed(KEY_A): lx -= 1.0
	if Input.is_key_pressed(KEY_D): lx += 1.0
	if Input.is_key_pressed(KEY_W): ly += 1.0
	if Input.is_key_pressed(KEY_S): ly -= 1.0
	var lt := 1.0 if Input.is_key_pressed(KEY_SHIFT) else 0.0
	controller.gamepad.set_raw_input(lx, ly, 0.0, 0.0, lt)


func _unhandled_key_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not visible or not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	match ke.keycode:
		KEY_SPACE:
			auto_tour = false
			controller.raise_event("JumpButton", _raycast_world)
		KEY_E:
			auto_tour = false
			controller.raise_event("Action", _raycast_world)
		KEY_R:
			auto_tour = false
			controller.raise_event("WeaponToggle", _raycast_world)
		KEY_F:
			auto_tour = false
			controller.raise_event("Attack", _raycast_world)
		KEY_Q:
			auto_tour = false
			if str(controller.state["active_state"]) == "Strafe":
				controller.raise_event("StrafeEnd", _raycast_world)
			else:
				controller.raise_event("Strafe", _raycast_world)
		KEY_TAB:
			show_docking_lines = not show_docking_lines
			if is_instance_valid(_lines_btn):
				_lines_btn.set_pressed_no_signal(show_docking_lines)
			if debug_lines_mesh != null:
				debug_lines_mesh.visible = show_docking_lines


func _on_vp_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_last_mouse = mb.position
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		controller.cam.add_mouse_orbit(mm.position - _last_mouse)
		_last_mouse = mm.position


func _sync_actor_and_camera(dt: float) -> void:
	if hero_root == null or hero_player == null:
		return
	hero_root.position = controller.hero_pos
	hero_root.rotation = Vector3(0.0, controller.hero_yaw, 0.0)

	var clip_name: String = str(controller.state["active_clip"])
	if clip_name != _last_clip_name:
		if hero_player.has_animation(clip_name):
			hero_player.play(clip_name, 0.14)
		_last_clip_name = clip_name
	if hero_player.is_playing():
		hero_player.advance(dt)

	if camera != null:
		var eye: Vector3 = controller.cam.from_pos
		var tgt: Vector3 = controller.cam.to_pos
		if eye.distance_to(tgt) > 0.05:
			camera.position = eye
			camera.look_at(tgt, Vector3.UP)


func _refresh_debug_lines() -> void:
	if debug_lines_mesh == null:
		return
	var hl: int = int(controller.line_world.docking_target.get("index", -1))
	if hl != _last_hl_line:
		_last_hl_line = hl
		debug_lines_mesh.mesh = controller.line_world.build_debug_lines_mesh(hl)
	debug_lines_mesh.visible = show_docking_lines


func _refresh_hud() -> void:
	if _state_label == null or _vars_label == null:
		return
	var st: Dictionary = controller.state
	var v: Dictionary = controller.variables
	var dock_txt := "없음"
	if not controller.line_world.docking_target.is_empty():
		var dt: Dictionary = controller.line_world.docking_target
		dock_txt = "#%d %s (u=%.2f)" % [int(dt["index"]), LinesScript.label_for_line_type(int(dt["line_type"])), float(st["line_param"])]
	var cam_modes := ["3RD_PERSON (5.0m)", "OVER_SHOULDER", "CLIMB_LEDGE (3.5m)"]

	_state_label.text = (
		"[b][color=#5cd3b0]상태:[/color] %s[/b]  |  클립: [color=#f0a85a]%s[/color]\n" +
		"최근 이벤트: [b]%s[/b]\n" +
		"배경맵: hero_environment.glb (%d삼각형 · %d정점)\n" +
		"도킹 라인: %d개 · 현재 타깃: %s"
	) % [
		str(st["active_state"]), str(st["active_clip"]), str(st["last_event"]),
		int(env_stats["tris"]), int(env_stats["verts"]),
		controller.line_world.lines.size(), dock_txt,
	]

	_vars_label.text = (
		"[color=#5cd3b0][복원된 Havok Lua 변수][/color]\n" +
		"IsRightFootForward = %d   |   WeaponType = %d\n" +
		"m_isSupported = %s   |   m_pushingIntoWall = %s\n" +
		"CameraMode = %s\n" +
		"AnimationIndex = %d   |   GravityFactor = %.2f\n" +
		"VaultingSelector = %d  |   VaultFromLeft = %d\n" +
		"ClimbAnimIndex = %d    |   LeapSelector = %d\n" +
		"DockingHeight = %d     |   IntoCoverStart = %d\n" +
		"Hero Pos = (%.1f, %.2f, %.1f)\n" +
		"[color=#99a8ba]이벤트 로그: %s[/color]"
	) % [
		int(v["IsRightFootForward"]), int(v["WeaponType"]),
		str(st["is_supported"]), str(st["pushing_into_wall"]),
		cam_modes[clampi(controller.cam.mode, 0, 2)],
		int(v["AnimationIndex"]), float(v["GravityFactor"]),
		int(v["VaultingSelector"]), int(v["VaultFromLeft"]),
		int(v["ClimbAnimationIndex"]), int(v["LeapSelector"]),
		int(v["DockingHeightSelector"]), int(v["IntoCoverStartState"]),
		controller.hero_pos.x, controller.hero_pos.y, controller.hero_pos.z,
		" → ".join(PackedStringArray((st["event_log"] as Array).slice(-5))),
	]

	_log_label.text = "조작: WASD=이동 · Shift=걷기 · Space=Jump/Vault/Climb/Leap · E=Cover/Drop · R=검 · F=공격 · Q=Strafe · Tab=라인 · 드래그=카메라"
