@tool
extends EditorPlugin
## Standard Godot EditorPlugin for Animation Studio.
## Uses Godot's native 3D Viewport (no custom main-screen override) and registers
## three standard dockable editor panels:
##   - Left Dock  (DOCK_SLOT_LEFT_BR):  "AnimStudio · 계층"
##   - Right Dock (DOCK_SLOT_RIGHT_BL): "AnimStudio · 상태"
##   - Bottom Panel:                    "Animation Flow"
##
## All three docks automatically synchronize with whichever AnimationStudioInstance
## node is selected in the 3D Viewport, Scene Tree dock, or Hierarchy dock.

const HierarchyDockScript := preload("res://addons/animation_studio/docks/hierarchy_dock.gd")
const StateDockScript := preload("res://addons/animation_studio/docks/state_dock.gd")
const FlowBottomPanelScript := preload("res://addons/animation_studio/docks/flow_bottom_panel.gd")
const InstanceScript := preload("res://addons/animation_studio/animation_studio_instance.gd")

const WORLD_SCENE_PATH := "res://hero/arena/hero_arena_world.tscn"
const TOOL_OPEN_WORLD := "Animation Studio · 3D 아레나 씬 열기 (표준 뷰포트)"
const TOOL_SHOW_FLOW := "Animation Studio · Animation Flow 하단 패널 열기"
const TOOL_OPEN_QUADRUPED := "Animation Studio · 4족 절차적 Locomotor 씬 열기"
const TOOL_OPEN_HERO := "Animation Studio · Hero 상태머신 스튜디오 씬 열기"
const TOOL_OPEN_SOLDIER := "Animation Studio · Soldier 114본 · M4 비교 씬 열기"
const TOOL_OPEN_ROSTER := "Animation Studio · 전체 28종 캐릭터 로스터 씬 열기"
const TOOL_OPEN_ARENA := "Animation Studio · Hero 배경맵 단독 데모 씬 열기"

var _hierarchy_dock: Control = null
var _state_dock: Control = null
var _flow_panel: Control = null
var _bound_instance: Node3D = null
var _live_timer: Timer = null
var _selection_connected: bool = false
var _spawn_counter: int = 0
var _initial_focus_done: bool = false
var _last_bound_pos: Vector3 = Vector3.ZERO
var _has_last_bound_pos: bool = false


func _has_main_screen() -> bool:
	return false


func _get_plugin_name() -> String:
	return "Animation Studio"


func _enter_tree() -> void:
	_hierarchy_dock = HierarchyDockScript.new()
	_hierarchy_dock.connect("instance_selected", _on_dock_instance_selected)
	_hierarchy_dock.connect("spawn_requested", _on_dock_spawn_requested)
	_hierarchy_dock.connect("focus_requested", _on_dock_focus_requested)
	_hierarchy_dock.connect("refresh_requested", _refresh_scene_instances)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BR, _hierarchy_dock)

	_state_dock = StateDockScript.new()
	_state_dock.connect("docking_lines_toggled", _on_docking_lines_toggled)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _state_dock)

	_flow_panel = FlowBottomPanelScript.new()
	add_control_to_bottom_panel(_flow_panel, "Animation Flow")

	add_tool_menu_item(TOOL_OPEN_WORLD, _open_world_scene)
	add_tool_menu_item(TOOL_SHOW_FLOW, _show_flow_panel)
	add_tool_menu_item(TOOL_OPEN_QUADRUPED, func(): _open_scene("res://quadruped/quadruped_locomotor_studio.tscn"))
	add_tool_menu_item(TOOL_OPEN_HERO, func(): _open_scene("res://hero/hero_locomotion_studio.tscn"))
	add_tool_menu_item(TOOL_OPEN_SOLDIER, func(): _open_scene("res://soldier/soldier_demo.tscn"))
	add_tool_menu_item(TOOL_OPEN_ROSTER, func(): _open_scene("res://characters/character_showcase.tscn"))
	add_tool_menu_item(TOOL_OPEN_ARENA, func(): _open_scene("res://hero/arena/hero_arena.tscn"))

	if not scene_changed.is_connected(_on_scene_changed):
		scene_changed.connect(_on_scene_changed)
	var sel := EditorInterface.get_selection()
	if sel != null and not sel.selection_changed.is_connected(_on_editor_selection_changed):
		sel.selection_changed.connect(_on_editor_selection_changed)
		_selection_connected = true

	_live_timer = Timer.new()
	_live_timer.wait_time = 0.08
	_live_timer.autostart = true
	_live_timer.timeout.connect(_on_live_tick)
	add_child(_live_timer)

	print("ANIMATION_STUDIO_EDITOR_READY mode=standard_docks scene=hero_arena_world.tscn web=%s" % OS.has_feature("web"))
	call_deferred("_bootstrap_workspace")


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_OPEN_WORLD)
	remove_tool_menu_item(TOOL_SHOW_FLOW)
	remove_tool_menu_item(TOOL_OPEN_QUADRUPED)
	remove_tool_menu_item(TOOL_OPEN_HERO)
	remove_tool_menu_item(TOOL_OPEN_SOLDIER)
	remove_tool_menu_item(TOOL_OPEN_ROSTER)
	remove_tool_menu_item(TOOL_OPEN_ARENA)

	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if _selection_connected:
		var sel := EditorInterface.get_selection()
		if sel != null and sel.selection_changed.is_connected(_on_editor_selection_changed):
			sel.selection_changed.disconnect(_on_editor_selection_changed)
		_selection_connected = false

	if is_instance_valid(_live_timer):
		_live_timer.queue_free()
	_live_timer = null

	if is_instance_valid(_hierarchy_dock):
		remove_control_from_docks(_hierarchy_dock)
		_hierarchy_dock.queue_free()
	_hierarchy_dock = null

	if is_instance_valid(_state_dock):
		remove_control_from_docks(_state_dock)
		_state_dock.queue_free()
	_state_dock = null

	if is_instance_valid(_flow_panel):
		remove_control_from_bottom_panel(_flow_panel)
		_flow_panel.queue_free()
	_flow_panel = null
	_bound_instance = null


