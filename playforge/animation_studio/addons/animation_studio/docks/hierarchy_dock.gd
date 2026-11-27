@tool
extends VBoxContainer
## Standard Godot Editor Dock: "AnimStudio · 계층" (Design v3 Styled)
## Displays rich styled character instance cards with left amber selection bar,
## vector SVG role icons, live state badges, quick Focus / Camera Follow actions,
## 28-character spawn picker, and Skeleton3D bone hierarchy + Pose Readout Card.

const Store := preload("res://characters/character_store.gd")
const StudioTheme := preload("res://addons/animation_studio/ui/studio_theme.gd")

signal instance_selected(inst: Node3D)
signal spawn_requested(role: String, character_id: String)
signal focus_requested(inst: Node3D)
signal follow_toggled(enabled: bool)
signal refresh_requested()

var _instances: Array[Node3D] = []
var _bound_instance: Node3D = null
var _selected_bone_idx: int = -1
var _follow_enabled: bool = false

var _cards_box: VBoxContainer = null
var _card_entries: Array[Dictionary] = [] # {inst, panel, state_lbl, name_lbl}
var _spawn_opt: OptionButton = null
var _btn_follow: Button = null
var _bone_filter: LineEdit = null
var _bone_tree: Tree = null
var _bone_title_lbl: Label = null
var _bone_pose_label: Label = null
var _count_label: Label = null
var _spawn_specs: Array[Dictionary] = []


