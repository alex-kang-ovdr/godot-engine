@tool
extends Control
## NaturalMotion Morpheme Connect-style Animation Studio & Virtual-Pointer Authoring Replay.
## Works seamlessly as a Godot Web Editor / Desktop Editor Main Screen Addon and standalone scene.
## Layout:
##   Top Ribbon   : Studio brand, Authoring vs 255-Tick Rewind mode, Live telemetry badge, Stage 1..5
##   Left Dock    : Asset Manager, Scene Hierarchy (+Node), Control Parameters live gauges
##   Center Split : Morpheme Animation Network Graph  |  3D Character Viewport
##   Right Dock   : Attribute Editor (Inspector) + Role Authoring Event Log
##   Bottom Dock  : 4-Track Event Timeline (Authoring / State / Blend / Foot IK) + Transport Bar

const Hero := preload("res://hero/hero.gd")
const HeroMotionData := preload("res://hero/hero_motion_data.gd")
const Locomotion := preload("res://hero/locomotion.gd")
const PoseBuffer := preload("res://addons/animation_studio/pose_buffer.gd")
const HeroSMCanvas := preload("res://hero/hero_sm_canvas.gd")
const MorphemeTimeline := preload("res://hero/morpheme_timeline_canvas.gd")
const AuthoringReplay := preload("res://hero/authoring_replay.gd")
const AuthoringCursorOverlay := preload("res://hero/authoring_cursor_overlay.gd")

const MOTION_FILE := HeroMotionData.NATIVE_MOTION_RES
const SKIN_FILE := HeroMotionData.NATIVE_SKIN_GLB
const STEP := 1.0 / 60.0
const TOTAL_TICKS := 255

const STAGE_TITLES := [
	"1단계 · 85본 리그·스킨 & Idle 상태",
	"2단계 · 걷기 진입 전이 (Idle → Idle→Walk → Walk)",
	"3단계 · 달리기 전이 · Smoothstep · 카메라 리드 회전",
	"4단계 · 지형 레이캐스트 & 스윙 페이즈 발 IK",
	"5단계 · 완성 로코모션 & 255틱 전 구간 다시보기",
]

const STAGE_DESCRIPTIONS := [
	"내재화된 85본 리그(hero_motion.res)와 18,050정점 스킨(hero_skin.glb)을 로드하고 기본 idle 상태만 구동합니다.",
	"스틱 입력 시 idle_to_walk로 방향을 전환한 뒤 26틱 후 Walking 상태로 전이합니다.",
	"Running 상태, Smoothstep 전환 블렌딩(4틱/10틱), Walk→Run 회전 속도 유지, 카메라 리드 각도를 추가합니다.",
	"평지·계단·경사면 지형 위에서 2본 발 IK와 스윙 페이즈 페이드아웃을 적용합니다.",
	"전체 상태머신·카메라 리드·발 IK 255틱 완성 상태입니다. 타임라인으로 임의 틱을 되감아 다시봅니다.",
]

const KEY_JUMPS := [
	{"label": "t=0 Idle", "tick": 0},
	{"label": "t=31 걷기진입", "tick": 31},
	{"label": "t=57 걷기", "tick": 57},
	{"label": "t=90 달리기", "tick": 90},
	{"label": "t=150 우회전", "tick": 150},
	{"label": "t=202 정지", "tick": 202},
]

const NODE_ATTRS := {
	"cp_stick": {"Node": "CP: MoveStick", "Type": "Vector2 Parameter", "DeadZone²": "0.10", "Response": "0.90"},
	"cp_walk": {"Node": "CP: WalkTrigger", "Type": "Bool Parameter (LT)", "WalkWindow": "t=30..89", "Target": "LocomotionSM"},
	"sm_idle": {"Node": "1. Idle", "Clip": "idle (hero_motion.res)", "Duration": "2.83 s", "Loop": "true"},
	"sm_i2w": {"Node": "2. Idle→Walk", "Clip": "idle_to_walk", "BlendIn": "4 ticks", "Hold": "26 ticks"},
	"sm_walk": {"Node": "2. Walking", "Clip": "walk", "BlendIn": "8 ticks Smoothstep", "YawGain": "2.0 rad/s"},
	"sm_run": {"Node": "3. Running", "Clip": "run", "Walk→Run": "4t (gain 2.0)", "Run→Idle": "10t Smoothstep"},
	"sm_cam": {"Node": "3. CameraLead", "FollowDist": "5.0 m", "LeadRate": "10 * dt", "XZDrift(215t)": "0.1 mm"},
	"sm_ik": {"Node": "4. TwoBone Foot IK", "Feet": "Left/RightLegFoot", "SwingFade": "0.14..0.26 m", "Smooth": "4.0 m/s"},
	"out_pose": {"Node": "Output Pose", "Bones": "85", "MeshVerts": "18,050", "Rate": "60 Hz Deterministic"},
}

