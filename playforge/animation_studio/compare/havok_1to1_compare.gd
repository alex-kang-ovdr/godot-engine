extends Control
class_name Havok1To1CompareViewer
## Interactive 1:1 Comparison Viewer: Real Havok 2015.1.0-r1 Behavior C++ SDK vs Godot 4.7.2 Port.
## Renders the live Godot skinned character alongside/overlapped with the real Havok C++ SDK
## landmark rig, root trajectory ribbon, live mm error segments, and clickable Event Timing table.

const Runner := preload("res://compare/behavior_1to1_runner.gd")
const Store := preload("res://characters/character_store.gd")
const FloorShader := preload("res://demo/floor.gdshader")

const COL_BG := Color("#10141a")
const COL_PANEL := Color("#171d26")
const COL_CARD := Color("#1e2632")
const COL_BORDER := Color("#2c3849")
const COL_FG := Color("#e8f0f6")
const COL_DIM := Color("#93a6b8")
const COL_HAVOK := Color("#f5a524")   # Amber = Real Havok 2015.1 C++ SDK
const COL_GODOT := Color("#2cc7b8")   # Teal = Godot 4.7.2 Live Port
const COL_ERR := Color("#ff5b6e")     # Coral-red = Delta error link
const COL_OK := Color("#46d893")      # Green = 0-tick / <5mm match

const GODOT_FOV := 45.0

var scenario_id: String = "hero_locomotion_flat"
var compare_mode: String = "overlap" # "overlap" or "side_by_side"
var playing: bool = true
var playback_speed: float = 1.0
var current_tick: int = 0
var camera_preset: int = 0 # 0=3/4, 1=Front, 2=Side, 3=Top Trajectory

var _run_cache: Dictionary = {}
var _current_run: Dictionary = {}
var _tick_accum: float = 0.0

# 3D scene references
var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _floor_mesh: MeshInstance3D
var _godot_group: Node3D
var _havok_group: Node3D
var _char_motion: Node3D
var _char_skel: Skeleton3D
var _havok_lm_nodes: Dictionary = {}
var _godot_lm_nodes: Dictionary = {}
var _havok_root_ring: MeshInstance3D
var _godot_root_ring: MeshInstance3D
var _havok_rig_mesh: MeshInstance3D
var _havok_trail_mesh: MeshInstance3D
var _godot_trail_mesh: MeshInstance3D
var _error_links_mesh: MeshInstance3D
var _mat_havok: StandardMaterial3D
var _mat_godot: StandardMaterial3D
var _mat_err: StandardMaterial3D
var _mat_havok_line: StandardMaterial3D
var _mat_godot_line: StandardMaterial3D

# Camera orbit state
var _cam_yaw: float = 0.55
var _cam_pitch: float = -0.26
var _cam_dist: float = 4.2
var _dragging: bool = false

# UI references
var _scenario_opt: OptionButton
var _mode_btn: Button
var _play_btn: Button
var _speed_opt: OptionButton
var _cam_opt: OptionButton
var _tick_slider: HSlider
var _tick_label: Label
var _kpi_events: Label
var _kpi_state: Label
var _kpi_clip: Label
var _kpi_root: Label
var _kpi_yaw: Label
var _kpi_pose: Label
var _live_state_lbl: Label
var _live_clip_lbl: Label
var _live_root_lbl: Label
var _live_events_lbl: Label
var _lm_rows_box: VBoxContainer
var _event_rows_box: VBoxContainer
var _event_buttons: Array[Button] = []
var _event_ticks: Array[int] = []
var _updating_slider: bool = false
var _initialized: bool = false


func _ready() -> void:
	ensure_initialized()


func ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_theme()
	_build_layout()
	_build_3d_world()
	load_scenario(scenario_id)


