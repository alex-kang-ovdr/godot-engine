@tool
extends VBoxContainer
## Standard Godot Editor Dock: "AnimStudio · 계층"
## Lists all AnimationStudioInstance nodes placed in the active 3D scene,
## lets the user click-select or spawn any of the 28 internalized characters
## (plus Hero Arena & Quadruped Locomotor) directly into the 3D scene, and
## displays the live Skeleton3D bone hierarchy & bone pose readout.

const Store := preload("res://characters/character_store.gd")

signal instance_selected(inst: Node3D)
signal spawn_requested(role: String, character_id: String)
signal focus_requested(inst: Node3D)
signal refresh_requested()

var _instances: Array[Node3D] = []
var _bound_instance: Node3D = null
var _selected_bone_idx: int = -1
var _syncing_list: bool = false

var _instance_list: ItemList = null
var _spawn_opt: OptionButton = null
var _bone_filter: LineEdit = null
var _bone_tree: Tree = null
var _bone_pose_label: Label = null
var _count_label: Label = null
var _spawn_specs: Array[Dictionary] = []


func _init() -> void:
	name = "AnimStudio · 계층"
	custom_minimum_size = Vector2(240, 260)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	if _instance_list != null:
		return
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 6)

	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 4)
	add_child(top_bar)

	var title := Label.new()
	title.text = "씬 캐릭터 인스턴스"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(title)

	_count_label = Label.new()
	_count_label.text = "0개"
	_count_label.modulate = Color("#7fd6cc")
	top_bar.add_child(_count_label)

	var btn_refresh := Button.new()
	btn_refresh.text = "새로고침"
	btn_refresh.tooltip_text = "현재 3D 씬의 AnimationStudioInstance 목록을 다시 스캔합니다."
	btn_refresh.pressed.connect(func(): refresh_requested.emit())
	top_bar.add_child(btn_refresh)

	_instance_list = ItemList.new()
	_instance_list.custom_minimum_size = Vector2(0, 128)
	_instance_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_instance_list.item_selected.connect(_on_instance_item_selected)
	_instance_list.item_activated.connect(_on_instance_item_activated)
	add_child(_instance_list)

	# Spawn new character instance into current 3D scene
	var spawn_row := HBoxContainer.new()
	spawn_row.add_theme_constant_override("separation", 4)
	add_child(spawn_row)

	_spawn_opt = OptionButton.new()
	_spawn_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spawn_opt.clip_text = true
	_populate_spawn_options()
	spawn_row.add_child(_spawn_opt)

	var btn_spawn := Button.new()
	btn_spawn.text = "+ 배치"
	btn_spawn.tooltip_text = "선택한 캐릭터를 현재 3D 씬에 새 인스턴스로 배치합니다."
	btn_spawn.pressed.connect(_on_spawn_pressed)
	spawn_row.add_child(btn_spawn)

	var btn_focus := Button.new()
	btn_focus.text = "포커스"
	btn_focus.tooltip_text = "선택한 인스턴스를 3D 뷰포트에서 선택·포커스합니다."
	btn_focus.pressed.connect(func():
		if is_instance_valid(_bound_instance):
			focus_requested.emit(_bound_instance)
	)
	spawn_row.add_child(btn_focus)

	var sep := HSeparator.new()
	add_child(sep)

	var bone_hdr := HBoxContainer.new()
	bone_hdr.add_theme_constant_override("separation", 4)
	add_child(bone_hdr)

	var bone_title := Label.new()
	bone_title.text = "스켈레톤 본 계층"
	bone_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bone_hdr.add_child(bone_title)

	_bone_filter = LineEdit.new()
	_bone_filter.placeholder_text = "본 검색..."
	_bone_filter.clear_button_enabled = true
	_bone_filter.custom_minimum_size = Vector2(110, 0)
	_bone_filter.text_changed.connect(func(_t: String): _rebuild_bone_tree())
	bone_hdr.add_child(_bone_filter)

	_bone_tree = Tree.new()
	_bone_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bone_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bone_tree.hide_root = true
	_bone_tree.item_selected.connect(_on_bone_selected)
	add_child(_bone_tree)

	_bone_pose_label = Label.new()
	_bone_pose_label.text = "본을 선택하면 실시간 Local/Global 포즈가 표시됩니다."
	_bone_pose_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bone_pose_label.modulate = Color("#a8bdd6")
	add_child(_bone_pose_label)