func _init() -> void:
	name = "AnimStudio · 계층"
	custom_minimum_size = Vector2(260, 280)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	if _cards_box != null:
		return
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 6)

	# --- Top Header Bar ---
	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 6)
	add_child(top_bar)

	var title := Label.new()
	title.text = "씬 캐릭터 인스턴스"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY)
	title.add_theme_font_size_override("font_size", 12)
	top_bar.add_child(title)

	_count_label = Label.new()
	_count_label.text = "0개"
	StudioTheme.style_pill_label(_count_label, StudioTheme.ACCENT_TEAL_DIM, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_TEXT)
	top_bar.add_child(_count_label)

	var btn_refresh := Button.new()
	btn_refresh.text = "↻"
	btn_refresh.tooltip_text = "현재 3D 씬의 AnimationStudioInstance 목록을 다시 스캔합니다."
	StudioTheme.style_button(btn_refresh, "default")
	btn_refresh.pressed.connect(func(): refresh_requested.emit())
	top_bar.add_child(btn_refresh)

	# --- Rich Styled Instance Cards List ---
	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(0, 158)
	list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(list_scroll)

	_cards_box = VBoxContainer.new()
	_cards_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_box.add_theme_constant_override("separation", 4)
	list_scroll.add_child(_cards_box)

	# --- Spawn Picker + 3-Button Action Bar (+ 배치 / 포커스 / 따라가기) ---
	_spawn_opt = OptionButton.new()
	_spawn_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spawn_opt.clip_text = true
	_populate_spawn_options()
	add_child(_spawn_opt)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 4)
	add_child(action_row)

	var btn_spawn := Button.new()
	btn_spawn.text = "+ 배치"
	btn_spawn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_spawn.tooltip_text = "선택한 캐릭터를 현재 3D 씬에 새 인스턴스로 배치합니다."
	StudioTheme.style_button(btn_spawn, "amber")
	btn_spawn.pressed.connect(_on_spawn_pressed)
	action_row.add_child(btn_spawn)

	var btn_focus := Button.new()
	btn_focus.text = "포커스"
	btn_focus.icon = StudioTheme.get_icon("focus", StudioTheme.TEXT_SECONDARY, 14)
	btn_focus.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_focus.tooltip_text = "선택한 인스턴스를 3D 뷰포트 카메라 중심으로 포커스합니다."
	StudioTheme.style_button(btn_focus, "default")
	btn_focus.pressed.connect(func():
		if is_instance_valid(_bound_instance):
			focus_requested.emit(_bound_instance)
	)
	action_row.add_child(btn_focus)

	_btn_follow = Button.new()
	_btn_follow.text = "따라가기"
	_btn_follow.toggle_mode = true
	_btn_follow.button_pressed = false
	_btn_follow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_follow.tooltip_text = "활성화하면 3D 뷰포트 카메라가 이동 중인 캐릭터를 자동 추적합니다."
	StudioTheme.style_button(_btn_follow, "teal")
	_btn_follow.toggled.connect(func(v: bool):
		_follow_enabled = v
		follow_toggled.emit(v)
	)
	action_row.add_child(_btn_follow)

	add_child(HSeparator.new())

	# --- Skeleton Bone Hierarchy Section ---
	var bone_hdr := HBoxContainer.new()
	bone_hdr.add_theme_constant_override("separation", 6)
	add_child(bone_hdr)

	var bone_ic := TextureRect.new()
	bone_ic.texture = StudioTheme.get_icon("bone", StudioTheme.ACCENT_TEAL, 14)
	bone_ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	bone_ic.custom_minimum_size = Vector2(14, 14)
	bone_hdr.add_child(bone_ic)

	var bone_title := Label.new()
	bone_title.text = "스켈레톤 본 계층"
	bone_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bone_title.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY)
	bone_title.add_theme_font_size_override("font_size", 12)
	bone_hdr.add_child(bone_title)

	_bone_filter = LineEdit.new()
	_bone_filter.placeholder_text = "본 검색..."
	_bone_filter.clear_button_enabled = true
	_bone_filter.custom_minimum_size = Vector2(105, 0)
	_bone_filter.text_changed.connect(func(_t: String): _rebuild_bone_tree())
	bone_hdr.add_child(_bone_filter)

	_bone_tree = Tree.new()
	_bone_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bone_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bone_tree.hide_root = true
	_bone_tree.add_theme_stylebox_override("panel", StudioTheme.make_box(StudioTheme.BG_CANVAS, StudioTheme.BORDER_BASE, 5, 1, 4, 4))
	_bone_tree.item_selected.connect(_on_bone_selected)
	add_child(_bone_tree)

	# --- Fixed Bottom Pose Readout Card ---
	var pose_card := PanelContainer.new()
	StudioTheme.style_section_card(pose_card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_NODE)
	add_child(pose_card)

	var pose_vb := VBoxContainer.new()
	pose_vb.add_theme_constant_override("separation", 2)
	pose_card.add_child(pose_vb)

	_bone_title_lbl = Label.new()
	_bone_title_lbl.text = "본 포즈 인스펙터"
	_bone_title_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
	_bone_title_lbl.add_theme_font_size_override("font_size", 11)
	pose_vb.add_child(_bone_title_lbl)

	_bone_pose_label = Label.new()
	_bone_pose_label.text = "본을 클릭하면 실시간 Local / Rot / Global 포즈가 표시됩니다."
	_bone_pose_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bone_pose_label.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	_bone_pose_label.add_theme_font_size_override("font_size", 11)
	pose_vb.add_child(_bone_pose_label)


func _populate_spawn_options() -> void:
	_spawn_specs.clear()
	_spawn_opt.clear()
	_spawn_specs.append({"role": "hero_arena", "character_id": "hero", "label": "Hero Arena (85본 · 10 Lua + AI)"})
	_spawn_specs.append({"role": "quadruped", "character_id": "quadruped", "label": "4족 Locomotor (28본 · 절차적 IK)"})
	for e in Store.load_catalog():
		var cid := str(e.get("id", ""))
		var cname := str(e.get("name", cid))
		var bones := int(e.get("bones", 0))
		_spawn_specs.append({"role": "character", "character_id": cid, "label": "%s (%d본)" % [cname, bones]})
	for spec in _spawn_specs:
		_spawn_opt.add_item(str(spec["label"]))


func _role_icon_name(role_str: String) -> String:
	match role_str:
		"hero_arena": return "hero"
		"quadruped": return "quadruped"
		_: return "character"


func _role_accent(role_str: String) -> Color:
	match role_str:
		"hero_arena": return StudioTheme.ACCENT_AMBER
		"quadruped": return StudioTheme.ACCENT_TEAL
		_: return StudioTheme.SEMANTIC_INFO


