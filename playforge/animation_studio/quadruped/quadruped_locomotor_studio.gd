@tool
extends Control
## NaturalMotion Morpheme-style Procedural Quadruped Locomotor Studio
## (inspired by Unreal Engine's "Procedural Animation with a Locomotor" tutorial).
## 100% procedural 28-bone quadruped (0 animation clips):
##   - Virtual-Pointer 14-Step Authoring Replay (empty -> wireframe -> body -> terrain -> Locomotor -> FBIK -> trail)
##   - Live Gait Switcher (Auto / Walk / Trot / Pace / Gallop) + 300-Tick Course Rewind
##   - Works seamlessly inside Godot Web Editor WASM, Desktop Editor, and standalone runtime.

const QuadrupedRig := preload("res://quadruped/quadruped_rig.gd")
const QuadrupedLocomotor := preload("res://quadruped/quadruped_locomotor.gd")
const QuadrupedNetworkCanvas := preload("res://quadruped/quadruped_network_canvas.gd")
const QuadrupedTimeline := preload("res://quadruped/quadruped_timeline_canvas.gd")
const QuadrupedAuthoringReplay := preload("res://quadruped/quadruped_authoring_replay.gd")
const PoseBuffer := preload("res://addons/animation_studio/pose_buffer.gd")
const AuthoringCursorOverlay := preload("res://hero/authoring_cursor_overlay.gd")

const STEP := 1.0 / 60.0
const TOTAL_TICKS := 300

const STAGE_TITLES := [
	"1단계 · 28본 4족 리그 & 4박자 Walk Locomotor",
	"2단계 · 대각선 속보(Trot) & 예측 보폭 타깃",
	"3단계 · 습보(Gallop)·골반 피치/롤·척추·꼬리 역학",
	"4단계 · 4다리 Pole-Vector FBIK & 계단·경사 적응",
	"5단계 · 완성 300틱 코스 & 무미끄러짐 다시보기",
]

const GAIT_MODES := [
	{"id": "auto", "label": "Gait: Auto (Course)"},
	{"id": "walk", "label": "Gait: Walk (4-Beat)"},
	{"id": "trot", "label": "Gait: Trot (Diagonal)"},
	{"id": "pace", "label": "Gait: Pace (Lateral)"},
	{"id": "gallop", "label": "Gait: Gallop (Rotary)"},
]

const KEY_JUMPS := [
	{"label": "t=0 Idle", "tick": 0},
	{"label": "t=55 Walk", "tick": 55},
	{"label": "t=115 계단 Trot", "tick": 115},
	{"label": "t=185 선회", "tick": 185},
	{"label": "t=240 Gallop", "tick": 240},
	{"label": "t=290 정지", "tick": 290},
]

const NODE_ATTRS := {
	"cp_vel": {"Node": "CP: Velocity / Yaw", "MaxSpeed": "4.90 m/s", "AccelDamp": "5.5 / 7.5", "YawRate": "4.2 rad/s"},
	"cp_gait": {"Node": "CP: GaitPreset", "Modes": "Auto / Walk / Trot / Pace / Gallop", "ClipsUsed": "0 (Procedural)"},
	"loco_front": {"Node": "Foot Set 0 (Front)", "Paws": "FL, FR", "PoleDir": "+Z (backward elbow)", "StanceLock": "0.0 mm slide"},
	"loco_hind": {"Node": "Foot Set 1 (Hind)", "Paws": "HL, HR", "PoleDir": "-Z (forward stifle)", "StanceLock": "0.0 mm slide"},
	"loco_gait": {"Node": "Gait Scheduler", "Walk": "[.50,.00,.25,.75] D=72%", "Trot": "[.0,.5,.5,.0] D=54%", "Gallop": "[.0,.18,.55,.72] D=40%"},
	"loco_pelvis": {"Node": "Pelvis & Spine", "RideHeight": "0.78 m", "PitchClamp": "±28°", "HeadStabilize": "Counter-pitch 80%"},
	"node_terrain": {"Node": "Terrain Raycast", "Step1": "+0.18 m", "Step2": "+0.32 m", "LateralRidge": "+0.24 m"},
	"node_fbik": {"Node": "4-Limb FBIK", "Bones": "16 leg + 12 spine", "Solver": "Pole-constrained 2-Bone", "Clearance": "Sine + Step Boost"},
	"node_out": {"Node": "Output Pose", "Bones": "28", "Clips": "0", "Rate": "60 Hz Deterministic"},
}

var editor_cursor_callback: Callable = Callable()

var assets_ready: bool = false
var authoring_mode: bool = true
var build_stage: int = 5
var gait_mode: String = "auto"
var stage_cache: Dictionary = {} # "<stage>:<gait>" -> Array[Dictionary]
var recorded_frames: Array[Dictionary] = []