func _bootstrap_workspace() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path != WORLD_SCENE_PATH:
		if ResourceLoader.exists(WORLD_SCENE_PATH):
			EditorInterface.open_scene_from_path(WORLD_SCENE_PATH)
	EditorInterface.set_main_screen_editor("3D")
	_activate_all_studio_docks()
	call_deferred("_refresh_scene_instances")
	var t := get_tree().create_timer(0.8)
	t.timeout.connect(_activate_all_studio_docks)


func _activate_all_studio_docks() -> void:
	_activate_dock_tab(_hierarchy_dock)
	_activate_dock_tab(_state_dock)
	_show_flow_panel()


func _activate_dock_tab(ctrl: Control) -> void:
	if not is_instance_valid(ctrl):
		return
	var p := ctrl.get_parent()
	if p is TabContainer:
		(p as TabContainer).current_tab = ctrl.get_index()


func _open_world_scene() -> void:
	if ResourceLoader.exists(WORLD_SCENE_PATH):
		EditorInterface.open_scene_from_path(WORLD_SCENE_PATH)
	EditorInterface.set_main_screen_editor("3D")
	_show_flow_panel()
	call_deferred("_refresh_scene_instances")


func _open_scene(path: String) -> void:
	if ResourceLoader.exists(path):
		EditorInterface.open_scene_from_path(path)
	call_deferred("_refresh_scene_instances")


func _show_flow_panel() -> void:
	if is_instance_valid(_flow_panel):
		make_bottom_panel_item_visible(_flow_panel)


func _on_scene_changed(_scene_root: Node) -> void:
	_initial_focus_done = false
	call_deferred("_refresh_scene_instances")


func _on_editor_selection_changed() -> void:
	var sel := EditorInterface.get_selection()
	if sel == null:
		return
	var nodes := sel.get_selected_nodes()
	for n in nodes:
		var inst := _find_enclosing_instance(n)
		if inst != null:
			_bind_instance(inst)
			return


func _find_enclosing_instance(node: Node) -> Node3D:
	var cur: Node = node
	while cur != null:
		if cur is Node3D and cur.has_method("get_state_snapshot") and cur.has_method("get_skeleton"):
			return cur as Node3D
		cur = cur.get_parent()
	return null


func _collect_scene_instances() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	_walk_collect(root, out)
	return out


func _walk_collect(node: Node, out: Array[Node3D]) -> void:
	if node is Node3D and node.has_method("get_state_snapshot") and node.has_method("get_skeleton"):
		out.append(node as Node3D)
		return
	for c in node.get_children():
		_walk_collect(c, out)


