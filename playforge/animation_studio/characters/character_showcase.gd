@tool
extends Control

const Store := preload("res://characters/character_store.gd")
const CrowdEval := preload("res://addons/animation_studio/crowd_evaluator.gd")

const BG_DARK := Color("#16191f")
const PANEL_BG := Color("#1f242c")
const BAR_BG := Color("#232933")
const BORDER := Color("#333c4a")
const ACCENT := Color("#5cd3b0")
const WARN := Color("#f0a85a")
const TEXT_MAIN := Color("#e5ecf4")
const TEXT_DIM := Color("#99a8ba")

const CATEGORY_LABELS := {
	"all": "전체",
	"combat": "전투·액션",
	"creature": "크리처",
	"showcase": "쇼케이스",
	"retargeting": "리타게팅",
}

var catalog: Array[Dictionary] = []
var filtered_entries: Array[Dictionary] = []
var active_category: String = "all"
var active_char_id: String = "orc_captain"
var active_clip: String = ""
var display_mode: String = "compare" # "compare" | "single" | "parade"
var playing: bool = true
var playback_speed: float = 1.0
var play_time: float = 0.0
var clip_duration: float = 1.0

var preview_viewport: SubViewport = null
var stage_root: Node3D = null
var camera: Camera3D = null
var left_pedestal: MeshInstance3D = null
var right_pedestal: MeshInstance3D = null
var parade_holder: Node3D = null

var left_rig: Dictionary = {}
var right_rig: Dictionary = {}
var quantized_clips: Dictionary = {}
var current_quantized = null
var native_evaluator: RefCounted = null
var parade_rigs: Array[Dictionary] = []

var camera_yaw: float = 0.48
var camera_pitch: float = 0.22
var camera_dist: float = 4.0
var camera_target: Vector3 = Vector3(0.0, 0.95, 0.0)
var dragging: bool = false
var last_drag_pos: Vector2 = Vector2.ZERO

var _roster_list: VBoxContainer = null
var _roster_buttons: Dictionary = {}
var _cat_buttons: Dictionary = {}
var _clip_opt: OptionButton = null
var _mode_compare_btn: Button = null
var _mode_single_btn: Button = null
var _mode_parade_btn: Button = null
var _play_btn: Button = null
var _time_slider: HSlider = null
var _time_label: Label = null
var _status_label: Label = null
var _metrics_label: RichTextLabel = null
var _badge_label: Label = null
var _bench_label: Label = null
var _updating_ui: bool = false
var _last_metrics: Dictionary = {}


func _ready() -> void:
	catalog = Store.load_catalog()
	_build_theme()
	_build_ui()
	_build_3d_stage()
	_apply_category("all")
	if not catalog.is_empty():
		var start_id := active_char_id
		if Store.get_entry(start_id).is_empty():
			start_id = str(catalog[0].get("id", ""))
		select_character(start_id)


func _build_theme() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans"])
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 13
	t.set_color("font_color", "Label", TEXT_MAIN)
	t.set_color("font_color", "Button", TEXT_MAIN)
	t.set_color("font_pressed_color", "Button", Color("#11171f"))
	t.set_stylebox("normal", "Button", _sb(Color("#2b3340"), 4, 8, 4))
	t.set_stylebox("hover", "Button", _sb(Color("#394456"), 4, 8, 4))
	t.set_stylebox("pressed", "Button", _sb(ACCENT, 4, 8, 4))
	t.set_stylebox("panel", "PanelContainer", _sb(PANEL_BG, 6, 8, 8))
	theme = t