var current_tick: int = 0
var authoring_time: float = 0.0
var playing: bool = true
var playback_speed: float = 1.0
var _accum: float = 0.0
var last_authoring_snapshot: Dictionary = {}

# 3D scene nodes
var preview_viewport: SubViewport
var preview_stage: Node3D
var terrain_group: Node3D
var root_node: Node3D
var rig: Skeleton3D
var bone_ids: Dictionary = {}
var body_attachments: Array[Node3D] = []
var bone_wire_mesh: ImmediateMesh
var bone_wire_inst: MeshInstance3D
var gizmo_mesh: ImmediateMesh
var gizmo_inst: MeshInstance3D
var trail_mesh: ImmediateMesh
var trail_inst: MeshInstance3D
var camera: Camera3D

# Morpheme Studio UI controls
var mode_authoring_btn: Button
var mode_rewind_btn: Button
var gait_option: OptionButton
var stage_option: OptionButton
var stage_desc: Label
var network_canvas: QuadrupedNetworkCanvas
var gait_timeline: QuadrupedTimeline
var detail_label: Label
var timeline: HSlider
var tick_label: Label
var play_button: Button
var speed_option: OptionButton
var back_button: Button
var jump_bar: HBoxContainer
var scene_add_btn: Button
var scene_tree_list: ItemList
var asset_list: ItemList
var inspector_label: Label
var log_list: ItemList
var cp_speed_bar: ProgressBar
var cp_pitch_bar: ProgressBar
var cp_planted_bar: ProgressBar
var cp_readout: Label
var view_container: SubViewportContainer
var bottom_controls_box: VBoxContainer
var cursor_overlay: AuthoringCursorOverlay


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip_contents = true
	custom_minimum_size = Vector2(480, 280)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()
	_init_quadruped()
	if assets_ready:
		set_build_stage(5)
		set_authoring_mode(true)
		seek_authoring(0.0, true)


func _make_panel_box(bg_hex: String, border_hex: String, pad := 5) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg_hex)
	sb.border_color = Color(border_hex)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	return sb


