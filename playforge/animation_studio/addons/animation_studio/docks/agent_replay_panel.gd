@tool
extends VBoxContainer
## PlayForge Motion Studio v3 — Agent Replay, Review & Branching Journal Panel
## Faithful Godot Dock implementation of PlayForge_Agent_Review_20261127.jpg and
## PlayForge_Agent_Branch_20261127.jpg:
##   - Top Status Banner: LIVE WORKSPACE (teal) vs REVIEW / READ ONLY (amber)
##   - Branch Switcher, Transaction Undo/Redo, Return-to-Live, Session JSON Export/Import
##   - Left Column: 4-Step Agent Scenario Checklist (Run 1 Step / Run All / Revalidate / Write Access)
##   - Center Column: Immutable Operation Journal History + Non-Destructive Replay Scrubber
##   - Right Column: Diff Inspector + Inline Mid-Step Edit Preview + Replace Step & New Branch (b001)

const StudioTheme := preload("res://addons/animation_studio/ui/studio_theme.gd")
const MotionCommandsScript := preload("res://addons/animation_studio/authoring/motion_commands.gd")

signal authoring_changed()

var _bound_instance: Node3D = null
var _syncing: bool = false
var _last_saved_json: String = ""
var _preview_lines_text: String = ""

# Top status & branch controls
var _mode_pill: Label = null
var _status_lbl: Label = null
var _branch_opt: OptionButton = null
var _branch_ids: PackedStringArray = PackedStringArray()
var _btn_undo: Button = null
var _btn_redo: Button = null
var _btn_return_live: Button = null
var _btn_export_json: Button = null
var _btn_restore_json: Button = null

# Left column: 4-step Agent Task checklist
var _step_labels: Array[Label] = []
var _btn_step_one: Button = null
var _btn_step_all: Button = null
var _btn_revalidate: Button = null
var _write_access_cb: CheckBox = null

# Center column: Work History & Replay Scrubber
var _summary_bar_lbl: Label = null
var _history_list: ItemList = null
var _history_commit_ids: PackedStringArray = PackedStringArray()
var _replay_slider: HSlider = null
var _replay_idx_lbl: Label = null

# Right column: Inspect & Mid-Step Branch Edit
var _inspect_title_lbl: Label = null
var _diff_lbl: Label = null
var _edit_field_a_lbl: Label = null
var _edit_spin_a: SpinBox = null
var _edit_field_b_lbl: Label = null
var _edit_spin_b: SpinBox = null
var _edit_field_c_lbl: Label = null
var _edit_spin_c: SpinBox = null
var _btn_preview: Button = null
var _btn_replace_branch: Button = null
var _btn_fork_here: Button = null


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 5)


func _ready() -> void:
	if _mode_pill != null:
		return
	_build_ui()


