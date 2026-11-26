extends Node3D
## Interactive stage-2 demo: upper-body masked attack slot during movement,
## quintic inertialization with single-clip base evaluation, live graph
## highlight, and skeleton_updated Rewind scrubbing.

const PoseBuffer = preload("res://addons/animation_studio/pose_buffer.gd")
const PoseGraph = preload("res://addons/animation_studio/pose_graph.gd")
const PoseGraphModifier = preload("res://addons/animation_studio/pose_graph_modifier.gd")
const RewindRecorder = preload("res://addons/animation_studio/rewind_recorder.gd")
const GraphCanvas = preload("res://demo/graph_canvas.gd")

const TICK := 1.0 / 60.0
const REWIND_CAPACITY := 300

@onready var character = $Character
@onready var skeleton: Skeleton3D = $Character/Rig
@onready var camera: Camera3D = $Camera3D

var graph := PoseGraph.new()
var graph_modifier: PoseGraphModifier
var recorder := RewindRecorder.new(REWIND_CAPACITY)
var upper_mask: PackedFloat32Array = PackedFloat32Array()
var idle_anim: Animation
var move_anim: Animation
var attack_anim: Animation

var running := true
var scrubbing := false
var tick_index := 0

var _graph_canvas: GraphCanvas
var _status_label: Label
var _rewind_slider: HSlider
var _rewind_label: Label
var _state_btn: Button
var _play_btn: Button


func _ready() -> void:
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	character.pose.active = false
	character.player.active = false

	upper_mask = PoseBuffer.build_branch_mask(skeleton, &"Spine")
	idle_anim = _build_idle_animation()
	move_anim = character.player.get_animation(&"stride").duplicate(true)
	attack_anim = _build_attack_animation()

	graph.configure(&"Root")
	graph.add_state(&"idle", idle_anim, true)
	graph.add_state(&"move", move_anim, true)

	graph_modifier = PoseGraphModifier.new()
	graph_modifier.name = "GraphPose"
	graph_modifier.graph = graph
	skeleton.add_child(graph_modifier)
	skeleton.move_child(graph_modifier, 0)
	recorder.attach(skeleton, character)

	_build_ui()
	reset_demo()


func _exit_tree() -> void:
	recorder.detach()


func reset_demo() -> void:
	running = true
	scrubbing = false
	tick_index = 0
	character.transform = Transform3D.IDENTITY
	skeleton.reset_bone_poses()
	recorder.clear()
	graph.reset(&"move")
	_refresh_ui()


func toggle_state() -> void:
	var next_state := &"idle" if graph.get_current_state() == &"move" else &"move"
	graph.transition_to(next_state, 0.20)
	_refresh_ui()


func trigger_attack() -> void:
	graph.play_slot(&"attack", attack_anim, upper_mask, 0.08, 0.12)
	_refresh_ui()


func cancel_attack() -> void:
	graph.cancel_slot(0.08)
	_refresh_ui()


func set_running(value: bool) -> void:
	running = value
	if running:
		scrubbing = false
	_refresh_ui()


func queue_step() -> void:
	scrubbing = false
	if graph.get_current_state() == &"move":
		character.global_position += character.global_basis * Vector3(1.2 * TICK, 0.0, 0.0)
	recorder.queue_metadata({"tick": tick_index})
	skeleton.advance(TICK)
	tick_index += 1


func step_tick_await() -> Dictionary:
	var before_recorded := recorder.get_total_recorded()
	queue_step()
	while recorder.get_total_recorded() == before_recorded:
		await get_tree().process_frame
	var snap: Dictionary = graph.last_snapshot
	snap["tick"] = tick_index - 1
	if recorder.get_frame_count() > 0:
		var latest := recorder.get_frame(recorder.get_frame_count() - 1)
		if not latest.is_empty():
			latest["meta"] = snap.duplicate(true)
	_update_camera()
	_refresh_ui()
	return snap


func step_tick() -> void:
	queue_step()
	_update_camera()
	_refresh_ui()


func scrub_to(index: int) -> Dictionary:
	running = false
	scrubbing = true
	var frame := recorder.apply_frame(index, skeleton, character)
	_update_camera()
	if not frame.is_empty():
		var meta: Dictionary = frame.get("meta", {})
		if _graph_canvas:
			_graph_canvas.set_snapshot(meta)
		_refresh_ui(meta, index)
	return frame


func _physics_process(_delta: float) -> void:
	if running and not scrubbing:
		step_tick()


func _update_camera() -> void:
	if camera == null or character == null:
		return
	var target: Vector3 = character.global_position + Vector3(0.0, 1.0, 0.0)
	camera.position = target + Vector3(2.4, 0.7, 3.4)
	camera.look_at(target)


func _build_idle_animation() -> Animation:
	var anim := Animation.new()
	anim.resource_name = "Courier idle"
	anim.length = 1.6
	anim.step = TICK
	anim.loop_mode = Animation.LOOP_LINEAR
	_add_rot_keys(anim, ^"Rig:Spine", Vector3.RIGHT, [0.0, 0.4, 0.8, 1.2, 1.6], [0.0, 0.05, 0.0, -0.04, 0.0])
	_add_rot_keys(anim, ^"Rig:ShoulderLeft", Vector3.FORWARD, [0.0, 0.8, 1.6], [0.08, 0.14, 0.08])
	_add_rot_keys(anim, ^"Rig:ShoulderRight", Vector3.FORWARD, [0.0, 0.8, 1.6], [-0.08, -0.14, -0.08])
	_add_rot_keys(anim, ^"Rig:HipLeft", Vector3.FORWARD, [0.0, 1.6], [0.0, 0.0])
	_add_rot_keys(anim, ^"Rig:HipRight", Vector3.FORWARD, [0.0, 1.6], [0.0, 0.0])
	return anim