func _populate_spawn_options() -> void:
	_spawn_specs.clear()
	_spawn_opt.clear()
	_spawn_specs.append({"role": "hero_arena", "character_id": "hero", "label": "Hero Arena (85본 · 10 Lua)"})
	_spawn_specs.append({"role": "quadruped", "character_id": "quadruped", "label": "4족 Locomotor (28본 · 절차적)"})
	for e in Store.load_catalog():
		var cid := str(e.get("id", ""))
		var cname := str(e.get("name", cid))
		var bones := int(e.get("bones", 0))
		_spawn_specs.append({"role": "character", "character_id": cid, "label": "%s (%d본)" % [cname, bones]})
	for spec in _spawn_specs:
		_spawn_opt.add_item(str(spec["label"]))


func set_scene_instances(instances: Array[Node3D], active: Node3D) -> void:
	if _instance_list == null:
		_build_ui()
	_instances = instances.duplicate()
	_count_label.text = "%d개" % _instances.size()
	_syncing_list = true
	_instance_list.clear()
	var active_idx := -1
	for i in _instances.size():
		var inst := _instances[i]
		if not is_instance_valid(inst):
			continue
		var label := str(inst.call("get_display_title")) if inst.has_method("get_display_title") else inst.name
		_instance_list.add_item(label)
		if inst == active:
			active_idx = i
	if active_idx >= 0:
		_instance_list.select(active_idx)
	_syncing_list = false
	bind_instance(active)


func bind_instance(inst: Node3D) -> void:
	if _instance_list == null:
		_build_ui()
	var changed := (_bound_instance != inst)
	_bound_instance = inst
	if _bound_instance != null and is_instance_valid(_bound_instance):
		_syncing_list = true
		for i in _instances.size():
			if _instances[i] == _bound_instance:
				_instance_list.select(i)
				break
		_syncing_list = false
	if changed:
		_selected_bone_idx = -1
		_rebuild_bone_tree()


func update_live() -> void:
	if _instance_list == null:
		return
	# Refresh subtle live state suffix on instance list items
	for i in mini(_instances.size(), _instance_list.item_count):
		var inst := _instances[i]
		if not is_instance_valid(inst) or not inst.has_method("get_state_snapshot"):
			continue
		var snap: Dictionary = inst.call("get_state_snapshot")
		var title := str(inst.call("get_display_title"))
		var st := str(snap.get("active_state", ""))
		_instance_list.set_item_text(i, "%s · %s" % [title, st] if not st.is_empty() else title)

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
		_bone_pose_label.text = "[%d] %s\nLocal: (%.3f, %.3f, %.3f) | Rot: (%.1f°, %.1f°, %.1f°)\nGlobal: (%.3f, %.3f, %.3f)" % [
			_selected_bone_idx, bname,
			lp.x, lp.y, lp.z,
			rad_to_deg(lr.x), rad_to_deg(lr.y), rad_to_deg(lr.z),
			gp.x, gp.y, gp.z,
		]


func _rebuild_bone_tree() -> void:
	if _bone_tree == null:
		return
	_bone_tree.clear()
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_skeleton"):
		_bone_pose_label.text = "3D 뷰포트에서 AnimationStudioInstance를 선택하세요."
		return
	var skel := _bound_instance.call("get_skeleton") as Skeleton3D
	if skel == null or skel.get_bone_count() == 0:
		_bone_pose_label.text = "스켈레톤 초기화 중..."
		return

	var filter_txt := _bone_filter.text.strip_edges().to_lower()
	var root_item := _bone_tree.create_item()
	var items_by_idx: Dictionary = {}

	for i in skel.get_bone_count():
		var bname := skel.get_bone_name(i)
		if not filter_txt.is_empty() and bname.to_lower().find(filter_txt) < 0:
			continue
		var p_idx := skel.get_bone_parent(i)
		var parent_item: TreeItem = items_by_idx.get(p_idx, root_item) if filter_txt.is_empty() else root_item
		var item := _bone_tree.create_item(parent_item)
		item.set_text(0, "%s  [#%d]" % [bname, i])
		item.set_metadata(0, i)
		items_by_idx[i] = item

	_bone_pose_label.text = "%s · 총 %d본 (클릭하여 실시간 포즈 확인)" % [_bound_instance.name, skel.get_bone_count()]


func _on_instance_item_selected(index: int) -> void:
	if _syncing_list or index < 0 or index >= _instances.size():
		return
	var inst := _instances[index]
	if is_instance_valid(inst):
		_bound_instance = inst
		_selected_bone_idx = -1
		_rebuild_bone_tree()
		instance_selected.emit(inst)


func _on_instance_item_activated(index: int) -> void:
	if index < 0 or index >= _instances.size():
		return
	var inst := _instances[index]
	if is_instance_valid(inst):
		focus_requested.emit(inst)


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