func _build_ui() -> void:
	# --- Top Status & Branch Bar ---
	var top_card := PanelContainer.new()
	StudioTheme.style_section_card(top_card, StudioTheme.BORDER_NODE, StudioTheme.BG_TOPBAR)
	add_child(top_card)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 6)
	top_card.add_child(top_row)

	_mode_pill = Label.new()
	_mode_pill.text = "LIVE WORKSPACE"
	StudioTheme.style_pill_label(_mode_pill, StudioTheme.ACCENT_TEAL_DIM, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_TEXT)
	top_row.add_child(_mode_pill)

	_status_lbl = Label.new()
	_status_lbl.text = "작업 c000 · b000 · r0"
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_SECONDARY)
	_status_lbl.add_theme_font_size_override("font_size", 11)
	top_row.add_child(_status_lbl)

	_btn_undo = Button.new()
	_btn_undo.text = "↶ Undo"
	StudioTheme.style_button(_btn_undo, "default")
	_btn_undo.pressed.connect(_on_undo)
	top_row.add_child(_btn_undo)

	_btn_redo = Button.new()
	_btn_redo.text = "↷ Redo"
	StudioTheme.style_button(_btn_redo, "default")
	_btn_redo.pressed.connect(_on_redo)
	top_row.add_child(_btn_redo)

	_branch_opt = OptionButton.new()
	_branch_opt.custom_minimum_size = Vector2(140, 0)
	_branch_opt.item_selected.connect(_on_branch_selected)
	top_row.add_child(_branch_opt)

	_btn_return_live = Button.new()
	_btn_return_live.text = "현재 작업 복귀"
	StudioTheme.style_button(_btn_return_live, "amber")
	_btn_return_live.pressed.connect(_on_return_live)
	top_row.add_child(_btn_return_live)

	_btn_export_json = Button.new()
	_btn_export_json.text = "JSON 저장"
	_btn_export_json.tooltip_text = "현재 저널 세션(커밋·분기·receipt)을 메모리에 스냅샷 저장합니다."
	StudioTheme.style_button(_btn_export_json, "default")
	_btn_export_json.pressed.connect(_on_export_json)
	top_row.add_child(_btn_export_json)

	_btn_restore_json = Button.new()
	_btn_restore_json.text = "JSON 복원"
	_btn_restore_json.tooltip_text = "저장한 저널 세션 JSON을 체크섬·트리 검증 후 복원합니다."
	StudioTheme.style_button(_btn_restore_json, "default")
	_btn_restore_json.pressed.connect(_on_restore_json)
	top_row.add_child(_btn_restore_json)

	# --- 3-Column Body ---
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 6)
	add_child(cols)

	# Column 1: AGENT TASK (4-Step Scenario)
	var col_left := PanelContainer.new()
	col_left.custom_minimum_size = Vector2(210, 0)
	StudioTheme.style_section_card(col_left, StudioTheme.BORDER_BASE, StudioTheme.SURFACE_CARD)
	cols.add_child(col_left)

	var lvb := VBoxContainer.new()
	lvb.add_theme_constant_override("separation", 4)
	col_left.add_child(lvb)

	lvb.add_child(StudioTheme.make_section_header("AGENT TASK · 4단계 시나리오", "ai-path", StudioTheme.ACCENT_TEAL_TEXT))

	_step_labels.clear()
	for s in MotionCommandsScript.AGENT_SCENARIO_STEPS:
		var sl := Label.new()
		sl.text = "○ %s (%s)" % [str(s["label"]), str(s["summary"])]
		sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
		sl.add_theme_font_size_override("font_size", 10)
		lvb.add_child(sl)
		_step_labels.append(sl)

	var step_btns := HBoxContainer.new()
	step_btns.add_theme_constant_override("separation", 4)
	lvb.add_child(step_btns)

	_btn_step_one = Button.new()
	_btn_step_one.text = "한 단계"
	_btn_step_one.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_button(_btn_step_one, "teal")
	_btn_step_one.pressed.connect(_on_run_one_step)
	step_btns.add_child(_btn_step_one)

	_btn_step_all = Button.new()
	_btn_step_all.text = "남은 단계 실행"
	_btn_step_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_button(_btn_step_all, "amber")
	_btn_step_all.pressed.connect(_on_run_all_steps)
	step_btns.add_child(_btn_step_all)

	_btn_revalidate = Button.new()
	_btn_revalidate.text = "분기 후 남은 작업 재검증"
	StudioTheme.style_button(_btn_revalidate, "green")
	_btn_revalidate.pressed.connect(_on_run_all_steps)
	lvb.add_child(_btn_revalidate)

	_write_access_cb = CheckBox.new()
	_write_access_cb.text = "Agent 쓰기 권한 허용"
	_write_access_cb.button_pressed = true
	_write_access_cb.toggled.connect(func(v: bool):
		if not _syncing and is_instance_valid(_bound_instance) and _bound_instance.has_method("get_motion_authoring"):
			var auth: RefCounted = _bound_instance.call("get_motion_authoring")
			auth.set("write_access", v)
	)
	lvb.add_child(_write_access_cb)

	# Column 2: WORK HISTORY (Operation Journal + Replay Scrubber)
	var col_mid := PanelContainer.new()
	col_mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_section_card(col_mid, StudioTheme.BORDER_BASE, StudioTheme.SURFACE_CARD)
	cols.add_child(col_mid)

	var mvb := VBoxContainer.new()
	mvb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mvb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mvb.add_theme_constant_override("separation", 4)
	col_mid.add_child(mvb)

	_summary_bar_lbl = Label.new()
	_summary_bar_lbl.text = "Speed 2.20 | Push 48–60f | Drive 0.65 | Recover 0.20s"
	_summary_bar_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_AMBER_TEXT)
	_summary_bar_lbl.add_theme_font_size_override("font_size", 11)
	mvb.add_child(_summary_bar_lbl)

	_history_list = ItemList.new()
	_history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_list.add_theme_stylebox_override("panel", StudioTheme.make_box(StudioTheme.BG_CANVAS, StudioTheme.BORDER_BASE, 4, 1, 4, 4))
	_history_list.item_selected.connect(_on_history_selected)
	mvb.add_child(_history_list)

	var replay_row := HBoxContainer.new()
	replay_row.add_theme_constant_override("separation", 6)
	mvb.add_child(replay_row)

	var r_lbl := Label.new()
	r_lbl.text = "Replay (읽기 전용)"
	r_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	r_lbl.add_theme_font_size_override("font_size", 10)
	replay_row.add_child(r_lbl)

	_replay_slider = HSlider.new()
	_replay_slider.min_value = 0
	_replay_slider.max_value = 0
	_replay_slider.step = 1
	_replay_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_replay_slider.value_changed.connect(_on_replay_scrub)
	replay_row.add_child(_replay_slider)

	_replay_idx_lbl = Label.new()
	_replay_idx_lbl.text = "1 / 1"
	_replay_idx_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_SECONDARY)
	_replay_idx_lbl.add_theme_font_size_override("font_size", 10)
	replay_row.add_child(_replay_idx_lbl)

	# Column 3: INSPECT & EDIT (Diff + Dry-Run Preview + Replace Step / Fork)
	var col_right := PanelContainer.new()
	col_right.custom_minimum_size = Vector2(265, 0)
	StudioTheme.style_section_card(col_right, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_CARD)
	cols.add_child(col_right)

	var rvb := VBoxContainer.new()
	rvb.add_theme_constant_override("separation", 4)
	col_right.add_child(rvb)

	_inspect_title_lbl = Label.new()
	_inspect_title_lbl.text = "INSPECT & EDIT · c000"
	_inspect_title_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY)
	_inspect_title_lbl.add_theme_font_size_override("font_size", 11)
	rvb.add_child(_inspect_title_lbl)

	_diff_lbl = Label.new()
	_diff_lbl.text = "커밋을 선택하면 변경 diff(before → after)와 수정안 미리보기가 표시됩니다."
	_diff_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diff_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
	_diff_lbl.add_theme_font_size_override("font_size", 10)
	rvb.add_child(_diff_lbl)

	var edit_grid := GridContainer.new()
	edit_grid.columns = 2
	edit_grid.add_theme_constant_override("h_separation", 4)
	edit_grid.add_theme_constant_override("v_separation", 3)
	rvb.add_child(edit_grid)

	_edit_field_a_lbl = Label.new()
	_edit_field_a_lbl.text = "Push 시작f"
	_edit_field_a_lbl.add_theme_font_size_override("font_size", 10)
	edit_grid.add_child(_edit_field_a_lbl)
	_edit_spin_a = SpinBox.new()
	_edit_spin_a.min_value = 0
	_edit_spin_a.max_value = 179
	_edit_spin_a.step = 1
	_edit_spin_a.value = 48
	edit_grid.add_child(_edit_spin_a)

	_edit_field_b_lbl = Label.new()
	_edit_field_b_lbl.text = "Push 종료f"
	_edit_field_b_lbl.add_theme_font_size_override("font_size", 10)
	edit_grid.add_child(_edit_field_b_lbl)
	_edit_spin_b = SpinBox.new()
	_edit_spin_b.min_value = 1
	_edit_spin_b.max_value = 180
	_edit_spin_b.step = 1
	_edit_spin_b.value = 72
	edit_grid.add_child(_edit_spin_b)

	_edit_field_c_lbl = Label.new()
	_edit_field_c_lbl.text = "Strength"
	_edit_field_c_lbl.add_theme_font_size_override("font_size", 10)
	edit_grid.add_child(_edit_field_c_lbl)
	_edit_spin_c = SpinBox.new()
	_edit_spin_c.min_value = 0.0
	_edit_spin_c.max_value = 1.0
	_edit_spin_c.step = 0.01
	_edit_spin_c.value = 0.65
	edit_grid.add_child(_edit_spin_c)

	var act_row := HBoxContainer.new()
	act_row.add_theme_constant_override("separation", 4)
	rvb.add_child(act_row)

	_btn_preview = Button.new()
	_btn_preview.text = "수정안 미리보기"
	_btn_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_button(_btn_preview, "default")
	_btn_preview.pressed.connect(_on_preview_replacement)
	act_row.add_child(_btn_preview)

	_btn_fork_here = Button.new()
	_btn_fork_here.text = "여기서 분기"
	_btn_fork_here.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_button(_btn_fork_here, "amber")
	_btn_fork_here.pressed.connect(_on_fork_here)
	act_row.add_child(_btn_fork_here)

	_btn_replace_branch = Button.new()
	_btn_replace_branch.text = "이 단계 교체 · 새 분기 생성"
	StudioTheme.style_button(_btn_replace_branch, "green")
	_btn_replace_branch.pressed.connect(_on_replace_step_branch)
	rvb.add_child(_btn_replace_branch)


