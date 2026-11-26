@tool
extends EditorPlugin
## Registers the Hero Locomotion State-Machine walkthrough & 255-tick Rewind
## studio as a Godot Editor bottom panel.

const StudioScene := preload("res://hero/hero_locomotion_studio.tscn")

var _panel: Control = null


func _enter_tree() -> void:
	_panel = StudioScene.instantiate()
	add_control_to_bottom_panel(_panel, "Hero 상태머신")


func _exit_tree() -> void:
	if is_instance_valid(_panel):
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
	_panel = null