func _build_attack_animation() -> Animation:
	var anim := Animation.new()
	anim.resource_name = "Upper-body slash"
	anim.length = 0.55
	anim.step = TICK
	anim.loop_mode = Animation.LOOP_NONE
	_add_rot_keys(anim, ^"Rig:Spine", Vector3.UP, [0.0, 0.15, 0.35, 0.55], [0.0, -0.45, 0.55, 0.0])
	_add_rot_keys(anim, ^"Rig:ShoulderRight", Vector3.FORWARD, [0.0, 0.15, 0.32, 0.55], [0.0, -1.25, 1.15, 0.0])
	_add_rot_keys(anim, ^"Rig:Hand.R", Vector3.RIGHT, [0.0, 0.15, 0.32, 0.55], [0.0, -0.65, 0.75, 0.0])
	_add_rot_keys(anim, ^"Rig:ShoulderLeft", Vector3.FORWARD, [0.0, 0.25, 0.55], [0.0, 0.45, 0.0])
	return anim


static func _add_rot_keys(anim: Animation, path: NodePath, axis: Vector3, times: Array[float], angles: Array[float]) -> void:
	var track := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track, path)
	for i in times.size():
		anim.rotation_track_insert_key(track, times[i], Quaternion(axis, angles[i]))


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root_ctrl)

	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR"])
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 15
	root_ctrl.theme = theme

	var panel := PanelContainer.new()
	panel.position = Vector2(20, 68 if Engine.has_singleton("PlayForgePlatform") else 20)
	root_ctrl.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var back := Button.new()
	back.text = "← 돌아가기"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/animation_lab.tscn"))
	header.add_child(back)
	var title := Label.new()
	title.text = "  Graph · Inertialize · Upper-Body Slot · Rewind"
	header.add_child(title)

	_graph_canvas = GraphCanvas.new()
	_graph_canvas.custom_minimum_size = Vector2(424, 170)
	vbox.add_child(_graph_canvas)

	_status_label = Label.new()
	vbox.add_child(_status_label)

	var actions := HBoxContainer.new()
	vbox.add_child(actions)
	_state_btn = Button.new()
	_state_btn.text = "Idle ↔ Move (관성 전환)"
	_state_btn.pressed.connect(toggle_state)
	actions.add_child(_state_btn)

	var atk_btn := Button.new()
	atk_btn.text = "상체 공격 (Slot)"
	atk_btn.pressed.connect(trigger_attack)
	actions.add_child(atk_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "공격 취소"
	cancel_btn.pressed.connect(cancel_attack)
	actions.add_child(cancel_btn)

	var playback := HBoxContainer.new()
	vbox.add_child(playback)
	_play_btn = Button.new()
	_play_btn.text = "일시정지"
	_play_btn.pressed.connect(func(): set_running(not running))
	playback.add_child(_play_btn)

	var step_btn := Button.new()
	step_btn.text = "+1 틱"
	step_btn.pressed.connect(func(): set_running(false); step_tick())
	playback.add_child(step_btn)

	var reset_btn := Button.new()
	reset_btn.text = "초기화"
	reset_btn.pressed.connect(reset_demo)
	playback.add_child(reset_btn)

	_rewind_label = Label.new()
	_rewind_label.text = "Rewind: 0 / 0"
	vbox.add_child(_rewind_label)

	_rewind_slider = HSlider.new()
	_rewind_slider.min_value = 0
	_rewind_slider.max_value = 0
	_rewind_slider.step = 1
	_rewind_slider.value_changed.connect(func(v: float): scrub_to(int(v)))
	vbox.add_child(_rewind_slider)


func _refresh_ui(override_meta: Dictionary = {}, scrub_index: int = -1) -> void:
	if _status_label == null:
		return
	var meta := override_meta if not override_meta.is_empty() else graph.last_snapshot
	if _graph_canvas:
		_graph_canvas.set_snapshot(meta)
	_play_btn.text = "일시정지" if running else "재생"
	_status_label.text = "상태: %s · 관성: %.2fs · 슬롯: %s (%.0f%%) · 평가 클립: %d" % [
		meta.get("state", "-"),
		float(meta.get("inertial_remaining", 0.0)),
		meta.get("slot_name", "-") if float(meta.get("slot_weight", 0.0)) > 0.001 else "없음",
		float(meta.get("slot_weight", 0.0)) * 100.0,
		int(meta.get("total_clips_evaluated", 0)),
	]
	var count := recorder.get_frame_count()
	_rewind_slider.max_value = maxi(0, count - 1)
	var shown := scrub_index if scrub_index >= 0 else maxi(0, count - 1)
	_rewind_slider.set_value_no_signal(shown)
	_rewind_label.text = "Rewind 버퍼: %d / %d (누적 %d틱)%s" % [
		shown, maxi(0, count - 1), recorder.get_total_recorded(),
		" · 되감기 중" if scrubbing else ""
	]
