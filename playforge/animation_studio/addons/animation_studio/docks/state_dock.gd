@tool
extends VBoxContainer
## Standard Godot Editor Dock: "AnimStudio · 상태"
## Context-aware inspector & controller dock bound to whichever
## AnimationStudioInstance is currently selected in Godot's standard 3D Viewport.
## Supports Hero Arena (10 Lua scripts + 90 docking lines), Procedural Quadruped
## Locomotor (Walk/Trot/Pace/Gallop), and all 28 internalized characters
## (Float32 vs 16-bit C++ QuantizedClip + 200-agent benchmark).

const Store := preload("res://characters/character_store.gd")

signal docking_lines_toggled(visible: bool)

var _bound_instance: Node3D = null
var _current_role: String = ""
var _syncing_ui: bool = false

var _hdr_title: Label = null
var _hdr_sub: Label = null

# Role sections
var _empty_box: VBoxContainer = null
var _hero_box: VBoxContainer = null
var _quad_box: VBoxContainer = null
var _char_box: VBoxContainer = null

# Hero controls
var _hero_auto_cb: CheckBox = null
var _hero_lines_cb: CheckBox = null
var _hero_status_lbl: Label = null
var _hero_vars_lbl: Label = null

# Quadruped controls
var _quad_auto_cb: CheckBox = null
var _quad_speed_slider: HSlider = null
var _quad_speed_lbl: Label = null
var _quad_gait_btns: Dictionary = {}
var _quad_telemetry_lbl: Label = null

# Character (28 roster) controls
var _char_opt: OptionButton = null
var _char_ids: PackedStringArray = PackedStringArray()
var _clip_opt: OptionButton = null
var _char_quant_cb: CheckBox = null
var _char_metrics_lbl: Label = null
var _char_bench_lbl: Label = null


func _init() -> void:
	name = "AnimStudio · 상태"
	custom_minimum_size = Vector2(260, 260)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	if _hdr_title != null:
		return
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 6)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	_hdr_title = Label.new()
	_hdr_title.text = "연결된 인스턴스 없음"
	_hdr_title.modulate = Color("#f6b44d")
	body.add_child(_hdr_title)

	_hdr_sub = Label.new()
	_hdr_sub.text = "3D 뷰포트나 계층 도크에서 캐릭터를 선택하세요."
	_hdr_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hdr_sub.modulate = Color("#9fb3ca")
	body.add_child(_hdr_sub)

	body.add_child(HSeparator.new())

	_empty_box = VBoxContainer.new()
	var empty_lbl := Label.new()
	empty_lbl.text = "AnimationStudioInstance 노드를 선택하면 해당 캐릭터의 상태머신·Lua 변수·보행 파라미터·16-bit C++ 비교 지표가 여기에 표시됩니다."
	empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_box.add_child(empty_lbl)
	body.add_child(_empty_box)

	_build_hero_section(body)
	_build_quad_section(body)
	_build_char_section(body)
	_update_section_visibility("")