func bind_instance(inst: Node3D) -> void:
	if _mode_pill == null:
		_build_ui()
	_bound_instance = inst
	_preview_lines_text = ""
	refresh_view()


func _get_auth() -> RefCounted:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_motion_authoring"):
		return null
	return _bound_instance.call("get_motion_authoring") as RefCounted


func _build_replacement_commands_for_selected() -> Array:
	return [
		{"op": "set_event_range", "event_id": "push", "start": int(_edit_spin_a.value), "end": maxi(int(_edit_spin_a.value) + 1, int(_edit_spin_b.value))},
		{"op": "set_event_strength", "event_id": "push", "value": float(_edit_spin_c.value)},
	]


func _on_run_one_step() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	var res: Dictionary = auth.call("run_next_agent_step")
	if not bool(res.get("ok", false)):
		_preview_lines_text = "오류: " + str((res.get("error", {}) as Dictionary).get("message", ""))
	else:
		_preview_lines_text = ""
		_bound_instance.call("sync_from_motion_authoring")
	refresh_view()
	authoring_changed.emit()


func _on_run_all_steps() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	auth.call("run_all_remaining_agent_steps")
	_preview_lines_text = ""
	_bound_instance.call("sync_from_motion_authoring")
	refresh_view()
	authoring_changed.emit()


