@tool
extends HBoxContainer
## PlayForge Motion Studio v3 — Behaviour Event Timeline & Frame Trace Panel
## Inspired by Endorphin Behaviour Event Board (PlayForge_NaturalMotion_Events_20261127.jpg).
## Left: Interactive 3-track timeline canvas (Behaviour / Balance, External Force,
##       Behaviour / Action) with 0–180f ruler, live playhead, clickable event bars,
##       and Frame Trace commit strip (sourceCommitId / sourceRevision).
## Right: Inline Event Property Editor committing edits via MotionCommands.

const StudioTheme := preload("res://addons/animation_studio/ui/studio_theme.gd")

signal authoring_changed()

var _bound_instance: Node3D = null
var _selected_event_id: String = "push"
var _playhead_frame: int = 24
var _syncing: bool = false

var _track_canvas: Control = null
var _trace_lbl: Label = null
var _ev_title_lbl: Label = null
var _spin_start: SpinBox = null
var _spin_end: SpinBox = null
var _str_slider: HSlider = null
var _str_lbl: Label = null
var _enabled_cb: CheckBox = null
var _btn_apply: Button = null


class _EventTrackCanvas extends Control:
	signal event_clicked(event_id: String)

	var events: Array = []
	var selected_id: String = "push"
	var playhead_frame: int = 24
	var reviewing: bool = false
	var _event_rects: Dictionary = {}

	func _init() -> void:
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		custom_minimum_size = Vector2(300, 120)
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				for eid in _event_rects.keys():
					if (_event_rects[eid] as Rect2).has_point(mb.position):
						event_clicked.emit(str(eid))
						accept_event()
						return

	func _draw() -> void:
		var sz := size
		if sz.x < 60.0 or sz.y < 50.0:
			return
		draw_rect(Rect2(Vector2.ZERO, sz), StudioTheme.BG_CANVAS, true)

		var left_w := 124.0
		var ruler_h := 22.0
		var timeline_w := maxf(40.0, sz.x - left_w - 10.0)
		var tracks := ["Behaviour / Balance", "External Force", "Behaviour / Action"]
		var row_h := maxf(24.0, (sz.y - ruler_h - 6.0) / float(tracks.size()))
		var font := get_theme_default_font()

		# Header ruler background
		draw_rect(Rect2(0.0, 0.0, sz.x, ruler_h), StudioTheme.BG_TOPBAR, true)
		draw_line(Vector2(0.0, ruler_h), Vector2(sz.x, ruler_h), StudioTheme.BORDER_BASE, 1.0)
		draw_line(Vector2(left_w, 0.0), Vector2(left_w, sz.y), StudioTheme.BORDER_BASE, 1.0)

		for f in range(0, 181, 30):
			var fx := left_w + (float(f) / 180.0) * timeline_w
			draw_line(Vector2(fx, ruler_h), Vector2(fx, sz.y), Color(1, 1, 1, 0.05), 1.0)
			if font != null:
				draw_string(font, Vector2(fx + 2.0, 14.0), "%df" % f, HORIZONTAL_ALIGNMENT_LEFT, 36.0, 9, StudioTheme.TEXT_DIM)

		# Track lanes
		for ti in tracks.size():
			var ty := ruler_h + float(ti) * row_h
			if ti % 2 == 1:
				draw_rect(Rect2(0.0, ty, sz.x, row_h), Color(1, 1, 1, 0.02), true)
			draw_line(Vector2(0.0, ty + row_h), Vector2(sz.x, ty + row_h), Color(1, 1, 1, 0.05), 1.0)
			if font != null:
				var dot_col := StudioTheme.ACCENT_TEAL if ti == 0 else (StudioTheme.ACCENT_AMBER if ti == 1 else StudioTheme.SEMANTIC_VIOLET)
				draw_circle(Vector2(10.0, ty + row_h * 0.5), 3.0, dot_col)
				draw_string(font, Vector2(18.0, ty + row_h * 0.5 + 4.0), tracks[ti], HORIZONTAL_ALIGNMENT_LEFT, left_w - 22.0, 10, StudioTheme.TEXT_MUTED)

		# Event bars
		_event_rects.clear()
		for raw_ev in events:
			if not (raw_ev is Dictionary):
				continue
			var ev: Dictionary = raw_ev as Dictionary
			var eid := str(ev.get("id", ""))
			var track_name := str(ev.get("track", "Behaviour / Action"))
			var ti := tracks.find(track_name)
			if ti < 0:
				ti = 2
			var st := clampi(int(ev.get("start", 0)), 0, 179)
			var en := clampi(int(ev.get("end", st + 10)), st + 1, 180)
			var enabled := bool(ev.get("enabled", true))
			var x0 := left_w + (float(st) / 180.0) * timeline_w
			var x1 := left_w + (float(en) / 180.0) * timeline_w
			var ty := ruler_h + float(ti) * row_h + 4.0
			var bh := maxf(16.0, row_h - 8.0)
			var rect := Rect2(x0, ty, maxf(18.0, x1 - x0), bh)
			_event_rects[eid] = rect

			var base_col := StudioTheme.ACCENT_TEAL if ti == 0 else (StudioTheme.ACCENT_AMBER if ti == 1 else StudioTheme.SEMANTIC_VIOLET)
			var is_sel := (eid == selected_id)
			var fill := Color(base_col.r, base_col.g, base_col.b, 0.28 if enabled else 0.08)
			if is_sel:
				fill = Color(base_col.r, base_col.g, base_col.b, 0.42 if enabled else 0.14)
			draw_rect(rect, fill, true)
			draw_rect(rect, StudioTheme.ACCENT_AMBER if is_sel else base_col, false, 2.0 if is_sel else 1.2)
			if font != null:
				var lbl_txt := "%s (%d–%df · %.2f)%s" % [
					str(ev.get("label", eid)), st, en, float(ev.get("strength", 0.5)),
					"" if enabled else " [OFF]"
				]
				draw_string(font, Vector2(rect.position.x + 6.0, rect.position.y + bh * 0.5 + 4.0), lbl_txt, HORIZONTAL_ALIGNMENT_LEFT, maxf(10.0, rect.size.x - 10.0), 10, StudioTheme.TEXT_PRIMARY if enabled else StudioTheme.TEXT_DIM)

		# Playhead needle
		var px := left_w + (float(clampi(playhead_frame, 0, 180)) / 180.0) * timeline_w
		draw_line(Vector2(px, 0.0), Vector2(px, sz.y), StudioTheme.ACCENT_AMBER, 1.8)
		var tri := PackedVector2Array([Vector2(px - 5.0, 0.0), Vector2(px + 5.0, 0.0), Vector2(px, 8.0)])
		draw_colored_polygon(tri, StudioTheme.ACCENT_AMBER)

		if reviewing and font != null:
			draw_string(font, Vector2(left_w + 8.0, sz.y - 6.0), "REVIEW / READ ONLY 스냅샷 표시 중", HORIZONTAL_ALIGNMENT_LEFT, timeline_w - 16.0, 10, StudioTheme.ACCENT_AMBER_TEXT)


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)


