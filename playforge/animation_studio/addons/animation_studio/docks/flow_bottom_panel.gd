@tool
extends VBoxContainer
## Standard Godot Editor Bottom Panel: "Animation Flow"
## Hosts the interactive Bezier Animation Flow Graph + clip timeline scrubber &
## transport bar, synchronized to whichever AnimationStudioInstance is selected
## in Godot's standard 3D Viewport.

const FlowCanvasScript := preload("res://addons/animation_studio/docks/flow_graph_canvas.gd")

var _bound_instance: Node3D = null
var _syncing_slider: bool = false

var _inst_badge: Label = null
var _btn_play: Button = null
var _speed_opt: OptionButton = null
var _scrubber: HSlider = null
var _time_lbl: Label = null
var _canvas: Control = null


func _init() -> void:
	name = "Animation Flow"
	custom_minimum_size = Vector2(360, 210)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	if _canvas != null:
		return
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 4)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)

	_inst_badge = Label.new()
	_inst_badge.text = "연결 인스턴스: 없음"
	_inst_badge.modulate = Color("#f6b44d")
	bar.add_child(_inst_badge)

	_btn_play = Button.new()
	_btn_play.text = "일시정지"
	_btn_play.pressed.connect(_on_toggle_play)
	bar.add_child(_btn_play)

	var btn_step := Button.new()
	btn_step.text = "+1/60s"
	btn_step.tooltip_text = "선택한 3D 캐릭터 인스턴스를 1프레임(1/60초) 진행합니다."
	btn_step.pressed.connect(_on_step_once)
	bar.add_child(btn_step)

	_speed_opt = OptionButton.new()
	for sp in ["0.25x", "0.5x", "1.0x", "1.5x", "2.0x"]:
		_speed_opt.add_item(sp)
	_speed_opt.select(2)
	_speed_opt.item_selected.connect(_on_speed_selected)
	bar.add_child(_speed_opt)

	_scrubber = HSlider.new()
	_scrubber.min_value = 0.0
	_scrubber.max_value = 1.0
	_scrubber.step = 0.005
	_scrubber.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrubber.value_changed.connect(_on_scrub_changed)
	bar.add_child(_scrubber)

	_time_lbl = Label.new()
	_time_lbl.text = "0.00 / 1.00s"
	_time_lbl.custom_minimum_size = Vector2(120, 0)
	_time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_time_lbl)

	_canvas = FlowCanvasScript.new()
	_canvas.node_clicked.connect(_on_flow_node_clicked)
	add_child(_canvas)


func bind_instance(inst: Node3D) -> void:
	if _canvas == null:
		_build_ui()
	_bound_instance = inst
	update_live()


func update_live() -> void:
	if _canvas == null:
		return
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_state_snapshot"):
		_inst_badge.text = "연결 인스턴스: 없음 (3D 뷰포트에서 캐릭터 선택)"
		_btn_play.text = "재생"
		_canvas.call("set_flow_state", "hero_arena", "", "노드를 클릭해 3D 뷰포트 캐릭터 상태를 전환할 수 있습니다.")
		return

	var snap: Dictionary = _bound_instance.call("get_state_snapshot")
	var role := str(snap.get("role", "character"))
	var playing := bool(snap.get("playing", true))
	var active_state := str(snap.get("active_state", ""))
	var clip := str(snap.get("active_clip", ""))
	var pt := float(snap.get("play_time", 0.0))
	var dur := maxf(0.05, float(snap.get("duration", 1.0)))

	_inst_badge.text = "연결: %s (%s)" % [_bound_instance.name, role]
	_btn_play.text = "일시정지" if playing else "재생"
	_syncing_slider = true
	_scrubber.max_value = dur
	_scrubber.value = clampf(pt, 0.0, dur)
	_syncing_slider = false
	_time_lbl.text = "%.2f / %.2fs · %s" % [pt, dur, clip]

	var hint := "노드 클릭으로 3D 뷰포트 캐릭터 전환"
	if role == "hero_arena":
		hint = "Hero Lua Flow · 상태=%s · 클립=%s (노드 클릭으로 시나리오 즉시 전환)" % [active_state, clip]
	elif role == "quadruped":
		hint = "Procedural Locomotor · 보행=%s · 접지=%d/4 · 슬립=%.2fmm (보행 노드 클릭으로 전환)" % [
			active_state.to_upper(), int(snap.get("planted_count", 4)), float(snap.get("foot_slip_mm", 0.0))
		]
	else:
		hint = "Native .res Pipeline · 모드=%s · 클립=%s (Float32 / 16-bit C++ 노드 클릭 전환)" % [active_state, clip]
	_canvas.call("set_flow_state", role, active_state, hint)


func _on_toggle_play() -> void:
	if not is_instance_valid(_bound_instance):
		return
	var cur := bool(_bound_instance.get("playing"))
	_bound_instance.set("playing", not cur)
	update_live()


func _on_step_once() -> void:
	if not is_instance_valid(_bound_instance):
		return
	_bound_instance.set("playing", false)
	if _bound_instance.has_method("step_once"):
		_bound_instance.call("step_once", 1.0 / 60.0)
	update_live()


func _on_speed_selected(idx: int) -> void:
	if not is_instance_valid(_bound_instance):
		return
	var vals := [0.25, 0.5, 1.0, 1.5, 2.0]
	if idx >= 0 and idx < vals.size():
		_bound_instance.set("playback_speed", vals[idx])


func _on_scrub_changed(val: float) -> void:
	if _syncing_slider or not is_instance_valid(_bound_instance):
		return
	_bound_instance.set("playing", false)
	if _bound_instance.has_method("seek_time"):
		_bound_instance.call("seek_time", val)
	update_live()


func _on_flow_node_clicked(node_id: String) -> void:
	if not is_instance_valid(_bound_instance):
		return
	var role := str(_bound_instance.get("role"))
	if role == "hero_arena":
		_bound_instance.set("auto_demo", false)
		match node_id:
			"Idle", "Run":
				_bound_instance.call("trigger_hero_scenario", "locomotion")
			"Strafe":
				_bound_instance.call("trigger_hero_scenario", "strafe")
			"Attack":
				_bound_instance.call("raise_hero_event", "Attack")
			"Cover":
				_bound_instance.call("trigger_hero_scenario", "cover")
			"Jump":
				_bound_instance.call("raise_hero_event", "JumpButton")
			"Vault":
				_bound_instance.call("trigger_hero_scenario", "vault")
			"Hanging", "ClimbUp":
				_bound_instance.call("trigger_hero_scenario", "climb")
			"Leap":
				_bound_instance.call("trigger_hero_scenario", "leap")
	elif role == "quadruped":
		if node_id in ["walk", "trot", "pace", "gallop"]:
			_bound_instance.call("set_quad_gait", node_id)
			_bound_instance.set("auto_demo", true)
	else:
		if node_id == "float32":
			_bound_instance.call("set_use_quantized_16bit", false)
		elif node_id == "quant16":
			_bound_instance.call("set_use_quantized_16bit", true)
	update_live()