func _sb(col: Color, radius: int, px: int, py: int, border: Color = BORDER) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = col
	b.border_color = border
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

	var root_box := VBoxContainer.new()
	root_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_box.add_theme_constant_override("separation", 4)
	add_child(root_box)

	# --- Top Bar ---
	var top_panel := PanelContainer.new()
	top_panel.add_theme_stylebox_override("panel", _sb(BAR_BG, 0, 10, 6))
	root_box.add_child(top_panel)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	top_panel.add_child(top)

	if not Engine.is_editor_hint():
		var back := Button.new()
		back.text = "← 모션 실험실"
		back.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/motion_lab.tscn"))
		top.add_child(back)

	var title := Label.new()
	title.text = "◆ HAVOK %d-CHARACTER ROSTER · NATIVE GLB/RES" % catalog.size()
	title.add_theme_color_override("font_color", WARN)
	top.add_child(title)

	_mode_compare_btn = Button.new()
	_mode_compare_btn.text = "나란히 비교 (Float32 vs 16-bit C++)"
	_mode_compare_btn.toggle_mode = true
	_mode_compare_btn.pressed.connect(func(): set_display_mode("compare"))
	top.add_child(_mode_compare_btn)

	_mode_single_btn = Button.new()
	_mode_single_btn.text = "단독 클로즈업"
	_mode_single_btn.toggle_mode = true
	_mode_single_btn.pressed.connect(func(): set_display_mode("single"))
	top.add_child(_mode_single_btn)

	_mode_parade_btn = Button.new()
	_mode_parade_btn.text = "단체 퍼레이드"
	_mode_parade_btn.toggle_mode = true
	_mode_parade_btn.pressed.connect(func(): set_display_mode("parade"))
	top.add_child(_mode_parade_btn)

	var prev_btn := Button.new()
	prev_btn.text = "◀"
	prev_btn.pressed.connect(func(): _step_character(-1))
	top.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "▶"
	next_btn.pressed.connect(func(): _step_character(1))
	top.add_child(next_btn)

	_clip_opt = OptionButton.new()
	_clip_opt.custom_minimum_size = Vector2(150, 0)
	_clip_opt.item_selected.connect(func(idx: int): select_clip(_clip_opt.get_item_metadata(idx)))
	top.add_child(_clip_opt)

	_badge_label = Label.new()
	_badge_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_badge_label.add_theme_color_override("font_color", ACCENT)
	top.add_child(_badge_label)

	# --- Main Split: Left Roster + Metrics | Right 3D Viewport ---
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	root_box.add_child(body)

	var left_panel := PanelContainer.new()
	left_panel.custom_minimum_size = Vector2(330, 0)
	left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(left_panel)

	var left_vbox := VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", 6)
	left_panel.add_child(left_vbox)

	# Category filter row
	var cat_flow := HFlowContainer.new()
	cat_flow.add_theme_constant_override("h_separation", 4)
	cat_flow.add_theme_constant_override("v_separation", 4)
	left_vbox.add_child(cat_flow)
	for cat_key in ["all", "combat", "creature", "showcase", "retargeting"]:
		var cb := Button.new()
		cb.toggle_mode = true
		cb.text = CATEGORY_LABELS[cat_key]
		cb.pressed.connect(func(): _apply_category(cat_key))
		cat_flow.add_child(cb)
		_cat_buttons[cat_key] = cb

	# Scrollable Character List
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_vbox.add_child(scroll)
	_roster_list = VBoxContainer.new()
	_roster_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roster_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_roster_list)

	# Live Metrics Box
	var metrics_panel := PanelContainer.new()
	metrics_panel.add_theme_stylebox_override("panel", _sb(Color("#151920"), 4, 8, 8))
	metrics_panel.custom_minimum_size = Vector2(0, 215)
	left_vbox.add_child(metrics_panel)

	var mbox := VBoxContainer.new()
	mbox.add_theme_constant_override("separation", 4)
	metrics_panel.add_child(mbox)

	_metrics_label = RichTextLabel.new()
	_metrics_label.bbcode_enabled = true
	_metrics_label.fit_content = false
	_metrics_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_metrics_label.scroll_active = false
	mbox.add_child(_metrics_label)

	var bench_row := HBoxContainer.new()
	bench_row.add_theme_constant_override("separation", 6)
	mbox.add_child(bench_row)
	var bench_btn := Button.new()
	bench_btn.text = "200체 C++ 성능 측정"
	bench_btn.pressed.connect(_run_quick_benchmark)
	bench_row.add_child(bench_btn)
	_bench_label = Label.new()
	_bench_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bench_label.add_theme_color_override("font_color", ACCENT)
	_bench_label.text = ""
	bench_row.add_child(_bench_label)

	# 3D Viewport Container
	var vp_frame := PanelContainer.new()
	vp_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_frame.add_theme_stylebox_override("panel", _sb(Color("#11151b"), 4, 2, 2))
	body.add_child(vp_frame)

	var vp_vbox := VBoxContainer.new()
	vp_vbox.add_theme_constant_override("separation", 2)
	vp_frame.add_child(vp_vbox)

	var vp_container := SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_container.gui_input.connect(_on_viewport_gui_input)
	vp_vbox.add_child(vp_container)

	preview_viewport = SubViewport.new()
	preview_viewport.own_world_3d = true
	preview_viewport.msaa_3d = Viewport.MSAA_4X
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp_container.add_child(preview_viewport)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", TEXT_DIM)
	vp_vbox.add_child(_status_label)

	# --- Bottom Transport Bar ---
	var bot_panel := PanelContainer.new()
	bot_panel.add_theme_stylebox_override("panel", _sb(BAR_BG, 0, 10, 6))
	root_box.add_child(bot_panel)
	var bot := HBoxContainer.new()
	bot.add_theme_constant_override("separation", 8)
	bot_panel.add_child(bot)

	_play_btn = Button.new()
	_play_btn.text = "일시정지"
	_play_btn.pressed.connect(func(): set_playing(not playing))
	bot.add_child(_play_btn)

	var step_btn := Button.new()
	step_btn.text = "+1/60s"
	step_btn.pressed.connect(func():
		set_playing(false)
		sample_at(fposmod(play_time + 1.0 / 60.0, maxf(0.01, clip_duration)))
	)
	bot.add_child(step_btn)

	var spd_opt := OptionButton.new()
	for r in [0.25, 0.5, 1.0, 1.5]:
		spd_opt.add_item("%s×" % str(r))
		spd_opt.set_item_metadata(spd_opt.item_count - 1, r)
	spd_opt.select(2)
	spd_opt.item_selected.connect(func(i: int): playback_speed = float(spd_opt.get_item_metadata(i)))
	bot.add_child(spd_opt)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(105, 0)
	bot.add_child(_time_label)

	_time_slider = HSlider.new()
	_time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_slider.min_value = 0.0
	_time_slider.max_value = 1.0
	_time_slider.step = 0.002
	_time_slider.value_changed.connect(func(v: float):
		if not _updating_ui:
			set_playing(false)
			sample_at(v)
	)
	bot.add_child(_time_slider)