var editor_cursor_callback: Callable = Callable()

var data: Dictionary = {}
var assets_ready: bool = false
var authoring_mode: bool = true
var build_stage: int = 5
var stage_cache: Dictionary = {} # int(stage) -> Array[Dictionary]
var recorded_frames: Array[Dictionary] = []

# Playback state
var current_tick: int = 0
var authoring_time: float = 0.0
var playing: bool = true
var playback_speed: float = 1.0
var _accum: float = 0.0
var last_authoring_snapshot: Dictionary = {}

# 3D preview nodes inside isolated SubViewport
var preview_viewport: SubViewport
var preview_stage: Node3D
var terrain_group: Node3D
var motion_node: Node3D
var rig: Skeleton3D
var skin_meshes: Array[MeshInstance3D] = []
var bone_wire_mesh: ImmediateMesh
var bone_wire_inst: MeshInstance3D
var camera: Camera3D
var trail_mesh: ImmediateMesh
var trail_inst: MeshInstance3D

# NaturalMotion Morpheme Studio UI controls & virtual-pointer targets
var mode_authoring_btn: Button
var mode_rewind_btn: Button
var stage_option: OptionButton
var stage_desc: Label
var sm_canvas: HeroSMCanvas
var morpheme_timeline: MorphemeTimeline
var detail_label: Label
var timeline: HSlider
var tick_label: Label
var play_button: Button
var speed_option: OptionButton
var back_button: Button
var jump_bar: HBoxContainer
var authoring_dock_col: Control
var right_inspector_col: Control
var scene_add_btn: Button
var scene_tree_list: ItemList
var asset_list: ItemList
var inspector_label: Label
var log_list: ItemList
var cp_speed_bar: ProgressBar
var cp_lead_bar: ProgressBar
var cp_ik_bar: ProgressBar
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
	_load_hero_assets()
	if assets_ready:
		set_build_stage(5)
		set_authoring_mode(true)
		seek_authoring(0.0, true)