func _on_undo() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	var st: Dictionary = auth.call("motion_read_state")
	auth.call("motion_undo_transaction", {"base_revision": int(st["revision"])}, "user")
	_bound_instance.call("sync_from_motion_authoring")
	refresh_view()
	authoring_changed.emit()


func _on_redo() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	var st: Dictionary = auth.call("motion_read_state")
	auth.call("motion_redo_transaction", {"base_revision": int(st["revision"])}, "user")
	_bound_instance.call("sync_from_motion_authoring")
	refresh_view()
	authoring_changed.emit()


func _on_return_live() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	auth.call("motion_review_snapshot", {"commit_id": null})
	_preview_lines_text = ""
	refresh_view()
	authoring_changed.emit()


func _on_branch_selected(idx: int) -> void:
	if _syncing or idx < 0 or idx >= _branch_ids.size():
		return
	var auth := _get_auth()
	if auth == null:
		return
	var target_bid := _branch_ids[idx]
	var view: Dictionary = auth.call("motion_history")
	for raw_b in (view["branches"] as Array):
		var b: Dictionary = raw_b as Dictionary
		if str(b["id"]) == target_bid:
			var hid := str(b["headId"])
			if target_bid == str(view["branchId"]):
				auth.call("motion_review_snapshot", {"commit_id": null})
			else:
				auth.call("motion_review_snapshot", {"commit_id": hid})
			break
	refresh_view()
	authoring_changed.emit()