func _add_dock_header(parent: Control, title: String, accent_hex: String, extra_ctrl: Control = null) -> void:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _make_panel_box("#222732", "#313949", 4))
	parent.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)
	var chip := ColorRect.new()
	chip.color = Color(accent_hex)
	chip.custom_minimum_size = Vector2(3, 14)
	row.add_child(chip)
	var lbl := Label.new()
	lbl.text = title
	lbl.modulate = Color("#dce6f2")
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	if extra_ctrl != null:
		row.add_child(extra_ctrl)


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#12151b")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var skin := Theme.new()
	if not Engine.is_editor_hint() and not OS.has_feature("web"):
		var font := SystemFont.new()
		font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans"])
		skin.default_font = font
	skin.default_font_size = 12
	theme = skin

	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_vbox.add_theme_constant_override("separation", 4)
	add_child(root_vbox)

	# 1. TOP RIBBON
	var ribbon_panel := PanelContainer.new()
	ribbon_panel.add_theme_stylebox_override("panel", _make_panel_box("#1a1f28", "#2d3545", 5))
	root_vbox.add_child(ribbon_panel)

	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 7)
	ribbon_panel.add_child(top_bar)

	if not Engine.is_editor_hint():
		back_button = Button.new()
		back_button.text = "← 모션 실험실"
		back_button.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/animation_lab.tscn"))
		top_bar.add_child(back_button)

	var brand := Label.new()
	brand.text = "◆ QUADRUPED LOCOMOTOR"
	brand.modulate = Color("#f39c2b")
	top_bar.add_child(brand)

	mode_authoring_btn = Button.new()
	mode_authoring_btn.text = "▶ 제작과정 가상포인터"
	mode_authoring_btn.toggle_mode = true
	mode_authoring_btn.pressed.connect(func(): set_authoring_mode(true))
	top_bar.add_child(mode_authoring_btn)

	mode_rewind_btn = Button.new()
	mode_rewind_btn.text = "300틱 코스 Rewind"
	mode_rewind_btn.toggle_mode = true
	mode_rewind_btn.pressed.connect(func(): set_authoring_mode(false))
	top_bar.add_child(mode_rewind_btn)

	gait_option = OptionButton.new()
	for gm in GAIT_MODES:
		gait_option.add_item(gm.label)
	gait_option.select(0)
	gait_option.item_selected.connect(func(i: int):
		set_gait_mode(str(GAIT_MODES[i].id))
	)
	top_bar.add_child(gait_option)

	var badge := Label.new()
	badge.text = "● 28 Bones · 0 Clips · UE Locomotor"
	badge.modulate = Color("#4ad689")
	top_bar.add_child(badge)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	stage_option = OptionButton.new()
	for st in STAGE_TITLES:
		stage_option.add_item(st)
	stage_option.select(4)
	stage_option.item_selected.connect(func(i: int):
		set_authoring_mode(false)
		set_build_stage(i + 1)
	)
	top_bar.add_child(stage_option)

	# 2. MAIN HORIZONTAL SPLIT: [Left Dock] | [Center Network + 3D] | [Right Inspector]
	var main_hsplit := HSplitContainer.new()
	main_hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(main_hsplit)

	# Left Dock
	var left_panel := PanelContainer.new()
	left_panel.custom_minimum_size.x = 224
	left_panel.add_theme_stylebox_override("panel", _make_panel_box("#171b22", "#2a3240", 5))
	main_hsplit.add_child(left_panel)

	var left_vbox := VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", 4)
	left_panel.add_child(left_vbox)

	_add_dock_header(left_vbox, "Procedural Modules", "#2cc7b8")
	asset_list = ItemList.new()
	asset_list.custom_minimum_size.y = 46
	asset_list.add_item("quadruped/quadruped_rig.gd (28본)")
	asset_list.add_item("quadruped/quadruped_locomotor.gd (FBIK)")
	left_vbox.add_child(asset_list)

	scene_add_btn = Button.new()
	scene_add_btn.text = "+ 노드"
	_add_dock_header(left_vbox, "Scene Hierarchy", "#559ef5", scene_add_btn)
	scene_tree_list = ItemList.new()
	scene_tree_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scene_tree_list.custom_minimum_size.y = 74
	scene_tree_list.allow_reselect = false
	left_vbox.add_child(scene_tree_list)

	_add_dock_header(left_vbox, "Control Parameters", "#9b72f2")
	var cp_box := VBoxContainer.new()
	cp_box.add_theme_constant_override("separation", 3)
	left_vbox.add_child(cp_box)

	cp_readout = Label.new()
	cp_readout.text = "Gait: IDLE · 0.00 m/s"
	cp_readout.modulate = Color("#c8d4e6")
	cp_box.add_child(cp_readout)

	cp_speed_bar = _add_param_gauge(cp_box, "Speed m/s", 0.0, 5.2)
	cp_pitch_bar = _add_param_gauge(cp_box, "Pitch deg", -25.0, 25.0)
	cp_planted_bar = _add_param_gauge(cp_box, "Planted", 0.0, 4.0)

	# Center + Right Split
	var center_right_split := HSplitContainer.new()
	center_right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_right_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hsplit.add_child(center_right_split)

	var center_split := HSplitContainer.new()
	center_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_split.size_flags_stretch_ratio = 3.2
	center_right_split.add_child(center_split)

	# Center-Left: Quadruped Locomotor Control Rig Graph
	var graph_panel := PanelContainer.new()
	graph_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_panel.size_flags_stretch_ratio = 1.85
	graph_panel.add_theme_stylebox_override("panel", _make_panel_box("#14181f", "#2a3240", 4))
	center_split.add_child(graph_panel)

	var graph_vbox := VBoxContainer.new()
	graph_vbox.add_theme_constant_override("separation", 3)
	graph_panel.add_child(graph_vbox)

	stage_desc = Label.new()
	stage_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stage_desc.modulate = Color("#f3c778")
	graph_vbox.add_child(stage_desc)

	network_canvas = QuadrupedNetworkCanvas.new()
	network_canvas.custom_minimum_size = Vector2(320, 140)
	network_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	network_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	network_canvas.node_selected.connect(_on_network_node_selected)
	graph_vbox.add_child(network_canvas)

	# Center-Right: 3D Creature Viewport
	var vp_panel := PanelContainer.new()
	vp_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_panel.size_flags_stretch_ratio = 1.05
	vp_panel.add_theme_stylebox_override("panel", _make_panel_box("#14181f", "#2a3240", 3))
	center_split.add_child(vp_panel)

	var vp_vbox := VBoxContainer.new()
	vp_vbox.add_theme_constant_override("separation", 3)
	vp_panel.add_child(vp_vbox)

	_add_dock_header(vp_vbox, "3D Quadruped Viewport", "#4ad689")

	view_container = SubViewportContainer.new()
	view_container.stretch = true
	view_container.custom_minimum_size = Vector2(210, 140)
	view_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_vbox.add_child(view_container)

	preview_viewport = SubViewport.new()
	preview_viewport.own_world_3d = true
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view_container.add_child(preview_viewport)

	preview_stage = Node3D.new()
	preview_viewport.add_child(preview_stage)
	_build_3d_stage()

	detail_label = Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.modulate = Color("#b8cbe0")
	vp_vbox.add_child(detail_label)

	# Right Dock: Attribute Editor + Authoring Event Log
	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size.x = 222
	right_panel.size_flags_stretch_ratio = 0.85
	right_panel.add_theme_stylebox_override("panel", _make_panel_box("#171b22", "#2a3240", 5))
	center_right_split.add_child(right_panel)

	var right_vbox := VBoxContainer.new()
	right_vbox.add_theme_constant_override("separation", 5)
	right_panel.add_child(right_vbox)

	_add_dock_header(right_vbox, "Attribute Editor", "#c994ff")
	var insp_box := PanelContainer.new()
	insp_box.add_theme_stylebox_override("panel", _make_panel_box("#12161d", "#262f3e", 6))
	right_vbox.add_child(insp_box)
	inspector_label = Label.new()
	inspector_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector_label.custom_minimum_size.y = 74
	inspector_label.modulate = Color("#dfe8f4")
	insp_box.add_child(inspector_label)

	_add_dock_header(right_vbox, "Authoring Event Log", "#f39c2b")
	log_list = ItemList.new()
	log_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(log_list)

	# 3. BOTTOM DOCK: 5-Track Gait Timeline + Transport
	var bottom_panel := PanelContainer.new()
	bottom_panel.add_theme_stylebox_override("panel", _make_panel_box("#171b22", "#2a3240", 4))
	root_vbox.add_child(bottom_panel)

	bottom_controls_box = VBoxContainer.new()
	bottom_controls_box.add_theme_constant_override("separation", 3)
	bottom_panel.add_child(bottom_controls_box)

	gait_timeline = QuadrupedTimeline.new()
	gait_timeline.custom_minimum_size = Vector2(320, 74 if Engine.is_editor_hint() else 92)
	gait_timeline.scrub_requested.connect(_on_timeline_track_scrub)
	bottom_controls_box.add_child(gait_timeline)

	jump_bar = HBoxContainer.new()
	jump_bar.add_theme_constant_override("separation", 5)
	bottom_controls_box.add_child(jump_bar)

	play_button = Button.new()
	play_button.text = "일시정지"
	play_button.pressed.connect(func(): set_playing(not playing))
	jump_bar.add_child(play_button)

	var restart_btn := Button.new()
	restart_btn.text = "처음부터"
	restart_btn.pressed.connect(func():
		if authoring_mode:
			seek_authoring(0.0, true)
		else:
			scrub_to(0)
		set_playing(true)
	)
	jump_bar.add_child(restart_btn)

	var prev_btn := Button.new()
	prev_btn.text = "◀ 이전"
	prev_btn.pressed.connect(func():
		set_playing(false)
		if authoring_mode:
			var cs := int(last_authoring_snapshot.get("step_index", 0))
			seek_authoring(float(maxi(0, cs - 1)) * QuadrupedAuthoringReplay.STEP_DURATION + 0.35, false)
		else:
			scrub_to(maxi(0, current_tick - 1))
	)
	jump_bar.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "다음 ▶"
	next_btn.pressed.connect(func():
		set_playing(false)
		if authoring_mode:
			var cs := int(last_authoring_snapshot.get("step_index", 0))
			seek_authoring(float(mini(QuadrupedAuthoringReplay.step_count() - 1, cs + 1)) * QuadrupedAuthoringReplay.STEP_DURATION + 0.35, false)
		else:
			scrub_to(mini(maxi(0, recorded_frames.size() - 1), current_tick + 1))
	)
	jump_bar.add_child(next_btn)

	speed_option = OptionButton.new()
	for label in ["0.25×", "0.5×", "1.0×", "2.0×"]:
		speed_option.add_item(label)
	speed_option.select(2)
	speed_option.item_selected.connect(func(i: int): playback_speed = [0.25, 0.5, 1.0, 2.0][i])
	jump_bar.add_child(speed_option)

	var jump_sep := Label.new()
	jump_sep.text = "  Events:"
	jump_sep.modulate = Color("#8898ad")
	jump_bar.add_child(jump_sep)

	for j in KEY_JUMPS:
		var jb := Button.new()
		jb.text = j.label
		var tt: int = j.tick
		jb.pressed.connect(func():
			set_authoring_mode(false)
			set_playing(false)
			scrub_to(tt)
		)
		jump_bar.add_child(jb)

	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 8)
	bottom_controls_box.add_child(slider_row)

	tick_label = Label.new()
	tick_label.custom_minimum_size.x = 160
	tick_label.text = "제작 1 / 14 (0.0s)"
	slider_row.add_child(tick_label)

	timeline = HSlider.new()
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.min_value = 0.0
	timeline.max_value = QuadrupedAuthoringReplay.total_duration()
	timeline.step = 0.05
	timeline.value_changed.connect(func(v: float):
		set_playing(false)
		if authoring_mode:
			seek_authoring(v, false)
		else:
			scrub_to(int(v))
	)
	slider_row.add_child(timeline)

	if Engine.is_editor_hint():
		slider_row.visible = false
		var compact_tick := Label.new()
		compact_tick.custom_minimum_size.x = 148
		compact_tick.modulate = Color("#f3c778")
		jump_bar.add_child(compact_tick)
		tick_label = compact_tick

	cursor_overlay = AuthoringCursorOverlay.new()
	add_child(cursor_overlay)