func _make_panel_box(bg_hex: String, border_hex: String, pad := 6) -> StyleBoxFlat:
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

	# Keep Godot Editor's built-in CJK/Hangul font on Web/Desktop Editor; only install SystemFont on standalone desktop.
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

	# ------------------------------------------------------------------
	# 1. TOP NATURALMOTION MORPHEME STUDIO RIBBON
	# ------------------------------------------------------------------
	var ribbon_panel := PanelContainer.new()
	ribbon_panel.add_theme_stylebox_override("panel", _make_panel_box("#1a1f28", "#2d3545", 5))
	root_vbox.add_child(ribbon_panel)

	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 8)
	ribbon_panel.add_child(top_bar)

	if not Engine.is_editor_hint():
		back_button = Button.new()
		back_button.text = "← 모션 실험실"
		back_button.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/animation_lab.tscn"))
		top_bar.add_child(back_button)

	var brand := Label.new()
	brand.text = "◆ MORPHEME STUDIO"
	brand.modulate = Color("#f39c2b")
	top_bar.add_child(brand)

	mode_authoring_btn = Button.new()
	mode_authoring_btn.text = "▶ 제작과정 가상포인터"
	mode_authoring_btn.toggle_mode = true
	mode_authoring_btn.pressed.connect(func(): set_authoring_mode(true))
	top_bar.add_child(mode_authoring_btn)

	mode_rewind_btn = Button.new()
	mode_rewind_btn.text = "255틱 런타임 Rewind"
	mode_rewind_btn.toggle_mode = true
	mode_rewind_btn.pressed.connect(func(): set_authoring_mode(false))
	top_bar.add_child(mode_rewind_btn)

	var live_badge := Label.new()
	live_badge.text = "● LIVE 60Hz · 85 Bones · Native GLB/RES"
	live_badge.modulate = Color("#4ad689")
	top_bar.add_child(live_badge)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	var stage_lbl := Label.new()
	stage_lbl.text = "Build Stage:"
	stage_lbl.modulate = Color("#94a3b8")
	top_bar.add_child(stage_lbl)

	stage_option = OptionButton.new()
	for s_title in STAGE_TITLES:
		stage_option.add_item(s_title)
	stage_option.select(4)
	stage_option.item_selected.connect(func(idx: int):
		set_authoring_mode(false)
		set_build_stage(idx + 1)
	)
	top_bar.add_child(stage_option)

	# ------------------------------------------------------------------
	# 2. MAIN HORIZONTAL SPLIT: [Left Dock] | [Center Network + 3D] | [Right Inspector]
	# ------------------------------------------------------------------
	var main_hsplit := HSplitContainer.new()
	main_hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(main_hsplit)

	# --- LEFT DOCK: Asset Manager + Scene Hierarchy + Control Parameters ---
	var left_panel := PanelContainer.new()
	left_panel.custom_minimum_size.x = 228
	left_panel.add_theme_stylebox_override("panel", _make_panel_box("#171b22", "#2a3240", 5))
	main_hsplit.add_child(left_panel)
	authoring_dock_col = left_panel

	var left_vbox := VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", 5)
	left_panel.add_child(left_vbox)

	_add_dock_header(left_vbox, "Asset Manager (Native)", "#2cc7b8")
	asset_list = ItemList.new()
	asset_list.custom_minimum_size.y = 46
	asset_list.add_item("hero/assets/hero_motion.res (85본·5클립)")
	asset_list.add_item("hero/assets/hero_skin.glb (18,050정점)")
	left_vbox.add_child(asset_list)

	scene_add_btn = Button.new()
	scene_add_btn.text = "+ 노드"
	_add_dock_header(left_vbox, "Scene Hierarchy", "#559ef5", scene_add_btn)
	scene_tree_list = ItemList.new()
	scene_tree_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scene_tree_list.custom_minimum_size.y = 76
	scene_tree_list.allow_reselect = false
	left_vbox.add_child(scene_tree_list)

	_add_dock_header(left_vbox, "Control Parameters", "#9b72f2")
	var cp_box := VBoxContainer.new()
	cp_box.add_theme_constant_override("separation", 3)
	left_vbox.add_child(cp_box)

	cp_readout = Label.new()
	cp_readout.text = "Stick (0.00, 0.00) · LT OFF"
	cp_readout.modulate = Color("#c8d4e6")
	cp_box.add_child(cp_readout)

	cp_speed_bar = _add_param_gauge(cp_box, "MoveSpeed", 0.0, 1.0)
	cp_lead_bar = _add_param_gauge(cp_box, "CameraLead", -30.0, 30.0)
	cp_ik_bar = _add_param_gauge(cp_box, "FootIK mm", 0.0, 30.0)

	# --- CENTER + RIGHT SPLIT ---
	var center_right_split := HSplitContainer.new()
	center_right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_right_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hsplit.add_child(center_right_split)

	# Center Dual Workspace: Morpheme Animation Network Graph | 3D Character Viewport
	var center_split := HSplitContainer.new()
	center_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_split.size_flags_stretch_ratio = 3.2
	center_right_split.add_child(center_split)

	# Center-Left: Morpheme Network Graph Canvas
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

	sm_canvas = HeroSMCanvas.new()
	sm_canvas.custom_minimum_size = Vector2(320, 140)
	sm_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sm_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sm_canvas.node_selected.connect(_on_network_node_selected)
	graph_vbox.add_child(sm_canvas)

	# Center-Right: Isolated 3D Character Viewport + Live HUD
	var vp_panel := PanelContainer.new()
	vp_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_panel.size_flags_stretch_ratio = 1.0
	vp_panel.add_theme_stylebox_override("panel", _make_panel_box("#14181f", "#2a3240", 3))
	center_split.add_child(vp_panel)

	var vp_vbox := VBoxContainer.new()
	vp_vbox.add_theme_constant_override("separation", 3)
	vp_panel.add_child(vp_vbox)

	_add_dock_header(vp_vbox, "3D Character Viewport", "#4ad689")

	view_container = SubViewportContainer.new()
	view_container.stretch = true
	view_container.custom_minimum_size = Vector2(200, 140)
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

	# --- RIGHT DOCK: Attribute Editor (Inspector) + Role Event Log ---
	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size.x = 225
	right_panel.size_flags_stretch_ratio = 0.85
	right_panel.add_theme_stylebox_override("panel", _make_panel_box("#171b22", "#2a3240", 5))
	center_right_split.add_child(right_panel)
	right_inspector_col = right_panel

	var right_vbox := VBoxContainer.new()
	right_vbox.add_theme_constant_override("separation", 5)
	right_panel.add_child(right_vbox)

	_add_dock_header(right_vbox, "Attribute Editor", "#c994ff")
	var insp_box := PanelContainer.new()
	insp_box.add_theme_stylebox_override("panel", _make_panel_box("#12161d", "#262f3e", 6))
	right_vbox.add_child(insp_box)
	inspector_label = Label.new()
	inspector_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector_label.custom_minimum_size.y = 84
	inspector_label.modulate = Color("#dfe8f4")
	insp_box.add_child(inspector_label)

	_add_dock_header(right_vbox, "Authoring Event Log", "#f39c2b")
	log_list = ItemList.new()
	log_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(log_list)

	# ------------------------------------------------------------------
	# 3. BOTTOM DOCK: NaturalMotion Multi-Track Event Timeline + Transport
	# ------------------------------------------------------------------
	var bottom_panel := PanelContainer.new()
	bottom_panel.add_theme_stylebox_override("panel", _make_panel_box("#171b22", "#2a3240", 4))
	root_vbox.add_child(bottom_panel)

	bottom_controls_box = VBoxContainer.new()
	bottom_controls_box.add_theme_constant_override("separation", 3)
	bottom_panel.add_child(bottom_controls_box)

	morpheme_timeline = MorphemeTimeline.new()
	morpheme_timeline.custom_minimum_size = Vector2(320, 74)
	morpheme_timeline.scrub_requested.connect(_on_timeline_track_scrub)
	bottom_controls_box.add_child(morpheme_timeline)

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
			var cur_step := int(last_authoring_snapshot.get("step_index", 0))
			seek_authoring(float(maxi(0, cur_step - 1)) * AuthoringReplay.STEP_DURATION + 0.35, false)
		else:
			scrub_to(maxi(0, current_tick - 1))
	)
	jump_bar.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "다음 ▶"
	next_btn.pressed.connect(func():
		set_playing(false)
		if authoring_mode:
			var cur_step := int(last_authoring_snapshot.get("step_index", 0))
			seek_authoring(float(mini(AuthoringReplay.step_count() - 1, cur_step + 1)) * AuthoringReplay.STEP_DURATION + 0.35, false)
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
		var target_t: int = j.tick
		jb.pressed.connect(func():
			set_authoring_mode(false)
			set_playing(false)
			scrub_to(target_t)
		)
		jump_bar.add_child(jb)

	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 8)
	bottom_controls_box.add_child(slider_row)

	tick_label = Label.new()
	tick_label.custom_minimum_size.x = 165
	tick_label.text = "제작 1 / 14 (0.0s)"
	slider_row.add_child(tick_label)

	timeline = HSlider.new()
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.min_value = 0.0
	timeline.max_value = AuthoringReplay.total_duration()
	timeline.step = 0.05
	timeline.value_changed.connect(func(v: float):
		set_playing(false)
		if authoring_mode:
			seek_authoring(v, false)
		else:
			scrub_to(int(v))
	)
	slider_row.add_child(timeline)
	# Compact bottom padding inside Godot Web/Desktop Editor so transport never clips behind bottom dock bar
	if Engine.is_editor_hint():
		slider_row.visible = false
		morpheme_timeline.custom_minimum_size.y = 66
		var compact_tick := Label.new()
		compact_tick.custom_minimum_size.x = 150
		compact_tick.modulate = Color("#f3c778")
		jump_bar.add_child(compact_tick)
		tick_label = compact_tick

	# Virtual pointer overlay covering the entire Morpheme workspace
	cursor_overlay = AuthoringCursorOverlay.new()
	add_child(cursor_overlay)