func _free_node_immediate(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	var p := n.get_parent()
	if p != null:
		p.remove_child(n)
	n.free()


func cleanup() -> void:
	_run_cache.clear()
	_current_run = {}
	if _char_motion != null:
		_free_node_immediate(_char_motion)
		_char_motion = null
		_char_skel = null
	for node in _havok_lm_nodes.values():
		_free_node_immediate(node as Node)
	for node in _godot_lm_nodes.values():
		_free_node_immediate(node as Node)
	_havok_lm_nodes.clear()
	_godot_lm_nodes.clear()
	if _havok_rig_mesh != null:
		_havok_rig_mesh.mesh = null
	if _havok_trail_mesh != null:
		_havok_trail_mesh.mesh = null
	if _godot_trail_mesh != null:
		_godot_trail_mesh.mesh = null
	if _error_links_mesh != null:
		_error_links_mesh.mesh = null


func _apply_theme() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Segoe UI", "Noto Sans"])
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 13
	t.set_color("font_color", "Label", COL_FG)
	t.set_color("font_color", "Button", COL_FG)
	t.set_color("font_color", "OptionButton", COL_FG)
	t.set_stylebox("normal", "Button", _flat_box(COL_CARD, COL_BORDER, 5, 10, 5))
	t.set_stylebox("hover", "Button", _flat_box(Color("#263141"), COL_GODOT, 5, 10, 5))
	t.set_stylebox("pressed", "Button", _flat_box(Color("#1f3a3b"), COL_GODOT, 5, 10, 5))
	t.set_stylebox("normal", "OptionButton", _flat_box(COL_CARD, COL_BORDER, 5, 10, 5))
	t.set_stylebox("hover", "OptionButton", _flat_box(Color("#263141"), COL_GODOT, 5, 10, 5))
	t.set_stylebox("panel", "PanelContainer", _flat_box(COL_PANEL, COL_BORDER, 8, 12, 10))
	theme = t


func _flat_box(bg: Color, border: Color, radius: int, px: int, py: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = px
	sb.content_margin_right = px
	sb.content_margin_top = py
	sb.content_margin_bottom = py
	return sb


func _build_layout() -> void:
	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root_v := VBoxContainer.new()
	root_v.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_v.add_theme_constant_override("separation", 6)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 58 if Engine.has_singleton("PlayForgePlatform") else 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	margin.add_child(root_v)

	# --- Top Toolbar ---
	var top_panel := PanelContainer.new()
	root_v.add_child(top_panel)
	var top_h := HBoxContainer.new()
	top_h.add_theme_constant_override("separation", 8)
	top_panel.add_child(top_h)

	var back_btn := Button.new()
	back_btn.text = "← 모션 실험실"
	back_btn.pressed.connect(func():
		if get_tree() != null:
			get_tree().change_scene_to_file("res://demo/animation_lab.tscn")
	)
	top_h.add_child(back_btn)

	var title_lbl := Label.new()
	title_lbl.text = "Havok 2015.1 C++ vs Godot 4.7.2 · 1:1 정밀 비교"
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.add_theme_color_override("font_color", COL_FG)
	top_h.add_child(title_lbl)

	_scenario_opt = OptionButton.new()
	_scenario_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for sc_id in Runner.SCENARIO_ORDER:
		var meta: Dictionary = Runner.SCENARIO_META[sc_id] as Dictionary
		_scenario_opt.add_item(str(meta["title"]))
	_scenario_opt.item_selected.connect(func(idx: int):
		if idx >= 0 and idx < Runner.SCENARIO_ORDER.size():
			load_scenario(str(Runner.SCENARIO_ORDER[idx]))
	)
	top_h.add_child(_scenario_opt)

	_mode_btn = Button.new()
	_mode_btn.text = "모드: 겹쳐 비교"
	_mode_btn.pressed.connect(toggle_compare_mode)
	top_h.add_child(_mode_btn)

	_cam_opt = OptionButton.new()
	for label in ["카메라: 3/4 표준", "카메라: 정면", "카메라: 측면", "카메라: 상단 궤적"]:
		_cam_opt.add_item(label)
	_cam_opt.item_selected.connect(func(idx: int): set_camera_preset(idx))
	top_h.add_child(_cam_opt)

	# --- Main Content Split (Left 3D Viewport + Right Telemetry Panel) ---
	var main_h := HBoxContainer.new()
	main_h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_h.add_theme_constant_override("separation", 8)
	root_v.add_child(main_h)

	# Left: 3D Viewport + Transport bar
	var left_v := VBoxContainer.new()
	left_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_v.add_theme_constant_override("separation", 6)
	main_h.add_child(left_v)

	var vp_frame := PanelContainer.new()
	vp_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_frame.add_theme_stylebox_override("panel", _flat_box(Color("#0c1016"), COL_BORDER, 8, 2, 2))
	left_v.add_child(vp_frame)

	_viewport_container = SubViewportContainer.new()
	_viewport_container.stretch = true
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.gui_input.connect(_on_viewport_gui_input)
	vp_frame.add_child(_viewport_container)

	_viewport = SubViewport.new()
	_viewport.handle_input_locally = false
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport_container.add_child(_viewport)

	# Bottom Transport Bar
	var transport_panel := PanelContainer.new()
	left_v.add_child(transport_panel)
	var tr_h := HBoxContainer.new()
	tr_h.add_theme_constant_override("separation", 6)
	transport_panel.add_child(tr_h)

	_play_btn = Button.new()
	_play_btn.text = "일시정지"
	_play_btn.pressed.connect(func(): set_playing(not playing))
	tr_h.add_child(_play_btn)

	var prev_btn := Button.new()
	prev_btn.text = "-1틱"
	prev_btn.pressed.connect(func():
		set_playing(false)
		set_tick(current_tick - 1)
	)
	tr_h.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "+1틱"
	next_btn.pressed.connect(func():
		set_playing(false)
		set_tick(current_tick + 1)
	)
	tr_h.add_child(next_btn)

	var reset_btn := Button.new()
	reset_btn.text = "0틱"
	reset_btn.pressed.connect(func(): set_tick(0))
	tr_h.add_child(reset_btn)

	_tick_slider = HSlider.new()
	_tick_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tick_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tick_slider.step = 1.0
	_tick_slider.value_changed.connect(func(v: float):
		if not _updating_slider:
			set_playing(false)
			set_tick(int(v))
	)
	tr_h.add_child(_tick_slider)

	_tick_label = Label.new()
	_tick_label.custom_minimum_size = Vector2(155, 0)
	_tick_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tr_h.add_child(_tick_label)

	_speed_opt = OptionButton.new()
	for sp in ["0.25×", "0.5×", "1.0×"]:
		_speed_opt.add_item(sp)
	_speed_opt.select(2)
	_speed_opt.item_selected.connect(func(idx: int):
		var rates := [0.25, 0.5, 1.0]
		playback_speed = rates[clampi(idx, 0, rates.size() - 1)]
	)
	tr_h.add_child(_speed_opt)

	# --- Right Panel: KPI Summary, Live Tick Readout, Per-Bone Landmarks, Clickable Event Timing Table ---
	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size = Vector2(430, 0)
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_h.add_child(right_panel)

	var right_v := VBoxContainer.new()
	right_v.add_theme_constant_override("separation", 8)
	right_panel.add_child(right_v)

	# Legend Strip
	var legend_h := HBoxContainer.new()
	legend_h.add_theme_constant_override("separation", 12)
	right_v.add_child(legend_h)
	var leg_hk := Label.new()
	leg_hk.text = "● Havok 2015.1 C++ 실측"
	leg_hk.add_theme_color_override("font_color", COL_HAVOK)
	legend_h.add_child(leg_hk)
	var leg_gd := Label.new()
	leg_gd.text = "● Godot 4.7.2 포팅"
	leg_gd.add_theme_color_override("font_color", COL_GODOT)
	legend_h.add_child(leg_gd)
	var leg_err := Label.new()
	leg_err.text = "— 오차 링크"
	leg_err.add_theme_color_override("font_color", COL_ERR)
	legend_h.add_child(leg_err)

	# KPI Card
	var kpi_card := PanelContainer.new()
	kpi_card.add_theme_stylebox_override("panel", _flat_box(COL_CARD, COL_BORDER, 6, 10, 8))
	right_v.add_child(kpi_card)
	var kpi_grid := GridContainer.new()
	kpi_grid.columns = 2
	kpi_grid.add_theme_constant_override("h_separation", 12)
	kpi_grid.add_theme_constant_override("v_separation", 4)
	kpi_card.add_child(kpi_grid)
	_kpi_events = _add_kv(kpi_grid, "이벤트 타이밍")
	_kpi_state = _add_kv(kpi_grid, "상태머신 일치")
	_kpi_clip = _add_kv(kpi_grid, "클립 로컬타임")
	_kpi_root = _add_kv(kpi_grid, "루트 궤적 오차")
	_kpi_yaw = _add_kv(kpi_grid, "회전(Yaw) 오차")
	_kpi_pose = _add_kv(kpi_grid, "포즈 랜드마크")

	# Live Tick Card
	var live_card := PanelContainer.new()
	live_card.add_theme_stylebox_override("panel", _flat_box(COL_CARD, COL_BORDER, 6, 10, 8))
	right_v.add_child(live_card)
	var live_v := VBoxContainer.new()
	live_v.add_theme_constant_override("separation", 3)
	live_card.add_child(live_v)
	var live_hdr := Label.new()
	live_hdr.text = "현재 틱 실시간 비교 (60 Hz)"
	live_hdr.add_theme_color_override("font_color", COL_DIM)
	live_v.add_child(live_hdr)
	_live_state_lbl = Label.new()
	_live_clip_lbl = Label.new()
	_live_root_lbl = Label.new()
	_live_events_lbl = Label.new()
	_live_events_lbl.add_theme_color_override("font_color", COL_HAVOK)
	for lbl in [_live_state_lbl, _live_clip_lbl, _live_root_lbl, _live_events_lbl]:
		live_v.add_child(lbl)

	# Per-Bone Landmarks Card
	var lm_hdr := Label.new()
	lm_hdr.text = "랜드마크 본 3D 위치 비교 (현재 포즈 Δmm · 시나리오 RMS)"
	lm_hdr.add_theme_color_override("font_color", COL_DIM)
	right_v.add_child(lm_hdr)
	var lm_card := PanelContainer.new()
	lm_card.add_theme_stylebox_override("panel", _flat_box(COL_CARD, COL_BORDER, 6, 10, 6))
	right_v.add_child(lm_card)
	_lm_rows_box = VBoxContainer.new()
	_lm_rows_box.add_theme_constant_override("separation", 2)
	lm_card.add_child(_lm_rows_box)

	# Clickable Event Timing Table
	var ev_hdr := Label.new()
	ev_hdr.text = "이벤트 타이밍 1:1 대조표 (클릭 시 해당 틱으로 이동)"
	ev_hdr.add_theme_color_override("font_color", COL_DIM)
	right_v.add_child(ev_hdr)
	var ev_scroll := ScrollContainer.new()
	ev_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_v.add_child(ev_scroll)
	_event_rows_box = VBoxContainer.new()
	_event_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_event_rows_box.add_theme_constant_override("separation", 3)
	ev_scroll.add_child(_event_rows_box)


func _add_kv(grid: GridContainer, k: String) -> Label:
	var kl := Label.new()
	kl.text = k
	kl.add_theme_color_override("font_color", COL_DIM)
	grid.add_child(kl)
	var vl := Label.new()
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grid.add_child(vl)
	return vl


func _build_3d_world() -> void:
	_world = Node3D.new()
	_viewport.add_child(_world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#131a22")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#d8e6f2")
	env.ambient_light_energy = 0.72
	var we := WorldEnvironment.new()
	we.environment = env
	_world.add_child(we)

	var key_light := DirectionalLight3D.new()
	key_light.rotation = Vector3(-0.88, -0.58, 0.0)
	key_light.light_color = Color("#fff4e4")
	key_light.light_energy = 1.15
	key_light.shadow_enabled = true
	key_light.directional_shadow_max_distance = 24.0
	_world.add_child(key_light)

	var rim_light := DirectionalLight3D.new()
	rim_light.rotation = Vector3(-0.32, 2.55, 0.08)
	rim_light.light_color = Color("#70c4ff")
	rim_light.light_energy = 0.55
	_world.add_child(rim_light)

	_floor_mesh = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60.0, 60.0)
	var smat := ShaderMaterial.new()
	smat.shader = FloorShader
	pm.material = smat
	_floor_mesh.mesh = pm
	_world.add_child(_floor_mesh)

	_camera = Camera3D.new()
	_camera.fov = GODOT_FOV
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.near = 0.05
	_camera.far = 120.0
	_camera.current = true
	_world.add_child(_camera)

	_mat_havok = StandardMaterial3D.new()
	_mat_havok.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_havok.albedo_color = COL_HAVOK
	_mat_havok.no_depth_test = true
	_mat_havok.render_priority = 4

	_mat_godot = StandardMaterial3D.new()
	_mat_godot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_godot.albedo_color = COL_GODOT
	_mat_godot.no_depth_test = true
	_mat_godot.render_priority = 5

	_mat_err = StandardMaterial3D.new()
	_mat_err.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_err.albedo_color = COL_ERR
	_mat_err.no_depth_test = true
	_mat_err.render_priority = 6

	_mat_havok_line = StandardMaterial3D.new()
	_mat_havok_line.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_havok_line.albedo_color = Color(COL_HAVOK.r, COL_HAVOK.g, COL_HAVOK.b, 0.92)
	_mat_havok_line.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_havok_line.render_priority = 2

	_mat_godot_line = StandardMaterial3D.new()
	_mat_godot_line.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_godot_line.albedo_color = Color(COL_GODOT.r, COL_GODOT.g, COL_GODOT.b, 0.92)
	_mat_godot_line.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_godot_line.render_priority = 3

	_godot_group = Node3D.new()
	_godot_group.name = "GodotPortGroup"
	_world.add_child(_godot_group)

	_havok_group = Node3D.new()
	_havok_group.name = "HavokReferenceGroup"
	_world.add_child(_havok_group)

	_havok_root_ring = _make_root_ring(_mat_havok, 0.34, 0.012)
	_havok_group.add_child(_havok_root_ring)
	_godot_root_ring = _make_root_ring(_mat_godot, 0.28, 0.016)
	_godot_group.add_child(_godot_root_ring)

	_havok_rig_mesh = MeshInstance3D.new()
	_havok_rig_mesh.material_override = _mat_havok
	_havok_rig_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_havok_group.add_child(_havok_rig_mesh)

	_havok_trail_mesh = MeshInstance3D.new()
	_havok_trail_mesh.material_override = _mat_havok_line
	_havok_trail_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_havok_group.add_child(_havok_trail_mesh)

	_godot_trail_mesh = MeshInstance3D.new()
	_godot_trail_mesh.material_override = _mat_godot_line
	_godot_trail_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_godot_group.add_child(_godot_trail_mesh)

	_error_links_mesh = MeshInstance3D.new()
	_error_links_mesh.material_override = _mat_err
	_error_links_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_error_links_mesh)


func _make_root_ring(mat: Material, radius: float, y_pos: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	const SEGS := 28
	for i in SEGS + 1:
		var a := float(i) / float(SEGS) * TAU
		im.surface_add_vertex(Vector3(cos(a) * radius, y_pos, sin(a) * radius))
	im.surface_end()
	# Forward nose tick (+Z in raw space, rotated by root basis)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(Vector3(0.0, y_pos, 0.0))
	im.surface_add_vertex(Vector3(0.0, y_pos, radius * 1.45))
	im.surface_end()
	mi.mesh = im
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _make_orb(mat: Material, radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 14
	sm.rings = 8
	mi.mesh = sm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func load_scenario(sc_id: String) -> void:
	if not _initialized:
		scenario_id = sc_id
		ensure_initialized()
		return
	if not Runner.SCENARIO_META.has(sc_id):
		return
	scenario_id = sc_id
	var idx := Runner.SCENARIO_ORDER.find(sc_id)
	if idx >= 0 and _scenario_opt != null:
		_scenario_opt.select(idx)

	if not _run_cache.has(sc_id):
		_run_cache[sc_id] = Runner.run_scenario(sc_id, "", true)
	_current_run = _run_cache[sc_id] as Dictionary

	var meta: Dictionary = _current_run["meta"] as Dictionary
	var cid := str(meta["character"])
	var mdict := Store.load_motion_dict(cid)

	# Rebuild Godot live skinned character
	if _char_motion != null:
		_free_node_immediate(_char_motion)
		_char_motion = null
		_char_skel = null
	_char_motion = Node3D.new()
	_char_motion.name = "Character_" + cid
	_char_skel = Skeleton3D.new()
	_char_skel.name = "Rig"
	Store.populate_skeleton(_char_skel, mdict)
	Store.attach_skin_to_skeleton(cid, _char_skel)
	_char_motion.add_child(_char_skel)
	_godot_group.add_child(_char_motion)

	# Rebuild landmark orbs for Havok (Amber) and Godot (Teal)
	for node in _havok_lm_nodes.values():
		_free_node_immediate(node as Node)
	for node in _godot_lm_nodes.values():
		_free_node_immediate(node as Node)
	_havok_lm_nodes.clear()
	_godot_lm_nodes.clear()
	var lm_names: Array = meta["landmarks"] as Array
	var orb_r := 0.055 if cid == "siege_fiend" else 0.036
	for nm_raw in lm_names:
		var nm := str(nm_raw)
		var ho := _make_orb(_mat_havok, orb_r)
		_havok_group.add_child(ho)
		_havok_lm_nodes[nm] = ho
		var go := _make_orb(_mat_godot, orb_r * 0.72)
		_godot_group.add_child(go)
		_godot_lm_nodes[nm] = go

	# Build root trajectory ribbons
	_rebuild_trails()
	_populate_summary_ui()
	_apply_mode_offsets()

	var n_ticks := mini((_current_run["godot_frames"] as Array).size(), (_current_run["havok_frames"] as Array).size())
	_updating_slider = true
	_tick_slider.min_value = 0
	_tick_slider.max_value = maxi(0, n_ticks - 1)
	_tick_slider.value = 0
	_updating_slider = false

	_cam_dist = 6.2 if cid == "siege_fiend" else 3.8
	set_camera_preset(camera_preset)
	set_tick(0)


func _rebuild_trails() -> void:
	var g_frames: Array = _current_run["godot_frames"] as Array
	var h_frames: Array = _current_run["havok_frames"] as Array
	_havok_trail_mesh.mesh = _build_trail_mesh(h_frames, true)
	_godot_trail_mesh.mesh = _build_trail_mesh(g_frames, false)


func _build_trail_mesh(frames: Array, is_havok: bool) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	if frames.size() < 2:
		return im
	var pts: Array[Vector3] = []
	for fr_raw in frames:
		var fr: Dictionary = fr_raw as Dictionary
		var p: Vector3
		if is_havok:
			var arr: Array = fr.get("r", [0.0, 0.0, 0.0]) as Array
			p = Vector3(float(arr[0]), 0.025, float(arr[2]))
		else:
			var gr: Vector3 = fr["root"] as Vector3
			p = Vector3(gr.x, 0.032, gr.z)
		if pts.is_empty() or pts[pts.size() - 1].distance_squared_to(p) > 1e-6:
			pts.append(p)
	if pts.size() >= 2:
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for p in pts:
			im.surface_add_vertex(p)
		im.surface_end()
	return im


func _populate_summary_ui() -> void:
	var m: Dictionary = _current_run["metrics"] as Dictionary
	var matched := int(m["matched_events"])
	var total_hk := int(m["havok_events"])
	var max_dt := int(m["max_event_dtick"])
	var max_dms := float(m["max_event_dms"])
	_kpi_events.text = "%d / %d 일치 (최대 Δ%d틱 · %.1fms)" % [matched, total_hk, max_dt, max_dms]
	_kpi_events.add_theme_color_override("font_color", COL_OK if matched == total_hk and max_dt == 0 else COL_HAVOK)

	var st_pct := float(m["state_match_pct"])
	_kpi_state.text = "%.1f%% (%d / %d틱)" % [st_pct, int(m["state_match_ticks"]), int(m["ticks"])]
	_kpi_state.add_theme_color_override("font_color", COL_OK if st_pct >= 99.9 else COL_HAVOK)

	_kpi_clip.text = "RMS %.2fms · Max %.2fms" % [float(m["clip_rms_ms"]), float(m["clip_max_ms"])]
	_kpi_root.text = "XZ %.2fmm · XYZ %.2fmm" % [float(m["root_xz_rms_mm"]), float(m["root_xyz_rms_mm"])]
	_kpi_yaw.text = "Max %.2f°" % float(m["yaw_max_deg"])
	_kpi_pose.text = "RMS %.2fmm · Max %.2fmm" % [float(m["pose_landmark_rms_mm"]), float(m["pose_landmark_max_mm"])]

	# Populate Clickable Event Table
	for c in _event_rows_box.get_children():
		_free_node_immediate(c)
	_event_buttons.clear()
	_event_ticks.clear()
	var pairs: Array = m.get("event_pairs", []) as Array
	for pair_raw in pairs:
		var pair: Dictionary = pair_raw as Dictionary
		var ht := int(pair["havok_tick"])
		var gt := int(pair["godot_tick"])
		var dt := int(pair["dtick"])
		var dms := float(pair["dms"])
		var nm := str(pair["name"])
		var btn := Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.clip_text = true
		btn.text = "T%03d (%.2fs)  %s  [H:%03d|G:%03d Δ%d틱]" % [
			ht, float(ht) * Runner.STEP, nm, ht, gt, dt
		]
		btn.tooltip_text = "%s — Havok Tick %d (%.3fs) vs Godot Tick %d (%.3fs) · Δ%d틱 (%.2fms)" % [
			nm, ht, float(ht) * Runner.STEP, gt, float(gt) * Runner.STEP, dt, dms
		]
		btn.add_theme_color_override("font_color", COL_OK if dt == 0 else COL_ERR)
		btn.pressed.connect(func():
			set_playing(false)
			set_tick(ht)
		)
		_event_rows_box.add_child(btn)
		_event_buttons.append(btn)
		_event_ticks.append(ht)


func toggle_compare_mode() -> void:
	set_compare_mode("side_by_side" if compare_mode == "overlap" else "overlap")


func set_compare_mode(mode: String) -> void:
	compare_mode = "side_by_side" if mode == "side_by_side" else "overlap"
	if _mode_btn != null:
		_mode_btn.text = "모드: 나란히 비교" if compare_mode == "side_by_side" else "모드: 겹쳐 비교"
	_apply_mode_offsets()
	_update_frame_visuals()


func _apply_mode_offsets() -> void:
	var cid := str((_current_run.get("meta", {}) as Dictionary).get("character", "hero"))
	var sep := 1.65 if cid == "siege_fiend" else 0.95
	if compare_mode == "side_by_side":
		_havok_group.position = Vector3(-sep, 0.0, 0.0)
		_godot_group.position = Vector3(sep, 0.0, 0.0)
	else:
		_havok_group.position = Vector3.ZERO
		_godot_group.position = Vector3.ZERO


func set_playing(value: bool) -> void:
	playing = value
	if _play_btn != null:
		_play_btn.text = "일시정지" if playing else "재생"


func set_camera_preset(preset: int) -> void:
	camera_preset = clampi(preset, 0, 3)
	if _cam_opt != null:
		_cam_opt.select(camera_preset)
	var cid := str((_current_run.get("meta", {}) as Dictionary).get("character", "hero"))
	var base_d := 6.0 if cid == "siege_fiend" else 3.7
	match camera_preset:
		0: # 3/4 Godot Standard front view
			_cam_yaw = 0.55 if cid != "soldier" else 1.15
			_cam_pitch = -0.26
			_cam_dist = base_d
		1: # Front
			_cam_yaw = 0.0 if cid != "soldier" else PI * 0.5
			_cam_pitch = -0.14
			_cam_dist = base_d * 0.95
		2: # Side
			_cam_yaw = PI * 0.5 if cid != "soldier" else 0.0
			_cam_pitch = -0.14
			_cam_dist = base_d
		3: # Top Trajectory
			_cam_yaw = 0.35
			_cam_pitch = -1.25
			_cam_dist = base_d * 1.65
	_update_camera()


func set_tick(tick: int) -> void:
	var g_frames: Array = _current_run.get("godot_frames", []) as Array
	var h_frames: Array = _current_run.get("havok_frames", []) as Array
	var n := mini(g_frames.size(), h_frames.size())
	if n == 0:
		return
	current_tick = clampi(tick, 0, n - 1)
	_updating_slider = true
	_tick_slider.value = float(current_tick)
	_updating_slider = false
	_update_frame_visuals()


func _process(delta: float) -> void:
	if playing and not _current_run.is_empty():
		var g_frames: Array = _current_run["godot_frames"] as Array
		var h_frames: Array = _current_run["havok_frames"] as Array
		var n := mini(g_frames.size(), h_frames.size())
		if n > 0:
			_tick_accum += delta * playback_speed
			while _tick_accum >= Runner.STEP:
				_tick_accum -= Runner.STEP
				current_tick = (current_tick + 1) % n
			_updating_slider = true
			_tick_slider.value = float(current_tick)
			_updating_slider = false
			_update_frame_visuals()


func _update_frame_visuals() -> void:
	if _current_run.is_empty() or _char_skel == null:
		return
	var g_frames: Array = _current_run["godot_frames"] as Array
	var h_frames: Array = _current_run["havok_frames"] as Array
	var n := mini(g_frames.size(), h_frames.size())
	if n == 0:
		return
	var t := clampi(current_tick, 0, n - 1)
	var gf: Dictionary = g_frames[t] as Dictionary
	var hf: Dictionary = h_frames[t] as Dictionary
	var meta: Dictionary = _current_run["meta"] as Dictionary
	var lm_names: Array = meta["landmarks"] as Array
	var primary_sm := str(meta["primary_sm"])

	# Apply live Godot skinned character pose
	Runner.apply_captured_pose(_char_skel, _char_motion, gf)

	# Update root rings
	var hr_arr: Array = hf.get("r", [0.0, 0.0, 0.0]) as Array
	var hr := Vector3(float(hr_arr[0]), float(hr_arr[1]), float(hr_arr[2]))
	var hy := float(hf.get("y", 0.0))
	var gr: Vector3 = gf["root"] as Vector3
	var gy := float(gf.get("yaw", 0.0))
	_havok_root_ring.position = Vector3(hr.x, 0.0, hr.z)
	_havok_root_ring.rotation = Vector3(0.0, hy, 0.0)
	_godot_root_ring.position = Vector3(gr.x, 0.0, gr.z)
	_godot_root_ring.rotation = Vector3(0.0, gy, 0.0)
	_floor_mesh.position = Vector3(gr.x, 0.0, gr.z)

	# Update landmark spheres + Havok stick rig + Error lines
	var h_lm: Dictionary = hf.get("lm", {}) as Dictionary
	var g_lm: Dictionary = gf.get("landmarks", {}) as Dictionary
	var h_pts: Dictionary = {}
	var g_pts: Dictionary = {}
	var err_im := ImmediateMesh.new()
	var has_err_seg := false
	for nm_raw in lm_names:
		var nm := str(nm_raw)
		if h_lm.has(nm):
			var ha: Array = h_lm[nm] as Array
			var hp := Vector3(float(ha[0]), float(ha[1]), float(ha[2]))
			h_pts[nm] = hp
			(_havok_lm_nodes[nm] as Node3D).position = hp
		if g_lm.has(nm):
			var gp: Vector3 = g_lm[nm] as Vector3
			g_pts[nm] = gp
			(_godot_lm_nodes[nm] as Node3D).position = gp
		if compare_mode == "overlap" and h_pts.has(nm) and g_pts.has(nm):
			var hp2: Vector3 = h_pts[nm] as Vector3
			var gp2: Vector3 = g_pts[nm] as Vector3
			if hp2.distance_to(gp2) > 0.004:
				if not has_err_seg:
					err_im.surface_begin(Mesh.PRIMITIVE_LINES)
					has_err_seg = true
				err_im.surface_add_vertex(_havok_group.position + hp2)
				err_im.surface_add_vertex(_godot_group.position + gp2)
	if has_err_seg:
		err_im.surface_end()
	_error_links_mesh.mesh = err_im

	# Draw Havok SDK reference stick skeleton connecting Pelvis/Root -> Head, Hands, Feet
	var rig_im := ImmediateMesh.new()
	if lm_names.size() >= 6:
		var pelvis_nm := str(lm_names[0])
		if h_pts.has(pelvis_nm):
			var pelvis: Vector3 = h_pts[pelvis_nm] as Vector3
			rig_im.surface_begin(Mesh.PRIMITIVE_LINES)
			for i in range(1, lm_names.size()):
				var cnm := str(lm_names[i])
				if h_pts.has(cnm):
					rig_im.surface_add_vertex(pelvis)
					rig_im.surface_add_vertex(h_pts[cnm] as Vector3)
			rig_im.surface_end()
	_havok_rig_mesh.mesh = rig_im

	# Update HUD text
	_tick_label.text = "Tick %03d / %03d · %.2fs" % [t, n - 1, float(t) * Runner.STEP]
	var h_st := str((hf.get("st", {}) as Dictionary).get(primary_sm, ""))
	var g_st := str(gf.get("state", ""))
	_live_state_lbl.text = "상태: Havok [%s]  vs  Godot [%s]  %s" % [
		h_st if not h_st.is_empty() else "(Idle)",
		g_st if not g_st.is_empty() else "(Idle)",
		"✓" if h_st == g_st else "✗",
	]

	var h_clips: Array = hf.get("cl", []) as Array
	var h_lt := float((h_clips[0] as Dictionary).get("lt", 0.0)) if not h_clips.is_empty() else 0.0
	var g_lt := float(gf.get("clip_time", 0.0))
	_live_clip_lbl.text = "클립 시간: H %.4fs | G %.4fs (Δ%.2fms)" % [h_lt, g_lt, absf(g_lt - h_lt) * 1000.0]

	var d_xz := Vector2(gr.x - hr.x, gr.z - hr.z).length() * 1000.0
	var d_yaw := rad_to_deg(absf(angle_difference(gy, hy)))
	_live_root_lbl.text = "루트 XZ Δ%.2fmm · Yaw Δ%.2f° (G %.2f, %.2f)" % [d_xz, d_yaw, gr.x, gr.z]

	var hev: Array = hf.get("ev", []) as Array
	var gev: Array = gf.get("events", []) as Array
	if hev.is_empty() and gev.is_empty():
		_live_events_lbl.text = "이벤트(현재 틱): 없음"
		_live_events_lbl.add_theme_color_override("font_color", COL_DIM)
	else:
		_live_events_lbl.text = "이벤트 발화! H:%s | G:%s" % [", ".join(hev), ", ".join(gev)]
		_live_events_lbl.add_theme_color_override("font_color", COL_HAVOK)

	# Update per-bone landmark rows
	for c in _lm_rows_box.get_children():
		_free_node_immediate(c)
	var lm_metrics: Dictionary = (_current_run["metrics"] as Dictionary).get("landmarks", {}) as Dictionary
	for nm_raw in lm_names:
		var nm := str(nm_raw)
		var pose_mm := 0.0
		if h_pts.has(nm) and g_pts.has(nm):
			pose_mm = ((g_pts[nm] as Vector3) - gr).distance_to((h_pts[nm] as Vector3) - hr) * 1000.0
		var st: Dictionary = lm_metrics.get(nm, {}) as Dictionary
		var row := Label.new()
		row.text = "%-13s  현재 %5.2fmm  |  RMS %5.2fmm  |  Max %6.2fmm" % [
			nm, pose_mm, float(st.get("pose_rms_mm", 0.0)), float(st.get("pose_max_mm", 0.0))
		]
		row.add_theme_color_override("font_color", COL_OK if pose_mm < 5.0 else (COL_HAVOK if pose_mm < 35.0 else COL_ERR))
		_lm_rows_box.add_child(row)

	# Highlight active event row
	for i in _event_buttons.size():
		var is_cur := _event_ticks[i] == t
		_event_buttons[i].modulate = Color(1.25, 1.25, 1.0, 1.0) if is_cur else Color.WHITE

	_update_camera()


func _update_camera() -> void:
	if _camera == null or _current_run.is_empty():
		return
	var g_frames: Array = _current_run["godot_frames"] as Array
	if g_frames.is_empty():
		return
	var t := clampi(current_tick, 0, g_frames.size() - 1)
	var gr: Vector3 = (g_frames[t] as Dictionary)["root"] as Vector3
	var cid := str((_current_run["meta"] as Dictionary).get("character", "hero"))
	var target := Vector3(gr.x, 1.15 if cid == "siege_fiend" else 0.95, gr.z)
	var cos_p := cos(_cam_pitch)
	var offset := Vector3(
		sin(_cam_yaw) * cos_p,
		-sin(_cam_pitch),
		cos(_cam_yaw) * cos_p
	) * _cam_dist
	_camera.look_at_from_position(target + offset, target, Vector3.UP)


func _on_viewport_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_cam_dist = clampf(_cam_dist * 0.9, 1.5, 18.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_cam_dist = clampf(_cam_dist * 1.1, 1.5, 18.0)
			_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_cam_yaw -= mm.relative.x * 0.008
		_cam_pitch = clampf(_cam_pitch - mm.relative.y * 0.008, -1.45, -0.05)
		_update_camera()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_SPACE: set_playing(not playing)
		KEY_LEFT:
			set_playing(false)
			set_tick(current_tick - 1)
		KEY_RIGHT:
			set_playing(false)
			set_tick(current_tick + 1)
		KEY_M: toggle_compare_mode()
		KEY_R: set_tick(0)
		KEY_1, KEY_2, KEY_3, KEY_4: set_camera_preset((event as InputEventKey).keycode - KEY_1)
		_: return
	get_viewport().set_input_as_handled()


func get_comparison_summary() -> Dictionary:
	return _current_run.get("metrics", {}) as Dictionary