func _build_3d_stage() -> void:
	stage_root = Node3D.new()
	stage_root.name = "StageRoot"
	preview_viewport.add_child(stage_root)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#202733")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#b8c8dc")
	env.ambient_light_energy = 0.72
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	stage_root.add_child(we)

	var key := DirectionalLight3D.new()
	key.light_energy = 1.45
	key.shadow_enabled = true
	key.rotation_degrees = Vector3(-42.0, 32.0, 0.0)
	stage_root.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.55
	fill.light_color = Color("#8fb8ff")
	fill.rotation_degrees = Vector3(-18.0, -140.0, 0.0)
	stage_root.add_child(fill)

	# Ground plane
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	floor_mesh.mesh = plane
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color("#343e4e")
	fmat.roughness = 0.85
	floor_mesh.material_override = fmat
	floor_mesh.position = Vector3(0.0, -0.02, 0.0)
	stage_root.add_child(floor_mesh)

	left_pedestal = _make_pedestal(Color("#29b89b"))
	right_pedestal = _make_pedestal(Color("#e08b32"))
	stage_root.add_child(left_pedestal)
	stage_root.add_child(right_pedestal)

	parade_holder = Node3D.new()
	parade_holder.name = "ParadeHolder"
	stage_root.add_child(parade_holder)

	camera = Camera3D.new()
	camera.fov = 38.0
	camera.near = 0.05
	camera.far = 120.0
	stage_root.add_child(camera)
	_update_camera()