func _add_param_gauge(parent: Control, label_text: String, min_v: float, max_v: float) -> ProgressBar:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = 76
	lbl.modulate = Color("#8fa0b5")
	row.add_child(lbl)
	var pb := ProgressBar.new()
	pb.min_value = min_v
	pb.max_value = max_v
	pb.value = 0.0
	pb.show_percentage = false
	pb.custom_minimum_size.y = 12
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
		seek_authoring(u * AuthoringReplay.total_duration(), false)
	else:
		scrub_to(int(round(u * float(maxi(0, recorded_frames.size() - 1)))))


func _build_3d_stage() -> void:
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.current = true
	preview_stage.add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, -0.6, 0.0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	preview_stage.add_child(light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#1b232c")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.85
	env_node.environment = env
	preview_stage.add_child(env_node)

	var ref_plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 30)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color("#1d242e")
	pmat.roughness = 1.0
	pm.material = pmat
	ref_plane.mesh = pm
	ref_plane.position.y = -0.025
	preview_stage.add_child(ref_plane)

	terrain_group = Node3D.new()
	terrain_group.name = "Terrain"
	preview_stage.add_child(terrain_group)
	_add_terrain_box("LevelGround", Vector3(0.0, -0.12, 0.0), Vector3(30.0, 0.20, 30.0), Color("#3c4856"))
	_add_terrain_box("FirstStep", Vector3(-0.1, 0.08, 0.92), Vector3(0.8, 0.16, 0.55), Color("#58687a"))
	_add_terrain_box("SecondStep", Vector3(0.15, 0.22, 1.47), Vector3(0.8, 0.12, 0.55), Color("#6a7b8f"))
	var slope := _add_terrain_box("Slope", Vector3(0.8, 0.13, 1.05), Vector3(1.0, 0.22, 1.8), Color("#4c5c6d"))
	slope.rotation.z = deg_to_rad(-10.0)

	trail_mesh = ImmediateMesh.new()
	trail_inst = MeshInstance3D.new()
	trail_inst.mesh = trail_mesh
	var trail_mat := StandardMaterial3D.new()
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.albedo_color = Color("#f39c2b")
	trail_inst.material_override = trail_mat
	preview_stage.add_child(trail_inst)

	motion_node = Node3D.new()
	motion_node.name = "Motion"
	preview_stage.add_child(motion_node)

	rig = Skeleton3D.new()
	rig.name = "Rig"
	motion_node.add_child(rig)

	bone_wire_mesh = ImmediateMesh.new()
	bone_wire_inst = MeshInstance3D.new()
	bone_wire_inst.mesh = bone_wire_mesh
	var wire_mat := StandardMaterial3D.new()
	wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wire_mat.albedo_color = Color("#2cc7b8")
	bone_wire_inst.material_override = wire_mat
	bone_wire_inst.visible = false
	motion_node.add_child(bone_wire_inst)


