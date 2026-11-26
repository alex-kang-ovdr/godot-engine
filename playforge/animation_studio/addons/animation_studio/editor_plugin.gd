@tool
extends EditorPlugin
## Registers the Hero Locomotion State-Machine & Virtual-Pointer Authoring
## Replay studio in the Godot Editor bottom panel and Tools menu, plus a live
## virtual cursor overlay over the real Editor docks (SceneTree / FileSystem /
## Inspector / Viewport) mirroring Tappy Chicken's showcase replay.

const StudioScene := preload("res://hero/hero_locomotion_studio.tscn")
const CursorOverlay := preload("res://hero/authoring_cursor_overlay.gd")
const TOOL_MENU_LABEL := "Hero 제작 과정 가상 포인터 다시보기"

var _panel: Control = null
var _editor_overlay: CursorOverlay = null
var _docks: Dictionary = {}


func _enter_tree() -> void:
	_panel = StudioScene.instantiate()
	add_control_to_bottom_panel(_panel, "Hero 상태머신")
	add_tool_menu_item(TOOL_MENU_LABEL, _open_authoring_replay)
	_setup_editor_overlay()
	if _panel.has_method("set_authoring_mode"):
		_panel.editor_cursor_callback = _on_authoring_cursor


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_LABEL)
	if is_instance_valid(_editor_overlay):
		_editor_overlay.queue_free()
	_editor_overlay = null
	_docks.clear()
	if is_instance_valid(_panel):
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
	_panel = null


func _open_authoring_replay() -> void:
	if not is_instance_valid(_panel):
		return
	make_bottom_panel_item_visible(_panel)
	_panel.call("set_authoring_mode", true)
	_panel.call("seek_authoring", 0.0, true)
	_panel.call("set_playing", true)


func _setup_editor_overlay() -> void:
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	_docks.clear()
	var scene_docks := base.find_children("*", "SceneTreeDock", true, false)
	if not scene_docks.is_empty():
		_docks["scene"] = scene_docks[0]
	var files := EditorInterface.get_file_system_dock()
	if files != null:
		_docks["filesystem"] = files
	var insp: Node = EditorInterface.get_inspector()
	while insp != null and not insp.is_class("InspectorDock"):
		insp = insp.get_parent()
	if insp != null:
		_docks["inspector"] = insp
	_docks["viewport"] = EditorInterface.get_editor_main_screen()

	_editor_overlay = CursorOverlay.new()
	base.add_child(_editor_overlay)


func _on_authoring_cursor(active: bool, snap: Dictionary) -> void:
	if not is_instance_valid(_editor_overlay):
		return
	var base := EditorInterface.get_base_control()
	if not active or snap.is_empty() or base == null or not is_instance_valid(_panel) or not _panel.is_visible_in_tree():
		_editor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)
		return
	var step: Dictionary = snap.get("step", {})
	var dock_key := str(step.get("editor_dock", "bottom"))
	# When the step targets the bottom panel itself, the panel's local cursor already highlights the exact node.
	if dock_key == "bottom" or not _docks.has(dock_key):
		_editor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)
		return
	var dock_ctrl := _docks[dock_key] as Control
	if not is_instance_valid(dock_ctrl) or not dock_ctrl.is_visible_in_tree():
		_editor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)
		return
	var gr := dock_ctrl.get_global_rect()
	var local_rect := Rect2(gr.position - base.global_position, gr.size)
	_editor_overlay.present(
		true,
		str(step.get("role", "assets")),
		str(step.get("phase", "search")),
		str(step.get("caption", "")),
		local_rect,
		str(step.get("target_label", "")),
		float(snap.get("click_pulse", 0.0)),
		false
	)