func _ready() -> void:
	if _track_canvas != null:
		return
	_build_ui()


func _build_ui() -> void:
	# Left column: multi-track canvas + frame trace footer
	var left_vb := VBoxContainer.new()
	left_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vb.add_theme_constant_override("separation", 4)
	add_child(left_vb)

	_track_canvas = _EventTrackCanvas.new()
	_track_canvas.connect("event_clicked", _on_event_clicked)
	left_vb.add_child(_track_canvas)

	_trace_lbl = Label.new()
	_trace_lbl.text = "Frame Trace: sourceCommitId=c000 · sourceRevision=r0 (Undo/Redo와 분리된 시뮬레이션 프레임 기록)"
	_trace_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	_trace_lbl.add_theme_font_size_override("font_size", 10)
	left_vb.add_child(_trace_lbl)

	# Right column: compact Event Property Inspector card
	var prop_card := PanelContainer.new()
	prop_card.custom_minimum_size = Vector2(236, 0)
	StudioTheme.style_section_card(prop_card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_CARD)
	add_child(prop_card)

	var pvb := VBoxContainer.new()
	pvb.add_theme_constant_override("separation", 5)
	prop_card.add_child(pvb)

	_ev_title_lbl = Label.new()
	_ev_title_lbl.text = "이벤트 속성 · Push"
	_ev_title_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_AMBER_TEXT)
	_ev_title_lbl.add_theme_font_size_override("font_size", 12)
	pvb.add_child(_ev_title_lbl)

	var rng_row := HBoxContainer.new()
	rng_row.add_theme_constant_override("separation", 4)
	pvb.add_child(rng_row)

	_spin_start = SpinBox.new()
	_spin_start.prefix = "시작 "
	_spin_start.suffix = "f"
	_spin_start.min_value = 0
	_spin_start.max_value = 179
	_spin_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rng_row.add_child(_spin_start)

	_spin_end = SpinBox.new()
	_spin_end.prefix = "종료 "
	_spin_end.suffix = "f"
	_spin_end.min_value = 1
	_spin_end.max_value = 180
	_spin_end.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rng_row.add_child(_spin_end)

	_str_lbl = Label.new()
	_str_lbl.text = "Strength: 0.55"
	_str_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_SECONDARY)
	_str_lbl.add_theme_font_size_override("font_size", 11)
	pvb.add_child(_str_lbl)

	_str_slider = HSlider.new()
	_str_slider.min_value = 0.0
	_str_slider.max_value = 1.0
	_str_slider.step = 0.01
	_str_slider.value = 0.55
	_str_slider.value_changed.connect(func(v: float):
		_str_lbl.text = "Strength: %.2f" % v
	)
	pvb.add_child(_str_slider)

	_enabled_cb = CheckBox.new()
	_enabled_cb.text = "이벤트 활성 (재생 구간에 적용)"
	_enabled_cb.button_pressed = true
	pvb.add_child(_enabled_cb)

	_btn_apply = Button.new()
	_btn_apply.text = "이벤트 변경 커밋 (MotionCommands)"
	StudioTheme.style_button(_btn_apply, "teal")
	_btn_apply.pressed.connect(_on_apply_event_edit)
	pvb.add_child(_btn_apply)