func _add_terrain_box(n: String, pos: Vector3, box_size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	var box := BoxMesh.new()
	box.size = box_size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	box.material = mat
	mi.mesh = box
	mi.position = pos
	terrain_group.add_child(mi)
	return mi


func _load_hero_assets() -> void:
	assets_ready = false
	var parsed: Dictionary = HeroMotionData.load_motion_dict()
	if parsed.is_empty() or parsed.get("clips", {}).is_empty():
		detail_label.text = "내재화된 Hero 리소스(hero/assets/hero_motion.res)가 없습니다."
		return
	data = parsed
	rig.clear_bones()
	for bone in data.skeleton.bones:
		var idx := rig.add_bone(bone.name)
		rig.set_bone_parent(idx, int(bone.parent))
		rig.set_bone_rest(idx, Hero.transform_from(bone.bind))
	rig.reset_bone_poses()
	_load_hero_skin()
	assets_ready = true


func _load_hero_skin() -> void:
	skin_meshes.clear()
	var skin_path := HeroMotionData.resolve_skin_path()
	if skin_path.is_empty():
		return
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.use_named_skin_binds = true
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var err := OK
	if skin_path.ends_with(".glb"):
		var bytes := FileAccess.get_file_as_bytes(skin_path)
		err = doc.append_from_buffer(bytes, "", st)
	else:
		err = doc.append_from_file(skin_path, st)
	if err != OK:
		print("HERO_SKIN_LOAD_ERR err=%d path=%s" % [err, skin_path])
		return
	var scene := doc.generate_scene(st)
	if scene == null:
		print("HERO_SKIN_SCENE_NULL")
		return
	var mesh_nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	mesh_nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))
	for src in mesh_nodes:
		var src_mesh: Mesh = null
		var src_skin: Skin = null
		var src_skel_path := NodePath()
		if src is MeshInstance3D:
			src_mesh = src.mesh
			src_skin = src.skin
			src_skel_path = src.skeleton
		elif src.is_class("ImporterMeshInstance3D"):
			var imp_mesh = src.get("mesh")
			if imp_mesh != null and imp_mesh.has_method("get_mesh"):
				src_mesh = imp_mesh.call("get_mesh")
			src_skin = src.get("skin") as Skin
			src_skel_path = src.get("skeleton_path") as NodePath
		if src_mesh == null or src_skin == null:
			continue
		var src_rig := src.get_node_or_null(src_skel_path) as Skeleton3D
		if src_rig == null:
			var skels := scene.find_children("*", "Skeleton3D", true, false)
			if not skels.is_empty():
				src_rig = skels[0] as Skeleton3D
		var skin := src_skin.duplicate() as Skin
		var valid := true
		for i in skin.get_bind_count():
			var bname := skin.get_bind_name(i)
			if bname.is_empty() and src_rig:
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
		rig.add_child(vis)
		skin_meshes.append(vis)
	scene.free()
	print("HERO_SKIN_LOADED meshes=%d web=%s" % [skin_meshes.size(), OS.has_feature("web")])