func _add_param_gauge(parent: Control, label_text: String, min_v: float, max_v: float) -> ProgressBar:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 72
	lbl.modulate = Color("#8fa0b5")
	row.add_child(lbl)
	var pb := ProgressBar.new()
	pb.min_value = min_v
	pb.max_value = max_v
	pb.value = 0.0
	pb.show_percentage = false
	pb.custom_minimum_size.y = 11
	pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(pb)
	return pb


func _on_network_node_selected(node_id: String) -> void:
	if not NODE_ATTRS.has(node_id):
		return
	var attrs: Dictionary = NODE_ATTRS[node_id]
	var lines: Array[String] = ["선택 노드: " + str(attrs.get("Node", node_id))]
	for k in attrs:
		if k == "Node":
			continue
		lines.append("  %s = %s" % [k, str(attrs[k])])
	inspector_label.text = "\n".join(lines)


func _on_timeline_track_scrub(u: float) -> void:
	set_playing(false)
	if authoring_mode:
		seek_authoring(u * QuadrupedAuthoringReplay.total_duration(), false)
	else:
		scrub_to(int(round(u * float(maxi(0, recorded_frames.size() - 1)))))


func _build_3d_stage() -> void:
	camera = Camera3D.new()
	camera.fov = 42.0
	camera.current = true
	preview_stage.add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.92, -0.55, 0.0)
	light.light_energy = 1.3
	light.shadow_enabled = true
	preview_stage.add_child(light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#182029")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.85
	env_node.environment = env
	preview_stage.add_child(env_node)

	var ref_plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color("#1c242e")
	pmat.roughness = 1.0
	pm.material = pmat
	ref_plane.mesh = pm
	ref_plane.position.y = -0.01
	preview_stage.add_child(ref_plane)

	terrain_group = Node3D.new()
	terrain_group.name = "CourseTerrain"
	preview_stage.add_child(terrain_group)
	_build_course_terrain_visuals()

	trail_mesh = ImmediateMesh.new()
	trail_inst = MeshInstance3D.new()
	trail_inst.mesh = trail_mesh
	var trail_mat := StandardMaterial3D.new()
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.albedo_color = Color("#f39c2b")
	trail_inst.material_override = trail_mat
	preview_stage.add_child(trail_inst)

	gizmo_mesh = ImmediateMesh.new()
	gizmo_inst = MeshInstance3D.new()
	gizmo_inst.mesh = gizmo_mesh
	var gizmo_mat := StandardMaterial3D.new()
	gizmo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gizmo_mat.vertex_color_use_as_albedo = true
	gizmo_inst.material_override = gizmo_mat
	preview_stage.add_child(gizmo_inst)

	root_node = Node3D.new()
	root_node.name = "LocomotorRoot"
	preview_stage.add_child(root_node)

	rig = Skeleton3D.new()
	rig.name = "QuadrupedRig"
	root_node.add_child(rig)

	bone_wire_mesh = ImmediateMesh.new()
	bone_wire_inst = MeshInstance3D.new()
	bone_wire_inst.mesh = bone_wire_mesh
	var wire_mat := StandardMaterial3D.new()
	wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wire_mat.albedo_color = Color("#2cc7b8")
	bone_wire_inst.material_override = wire_mat
	bone_wire_inst.visible = false
	root_node.add_child(bone_wire_inst)


func _build_course_terrain_visuals() -> void:
	_add_box("LevelGround", Vector3(2.0, -0.10, -4.0), Vector3(24.0, 0.20, 24.0), Color("#34404d"))
	_add_box("FirstStep", Vector3(0.0, 0.09, -3.2), Vector3(4.4, 0.18, 1.6), Color("#4e6073"))
	_add_box("SecondStep", Vector3(0.0, 0.16, -4.9), Vector3(4.4, 0.32, 1.8), Color("#60758c"))
	# Down-ramp bars approximating linear slope z in [-7.6 .. -5.8]
	for i in 6:
		var u := (float(i) + 0.5) / 6.0
		var z := lerpf(-7.6, -5.8, u)
		var h := maxf(0.04, 0.32 * u)
		_add_box("Ramp_%d" % i, Vector3(0.0, h * 0.5, z), Vector3(4.4, h, 0.32), Color("#495c6f"))
	# Lateral sine ridge along the turn & gallop lane (x in [1.5 .. 5.5])
	for i in 8:
		var u := (float(i) + 0.5) / 8.0
		var x := lerpf(1.5, 5.5, u)
		var h := maxf(0.04, sin(u * PI) * 0.24)
		_add_box("Ridge_%d" % i, Vector3(x, h * 0.5, -7.5), Vector3(0.52, h, 6.0), Color("#465969"))


func _add_box(n: String, pos: Vector3, sz: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.name = n
	var box := BoxMesh.new()
	box.size = sz
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.94
	box.material = mat
	mi.mesh = box
	mi.position = pos
	terrain_group.add_child(mi)


func _init_quadruped() -> void:
	bone_ids = QuadrupedRig.build_skeleton(rig)
	body_attachments = QuadrupedRig.build_visual_body(rig)
	assets_ready = rig.get_bone_count() == 28


func set_gait_mode(mode: String) -> void:
	gait_mode = mode
	if gait_option:
		for i in GAIT_MODES.size():
			if str(GAIT_MODES[i].id) == mode:
				gait_option.select(i)
				break
	if assets_ready:
		_load_stage_frames(build_stage)
		if authoring_mode:
			seek_authoring(authoring_time, true)
		else:
			scrub_to(current_tick)


func set_authoring_mode(enabled: bool) -> void:
	authoring_mode = enabled
	if mode_authoring_btn:
		mode_authoring_btn.set_pressed_no_signal(authoring_mode)
	if mode_rewind_btn:
		mode_rewind_btn.set_pressed_no_signal(not authoring_mode)
	if authoring_mode:
		timeline.min_value = 0.0
		timeline.max_value = QuadrupedAuthoringReplay.total_duration()
		timeline.step = 0.05
		seek_authoring(authoring_time, true)
	else:
		_apply_scene_visibility(true, true, true, true, true)
		if cursor_overlay:
			cursor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)
		if editor_cursor_callback.is_valid():
			editor_cursor_callback.call(false, {})
		timeline.min_value = 0.0
		timeline.max_value = maxi(0, recorded_frames.size() - 1)
		timeline.step = 1.0
		scrub_to(current_tick)


func set_build_stage(stage: int) -> void:
	build_stage = clampi(stage, 1, 5)
	if stage_option and stage_option.selected != build_stage - 1:
		stage_option.select(build_stage - 1)
	if assets_ready:
		_load_stage_frames(build_stage)
		if not authoring_mode:
			timeline.max_value = maxi(0, recorded_frames.size() - 1)
			scrub_to(0)


func _load_stage_frames(stage: int) -> void:
	var cache_key := "%d:%s" % [stage, gait_mode]
	if not stage_cache.has(cache_key):
		stage_cache[cache_key] = _bake_course(stage, gait_mode)
	recorded_frames = stage_cache[cache_key]
	_rebuild_trail()


func _bake_course(stage: int, forced_gait_mode: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var solver := QuadrupedLocomotor.new()
	solver.forced_gait = forced_gait_mode
	solver.enable_pelvis_dynamics = stage >= 3
	solver.enable_terrain_ik = stage >= 4
	solver.setup(rig, root_node, bone_ids)

	for tick in TOTAL_TICKS:
		var cmd := QuadrupedLocomotor.demo_course_command(tick)
		var speed: float = float(cmd.speed)
		if stage == 1:
			speed = minf(speed, 1.35)
		elif stage == 2:
			speed = minf(speed, 2.85)
		var res := solver.step(cmd.dir, speed, STEP, stage)
		res["tick"] = tick
		res["pose"] = PoseBuffer.capture_from_skeleton(rig)
		out.append(res)
	return out


func seek_authoring(time_sec: float, instant_cursor := false) -> Dictionary:
	authoring_time = clampf(time_sec, 0.0, QuadrupedAuthoringReplay.total_duration())
	var snap := QuadrupedAuthoringReplay.evaluate_at(authoring_time)
	last_authoring_snapshot = snap
	var step: Dictionary = snap.step

	var target_stage: int = int(step.stage)
	if build_stage != target_stage or recorded_frames.is_empty():
		set_build_stage(target_stage)

	_apply_scene_visibility(bool(step.has_rig), bool(step.has_body), bool(step.has_terrain), bool(step.has_gizmos), bool(step.has_trail))

	scrub_to(int(snap.preview_tick))
	if bool(step.has_rig) and not bool(step.has_body):
		_rebuild_bone_wireframe()

	var tgt := str(step.target)
	if network_canvas:
		network_canvas.set_selected_node(tgt if (tgt.begins_with("loco_") or tgt.begins_with("node_") or tgt.begins_with("cp_")) else "")

	scene_tree_list.clear()
	for node_line: String in step.nodes:
		scene_tree_list.add_item(node_line)
	if scene_tree_list.item_count > 0:
		scene_tree_list.select(scene_tree_list.item_count - 1)

	if tgt == "asset_rig":
		asset_list.select(0)
	elif tgt == "asset_locomotor":
		asset_list.select(1)

	var insp_lines: Array[String] = ["선택 노드: " + str(step.selected_node)]
	for k in step.inspector:
		insp_lines.append("  %s = %s" % [k, str(step.inspector[k])])
	inspector_label.text = "\n".join(insp_lines)

	log_list.clear()
	for line: String in snap.logs:
		log_list.add_item(line)
	if log_list.item_count > 0:
		log_list.select(log_list.item_count - 1)
		log_list.ensure_current_is_visible()

	stage_desc.text = "4족 Locomotor 제작 %d/%d · %s" % [
		int(snap.step_index) + 1, QuadrupedAuthoringReplay.step_count(), str(step.caption)
	]
	if timeline:
		timeline.set_value_no_signal(authoring_time)
	if tick_label:
		tick_label.text = "제작 %d/%d (%.1f / %.0fs)" % [
			int(snap.step_index) + 1, QuadrupedAuthoringReplay.step_count(), authoring_time, QuadrupedAuthoringReplay.total_duration()
		]
	_sync_timeline()

	var target_rect := _resolve_target_rect(tgt)
	if cursor_overlay:
		cursor_overlay.present(
			true, str(step.role), str(step.phase), str(step.caption),
			target_rect, str(step.target_label), float(snap.click_pulse), instant_cursor
		)
	if editor_cursor_callback.is_valid():
		editor_cursor_callback.call(true, snap)
	return snap


func _sync_timeline() -> void:
	if gait_timeline:
		gait_timeline.set_timeline_state(
			authoring_mode, authoring_time, QuadrupedAuthoringReplay.total_duration(),
			QuadrupedAuthoringReplay.STEPS, recorded_frames, current_tick
		)


func _apply_scene_visibility(has_rig: bool, has_body: bool, has_terrain: bool, has_gizmos: bool, has_trail: bool) -> void:
	if terrain_group:
		terrain_group.visible = has_terrain
	if gizmo_inst:
		gizmo_inst.visible = has_gizmos
	if trail_inst:
		trail_inst.visible = has_trail
	if bone_wire_inst:
		bone_wire_inst.visible = has_rig and not has_body
	for att in body_attachments:
		if is_instance_valid(att):
			att.visible = has_body


func _rebuild_bone_wireframe() -> void:
	if bone_wire_mesh == null or rig == null:
		return
	bone_wire_mesh.clear_surfaces()
	var cnt := rig.get_bone_count()
	if cnt < 2:
		return
	bone_wire_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for b in cnt:
		var p := rig.get_bone_parent(b)
		if p >= 0:
			bone_wire_mesh.surface_add_vertex(rig.get_bone_global_pose(p).origin)
			bone_wire_mesh.surface_add_vertex(rig.get_bone_global_pose(b).origin)
	bone_wire_mesh.surface_end()


func _rebuild_gizmos(frame: Dictionary) -> void:
	if gizmo_mesh == null or frame.is_empty():
		return
	gizmo_mesh.clear_surfaces()
	var feet: Dictionary = frame.get("feet", {})
	if feet.is_empty():
		return
	gizmo_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var planted_pts: Array[Vector3] = []
	for leg_id in QuadrupedRig.LEG_NAMES:
		var f: Dictionary = feet.get(leg_id, {})
		var wp: Vector3 = f.get("world_pos", Vector3.ZERO)
		var tp: Vector3 = f.get("target_pos", wp)
		var is_p: bool = bool(f.get("planted", true))
		var col := Color("#4ad689") if is_p else Color("#f39c2b")
		if is_p:
			planted_pts.append(wp + Vector3(0.0, 0.03, 0.0))
		# Draw paw target ring on ground
		var segs := 12
		var r := 0.11 if is_p else 0.13
		for s in segs:
			var a0 := TAU * float(s) / float(segs)
			var a1 := TAU * float(s + 1) / float(segs)
			gizmo_mesh.surface_set_color(col)
			gizmo_mesh.surface_add_vertex(tp + Vector3(cos(a0) * r, 0.03, sin(a0) * r))
			gizmo_mesh.surface_set_color(col)
			gizmo_mesh.surface_add_vertex(tp + Vector3(cos(a1) * r, 0.03, sin(a1) * r))
		# Vertical clearance line when swinging
		if not is_p:
			gizmo_mesh.surface_set_color(Color("#f39c2b"))
			gizmo_mesh.surface_add_vertex(wp)
			gizmo_mesh.surface_set_color(Color("#f39c2b"))
			gizmo_mesh.surface_add_vertex(tp + Vector3(0.0, 0.03, 0.0))

	# Support polygon between currently planted paws
	if planted_pts.size() >= 2:
		for i in planted_pts.size():
			var a := planted_pts[i]
			var b := planted_pts[(i + 1) % planted_pts.size()]
			gizmo_mesh.surface_set_color(Color("#2cc7b8"))
			gizmo_mesh.surface_add_vertex(a)
			gizmo_mesh.surface_set_color(Color("#2cc7b8"))
			gizmo_mesh.surface_add_vertex(b)
	gizmo_mesh.surface_end()


func _rebuild_trail() -> void:
	if trail_mesh == null:
		return
	trail_mesh.clear_surfaces()
	if recorded_frames.size() < 2:
		return
	trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for f in recorded_frames:
		var p: Vector3 = f.root_transform.origin
		trail_mesh.surface_add_vertex(Vector3(p.x, p.y + 0.05, p.z))
	trail_mesh.surface_end()


func _resolve_target_rect(target_id: String) -> Rect2:
	var origin := global_position
	var ctrl_rect := func(c: Control) -> Rect2:
		if c == null or not is_instance_valid(c):
			return Rect2(40, 40, 120, 32)
		var gr := c.get_global_rect()
		return Rect2(gr.position - origin, gr.size)

	match target_id:
		"scene_add_btn":
			return ctrl_rect.call(scene_add_btn)
		"scene_row_rig", "scene_row_terrain":
			var r: Rect2 = ctrl_rect.call(scene_tree_list)
			var row_y := minf(r.size.y - 24.0, maxf(4.0, float(maxi(0, scene_tree_list.item_count - 1)) * 21.0))
			return Rect2(r.position + Vector2(4.0, row_y), Vector2(maxf(80.0, r.size.x - 8.0), 21.0))
		"asset_rig":
			var r: Rect2 = ctrl_rect.call(asset_list)
			return Rect2(r.position + Vector2(4.0, 2.0), Vector2(maxf(80.0, r.size.x - 8.0), 21.0))
		"asset_locomotor":
			var r: Rect2 = ctrl_rect.call(asset_list)
			return Rect2(r.position + Vector2(4.0, 24.0), Vector2(maxf(80.0, r.size.x - 8.0), 21.0))
		"cp_vel", "cp_gait", "loco_front", "loco_hind", "loco_gait", "loco_pelvis", "node_terrain", "node_fbik", "node_out":
			var r: Rect2 = ctrl_rect.call(network_canvas)
			var nr := network_canvas.get_node_rect(target_id)
			return Rect2(r.position + nr.position, nr.size)
		"timeline_bar":
			return ctrl_rect.call(gait_timeline)
		_:
			var r: Rect2 = ctrl_rect.call(view_container)
			return Rect2(r.position + Vector2(14, 14), Vector2(maxf(80.0, r.size.x - 28.0), maxf(80.0, r.size.y - 28.0)))


func set_playing(value: bool) -> void:
	playing = value
	if play_button:
		play_button.text = "일시정지" if playing else "재생"


func scrub_to(tick: int) -> Dictionary:
	if recorded_frames.is_empty():
		return {}
	current_tick = clampi(tick, 0, recorded_frames.size() - 1)
	var frame: Dictionary = recorded_frames[current_tick]
	root_node.transform = frame.root_transform
	var pose: PoseBuffer = frame.pose
	pose.apply_to_skeleton(rig)
	rig.force_update_all_bone_transforms()
	_rebuild_gizmos(frame)

	var at: Vector3 = root_node.position + Vector3(0.0, 0.72, 0.0)
	var cam_offset := Vector3(2.45, 1.15, 2.65)
	camera.position = at + cam_offset
	camera.look_at(at)

	if network_canvas:
		network_canvas.set_display(build_stage, frame)
	if cp_readout:
		cp_readout.text = "Gait: %s · %.2f m/s · %d/4" % [str(frame.gait).to_upper(), float(frame.speed), int(frame.planted_count)]
	if cp_speed_bar:
		cp_speed_bar.value = float(frame.speed)
	if cp_pitch_bar:
		cp_pitch_bar.value = clampf(float(frame.pelvis_pitch_deg), -25.0, 25.0)
	if cp_planted_bar:
		cp_planted_bar.value = float(frame.planted_count)

	if not authoring_mode:
		if timeline:
			timeline.set_value_no_signal(current_tick)
		if tick_label:
			tick_label.text = "틱 %d / %d (%.2fs)" % [current_tick, recorded_frames.size() - 1, float(current_tick) * STEP]
	_sync_timeline()

	if detail_label:
		var p: Vector3 = frame.root_transform.origin
		detail_label.text = "Gait: %s · %.2f m/s · Root (%.2f, %.2f, %.2f)m · Pitch %+.1f° · Roll %+.1f° · Planted %d/4 · Slide %.1fmm" % [
			str(frame.gait).to_upper(), float(frame.speed),
			p.x, p.y, p.z, float(frame.pelvis_pitch_deg), float(frame.pelvis_roll_deg),
			int(frame.planted_count), float(frame.max_slide_mm),
		]
	return frame


func _process(delta: float) -> void:
	if not assets_ready or not playing:
		return
	if authoring_mode:
		var next_t := authoring_time + delta * playback_speed
		if next_t >= QuadrupedAuthoringReplay.total_duration():
			next_t = QuadrupedAuthoringReplay.total_duration()
			seek_authoring(next_t, false)
			set_playing(false)
		else:
			seek_authoring(next_t, false)
		return
	if recorded_frames.is_empty():
		return
	_accum += delta * playback_speed
	if _accum >= STEP:
		var steps := int(_accum / STEP)
		_accum -= float(steps) * STEP
		scrub_to((current_tick + steps) % recorded_frames.size())