func _make_pedestal(col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.65
	cyl.bottom_radius = 0.72
	cyl.height = 0.04
	m.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.45
	m.material_override = mat
	m.position = Vector3(0.0, -0.02, 0.0)
	return m


func _apply_category(cat: String) -> void:
	active_category = cat
	for k in _cat_buttons.keys():
		(_cat_buttons[k] as Button).set_pressed_no_signal(k == cat)
	filtered_entries.clear()
	for entry in catalog:
		if cat == "all" or str(entry.get("category", "")) == cat:
			filtered_entries.append(entry)
	for child in _roster_list.get_children():
		child.queue_free()
	_roster_buttons.clear()

	# Update counts on category buttons
	for k in _cat_buttons.keys():
		var cnt := 0
		for e in catalog:
			if k == "all" or str(e.get("category", "")) == k:
				cnt += 1
		(_cat_buttons[k] as Button).text = "%s (%d)" % [CATEGORY_LABELS[k], cnt]

	for entry in filtered_entries:
		var cid := str(entry.get("id", ""))
		var btn := Button.new()
		btn.toggle_mode = true
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.text = "%s  [%d본 · %d클립]" % [str(entry.get("name", cid)), int(entry.get("bones", 0)), (entry.get("clips", []) as Array).size()]
		btn.pressed.connect(func(): select_character(cid))
		_roster_list.add_child(btn)
		_roster_buttons[cid] = btn

	if display_mode == "parade":
		_rebuild_parade()
	elif not filtered_entries.is_empty() and not _roster_buttons.has(active_char_id):
		select_character(str(filtered_entries[0].get("id", "")))
	else:
		_sync_roster_highlight()


func _sync_roster_highlight() -> void:
	for cid in _roster_buttons.keys():
		(_roster_buttons[cid] as Button).set_pressed_no_signal(cid == active_char_id)


func _step_character(delta: int) -> void:
	if filtered_entries.is_empty():
		return
	var idx := 0
	for i in filtered_entries.size():
		if str(filtered_entries[i].get("id", "")) == active_char_id:
			idx = i
			break
	var next_idx := posmod(idx + delta, filtered_entries.size())
	select_character(str(filtered_entries[next_idx].get("id", "")))


func _clear_single_rigs() -> void:
	if not left_rig.is_empty() and is_instance_valid(left_rig.get("root")):
		left_rig["root"].queue_free()
	if not right_rig.is_empty() and is_instance_valid(right_rig.get("root")):
		right_rig["root"].queue_free()
	left_rig.clear()
	right_rig.clear()
	quantized_clips.clear()
	current_quantized = null
	native_evaluator = null


func _clear_parade() -> void:
	for r in parade_rigs:
		if is_instance_valid(r.get("root")):
			r["root"].queue_free()
	parade_rigs.clear()


func select_character(char_id: String) -> void:
	var entry := Store.get_entry(char_id)
	if entry.is_empty():
		return
	active_char_id = char_id
	_sync_roster_highlight()
	_bench_label.text = ""

	_clear_single_rigs()
	if display_mode != "parade":
		_clear_parade()
	left_rig = Store.build_rig(char_id, "LeftPlayerRig")
	right_rig = Store.build_rig(char_id, "RightQuantRig")
	if left_rig.is_empty() or right_rig.is_empty():
		return
	stage_root.add_child(left_rig["root"])
	stage_root.add_child(right_rig["root"])

	# Populate clip dropdown
	_clip_opt.clear()
	var clip_list: Array = entry.get("clips", [])
	for cname in clip_list:
		var s := str(cname)
		_clip_opt.add_item(s)
		_clip_opt.set_item_metadata(_clip_opt.item_count - 1, s)

	var first_clip := str(clip_list[0]) if not clip_list.is_empty() else ""
	if not first_clip.is_empty():
		_clip_opt.select(0)
		select_clip(first_clip)

	_badge_label.text = "● %d본 · %d메시 · %d정점 · %.0f KB GLB" % [
		int(entry.get("bones", 0)),
		int(entry.get("meshes", 0)),
		int(entry.get("vertices", 0)),
		float(entry.get("glb_kb", 0.0)),
	]
	_apply_display_mode_layout()


func select_clip(clip_name: String) -> void:
	if left_rig.is_empty() or clip_name.is_empty():
		return
	var library: AnimationLibrary = left_rig["library"]
	if not library.has_animation(clip_name):
		return
	active_clip = clip_name
	var anim: Animation = library.get_animation(clip_name)
	clip_duration = maxf(0.05, anim.length)

	if not quantized_clips.has(clip_name):
		quantized_clips[clip_name] = CrowdEval.QuantizedClip.bake_from_animation(anim, left_rig["skeleton"], 60.0)
	current_quantized = quantized_clips[clip_name]

	play_time = 0.0
	_updating_ui = true
	_time_slider.max_value = clip_duration
	_time_slider.value = 0.0
	_updating_ui = false
	sample_at(0.0)


func set_display_mode(mode: String) -> void:
	display_mode = mode
	if mode == "parade":
		_rebuild_parade()
	else:
		_clear_parade()
	_apply_display_mode_layout()


func _apply_display_mode_layout() -> void:
	if is_instance_valid(_mode_compare_btn):
		_mode_compare_btn.set_pressed_no_signal(display_mode == "compare")
	if is_instance_valid(_mode_single_btn):
		_mode_single_btn.set_pressed_no_signal(display_mode == "single")
	if is_instance_valid(_mode_parade_btn):
		_mode_parade_btn.set_pressed_no_signal(display_mode == "parade")

	if display_mode == "parade":
		if not left_rig.is_empty():
			left_rig["root"].visible = false
		if not right_rig.is_empty():
			right_rig["root"].visible = false
		left_pedestal.visible = false
		right_pedestal.visible = false
		parade_holder.visible = true
		return

	parade_holder.visible = false
	if left_rig.is_empty() or right_rig.is_empty():
		return

	# Auto-frame camera & pedestals based on current character's live pose AABB!
	var aabb := Store.compute_pose_aabb(left_rig["skeleton"], left_rig["skin_info"])
	var h := clampf(aabb.size.y, 0.5, 6.0)
	var w := clampf(maxf(aabb.size.x, aabb.size.z), 0.4, 4.0)
	var ground_offset := -aabb.position.y
	var ped_r := clampf(maxf(w * 0.52, h * 0.28), 0.35, 1.55)
	(left_pedestal.mesh as CylinderMesh).top_radius = ped_r
	(left_pedestal.mesh as CylinderMesh).bottom_radius = ped_r * 1.08
	(right_pedestal.mesh as CylinderMesh).top_radius = ped_r
	(right_pedestal.mesh as CylinderMesh).bottom_radius = ped_r * 1.08

	if display_mode == "compare":
		var sep := maxf(ped_r * 1.38, h * 0.48)
		left_rig["root"].visible = true
		right_rig["root"].visible = true
		left_rig["root"].position = Vector3(-sep, ground_offset, 0.0)
		right_rig["root"].position = Vector3(sep, ground_offset, 0.0)
		left_pedestal.visible = true
		right_pedestal.visible = true
		left_pedestal.position = Vector3(-sep, -0.02, 0.0)
		right_pedestal.position = Vector3(sep, -0.02, 0.0)
		camera_target = Vector3(0.0, h * 0.48, 0.0)
		camera_dist = maxf(h * 2.25, sep * 3.85)
	else:
		left_rig["root"].visible = true
		right_rig["root"].visible = false
		left_rig["root"].position = Vector3(0.0, ground_offset, 0.0)
		left_pedestal.visible = true
		right_pedestal.visible = false
		left_pedestal.position = Vector3(0.0, -0.02, 0.0)
		camera_target = Vector3(0.0, h * 0.48, 0.0)
		camera_dist = maxf(h * 1.85, w * 2.5)
	_update_camera()


func _rebuild_parade() -> void:
	_clear_parade()
	var list := filtered_entries
	if list.size() > 9:
		var step := maxi(1, list.size() / 9)
		var sub: Array[Dictionary] = []
		for i in range(0, list.size(), step):
			sub.append(list[i])
			if sub.size() >= 9:
				break
		list = sub

	var cols := mini(list.size(), 4)
	var spacing := 2.25
	for i in list.size():
		var cid := str(list[i].get("id", ""))
		var rig := Store.build_rig(cid, "Parade_" + cid)
		if rig.is_empty():
			continue
		parade_holder.add_child(rig["root"])
		var clips: Array = list[i].get("clips", [])
		var cname := str(clips[0]) if not clips.is_empty() else ""
		if not cname.is_empty() and (rig["library"] as AnimationLibrary).has_animation(cname):
			var p: AnimationPlayer = rig["player"]
			p.assigned_animation = cname
			p.seek(0.2 * float(i), true)
			p.advance(0.0)
			rig["active_clip"] = cname
			rig["duration"] = maxf(0.1, (rig["library"] as AnimationLibrary).get_animation(cname).length)
		var aabb := Store.compute_pose_aabb(rig["skeleton"], rig["skin_info"])
		# Normalize parade scale gently so giant rigs (3m-4.4m) fit cohesively alongside standard humanoids
		var target_h := clampf(aabb.size.y, 1.35, 2.35)
		var scale_f := target_h / maxf(0.4, aabb.size.y)
		rig["root"].scale = Vector3.ONE * scale_f
		var row := i / cols
		var col := i % cols
		var row_count := mini(cols, list.size() - row * cols)
		var x := (float(col) - float(row_count - 1) * 0.5) * spacing
		var z := -float(row) * 2.45
		rig["root"].position = Vector3(x, -aabb.position.y * scale_f, z)
		parade_rigs.append(rig)

	camera_yaw = 0.14
	camera_pitch = 0.24
	camera_target = Vector3(0.0, 0.95, -1.0)
	camera_dist = 10.6
	_update_camera()


func set_playing(v: bool) -> void:
	playing = v
	if is_instance_valid(_play_btn):
		_play_btn.text = "일시정지" if playing else "재생"


func _process(delta: float) -> void:
	if not visible:
		return
	if playing:
		play_time = fposmod(play_time + delta * playback_speed, maxf(0.05, clip_duration))
		if display_mode == "parade":
			for r in parade_rigs:
				var p: AnimationPlayer = r["player"]
				var dur: float = float(r.get("duration", 1.0))
				p.seek(fposmod(play_time, dur), true)
				p.advance(0.0)
			_updating_ui = true
			_time_label.text = "%.2f s (단체)" % play_time
			_updating_ui = false
		else:
			sample_at(play_time)


func sample_at(t: float) -> void:
	if left_rig.is_empty() or right_rig.is_empty() or current_quantized == null:
		return
	play_time = clampf(t, 0.0, clip_duration)
	var lskel: Skeleton3D = left_rig["skeleton"]
	var rskel: Skeleton3D = right_rig["skeleton"]
	lskel.reset_bone_poses()
	var lp: AnimationPlayer = left_rig["player"]
	lp.assigned_animation = active_clip
	lp.seek(play_time, true)
	lp.advance(0.0)
	Store.apply_quantized_to_skeleton(current_quantized, rskel, play_time)

	var max_pos_mm := 0.0
	var max_rot_deg := 0.0
	var max_world_mm := 0.0
	var bc := lskel.get_bone_count()
	for i in bc:
		var lp_pos := lskel.get_bone_pose_position(i)
		var rp_pos := rskel.get_bone_pose_position(i)
		max_pos_mm = maxf(max_pos_mm, lp_pos.distance_to(rp_pos) * 1000.0)
		var lr := lskel.get_bone_pose_rotation(i).normalized()
		var rr := rskel.get_bone_pose_rotation(i).normalized()
		var d := clampf(absf(lr.dot(rr)), 0.0, 1.0)
		max_rot_deg = maxf(max_rot_deg, rad_to_deg(2.0 * acos(d)))
		var lw := lskel.get_bone_global_pose(i).origin
		var rw := rskel.get_bone_global_pose(i).origin
		max_world_mm = maxf(max_world_mm, lw.distance_to(rw) * 1000.0)

	var res_bytes: int = current_quantized.resident_bytes()
	var uncomp_bytes: int = CrowdEval.QuantizedClip.uncompressed_bytes(current_quantized.bone_count, current_quantized.key_count)
	var saving_pct := (1.0 - float(res_bytes) / maxf(1.0, float(uncomp_bytes))) * 100.0
	_last_metrics = {
		"char_id": active_char_id,
		"clip": active_clip,
		"time": play_time,
		"max_pos_mm": max_pos_mm,
		"max_rot_deg": max_rot_deg,
		"max_world_mm": max_world_mm,
		"saving_pct": saving_pct,
		"resident_kb": float(res_bytes) / 1024.0,
	}

	_updating_ui = true
	_time_slider.value = play_time
	_time_label.text = "%.2f / %.2f s" % [play_time, clip_duration]
	_updating_ui = false

	var entry := Store.get_entry(active_char_id)
	_metrics_label.text = (
		"[b][color=#5cd3b0]%s[/color][/b] (%s)\n" +
		"스켈레톤: %d본 · 메시: %d개 · 정점: %d · 텍스처: %d장\n" +
		"좌(청록): AnimationPlayer (float32)\n" +
		"우(주황): C++ CrowdEvaluator (16-bit)\n" +
		"클립: [b]%s[/b] (%.2f / %.2f s)\n" +
		"로컬 최대 오차: [color=#5cd3b0]%.4f mm[/color] / [color=#5cd3b0]%.4f°[/color]\n" +
		"월드 최대 오차: [color=#f0a85a]%.3f mm[/color]\n" +
		"메모리 절감: [color=#5cd3b0]%.1f%%[/color] (%.1f KB 상주)"
	) % [
		str(entry.get("name", active_char_id)),
		CATEGORY_LABELS.get(str(entry.get("category", "")), ""),
		int(entry.get("bones", 0)),
		int(entry.get("meshes", 0)),
		int(entry.get("vertices", 0)),
		int(entry.get("textures", 0)),
		active_clip, play_time, clip_duration,
		max_pos_mm, max_rot_deg, max_world_mm,
		saving_pct, float(res_bytes) / 1024.0,
	]
	_status_label.text = "%s · Clip: %s @ %.3fs · Local Δ=%.4fmm / %.4f° · World Δ=%.3fmm · Drag=회전 · Wheel=줌" % [
		active_char_id, active_clip, play_time, max_pos_mm, max_rot_deg, max_world_mm
	]


func _run_quick_benchmark() -> void:
	if left_rig.is_empty() or current_quantized == null:
		_bench_label.text = "클립 없음"
		return
	var agents := 200
	var skels: Array[Skeleton3D] = []
	var data = left_rig["data"]
	var tmp_root := Node3D.new()
	add_child(tmp_root)
	for i in agents:
		var s := Skeleton3D.new()
		tmp_root.add_child(s)
		Store.populate_skeleton(s, data)
		skels.append(s)
	var ev := CrowdEval.new()
	ev.setup(current_quantized, agents, true, 0)
	ev.step_parallel(1.0 / 60.0, skels)
	var last_stats: Dictionary = {}
	var sum_ms := 0.0
	for _it in 5:
		last_stats = ev.step_parallel(1.0 / 60.0, skels)
		sum_ms += float(last_stats.get("main_total_ms", 0.0))
	tmp_root.queue_free()
	var mode_tag := "C++" if bool(last_stats.get("native", false)) else "GDScript"
	_bench_label.text = "200체(%d본 %s): %.2f ms" % [int(left_rig["skeleton"].get_bone_count()) * agents, mode_tag, sum_ms / 5.0]


func _on_viewport_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			dragging = mb.pressed
			last_drag_pos = mb.position
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			camera_dist = clampf(camera_dist * 0.9, 0.8, 25.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			camera_dist = clampf(camera_dist * 1.12, 0.8, 25.0)
			_update_camera()
	elif event is InputEventMouseMotion and dragging:
		var mm := event as InputEventMouseMotion
		var d := mm.position - last_drag_pos
		last_drag_pos = mm.position
		camera_yaw -= d.x * 0.008
		camera_pitch = clampf(camera_pitch + d.y * 0.006, -0.35, 1.25)
		_update_camera()


func _update_camera() -> void:
	if camera == null:
		return
	var offset := Vector3(
		sin(camera_yaw) * cos(camera_pitch),
		sin(camera_pitch),
		cos(camera_yaw) * cos(camera_pitch)
	) * camera_dist
	camera.position = camera_target + offset
	camera.look_at(camera_target, Vector3.UP)


func get_last_metrics() -> Dictionary:
	return _last_metrics.duplicate()