func _rebuild_instance_cards() -> void:
	if _cards_box == null:
		return
	for ch in _cards_box.get_children():
		ch.queue_free()
	_card_entries.clear()

	for inst in _instances:
		if not is_instance_valid(inst):
			continue
		var role_str := str(inst.get("role"))
		var is_sel := (inst == _bound_instance)
		var accent := _role_accent(role_str)

		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		StudioTheme.style_card(panel, is_sel, StudioTheme.ACCENT_AMBER)
		var captured_inst := inst
		panel.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				if (ev as InputEventMouseButton).double_click:
					focus_requested.emit(captured_inst)
				else:
					_select_card_instance(captured_inst)
		)
		_cards_box.add_child(panel)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		panel.add_child(row)

		var icon_tr := TextureRect.new()
		icon_tr.texture = StudioTheme.get_icon(_role_icon_name(role_str), accent, 16)
		icon_tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		icon_tr.custom_minimum_size = Vector2(18, 18)
		row.add_child(icon_tr)

		var text_vb := VBoxContainer.new()
		text_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_vb.add_theme_constant_override("separation", 1)
		row.add_child(text_vb)

		var name_lbl := Label.new()
		name_lbl.text = inst.name
		name_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY if is_sel else StudioTheme.TEXT_SECONDARY)
		name_lbl.add_theme_font_size_override("font_size", 12)
		text_vb.add_child(name_lbl)

		var sub_lbl := Label.new()
		sub_lbl.text = str(inst.call("get_display_subtitle")) if inst.has_method("get_display_subtitle") else role_str
		sub_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
		sub_lbl.add_theme_font_size_override("font_size", 10)
		text_vb.add_child(sub_lbl)

		var state_lbl := Label.new()
		state_lbl.text = "대기"
		StudioTheme.style_pill_label(state_lbl, StudioTheme.ACCENT_TEAL_DIM if is_sel else Color("#202634"), StudioTheme.ACCENT_TEAL if is_sel else StudioTheme.BORDER_CONTROL, StudioTheme.ACCENT_TEAL_TEXT if is_sel else StudioTheme.TEXT_MUTED)
		row.add_child(state_lbl)

		var f_btn := Button.new()
		f_btn.icon = StudioTheme.get_icon("focus", StudioTheme.TEXT_MUTED, 13)
		f_btn.tooltip_text = "%s 포커스" % inst.name
		f_btn.custom_minimum_size = Vector2(24, 24)
		StudioTheme.style_button(f_btn, "default")
		f_btn.pressed.connect(func(): focus_requested.emit(captured_inst))
		row.add_child(f_btn)

		_card_entries.append({
			"inst": inst,
			"panel": panel,
			"state_lbl": state_lbl,
			"name_lbl": name_lbl,
		})


func _refresh_card_selection_styles() -> void:
	for entry in _card_entries:
		var inst: Node3D = entry["inst"] as Node3D
		var panel: PanelContainer = entry["panel"] as PanelContainer
		var name_lbl: Label = entry["name_lbl"] as Label
		var state_lbl: Label = entry["state_lbl"] as Label
		if not is_instance_valid(panel):
			continue
		var is_sel := (inst == _bound_instance)
		StudioTheme.style_card(panel, is_sel, StudioTheme.ACCENT_AMBER)
		name_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY if is_sel else StudioTheme.TEXT_SECONDARY)
		StudioTheme.style_pill_label(
			state_lbl,
			StudioTheme.ACCENT_TEAL_DIM if is_sel else Color("#202634"),
			StudioTheme.ACCENT_TEAL if is_sel else StudioTheme.BORDER_CONTROL,
			StudioTheme.ACCENT_TEAL_TEXT if is_sel else StudioTheme.TEXT_MUTED
		)


func set_scene_instances(instances: Array[Node3D], active: Node3D) -> void:
	if _cards_box == null:
		_build_ui()
	_instances = instances.duplicate()
	_count_label.text = "%d개" % _instances.size()
	_bound_instance = active
	_rebuild_instance_cards()
	_selected_bone_idx = -1
	_rebuild_bone_tree()
	update_live()


func bind_instance(inst: Node3D) -> void:
	if _cards_box == null:
		_build_ui()
	var changed := (_bound_instance != inst)
	_bound_instance = inst
	_refresh_card_selection_styles()
	if changed:
		_selected_bone_idx = -1
		_rebuild_bone_tree()