func _build_hero_section(parent: VBoxContainer) -> void:
	_hero_box = VBoxContainer.new()
	_hero_box.add_theme_constant_override("separation", 6)
	parent.add_child(_hero_box)

	var scen_lbl := Label.new()
	scen_lbl.text = "파쿠르 · Lua 시나리오 즉시 실행"
	_hero_box.add_child(scen_lbl)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	_hero_box.add_child(grid)

	var scenarios := [
		["로코모션", "locomotion"],
		["엄폐 (Cover)", "cover"],
		["볼트 (Vault)", "vault"],
		["클라임 (Climb)", "climb"],
		["도약 (Leap)", "leap"],
		["스트레이프", "strafe"],
	]
	for s in scenarios:
		var b := Button.new()
		b.text = s[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sid: String = s[1]
		b.pressed.connect(func(): _trigger_hero_scenario(sid))
		grid.add_child(b)

	var ev_lbl := Label.new()
	ev_lbl.text = "Lua 상태머신 이벤트 발생"
	_hero_box.add_child(ev_lbl)

	var ev_grid := GridContainer.new()
	ev_grid.columns = 2
	ev_grid.add_theme_constant_override("h_separation", 4)
	ev_grid.add_theme_constant_override("v_separation", 4)
	_hero_box.add_child(ev_grid)

	for ev_name in ["JumpButton", "Action", "WeaponToggle", "Attack", "Strafe"]:
		var b := Button.new()
		b.text = ev_name
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ename: String = ev_name
		b.pressed.connect(func(): _raise_hero_event(ename))
		ev_grid.add_child(b)

	_hero_auto_cb = CheckBox.new()
	_hero_auto_cb.text = "자동 파쿠르 투어 순환 (auto_demo)"
	_hero_auto_cb.toggled.connect(func(v: bool):
		if not _syncing_ui and is_instance_valid(_bound_instance):
			_bound_instance.set("auto_demo", v)
	)
	_hero_box.add_child(_hero_auto_cb)

	_hero_lines_cb = CheckBox.new()
	_hero_lines_cb.text = "90개 도킹 라인 오버레이 표시"
	_hero_lines_cb.button_pressed = true
	_hero_lines_cb.toggled.connect(func(v: bool):
		if not _syncing_ui:
			docking_lines_toggled.emit(v)
	)
	_hero_box.add_child(_hero_lines_cb)

	_hero_box.add_child(HSeparator.new())

	_hero_status_lbl = Label.new()
	_hero_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_status_lbl.modulate = Color("#7fd6cc")
	_hero_box.add_child(_hero_status_lbl)

	_hero_vars_lbl = Label.new()
	_hero_vars_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_vars_lbl.modulate = Color("#c5d4e6")
	_hero_box.add_child(_hero_vars_lbl)


func _build_quad_section(parent: VBoxContainer) -> void:
	_quad_box = VBoxContainer.new()
	_quad_box.add_theme_constant_override("separation", 6)
	parent.add_child(_quad_box)

	var gait_lbl := Label.new()
	gait_lbl.text = "4족 Locomotor 보행 모드 (0클립 절차적 IK)"
	_quad_box.add_child(gait_lbl)

	var g_row := GridContainer.new()
	g_row.columns = 3
	g_row.add_theme_constant_override("h_separation", 4)
	g_row.add_theme_constant_override("v_separation", 4)
	_quad_box.add_child(g_row)

	for g in ["auto", "walk", "trot", "pace", "gallop"]:
		var b := Button.new()
		b.text = g.capitalize()
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var gk: String = g
		b.pressed.connect(func(): _set_quad_gait(gk))
		g_row.add_child(b)
		_quad_gait_btns[gk] = b

	_quad_speed_lbl = Label.new()
	_quad_speed_lbl.text = "목표 속도: 2.60 m/s"
	_quad_box.add_child(_quad_speed_lbl)

	_quad_speed_slider = HSlider.new()
	_quad_speed_slider.min_value = 0.0
	_quad_speed_slider.max_value = 5.5
	_quad_speed_slider.step = 0.05
	_quad_speed_slider.value = 2.6
	_quad_speed_slider.value_changed.connect(func(v: float):
		_quad_speed_lbl.text = "목표 속도: %.2f m/s" % v
		if not _syncing_ui and is_instance_valid(_bound_instance) and _bound_instance.has_method("set_quad_speed"):
			_bound_instance.call("set_quad_speed", v)
	)
	_quad_box.add_child(_quad_speed_slider)

	_quad_auto_cb = CheckBox.new()
	_quad_auto_cb.text = "제자리 순환 보행 활성 (auto_demo)"
	_quad_auto_cb.toggled.connect(func(v: bool):
		if not _syncing_ui and is_instance_valid(_bound_instance):
			_bound_instance.set("auto_demo", v)
	)
	_quad_box.add_child(_quad_auto_cb)

	_quad_box.add_child(HSeparator.new())

	_quad_telemetry_lbl = Label.new()
	_quad_telemetry_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quad_telemetry_lbl.modulate = Color("#c5d4e6")
	_quad_box.add_child(_quad_telemetry_lbl)


func _build_char_section(parent: VBoxContainer) -> void:
	_char_box = VBoxContainer.new()
	_char_box.add_theme_constant_override("separation", 6)
	parent.add_child(_char_box)

	var c_lbl := Label.new()
	c_lbl.text = "내재화 캐릭터 에셋 (28종 GLB/RES)"
	_char_box.add_child(c_lbl)

	_char_opt = OptionButton.new()
	_char_opt.clip_text = true
	_char_ids.clear()
	for e in Store.load_catalog():
		var cid := str(e.get("id", ""))
		_char_ids.append(cid)
		var clip_val = e.get("clips", [])
		var clip_cnt := (clip_val as Array).size() if clip_val is Array else int(clip_val)
		_char_opt.add_item("%s (%d본 · %d클립)" % [str(e.get("name", cid)), int(e.get("bones", 0)), clip_cnt])
	_char_opt.item_selected.connect(func(idx: int):
		if _syncing_ui or not is_instance_valid(_bound_instance) or idx < 0 or idx >= _char_ids.size():
			return
		_bound_instance.set("character_id", _char_ids[idx])
		_refresh_clip_options()
	)
	_char_box.add_child(_char_opt)

	var cl_lbl := Label.new()
	cl_lbl.text = "재생 클립 선택"
	_char_box.add_child(cl_lbl)

	_clip_opt = OptionButton.new()
	_clip_opt.clip_text = true
	_clip_opt.item_selected.connect(func(idx: int):
		if _syncing_ui or not is_instance_valid(_bound_instance) or idx < 0:
			return
		var cname := _clip_opt.get_item_text(idx)
		if _bound_instance.has_method("select_clip"):
			_bound_instance.call("select_clip", cname)
	)
	_char_box.add_child(_clip_opt)

	_char_quant_cb = CheckBox.new()
	_char_quant_cb.text = "16-bit C++ QuantizedClip 평가기 사용"
	_char_quant_cb.toggled.connect(func(v: bool):
		if not _syncing_ui and is_instance_valid(_bound_instance) and _bound_instance.has_method("set_use_quantized_16bit"):
			_bound_instance.call("set_use_quantized_16bit", v)
	)
	_char_box.add_child(_char_quant_cb)

	_char_metrics_lbl = Label.new()
	_char_metrics_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_char_metrics_lbl.modulate = Color("#7fd6cc")
	_char_box.add_child(_char_metrics_lbl)

	var bench_btn := Button.new()
	bench_btn.text = "200-에이전트 C++ 크라우드 벤치마크 실행"
	bench_btn.pressed.connect(_on_run_crowd_bench)
	_char_box.add_child(bench_btn)

	_char_bench_lbl = Label.new()
	_char_bench_lbl.text = "버튼을 눌러 200-에이전트 병렬 포즈 평가 성능을 측정하세요."
	_char_bench_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_char_bench_lbl.modulate = Color("#b8c8dc")
	_char_box.add_child(_char_bench_lbl)


func _update_section_visibility(role: String) -> void:
	_current_role = role
	_empty_box.visible = role.is_empty()
	_hero_box.visible = (role == "hero_arena")
	_quad_box.visible = (role == "quadruped")
	_char_box.visible = (role == "character")


func bind_instance(inst: Node3D) -> void:
	if _hdr_title == null:
		_build_ui()
	_bound_instance = inst
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_state_snapshot"):
		_hdr_title.text = "연결된 인스턴스 없음"
		_hdr_sub.text = "3D 뷰포트나 계층 도크에서 캐릭터를 선택하세요."
		_update_section_visibility("")
		return

	var snap: Dictionary = _bound_instance.call("get_state_snapshot")
	var role := str(snap.get("role", "character"))
	_update_section_visibility(role)
	_syncing_ui = true
	if role == "hero_arena":
		_hero_auto_cb.button_pressed = bool(snap.get("auto_demo", true))
	elif role == "quadruped":
		_quad_auto_cb.button_pressed = bool(snap.get("auto_demo", true))
		var qspd := float(snap.get("quad_speed", 2.6))
		_quad_speed_slider.value = qspd
		_quad_speed_lbl.text = "목표 속도: %.2f m/s" % qspd
		var qg := str(snap.get("quad_gait", "auto"))
		for k in _quad_gait_btns.keys():
			(_quad_gait_btns[k] as Button).set_pressed_no_signal(k == qg)
	else:
		var cid := str(snap.get("character_id", "soldier"))
		var idx := _char_ids.find(cid)
		if idx >= 0:
			_char_opt.select(idx)
		_char_quant_cb.button_pressed = bool(snap.get("use_quantized_16bit", false))
		_refresh_clip_options()
	_syncing_ui = false
	update_live()


func _refresh_clip_options() -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_clip_names"):
		return
	var prev_sync := _syncing_ui
	_syncing_ui = true
	_clip_opt.clear()
	var clips: PackedStringArray = _bound_instance.call("get_clip_names")
	var cur := str(_bound_instance.get("active_clip"))
	var cur_idx := 0
	for i in clips.size():
		_clip_opt.add_item(clips[i])
		if clips[i] == cur:
			cur_idx = i
	if _clip_opt.item_count > 0:
		_clip_opt.select(cur_idx)
	_syncing_ui = prev_sync


func update_live() -> void:
	if _hdr_title == null or not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_state_snapshot"):
		return
	var snap: Dictionary = _bound_instance.call("get_state_snapshot")
	var role := str(snap.get("role", "character"))
	if role != _current_role:
		bind_instance(_bound_instance)
		return
	var wp: Vector3 = snap.get("world_pos", Vector3.ZERO)
	_hdr_title.text = str(_bound_instance.call("get_display_title"))
	_hdr_sub.text = "위치: (%.2f, %.2f, %.2f)  |  상태: %s  |  클립: %s" % [
		wp.x, wp.y, wp.z, str(snap.get("active_state", "")), str(snap.get("active_clip", ""))
	]

	if role == "hero_arena":
		var dock: Dictionary = snap.get("dock_target", {})
		var dock_str := "#%d (type=%d)" % [int(dock.get("index", -1)), int(dock.get("line_type", -1))] if int(dock.get("index", -1)) >= 0 else "없음"
		_hero_status_lbl.text = "상태: %s  |  최근 이벤트: %s\n카메라 모드: %s  |  도킹 라인: %s" % [
			str(snap.get("active_state", "Idle")),
			str(snap.get("last_event", "-")),
			str(snap.get("cam_mode", "follow")),
			dock_str,
		]
		var vars: Dictionary = snap.get("variables", {})
		var lines := PackedStringArray()
		for k in ["CharacterSpeed", "Direction", "SwordEquipped", "CoverEdgeAngle", "VaultHeight", "ClimbHeight", "LeapDistance", "IsFalling"]:
			if vars.has(k):
				var v = vars[k]
				lines.append("• %s: %s" % [k, "%.2f" % float(v) if (v is float or v is int) else str(v)])
		_hero_vars_lbl.text = "\n".join(lines)
	elif role == "quadruped":
		var feet: Dictionary = snap.get("feet", {})
		var foot_bits := PackedStringArray()
		for leg in ["FL", "FR", "HL", "HR"]:
			var f: Dictionary = feet.get(leg, {})
			foot_bits.append("%s:%s" % [leg, "PLANTED" if bool(f.get("planted", true)) else "SWING"])
		_quad_telemetry_lbl.text = "활성 보행: %s  |  실속도: %.2f m/s\nPelvis Y: %.3fm  |  Pitch: %.1f°  |  Roll: %.1f°\n접지 발: %d/4  |  최대 슬립: %.2f mm\n%s" % [
			str(snap.get("active_state", "idle")).to_upper(),
			float(snap.get("actual_speed", 0.0)),
			float(snap.get("pelvis_y", 0.78)),
			float(snap.get("pelvis_pitch_deg", 0.0)),
			float(snap.get("pelvis_roll_deg", 0.0)),
			int(snap.get("planted_count", 4)),
			float(snap.get("foot_slip_mm", 0.0)),
			"  ".join(foot_bits),
		]
	else:
		var cmp: Dictionary = snap.get("compare", {})
		if cmp.is_empty():
			_char_metrics_lbl.text = "평가 비교 메트릭 계산 중..."
		else:
			_char_metrics_lbl.text = "평가 모드: %s\nFloat32 vs 16-bit C++ 오차:\n• Max Pos: %.3f mm  |  Max Rot: %.3f°\n• World FK: %.3f mm\n• 메모리 절감: %.1f%% (%.1f KB)" % [
				"16-bit C++ QuantizedClip" if bool(snap.get("use_quantized_16bit", false)) else "Float32 AnimationPlayer",
				float(cmp.get("max_pos_mm", 0.0)),
				float(cmp.get("max_rot_deg", 0.0)),
				float(cmp.get("max_world_mm", 0.0)),
				float(cmp.get("saving_pct", 0.0)),
				float(cmp.get("resident_kb", 0.0)),
			]


func _trigger_hero_scenario(sid: String) -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("trigger_hero_scenario"):
		return
	_bound_instance.set("auto_demo", false)
	_syncing_ui = true
	_hero_auto_cb.button_pressed = false
	_syncing_ui = false
	_bound_instance.call("trigger_hero_scenario", sid)
	update_live()


func _raise_hero_event(ename: String) -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("raise_hero_event"):
		return
	_bound_instance.set("auto_demo", false)
	_syncing_ui = true
	_hero_auto_cb.button_pressed = false
	_syncing_ui = false
	_bound_instance.call("raise_hero_event", ename)
	update_live()


func _set_quad_gait(gk: String) -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("set_quad_gait"):
		return
	_bound_instance.call("set_quad_gait", gk)
	for k in _quad_gait_btns.keys():
		(_quad_gait_btns[k] as Button).set_pressed_no_signal(k == gk)
	update_live()


func _on_run_crowd_bench() -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("run_crowd_benchmark_200"):
		return
	var res: Dictionary = _bound_instance.call("run_crowd_benchmark_200")
	if res.is_empty():
		_char_bench_lbl.text = "벤치마크 실행 불가 (클립 없음)"
		return
	_char_bench_lbl.text = "200 Agents × %d bones/tick -> %.3f ms/tick (%s)" % [
		int(res.get("bones_per_tick", 0)),
		float(res.get("ms", 0.0)),
		"C++ Native" if bool(res.get("native", false)) else "GDScript Fallback",
	]