func bind_instance(inst: Node3D) -> void:
	if _track_canvas == null:
		_build_ui()
	_bound_instance = inst
	refresh_view()


func _on_event_clicked(eid: String) -> void:
	_selected_event_id = eid
	refresh_view()


func _on_apply_event_edit() -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_motion_authoring"):
		return
	var auth: RefCounted = _bound_instance.call("get_motion_authoring")
	var st_f := int(_spin_start.value)
	var en_f := maxi(st_f + 1, int(_spin_end.value))
	var cmds := [
		{"op": "set_event_range", "event_id": _selected_event_id, "start": st_f, "end": en_f},
		{"op": "set_event_strength", "event_id": _selected_event_id, "value": _str_slider.value},
		{"op": "set_event_enabled", "event_id": _selected_event_id, "enabled": _enabled_cb.button_pressed},
	]
	auth.call("apply_user_commands", cmds, "이벤트 편집 · %s (%d–%df)" % [_selected_event_id, st_f, en_f])
	refresh_view()
	authoring_changed.emit()


func refresh_view() -> void:
	if _track_canvas == null:
		return
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_motion_authoring"):
		return
	var auth: RefCounted = _bound_instance.call("get_motion_authoring")
	var st: Dictionary = auth.call("motion_read_state")
	var doc: Dictionary = st.get("selected_document", {}) as Dictionary
	var evs: Array = doc.get("events", []) as Array
	var snap: Dictionary = _bound_instance.call("get_state_snapshot")
	var dur := maxf(0.05, float(snap.get("duration", 1.0)))
	var pt := float(snap.get("play_time", 0.0))
	_playhead_frame = clampi(int((pt / dur) * 180.0), 0, 180)

	_track_canvas.set("events", evs)
	_track_canvas.set("selected_id", _selected_event_id)
	_track_canvas.set("playhead_frame", _playhead_frame)
	_track_canvas.set("reviewing", bool(st.get("reviewing", false)))
	_track_canvas.queue_redraw()

	_btn_apply.disabled = bool(st.get("reviewing", false))
	var trace_arr: Array = auth.get("frame_trace") as Array
	if not trace_arr.is_empty():
		var last_t: Dictionary = trace_arr[trace_arr.size() - 1] as Dictionary
		var active_evs: Array = last_t.get("activeEvents", []) as Array
		_trace_lbl.text = "Frame Trace: F%03d · 상태=%s · 활성=%s · sourceCommitId=%s · sourceRevision=r%d" % [
			int(last_t.get("frame", 0)),
			str(last_t.get("state", "")),
			", ".join(active_evs) if not active_evs.is_empty() else "없음",
			str(last_t.get("sourceCommitId", "c000")),
			int(last_t.get("sourceRevision", 0)),
		]

	# Populate selected event inspector (only when not actively editing spinboxes)
	for raw_ev in evs:
		var ev: Dictionary = raw_ev as Dictionary
		if str(ev.get("id", "")) == _selected_event_id:
			_ev_title_lbl.text = "이벤트 속성 · %s (%s)" % [str(ev.get("label", _selected_event_id)), str(ev.get("track", ""))]
			if not _spin_start.has_focus() and not _spin_end.has_focus():
				_syncing = true
				_spin_start.value = int(ev.get("start", 0))
				_spin_end.value = int(ev.get("end", 10))
				_str_slider.value = float(ev.get("strength", 0.5))
				_str_lbl.text = "Strength: %.2f" % _str_slider.value
				_enabled_cb.button_pressed = bool(ev.get("enabled", true))
				_syncing = false
			break