func set_authoring_mode(enabled: bool) -> void:
	authoring_mode = enabled
	if mode_authoring_btn:
		mode_authoring_btn.set_pressed_no_signal(authoring_mode)
	if mode_rewind_btn:
		mode_rewind_btn.set_pressed_no_signal(not authoring_mode)
	if authoring_mode:
		timeline.min_value = 0.0
		timeline.max_value = AuthoringReplay.total_duration()
		timeline.step = 0.05
		seek_authoring(authoring_time, true)
	else:
		_apply_scene_visibility(true, true, true, true)
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
	if stage_desc:
		stage_desc.text = STAGE_DESCRIPTIONS[build_stage - 1]
	if assets_ready:
		if not stage_cache.has(build_stage):
			stage_cache[build_stage] = _bake_stage_frames(build_stage)
		recorded_frames = stage_cache[build_stage]
		_rebuild_trail()
		if not authoring_mode:
			timeline.max_value = maxi(0, recorded_frames.size() - 1)
			scrub_to(0)


func bake_replay() -> void:
	stage_cache.erase(build_stage)
	set_build_stage(build_stage)


func _bake_stage_frames(stage: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not assets_ready:
		return out
	motion_node.transform = Transform3D.IDENTITY
	rig.reset_bone_poses()

	var loco := Locomotion.new()
	loco.setup(rig, motion_node, data.clips)

	var left_foot := rig.find_bone("LeftLegFoot")
	var right_foot := rig.find_bone("RightLegFoot")
	var left_thigh := rig.find_bone("LeftLegThigh1")
	var left_calf := rig.find_bone("LeftLegCalf")
	var right_thigh := rig.find_bone("RightLegThigh1")
	var right_calf := rig.find_bone("RightLegCalf")
	var smoothed_y := [0.12, 0.12]

	for tick in TOTAL_TICKS:
		var stick := Hero.replay_input(tick)
		var walk_mod := Hero.replay_walk_modifier(tick)
		var eff_stick := stick
		var eff_walk := walk_mod
		if stage == 1:
			eff_stick = Vector2.ZERO
			eff_walk = false
		elif stage == 2:
			eff_stick = Vector2(0.0, 0.45) if (tick >= 30 and tick < 195) else Vector2.ZERO
			eff_walk = tick >= 30 and tick < 195

		var step_res := loco.step(eff_stick, STEP, eff_walk)
		var ik_hits := 0
		var ik_offset_mm := 0.0
		if stage >= 4 and left_foot >= 0 and right_foot >= 0:
			var leg_bones := [[left_thigh, left_calf, left_foot], [right_thigh, right_calf, right_foot]]
			var root_y := motion_node.position.y
			for side in 2:
				var foot_idx: int = leg_bones[side][2]
				var ankle := rig.to_global(rig.get_bone_global_pose(foot_idx).origin)
				var ground_y := _analytic_terrain_height(ankle.x, ankle.z)
				ik_hits += 1
				var ankle_h := ankle.y - root_y
				var stance_w := clampf(1.0 - (ankle_h - 0.14) / 0.12, 0.0, 1.0)
				var desired_y := maxf(ankle.y + (ground_y - root_y) * stance_w, ground_y + 0.08)
				smoothed_y[side] = move_toward(smoothed_y[side], desired_y, STEP * 4.0)
				if stance_w > 0.001 or desired_y > ankle.y + 0.001:
					var target := Vector3(ankle.x, smoothed_y[side], ankle.z)
					ik_offset_mm = maxf(ik_offset_mm, absf(target.y - ankle.y) * 1000.0)
					_solve_two_bone_leg(leg_bones[side][0], leg_bones[side][1], foot_idx, rig.to_local(target))

		var outgoing_w := 0.0
		if not loco._outgoing_clip.is_empty() and loco._blend_duration > 0.0:
			var u := clampf(loco._state_elapsed / loco._blend_duration, 0.0, 1.0)
			outgoing_w = 1.0 - u * u * (3.0 - 2.0 * u)

		out.append({
			"tick": tick,
			"state": str(step_res.state),
			"clip": str(step_res.clip),
			"clip_time": float(step_res.time),
			"stick": eff_stick,
			"walk_modifier": eff_walk,
			"root_transform": motion_node.transform,
			"yaw_deg": rad_to_deg(motion_node.rotation.y),
			"camera_lead_deg": rad_to_deg(loco._camera_angle),
			"outgoing_weight": outgoing_w,
			"outgoing_state": str(loco._outgoing_name),
			"ik_hits": ik_hits,
			"ik_offset_mm": ik_offset_mm,
			"pose": PoseBuffer.capture_from_skeleton(rig),
		})
	return out


func seek_authoring(time_sec: float, instant_cursor := false) -> Dictionary:
	authoring_time = clampf(time_sec, 0.0, AuthoringReplay.total_duration())
	var snap := AuthoringReplay.evaluate_at(authoring_time)
	last_authoring_snapshot = snap
	var step: Dictionary = snap.step

	var target_stage: int = int(step.stage)
	if build_stage != target_stage or recorded_frames.is_empty():
		set_build_stage(target_stage)

	_apply_scene_visibility(bool(step.has_rig), bool(step.has_skin), bool(step.has_terrain), bool(step.has_trail))

	scrub_to(int(snap.preview_tick))
	if bool(step.has_rig) and not bool(step.has_skin):
		_rebuild_bone_wireframe()

	# Highlight matching Morpheme Network node when targeted
	var tgt := str(step.target)
	if sm_canvas:
		sm_canvas.set_selected_node(tgt if tgt.begins_with("sm_") else "")

	scene_tree_list.clear()
	for node_line: String in step.nodes:
		scene_tree_list.add_item(node_line)
	if scene_tree_list.item_count > 0:
		scene_tree_list.select(scene_tree_list.item_count - 1)

	if tgt == "asset_motion":
		asset_list.select(0)
	elif tgt == "asset_skin":
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

	stage_desc.text = "제작 과정 %d/%d · %s" % [int(snap.step_index) + 1, AuthoringReplay.step_count(), str(step.caption)]
	if timeline:
		timeline.set_value_no_signal(authoring_time)
	if tick_label:
		tick_label.text = "제작 %d/%d (%.1f / %.0fs)" % [
			int(snap.step_index) + 1, AuthoringReplay.step_count(), authoring_time, AuthoringReplay.total_duration()
		]
	_sync_morpheme_timeline()

	var target_rect := _resolve_target_rect(tgt)
	if cursor_overlay:
		cursor_overlay.present(
			true,
			str(step.role),
			str(step.phase),
			str(step.caption),
			target_rect,
			str(step.target_label),
			float(snap.click_pulse),
			instant_cursor
		)
	if editor_cursor_callback.is_valid():
		editor_cursor_callback.call(true, snap)
	return snap


func _sync_morpheme_timeline() -> void:
	if morpheme_timeline:
		morpheme_timeline.set_timeline_state(
			authoring_mode, authoring_time, AuthoringReplay.total_duration(),
			AuthoringReplay.STEPS, recorded_frames, current_tick
		)


func _apply_scene_visibility(has_rig: bool, has_skin: bool, has_terrain: bool, has_trail: bool) -> void:
	if terrain_group:
		terrain_group.visible = has_terrain
	if trail_inst:
		trail_inst.visible = has_trail
	if bone_wire_inst:
		bone_wire_inst.visible = has_rig and not has_skin
	for mi in skin_meshes:
		if is_instance_valid(mi):
			mi.visible = has_skin


func _rebuild_bone_wireframe() -> void:
	if bone_wire_mesh == null or rig == null:
		return
	bone_wire_mesh.clear_surfaces()
	var count := rig.get_bone_count()
	if count < 2:
		return
	bone_wire_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for b in count:
		var p := rig.get_bone_parent(b)
		if p >= 0:
			bone_wire_mesh.surface_add_vertex(rig.get_bone_global_pose(p).origin)
			bone_wire_mesh.surface_add_vertex(rig.get_bone_global_pose(b).origin)
	bone_wire_mesh.surface_end()


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
		"asset_motion":
			var r: Rect2 = ctrl_rect.call(asset_list)
			return Rect2(r.position + Vector2(4.0, 2.0), Vector2(maxf(80.0, r.size.x - 8.0), 21.0))
		"asset_skin":
			var r: Rect2 = ctrl_rect.call(asset_list)
			return Rect2(r.position + Vector2(4.0, 24.0), Vector2(maxf(80.0, r.size.x - 8.0), 21.0))
		"sm_idle", "sm_i2w", "sm_walk", "sm_run", "sm_cam", "sm_ik":
			var r: Rect2 = ctrl_rect.call(sm_canvas)
			var nr := sm_canvas.get_node_rect(target_id)
			return Rect2(r.position + nr.position, nr.size)
		"timeline_bar":
			return ctrl_rect.call(morpheme_timeline)
		_:
			var r: Rect2 = ctrl_rect.call(view_container)
			return Rect2(r.position + Vector2(14, 14), Vector2(maxf(80.0, r.size.x - 28.0), maxf(80.0, r.size.y - 28.0)))


func _analytic_terrain_height(x: float, z: float) -> float:
	var y := -0.02
	if absf(x - (-0.1)) <= 0.4 and absf(z - 0.92) <= 0.275:
		y = maxf(y, 0.16)
	if absf(x - 0.15) <= 0.4 and absf(z - 1.47) <= 0.275:
		y = maxf(y, 0.28)
	if absf(x - 0.8) <= 0.5 and absf(z - 1.05) <= 0.9:
		y = maxf(y, 0.24 - (x - 0.8) * tan(deg_to_rad(10.0)))
	return y


func _solve_two_bone_leg(hip: int, knee: int, ankle: int, target: Vector3) -> void:
	if hip < 0 or knee < 0 or ankle < 0:
		return
	var h := rig.get_bone_global_pose(hip).origin
	var k := rig.get_bone_global_pose(knee).origin
	var a := rig.get_bone_global_pose(ankle).origin
	var upper := h.distance_to(k)
	var lower := k.distance_to(a)
	var dir := (target - h).normalized()
	var dist := clampf(h.distance_to(target), absf(upper - lower) + 0.001, upper + lower - 0.001)
	var bend := (k - h).slide(dir).normalized()
	if dir.is_zero_approx() or bend.is_zero_approx():
		return
	var along := (upper * upper - lower * lower + dist * dist) / (2.0 * dist)
	var desired_k := h + dir * along + bend * sqrt(maxf(0.0, upper * upper - along * along))
	_rotate_bone(hip, (k - h).normalized(), (desired_k - h).normalized())
	rig.force_update_all_bone_transforms()
	k = rig.get_bone_global_pose(knee).origin
	a = rig.get_bone_global_pose(ankle).origin
	_rotate_bone(knee, (a - k).normalized(), (h + dir * dist - k).normalized())
	rig.force_update_all_bone_transforms()


func _rotate_bone(index: int, from_v: Vector3, to_v: Vector3) -> void:
	var pose := rig.get_bone_global_pose(index)
	pose.basis = Basis(Quaternion(from_v, to_v)) * pose.basis
	rig.set_bone_global_pose(index, pose)


func _rebuild_trail() -> void:
	if trail_mesh == null:
		return
	trail_mesh.clear_surfaces()
	if recorded_frames.size() < 2:
		return
	trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for f in recorded_frames:
		var p: Vector3 = f.root_transform.origin
		trail_mesh.surface_add_vertex(Vector3(p.x, p.y + 0.04, p.z))
	trail_mesh.surface_end()


func set_playing(value: bool) -> void:
	playing = value
	if play_button:
		play_button.text = "일시정지" if playing else "재생"


func scrub_to(tick: int) -> Dictionary:
	if recorded_frames.is_empty():
		return {}
	current_tick = clampi(tick, 0, recorded_frames.size() - 1)
	var frame: Dictionary = recorded_frames[current_tick]
	motion_node.transform = frame.root_transform
	var pose: PoseBuffer = frame.pose
	pose.apply_to_skeleton(rig)
	rig.force_update_all_bone_transforms()

	var at: Vector3 = motion_node.position + Vector3(0.0, 0.98, 0.0)
	camera.position = at + Vector3(2.4, 0.72, 3.5)
	camera.look_at(at)

	if sm_canvas:
		sm_canvas.set_display(build_stage, frame)
	if cp_readout:
		var st: Vector2 = frame.stick
		cp_readout.text = "Stick (%+.2f, %+.2f) · LT %s" % [st.x, st.y, "ON" if bool(frame.walk_modifier) else "OFF"]
	if cp_speed_bar:
		cp_speed_bar.value = (frame.stick as Vector2).length()
	if cp_lead_bar:
		cp_lead_bar.value = clampf(float(frame.camera_lead_deg), -30.0, 30.0)
	if cp_ik_bar:
		cp_ik_bar.value = clampf(float(frame.ik_offset_mm), 0.0, 30.0)

	if not authoring_mode:
		if timeline:
			timeline.set_value_no_signal(current_tick)
		if tick_label:
			tick_label.text = "틱 %d / %d (%.2fs)" % [current_tick, recorded_frames.size() - 1, float(current_tick) * STEP]
	_sync_morpheme_timeline()

	if detail_label:
		var p: Vector3 = frame.root_transform.origin
		detail_label.text = "State: %s (%s %.2fs) · Root (%.2f, %.2f, %.2f)m · Yaw %.1f° · Lead %+.1f° · IK %.1fmm" % [
			frame.state, frame.clip, float(frame.clip_time),
			p.x, p.y, p.z, float(frame.yaw_deg),
			float(frame.camera_lead_deg), float(frame.ik_offset_mm),
		]
	return frame


func _process(delta: float) -> void:
	if not assets_ready or not playing:
		return
	if authoring_mode:
		var next_t := authoring_time + delta * playback_speed
		if next_t >= AuthoringReplay.total_duration():
			next_t = AuthoringReplay.total_duration()
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