func _on_history_selected(idx: int) -> void:
	if _syncing or idx < 0 or idx >= _history_commit_ids.size():
		return
	var auth := _get_auth()
	if auth == null:
		return
	var cid := _history_commit_ids[idx]
	var view: Dictionary = auth.call("motion_history")
	if cid == str(view["cursorId"]) and not bool(view["reviewing"]):
		return
	if cid == str(view["cursorId"]):
		auth.call("motion_review_snapshot", {"commit_id": null})
	else:
		auth.call("motion_review_snapshot", {"commit_id": cid})
	_preview_lines_text = ""
	refresh_view()
	authoring_changed.emit()


func _on_replay_scrub(val: float) -> void:
	if _syncing:
		return
	var idx := clampi(int(val), 0, _history_commit_ids.size() - 1)
	if idx >= 0 and idx < _history_commit_ids.size():
		_on_history_selected(idx)


func _on_preview_replacement() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	var view: Dictionary = auth.call("motion_history")
	var sel_id := str(view["selectedId"])
	var parent_id := sel_id
	for raw_e in (view["entries"] as Array):
		var e: Dictionary = raw_e as Dictionary
		if str(e["id"]) == sel_id and e.get("parentId", null) != null:
			parent_id = str(e["parentId"])
			break
	var prev: Dictionary = auth.call("motion_preview_commands", {
		"commands": _build_replacement_commands_for_selected(),
		"base_commit_id": parent_id,
	})
	if bool(prev.get("ok", false)):
		var lines := PackedStringArray(["[수정안 미리보기 · 미적용 · 기준 %s]" % parent_id])
		for raw_c in (prev["changes"] as Array):
			var c: Dictionary = raw_c as Dictionary
			lines.append("• %s.%s: %s → %s" % [str(c["target"]), str(c["path"]), str(c["before"]), str(c["after"])])
		_preview_lines_text = "\n".join(lines)
	else:
		_preview_lines_text = "미리보기 오류: " + str((prev.get("error", {}) as Dictionary).get("message", ""))
	refresh_view()


func _on_replace_step_branch() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	var view: Dictionary = auth.call("motion_history")
	var sel_id := str(view["selectedId"])
	var res: Dictionary = auth.call("replace_step", sel_id, _build_replacement_commands_for_selected(), "사용자 수정안")
	if bool(res.get("ok", false)):
		_preview_lines_text = ""
		_bound_instance.call("sync_from_motion_authoring")
	else:
		_preview_lines_text = "교체 실패: " + str((res.get("error", {}) as Dictionary).get("message", ""))
	refresh_view()
	authoring_changed.emit()


func _on_fork_here() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	var st: Dictionary = auth.call("motion_read_state")
	var view: Dictionary = auth.call("motion_history")
	var sel_id := str(view["selectedId"])
	auth.call("motion_fork_snapshot", {
		"commit_id": sel_id,
		"label": "분기 %s" % sel_id,
		"base_revision": int(st["revision"]),
	}, "user")
	_preview_lines_text = ""
	refresh_view()
	authoring_changed.emit()


