extends Node3D

const TICK := 1.0 / 60.0
const STEP_LEFT := Color("#43ccb1")
const STEP_RIGHT := Color("#f89a50")

@onready var character = $Character
@onready var player: AnimationPlayer = $Character/Player
@onready var skeleton: Skeleton3D = $Character/Rig
@onready var camera: Camera3D = $Camera3D
@onready var hud = $HUD

var running := true
var speed := 1.0
var distance_traveled := 0.0
var left_steps := 0
var right_steps := 0
var last_step := ""
var focus := 0
var socket_error_mm := 0.0
var _hand_bone := -1
var _marks: Array[MeshInstance3D] = []
var _mark_materials: Dictionary[String, StandardMaterial3D] = {}
var _next_mark := 0
var _pending_steps: Array[String] = []
var _bound := false


func _ready() -> void:
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.callback_mode_method = AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	character.step_event.connect(_record_step)
	_hand_bone = skeleton.find_bone(character.get_tool_socket_bone_name())
	skeleton.skeleton_updated.connect(_measure_socket)
	_create_footprints()
	hud.bind(self)
	reset_demo()


func reset_demo() -> void:
	character.transform = Transform3D.IDENTITY
	left_steps = 0
	right_steps = 0
	last_step = ""
	distance_traveled = 0.0
	speed = 1.0
	_pending_steps.clear()
	_next_mark = 0
	for mark in _marks:
		mark.hide()
	_bound = $Character/Rig/Pose.play_clip(player, &"stride")
	if _bound:
		player.advance(0.0)
		skeleton.advance(0.0)
	else:
		push_error("Could not bind the demo stride clip.")
	_place_camera()
	hud.refresh()


func set_running(value: bool) -> void:
	running = value
	hud.refresh()


func set_speed(value: float) -> void:
	speed = clampf(value, 0.5, 2.0)
	hud.refresh()


func turn_character() -> void:
	character.rotate_y(PI / 2.0)
	hud.refresh()


func set_focus(index: int) -> void:
	focus = clampi(index, 0, 2)
	_place_camera()
	hud.refresh()


func _physics_process(_delta: float) -> void:
	if running:
		step_tick()


func step_tick() -> void:
	if not _bound:
		return
	var clip_delta := TICK * speed
	player.advance(clip_delta)
	# The displacement returned by the mixer is expressed in the actor frame.
	var displacement: Vector3 = character.global_basis * player.get_root_motion_position()
	character.global_position += displacement
	distance_traveled += displacement.length()
	skeleton.advance(clip_delta)
	for side in _pending_steps:
		_stamp_footprint(side)
	_pending_steps.clear()
	$Floor.position = Vector3(character.position.x, 0.0, character.position.z)
	hud.refresh()


func _record_step(side: String) -> void:
	if side == "L":
		left_steps += 1
	elif side == "R":
		right_steps += 1
	else:
		return
	last_step = side
	_pending_steps.append(side)


func _create_footprints() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.0
	mesh.bottom_radius = 1.0
	mesh.height = 0.006
	mesh.radial_segments = 20
	for side in ["L", "R"]:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = STEP_LEFT if side == "L" else STEP_RIGHT
		_mark_materials[side] = material
	for i in 16:
		var mark := MeshInstance3D.new()
		mark.mesh = mesh
		mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mark)
		_marks.append(mark)


func _stamp_footprint(side: String) -> void:
	var mark := _marks[_next_mark]
	mark.material_override = _mark_materials[side]
	_next_mark = (_next_mark + 1) % _marks.size()
	var offset := Vector3(0.0, 0.012, -0.16 if side == "L" else 0.16)
	mark.transform = character.transform * Transform3D(Basis.from_scale(Vector3(0.16, 1, 0.075)), offset)
	mark.show()


func _process(_delta: float) -> void:
	_place_camera()


func _measure_socket() -> void:
	# BoneAttachment3D has applied the final pose at this signal. Reading this
	# after the skeleton restores its base pose would report a spurious error.
	if _hand_bone >= 0:
		var hand := skeleton.global_transform * skeleton.get_bone_global_pose(_hand_bone)
		var expected: Transform3D = hand * character.get_tool_offset()
		socket_error_mm = expected.origin.distance_to(character.get_tool().global_position) * 1000.0
		if focus == 2:
			hud.refresh()


func _place_camera() -> void:
	var center: Vector3 = character.global_position + Vector3.UP * 1.0
	var offset := Vector3(4.6, 1.8, 5.1)
	if focus == 1:
		center.y = 0.45
		offset = Vector3(2.9, 2.5, 4.5)
	elif focus == 2:
		center = character.get_tool().global_position
		offset = character.global_basis * Vector3(1.35, 0.55, 2.5)
	camera.position = center + offset
	camera.look_at(center, Vector3.UP)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE: set_running(not running)
		KEY_N:
			set_running(false)
			step_tick()
		KEY_R: reset_demo()
		KEY_1, KEY_2, KEY_3: set_focus(event.keycode - KEY_1)
		_: return
	get_viewport().set_input_as_handled()