func _refresh_scene_instances() -> void:
	var instances := _collect_scene_instances()
	var active: Node3D = null

	# Prefer currently selected AnimationStudioInstance in Editor
	var sel := EditorInterface.get_selection()
	if sel != null:
		for n in sel.get_selected_nodes():
			var enc := _find_enclosing_instance(n)
			if enc != null and instances.has(enc):
				active = enc
				break

	if active == null and is_instance_valid(_bound_instance) and instances.has(_bound_instance):
		active = _bound_instance
	if active == null and not instances.is_empty():
		active = instances[0]

	if is_instance_valid(_hierarchy_dock):
		_hierarchy_dock.call("set_scene_instances", instances, active)
	_bind_instance(active)

	if active != null and not _initial_focus_done:
		_initial_focus_done = true
		_select_in_editor(active)
		call_deferred("_frame_3d_viewport_on", active)


func _bind_instance(inst: Node3D) -> void:
	_bound_instance = inst
	_has_last_bound_pos = is_instance_valid(inst)
	if _has_last_bound_pos:
		_last_bound_pos = inst.global_position
	if is_instance_valid(_hierarchy_dock):
		_hierarchy_dock.call("bind_instance", inst)
	if is_instance_valid(_state_dock):
		_state_dock.call("bind_instance", inst)
	if is_instance_valid(_flow_panel):
		_flow_panel.call("bind_instance", inst)


func _select_in_editor(inst: Node3D) -> void:
	var sel := EditorInterface.get_selection()
	if sel == null or not is_instance_valid(inst):
		return
	sel.clear()
	sel.add_node(inst)


func _on_dock_instance_selected(inst: Node3D) -> void:
	if not is_instance_valid(inst):
		return
	_select_in_editor(inst)
	_bind_instance(inst)


func _on_dock_focus_requested(inst: Node3D) -> void:
	if not is_instance_valid(inst):
		return
	EditorInterface.set_main_screen_editor("3D")
	_select_in_editor(inst)
	_bind_instance(inst)
	_frame_3d_viewport_on(inst)


func _frame_3d_viewport_on(inst: Node3D) -> void:
	if not is_instance_valid(inst):
		return
	var main_screen := EditorInterface.get_editor_main_screen()
	if main_screen == null:
		return
	# Trigger Godot's standard Node3DEditorViewport "Focus Selection" (VIEW_CENTER_TO_SELECTION = 10)
	var vps := main_screen.find_children("*", "Node3DEditorViewport", true, false)
	if vps.is_empty():
		return
	var vp0: Node = vps[0]
	for mb in vp0.find_children("*", "MenuButton", true, false):
		var popup: PopupMenu = (mb as MenuButton).get_popup()
		if popup != null and popup.item_count > 12:
			for i in popup.item_count:
				var txt := popup.get_item_text(i).to_lower()
				if txt.contains("focus selection") or txt.contains("선택에 초점"):
					popup.id_pressed.emit(popup.get_item_id(i))
					return


func _on_dock_spawn_requested(role: String, character_id: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_open_world_scene()
		return
	_spawn_counter += 1
	var inst := Node3D.new()
	inst.set_script(InstanceScript)
	var base_name := "Hero_Arena" if role == "hero_arena" else ("Quadruped" if role == "quadruped" else character_id.capitalize())
	inst.name = "%s_%d" % [base_name, _spawn_counter]
	var angle := float(_spawn_counter) * 1.15
	inst.position = Vector3(cos(angle) * 2.4, 0.0, sin(angle) * 2.2)
	inst.set("role", role)
	inst.set("character_id", character_id)
	inst.set("playing", true)
	inst.set("auto_demo", true)
	root.add_child(inst)
	inst.owner = root
	EditorInterface.set_main_screen_editor("3D")
	_refresh_scene_instances()
	_select_in_editor(inst)
	_bind_instance(inst)
	_frame_3d_viewport_on(inst)


func _on_docking_lines_toggled(show_lines: bool) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	for c in root.find_children("*", "", true, false):
		if c.has_method("refresh_docking_lines"):
			c.set("show_docking_lines", show_lines)


func _on_live_tick() -> void:
	if is_instance_valid(_bound_instance):
		var cur_p := _bound_instance.global_position
		if _has_last_bound_pos and cur_p.distance_to(_last_bound_pos) > 2.5:
			_frame_3d_viewport_on(_bound_instance)
		_last_bound_pos = cur_p
		_has_last_bound_pos = true
	if is_instance_valid(_hierarchy_dock):
		_hierarchy_dock.call("update_live")
	if is_instance_valid(_state_dock):
		_state_dock.call("update_live")
	if is_instance_valid(_flow_panel):
		_flow_panel.call("update_live")
