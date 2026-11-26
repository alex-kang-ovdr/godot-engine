@tool
extends EditorPlugin
## Registers the NaturalMotion Morpheme-style Hero Animation Studio as a
## full Main Screen workspace inside both Godot Web Editor (WASM) and Desktop Editor,
## alongside a Tools menu action and live Editor dock virtual-pointer overlay.

const StudioScene := preload("res://hero/hero_locomotion_studio.tscn")
const CursorOverlay := preload("res://hero/authoring_cursor_overlay.gd")
const PLUGIN_MAIN_SCREEN_NAME := "Morpheme Studio"
const TOOL_MENU_LABEL := "Hero 제작 과정 가상 포인터 다시보기"

var _main_panel: Control = null
var _editor_overlay: CursorOverlay = null
var _docks: Dictionary = {}


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return PLUGIN_MAIN_SCREEN_NAME


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("AnimationTree", "EditorIcons")


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_main_panel):
		_main_panel.visible = visible
	if not visible and is_instance_valid(_editor_overlay):
		_editor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)


func _enter_tree() -> void:
	_main_panel = StudioScene.instantiate()
	_main_panel.visible = false
	EditorInterface.get_editor_main_screen().add_child(_main_panel)
	add_tool_menu_item(TOOL_MENU_LABEL, _open_authoring_replay)
	_setup_editor_overlay()
	if _main_panel.has_method("set_authoring_mode"):
		_main_panel.editor_cursor_callback = _on_authoring_cursor
	print("ANIMATION_STUDIO_EDITOR_READY main_screen=%s web=%s" % [PLUGIN_MAIN_SCREEN_NAME, OS.has_feature("web")])
	if OS.has_feature("web"):
		call_deferred("_open_authoring_replay")


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_LABEL)
	if is_instance_valid(_editor_overlay):
		_editor_overlay.queue_free()
	_editor_overlay = null
	_docks.clear()
	if is_instance_valid(_main_panel):
		_main_panel.queue_free()
	_main_panel = null


func _open_authoring_replay() -> void:
	if not is_instance_valid(_main_panel):
		return
	if OS.has_feature("web"):
		EditorInterface.set_distraction_free_mode(true)
	EditorInterface.set_main_screen_editor(PLUGIN_MAIN_SCREEN_NAME)
	_main_panel.visible = true
	_main_panel.call("set_authoring_mode", true)
	_main_panel.call("seek_authoring", 0.0, true)
	_main_panel.call("set_playing", true)


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
	if not active or snap.is_empty() or base == null or not is_instance_valid(_main_panel) or not _main_panel.is_visible_in_tree():
		_editor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)
		return
	var step: Dictionary = snap.get("step", {})
	var dock_key := str(step.get("editor_dock", "bottom"))
	# Highlight external Godot Editor docks only when targeting SceneTree/FileSystem/Inspector outside the main screen.
	if dock_key in ["bottom", "viewport"] or not _docks.has(dock_key):
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