func _on_export_json() -> void:
	var auth := _get_auth()
	if auth == null:
		return
	_last_saved_json = str(auth.call("export_session_json"))
	_preview_lines_text = "저널 세션 JSON 저장됨 (%d bytes)" % _last_saved_json.length()
	refresh_view()


func _on_restore_json() -> void:
	var auth := _get_auth()
	if auth == null or _last_saved_json.is_empty():
		_preview_lines_text = "먼저 'JSON 저장'을 눌러 스냅샷을 저장하세요."
		refresh_view()
		return
	var res: Dictionary = auth.call("restore_session_json", _last_saved_json)
	if bool(res.get("ok", false)):
		_preview_lines_text = "세션 복원 완료 (체크섬·트리 검증 통과)"
		_bound_instance.call("sync_from_motion_authoring")
	else:
		_preview_lines_text = "복원 실패: " + str((res.get("error", {}) as Dictionary).get("message", ""))
	refresh_view()
	authoring_changed.emit()


func refresh_view() -> void:
	if _mode_pill == null:
		return
	var auth := _get_auth()
	if auth == null:
		return
	var view: Dictionary = auth.call("motion_history")
	var reviewing := bool(view.get("reviewing", false))
	var cursor_id := str(view.get("cursorId", "c000"))
	var sel_id := str(view.get("selectedId", "c000"))
	var bid := str(view.get("branchId", "b000"))
	var rev := int(view.get("revision", 0))

	if reviewing:
		_mode_pill.text = "REVIEW / READ ONLY"
		StudioTheme.style_pill_label(_mode_pill, StudioTheme.ACCENT_AMBER_DIM, StudioTheme.ACCENT_AMBER, StudioTheme.ACCENT_AMBER_TEXT)
		_status_lbl.text = "검토 %s · 작업 %s 보존 · r%d" % [sel_id, cursor_id, rev]
	else:
		_mode_pill.text = "LIVE WORKSPACE"
		StudioTheme.style_pill_label(_mode_pill, StudioTheme.ACCENT_TEAL_DIM, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_TEXT)
		_status_lbl.text = "작업 %s · %s · r%d" % [cursor_id, bid, rev]

	_btn_undo.disabled = not bool(view.get("canUndo", false))
	_btn_redo.disabled = not bool(view.get("canRedo", false))
	_btn_return_live.visible = reviewing

	# Branch dropdown
	_syncing = true
	_branch_opt.clear()
	_branch_ids.clear()
	var branches: Array = view.get("branches", []) as Array
	var active_b_idx := 0
	for i in branches.size():
		var b: Dictionary = branches[i] as Dictionary
		var b_id := str(b["id"])
		_branch_ids.append(b_id)
		var tag := " · 작업" if b_id == bid else ""
		_branch_opt.add_item("%s / %s%s" % [str(b["label"]), b_id, tag])
		if b_id == bid:
			active_b_idx = i
	if _branch_opt.item_count > 0:
		_branch_opt.select(active_b_idx)

	# 4-Step checklist progress
	var next_step_idx := int(auth.call("get_next_agent_step_index"))
	for i in _step_labels.size():
		var s: Dictionary = MotionCommandsScript.AGENT_SCENARIO_STEPS[i]
		var done := (i < next_step_idx)
		_step_labels[i].text = "%s %s (%s)" % ["●" if done else "○", str(s["label"]), str(s["summary"])]
		_step_labels[i].add_theme_color_override("font_color", StudioTheme.SEMANTIC_SUCCESS if done else StudioTheme.TEXT_MUTED)
	_btn_step_one.disabled = reviewing or next_step_idx >= MotionCommandsScript.AGENT_SCENARIO_STEPS.size()
	_btn_step_all.disabled = reviewing or next_step_idx >= MotionCommandsScript.AGENT_SCENARIO_STEPS.size()
	_btn_revalidate.disabled = reviewing or next_step_idx >= MotionCommandsScript.AGENT_SCENARIO_STEPS.size()
	_write_access_cb.button_pressed = bool(auth.get("write_access"))

	# Snapshot summary KPI strip
	var snap: Dictionary = view.get("selectedSnapshot", {}) as Dictionary
	var params: Dictionary = snap.get("defaultParameters", {}) as Dictionary
	var phys: Dictionary = snap.get("physics", {}) as Dictionary
	var push_str := "48–60f"
	for raw_ev in (snap.get("events", []) as Array):
		var ev: Dictionary = raw_ev as Dictionary
		if str(ev.get("id", "")) == "push":
			push_str = "%d–%df" % [int(ev.get("start", 48)), int(ev.get("end", 60))]
			break
	var rec_dur := 0.20
	for raw_tr in (snap.get("transitions", []) as Array):
		var tr: Dictionary = raw_tr as Dictionary
		if str(tr.get("id", "")) == "air-recover":
			rec_dur = float(tr.get("duration", 0.20))
			break
	_summary_bar_lbl.text = "%s · Speed %.2f | Push %s | Drive %.2f | Recover %.2fs" % [
		sel_id, float(params.get("speed", 2.2)), push_str, float(phys.get("strength", 0.65)), rec_dur
	]

	# History commit list (show active branch path + allow reviewing all commits)
	_history_list.clear()
	_history_commit_ids.clear()
	var path: Array = view.get("activePath", []) as Array
	var entry_by_id: Dictionary = {}
	for raw_e in (view.get("entries", []) as Array):
		var ed: Dictionary = raw_e as Dictionary
		entry_by_id[str(ed["id"])] = ed
	var sel_row := 0
	for i in path.size():
		var cid := str(path[i])
		var ed: Dictionary = entry_by_id.get(cid, {}) as Dictionary
		var src := str(ed.get("source", "user")).to_upper()
		var ch_cnt := (ed.get("changes", []) as Array).size()
		var mark := " [WORKING]" if cid == cursor_id else (" [REVIEW]" if cid == sel_id else "")
		_history_list.add_item("%s · %s · %s (r%d · %d건)%s" % [cid, src, str(ed.get("label", "")), int(ed.get("revision", 0)), ch_cnt, mark])
		_history_commit_ids.append(cid)
		if cid == sel_id:
			sel_row = i
	if _history_list.item_count > 0:
		_history_list.select(sel_row)
		_replay_slider.max_value = maxi(0, _history_commit_ids.size() - 1)
		_replay_slider.value = sel_row
		_replay_idx_lbl.text = "%d / %d" % [sel_row + 1, _history_commit_ids.size()]

	# Right column diff inspector
	var sel_entry: Dictionary = entry_by_id.get(sel_id, {}) as Dictionary
	_inspect_title_lbl.text = "INSPECT & EDIT · %s · %s · r%d" % [sel_id, str(sel_entry.get("branchId", bid)), int(sel_entry.get("revision", 0))]
	if not _preview_lines_text.is_empty():
		_diff_lbl.text = _preview_lines_text
		_diff_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_AMBER_TEXT)
	else:
		var changes: Array = sel_entry.get("changes", []) as Array
		if changes.is_empty():
			_diff_lbl.text = "초기 문서 스냅샷 (변경 0건)"
		else:
			var dlines := PackedStringArray()
			for raw_c in changes:
				var c: Dictionary = raw_c as Dictionary
				dlines.append("• %s.%s: %s → %s" % [str(c.get("target", "")), str(c.get("path", "")), str(c.get("before", "")), str(c.get("after", ""))])
			_diff_lbl.text = "\n".join(dlines)
		_diff_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
	_btn_replace_branch.disabled = (sel_id == "c000")
	_syncing = false