func update_live() -> void:
	if _cards_box == null:
		return
	for entry in _card_entries:
		var inst: Node3D = entry["inst"] as Node3D
		var state_lbl: Label = entry["state_lbl"] as Label
		if not is_instance_valid(inst) or not is_instance_valid(state_lbl) or not inst.has_method("get_state_snapshot"):
			continue
		var snap: Dictionary = inst.call("get_state_snapshot")
		var st := str(snap.get("active_state", "Idle"))
		if st.length() > 11:
			st = st.substr(0, 11)
		state_lbl.text = st

	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_skeleton"):
		return
	var skel := _bound_instance.call("get_skeleton") as Skeleton3D
	if skel == null:
		return
	if _bone_tree.get_root() == null and skel.get_bone_count() > 0:
		_rebuild_bone_tree()
	if _selected_bone_idx >= 0 and _selected_bone_idx < skel.get_bone_count():
		var bname := skel.get_bone_name(_selected_bone_idx)
		var lp := skel.get_bone_pose_position(_selected_bone_idx)
		var lr := skel.get_bone_pose_rotation(_selected_bone_idx).get_euler()
		var gp := skel.get_bone_global_pose(_selected_bone_idx).origin
		_bone_title_lbl.text = "[#%d] %s" % [_selected_bone_idx, bname]
		_bone_pose_label.text = "Local  : (%+.3f, %+.3f, %+.3f) m\nRot    : (%+.1f°, %+.1f°, %+.1f°)\nGlobal : (%+.3f, %+.3f, %+.3f) m" % [
			lp.x, lp.y, lp.z,
			rad_to_deg(lr.x), rad_to_deg(lr.y), rad_to_deg(lr.z),
			gp.x, gp.y, gp.z,
		]


func _rebuild_bone_tree() -> void:
	if _bone_tree == null:
		return
	_bone_tree.clear()
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_skeleton"):
		_bone_title_lbl.text = "선택된 인스턴스 없음"
		_bone_pose_label.text = "3D 뷰포트 또는 위 카드에서 캐릭터 인스턴스를 선택하세요."
		return
	var skel := _bound_instance.call("get_skeleton") as Skeleton3D
	if skel == null or skel.get_bone_count() == 0:
		_bone_title_lbl.text = "스켈레톤 초기화 중..."
		_bone_pose_label.text = ""
		return

	var filter_txt := _bone_filter.text.strip_edges().to_lower()
	var root_item := _bone_tree.create_item()
	var items_by_idx: Dictionary = {}
	var bone_icon := StudioTheme.get_icon("bone", StudioTheme.TEXT_DIM, 12)

	for i in skel.get_bone_count():
		var bname := skel.get_bone_name(i)
		if not filter_txt.is_empty() and bname.to_lower().find(filter_txt) < 0:
			continue
		var p_idx := skel.get_bone_parent(i)
		var parent_item: TreeItem = items_by_idx.get(p_idx, root_item) if filter_txt.is_empty() else root_item
		var item := _bone_tree.create_item(parent_item)
		item.set_text(0, "%s  [#%d]" % [bname, i])
		item.set_metadata(0, i)
		if bone_icon != null:
			item.set_icon(0, bone_icon)
		items_by_idx[i] = item

	_bone_title_lbl.text = "%s · 총 %d본" % [_bound_instance.name, skel.get_bone_count()]
	_bone_pose_label.text = "본을 클릭하면 실시간 Local / Rot / Global 포즈가 표시됩니다."


func _select_card_instance(inst: Node3D) -> void:
	if not is_instance_valid(inst):
		return
	_bound_instance = inst
	_refresh_card_selection_styles()
	_selected_bone_idx = -1
	_rebuild_bone_tree()
	instance_selected.emit(inst)


func _on_spawn_pressed() -> void:
	var idx := _spawn_opt.selected
	if idx < 0 or idx >= _spawn_specs.size():
		return
	var spec: Dictionary = _spawn_specs[idx]
	spawn_requested.emit(str(spec["role"]), str(spec["character_id"]))


func _on_bone_selected() -> void:
	var item := _bone_tree.get_selected()
	if item == null:
		return
	_selected_bone_idx = int(item.get_metadata(0))
	update_live()
