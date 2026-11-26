@tool
extends EditorPlugin
## Registers the NaturalMotion Morpheme-style Animation Studio as a Main Screen
## workspace inside both Godot Web Editor (WASM) and Desktop Editor, hosting:
##   Tab 1: Procedural Quadruped Locomotor (Unreal Engine Locomotor reference)
##   Tab 2: Hero 85-Bone State-Machine Studio (native GLB/RES)
## Plus Tools menu entries and live Editor dock virtual-pointer overlay.

const HeroStudioScene := preload("res://hero/hero_locomotion_studio.tscn")
const QuadrupedStudioScene := preload("res://quadruped/quadruped_locomotor_studio.tscn")
const CursorOverlay := preload("res://hero/authoring_cursor_overlay.gd")
const PLUGIN_MAIN_SCREEN_NAME := "Morpheme Studio"
const TOOL_MENU_QUADRUPED := "4족 절차적 Locomotor 제작 과정 다시보기"
const TOOL_MENU_HERO := "Hero 제작 과정 가상 포인터 다시보기"

var _root_shell: VBoxContainer = null
var _quad_panel: Control = null
var _hero_panel: Control = null
var _btn_quad: Button = null
var _btn_hero: Button = null
var _active_tab: String = "quadruped"
var _editor_overlay: CursorOverlay = null
var _docks: Dictionary = {}


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return PLUGIN_MAIN_SCREEN_NAME


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("AnimationTree", "EditorIcons")


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_root_shell):
		_root_shell.visible = visible
	if not visible and is_instance_valid(_editor_overlay):
		_editor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)


func _enter_tree() -> void:
	_root_shell = VBoxContainer.new()
	_root_shell.name = "MorphemeStudioShell"
	_root_shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_shell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root_shell.add_theme_constant_override("separation", 2)
	_root_shell.visible = false

	var switcher := HBoxContainer.new()
	switcher.add_theme_constant_override("separation", 6)
	_root_shell.add_child(switcher)

	_btn_quad = Button.new()
	_btn_quad.text = "4족 절차적 Locomotor (UE 참고 · 28본 · 0클립)"
	_btn_quad.toggle_mode = true
	_btn_quad.pressed.connect(func(): _select_tab("quadruped"))
	switcher.add_child(_btn_quad)

	_btn_hero = Button.new()
	_btn_hero.text = "Hero 85본 로코모션 상태머신 (GLB/RES)"
	_btn_hero.toggle_mode = true
	_btn_hero.pressed.connect(func(): _select_tab("hero"))
	switcher.add_child(_btn_hero)

	var content_host := Control.new()
	content_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_host.clip_contents = true
	_root_shell.add_child(content_host)

	_quad_panel = QuadrupedStudioScene.instantiate()
	_hero_panel = HeroStudioScene.instantiate()
	content_host.add_child(_quad_panel)
	content_host.add_child(_hero_panel)

	EditorInterface.get_editor_main_screen().add_child(_root_shell)
	add_tool_menu_item(TOOL_MENU_QUADRUPED, _open_quadruped_replay)
	add_tool_menu_item(TOOL_MENU_HERO, _open_hero_replay)
	_setup_editor_overlay()

	if _quad_panel.has_method("set_authoring_mode"):
		_quad_panel.editor_cursor_callback = _on_authoring_cursor
	if _hero_panel.has_method("set_authoring_mode"):
		_hero_panel.editor_cursor_callback = _on_authoring_cursor

	_select_tab("quadruped")
	print("ANIMATION_STUDIO_EDITOR_READY main_screen=%s active_tab=%s web=%s" % [PLUGIN_MAIN_SCREEN_NAME, _active_tab, OS.has_feature("web")])
	if OS.has_feature("web"):
		call_deferred("_open_quadruped_replay")


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_QUADRUPED)
	remove_tool_menu_item(TOOL_MENU_HERO)
	if is_instance_valid(_editor_overlay):
		_editor_overlay.queue_free()
	_editor_overlay = null
	_docks.clear()
	if is_instance_valid(_root_shell):
		_root_shell.queue_free()
	_root_shell = null
	_quad_panel = null
	_hero_panel = null


func _select_tab(tab: String) -> void:
	_active_tab = tab
	var is_quad := tab == "quadruped"
	if is_instance_valid(_btn_quad):
		_btn_quad.set_pressed_no_signal(is_quad)
	if is_instance_valid(_btn_hero):
		_btn_hero.set_pressed_no_signal(not is_quad)
	if is_instance_valid(_quad_panel):
		_quad_panel.visible = is_quad
		_quad_panel.call("set_playing", is_quad)
	if is_instance_valid(_hero_panel):
		_hero_panel.visible = not is_quad
		_hero_panel.call("set_playing", not is_quad)


func _open_quadruped_replay() -> void:
	if not is_instance_valid(_root_shell):
		return
	if OS.has_feature("web"):
		EditorInterface.set_distraction_free_mode(true)
	EditorInterface.set_main_screen_editor(PLUGIN_MAIN_SCREEN_NAME)
	_root_shell.visible = true
	_select_tab("quadruped")
	_quad_panel.call("set_authoring_mode", true)
	_quad_panel.call("seek_authoring", 0.0, true)
	_quad_panel.call("set_playing", true)


func _open_hero_replay() -> void:
	if not is_instance_valid(_root_shell):
		return
	if OS.has_feature("web"):
		EditorInterface.set_distraction_free_mode(true)
	EditorInterface.set_main_screen_editor(PLUGIN_MAIN_SCREEN_NAME)
	_root_shell.visible = true
	_select_tab("hero")
	_hero_panel.call("set_authoring_mode", true)
	_hero_panel.call("seek_authoring", 0.0, true)
	_hero_panel.call("set_playing", true)


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
	if not active or snap.is_empty() or base == null or not is_instance_valid(_root_shell) or not _root_shell.is_visible_in_tree():
		_editor_overlay.present(false, "assets", "search", "", Rect2(), "", 0.0, true)
		return
	var step: Dictionary = snap.get("step", {})
	var dock_key := str(step.get("editor_dock", "bottom"))
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
