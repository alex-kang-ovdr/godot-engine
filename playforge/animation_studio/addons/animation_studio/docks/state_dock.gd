@tool
extends VBoxContainer
## Standard Godot Editor Dock: "AnimStudio · 상태" (Design v3 Styled)
## Context-aware inspector & controller dock with 4 distinct visual layouts:
##   1. Hero + AI (Spatial Analysis + A*, 6 missions, CostModifier, 5 UserEdge filter chips,
##      Dynamic Obstacle toggle, 12/12 Coverage Mini-Grid, Physics Rig Lab, Lua scenarios)
##   2. Quadruped (5-button Segmented Gait Bar, Speed Slider, 2x2 Visual Foot Contact Grid)
##   3. Character 28 Roster (Float32/16-bit Segmented Switcher, Native C++ Status Banner,
##      2x2 KPI Metric Cards, 200-Agent Benchmark)
##   4. Empty State (Hero_Arena select / Quick Spawn CTA buttons)

const Store := preload("res://characters/character_store.gd")
const StudioTheme := preload("res://addons/animation_studio/ui/studio_theme.gd")
const SpatialScript := preload("res://hero/ai/hero_spatial_analysis.gd")
const PathfinderScript := preload("res://hero/ai/hero_ai_pathfinder.gd")

signal docking_lines_toggled(visible: bool)
signal select_hero_requested()
signal quick_spawn_requested()
signal authoring_changed()

const COVERAGE_ITEMS := [
	["locomotion", "보행"],
	["turn180", "180°턴"],
	["cover_low", "낮음엄폐"],
	["cover_high", "높음엄폐"],
	["cover_roll", "엄폐구름"],
	["vault", "난간넘기"],
	["climb_up", "턱등반"],
	["leap", "도약"],
	["drop_down", "드롭다운"],
	["trench_pit", "지하참호"],
	["summit_10m", "정상10m"],
	["combat_strafe", "전투보법"],
]

var _bound_instance: Node3D = null
var _current_role: String = ""
var _syncing_ui: bool = false

# Header card
var _hdr_role_pill: Label = null
var _hdr_state_pill: Label = null
var _hdr_title: Label = null
var _hdr_pos_lbl: Label = null

# Role sections
var _empty_box: VBoxContainer = null
var _hero_box: VBoxContainer = null
var _quad_box: VBoxContainer = null
var _char_box: VBoxContainer = null

# Hero + AI controls
var _hero_auto_cb: CheckBox = null
var _hero_ai_cb: CheckBox = null
var _hero_cost_opt: OptionButton = null
var _hero_flag_chips: Dictionary = {} # flag_bit -> Button
var _hero_obs_cb: CheckBox = null
var _hero_lines_cb: CheckBox = null
var _hero_status_lbl: Label = null
var _hero_ai_lbl: Label = null
var _hero_cov_pills: Dictionary = {} # key -> Label
var _hero_cov_count_lbl: Label = null
var _hero_vars_lbl: Label = null
var _phys_drive_slider: HSlider = null
var _phys_drive_lbl: Label = null
var _phys_limit_slider: HSlider = null
var _phys_limit_lbl: Label = null
var _phys_balance_cb: CheckBox = null
var _phys_impulse_slider: HSlider = null
var _phys_impulse_lbl: Label = null
var _phys_rule_lbl: Label = null

# Quadruped controls
var _quad_auto_cb: CheckBox = null
var _quad_speed_slider: HSlider = null
var _quad_speed_lbl: Label = null
var _quad_gait_btns: Dictionary = {}
var _quad_foot_panels: Dictionary = {} # FL/FR/HL/HR -> {panel, status_lbl}
var _quad_telemetry_lbl: Label = null

# Character (28 roster) controls
var _char_opt: OptionButton = null
var _char_ids: PackedStringArray = PackedStringArray()
var _clip_opt: OptionButton = null
var _btn_float32: Button = null
var _btn_quant16: Button = null
var _backend_banner: PanelContainer = null
var _backend_banner_lbl: Label = null
var _kpi_pos_lbl: Label = null
var _kpi_rot_lbl: Label = null
var _kpi_world_lbl: Label = null
var _kpi_mem_lbl: Label = null
var _char_bench_lbl: Label = null


func _init() -> void:
	name = "AnimStudio · 상태"
	custom_minimum_size = Vector2(280, 280)
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
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	# --- Styled Top Instance Header Card ---
	var hdr_card := PanelContainer.new()
	StudioTheme.style_section_card(hdr_card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_NODE)
	body.add_child(hdr_card)

	var hdr_vb := VBoxContainer.new()
	hdr_vb.add_theme_constant_override("separation", 4)
	hdr_card.add_child(hdr_vb)

	var badge_row := HBoxContainer.new()
	badge_row.add_theme_constant_override("separation", 6)
	hdr_vb.add_child(badge_row)

	_hdr_role_pill = Label.new()
	_hdr_role_pill.text = "미연결"
	StudioTheme.style_pill_label(_hdr_role_pill, StudioTheme.ACCENT_AMBER_DIM, StudioTheme.ACCENT_AMBER, StudioTheme.ACCENT_AMBER_TEXT)
	badge_row.add_child(_hdr_role_pill)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	badge_row.add_child(spacer)

	_hdr_state_pill = Label.new()
	_hdr_state_pill.text = "IDLE"
	StudioTheme.style_pill_label(_hdr_state_pill, StudioTheme.ACCENT_TEAL_DIM, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_TEXT)
	badge_row.add_child(_hdr_state_pill)

	_hdr_title = Label.new()
	_hdr_title.text = "연결된 인스턴스 없음"
	_hdr_title.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY)
	_hdr_title.add_theme_font_size_override("font_size", 13)
	hdr_vb.add_child(_hdr_title)

	_hdr_pos_lbl = Label.new()
	_hdr_pos_lbl.text = "X: 0.00  Y: 0.00  Z: 0.00 m"
	_hdr_pos_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	_hdr_pos_lbl.add_theme_font_size_override("font_size", 11)
	hdr_vb.add_child(_hdr_pos_lbl)

	_build_empty_section(body)
	_build_hero_section(body)
	_build_quad_section(body)
	_build_char_section(body)
	_update_section_visibility("")


func _build_empty_section(parent: VBoxContainer) -> void:
	_empty_box = VBoxContainer.new()
	_empty_box.add_theme_constant_override("separation", 8)
	parent.add_child(_empty_box)

	var card := PanelContainer.new()
	StudioTheme.style_section_card(card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_CARD)
	_empty_box.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	card.add_child(vb)

	var title := Label.new()
	title.text = "캐릭터 인스턴스를 선택하세요"
	title.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY)
	title.add_theme_font_size_override("font_size", 13)
	vb.add_child(title)

	var desc := Label.new()
	desc.text = "3D 뷰포트나 좌측 계층 도크에서 AnimationStudioInstance 노드를 선택하면 AI 경로탐색·보행 IK·16-bit 비교 제어가 표시됩니다."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	desc.add_theme_font_size_override("font_size", 11)
	vb.add_child(desc)

	var btn_hero := Button.new()
	btn_hero.text = "Hero_Arena 선택하기"
	btn_hero.icon = StudioTheme.get_icon("hero", StudioTheme.ACCENT_AMBER_TEXT, 14)
	StudioTheme.style_button(btn_hero, "amber")
	btn_hero.pressed.connect(func(): select_hero_requested.emit())
	vb.add_child(btn_hero)

	var btn_spawn := Button.new()
	btn_spawn.text = "+ 새 캐릭터 배치"
	btn_spawn.icon = StudioTheme.get_icon("character", StudioTheme.ACCENT_TEAL_TEXT, 14)
	StudioTheme.style_button(btn_spawn, "teal")
	btn_spawn.pressed.connect(func(): quick_spawn_requested.emit())
	vb.add_child(btn_spawn)


func _build_hero_section(parent: VBoxContainer) -> void:
	_hero_box = VBoxContainer.new()
	_hero_box.add_theme_constant_override("separation", 8)
	parent.add_child(_hero_box)

	# --- 1. AI Pathfinding Card (Spatial Analysis + A*) ---
	var ai_card := PanelContainer.new()
	StudioTheme.style_section_card(ai_card, StudioTheme.ACCENT_TEAL, StudioTheme.SURFACE_CARD)
	_hero_box.add_child(ai_card)

	var ai_vb := VBoxContainer.new()
	ai_vb.add_theme_constant_override("separation", 6)
	ai_card.add_child(ai_vb)

	ai_vb.add_child(StudioTheme.make_section_header("AI Pathfinding · Spatial Analysis + A*", "ai-path", StudioTheme.ACCENT_TEAL_TEXT))

	_hero_ai_cb = CheckBox.new()
	_hero_ai_cb.text = "AI 자율 주행 활성화"
	_hero_ai_cb.toggled.connect(func(v: bool):
		if not _syncing_ui and is_instance_valid(_bound_instance) and _bound_instance.has_method("set_ai_driven"):
			_bound_instance.call("set_ai_driven", v)
			if v:
				_syncing_ui = true
				_hero_auto_cb.button_pressed = false
				_syncing_ui = false
	)
	ai_vb.add_child(_hero_ai_cb)

	# 2x3 AI Mission Grid
	var ai_grid := GridContainer.new()
	ai_grid.columns = 2
	ai_grid.add_theme_constant_override("h_separation", 4)
	ai_grid.add_theme_constant_override("v_separation", 4)
	ai_vb.add_child(ai_grid)

	var missions := [
		["AI 풀코스 (12개)", "grand_tour"],
		["AI 정상 +10.25m", "summit_ascent"],
		["AI 전술 엄폐", "tactical_cover"],
		["AI 난간 슬라럼", "vault_slalom"],
		["지하 참호 탈출", "trench_escape"],
		["고지대 선호", "high_road"],
	]
	for m in missions:
		var ab := Button.new()
		ab.text = m[0]
		ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StudioTheme.style_button(ab, "teal" if m[1] == "grand_tour" else "default")
		var mid: String = m[1]
		ab.pressed.connect(func():
			if is_instance_valid(_bound_instance) and _bound_instance.has_method("start_ai_mission"):
				_syncing_ui = true
				_hero_ai_cb.button_pressed = true
				_hero_auto_cb.button_pressed = false
				_syncing_ui = false
				_bound_instance.call("start_ai_mission", mid)
				update_live()
		)
		ai_grid.add_child(ab)

	# CostModifier Selector
	var cost_row := HBoxContainer.new()
	cost_row.add_theme_constant_override("separation", 6)
	ai_vb.add_child(cost_row)

	var cost_lbl := Label.new()
	cost_lbl.text = "CostModifier"
	cost_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	cost_lbl.add_theme_font_size_override("font_size", 11)
	cost_row.add_child(cost_lbl)

	_hero_cost_opt = OptionButton.new()
	_hero_cost_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hero_cost_opt.add_item("Shortest (최단 경로)", 0)
	_hero_cost_opt.add_item("PreferHigh (고지대 선호)", 1)
	_hero_cost_opt.add_item("TacticalCover (전술 엄폐)", 2)
	_hero_cost_opt.add_item("ParkourExpress (파쿠르 우선)", 3)
	_hero_cost_opt.select(3)
	_hero_cost_opt.item_selected.connect(func(idx: int):
		if _syncing_ui or not is_instance_valid(_bound_instance) or not _bound_instance.has_method("set_ai_cost_mode"):
			return
		var modes := [
			PathfinderScript.COST_SHORTEST,
			PathfinderScript.COST_PREFER_HIGH,
			PathfinderScript.COST_TACTICAL_COVER,
			PathfinderScript.COST_PARKOUR_EXPRESS,
		]
		if idx >= 0 and idx < modes.size():
			_bound_instance.call("set_ai_cost_mode", modes[idx])
			update_live()
	)
	cost_row.add_child(_hero_cost_opt)

	# 5 UserEdge Filter Chips (Vault / Climb / Leap / Drop / Cover)
	var fl_lbl := Label.new()
	fl_lbl.text = "UserEdge 허용 필터 (실시간 A* 재탐색)"
	fl_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	fl_lbl.add_theme_font_size_override("font_size", 11)
	ai_vb.add_child(fl_lbl)

	var chip_flow := HFlowContainer.new()
	chip_flow.add_theme_constant_override("h_separation", 4)
	chip_flow.add_theme_constant_override("v_separation", 4)
	ai_vb.add_child(chip_flow)

	var edge_specs := [
		[SpatialScript.FLAG_VAULT, "Vault", "vault", StudioTheme.TRAV_VAULT],
		[SpatialScript.FLAG_CLIMB, "Climb", "climb", StudioTheme.TRAV_CLIMB],
		[SpatialScript.FLAG_LEAP, "Leap", "leap", StudioTheme.TRAV_LEAP],
		[SpatialScript.FLAG_DROP, "Drop", "drop", StudioTheme.TRAV_DROP],
		[SpatialScript.FLAG_COVER, "Cover", "cover", StudioTheme.TRAV_COVER],
	]
	for es in edge_specs:
		var bit: int = int(es[0])
		var chip := Button.new()
		chip.text = str(es[1])
		chip.toggle_mode = true
		chip.button_pressed = true
		chip.icon = StudioTheme.get_icon(str(es[2]), es[3] as Color, 12)
		StudioTheme.style_button(chip, "chip", es[3] as Color)
		chip.toggled.connect(func(v: bool):
			if not _syncing_ui and is_instance_valid(_bound_instance) and _bound_instance.has_method("set_ai_allowed_flag"):
				_bound_instance.call("set_ai_allowed_flag", bit, v)
				update_live()
		)
		chip_flow.add_child(chip)
		_hero_flag_chips[bit] = chip

	_hero_obs_cb = CheckBox.new()
	_hero_obs_cb.text = "동적 장애물 실루엣 배치 (실시간 우회)"
	_hero_obs_cb.toggled.connect(func(v: bool):
		if not _syncing_ui and is_instance_valid(_bound_instance) and _bound_instance.has_method("set_ai_dynamic_obstacle"):
			_bound_instance.call("set_ai_dynamic_obstacle", v)
			update_live()
	)
	ai_vb.add_child(_hero_obs_cb)

	_hero_ai_lbl = Label.new()
	_hero_ai_lbl.text = "AI 대기 중 — 미션을 클릭하면 1,823 NavNode / 140 UserEdge 위에서 A* 자율 주행합니다."
	_hero_ai_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_ai_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_AMBER_TEXT)
	_hero_ai_lbl.add_theme_font_size_override("font_size", 11)
	ai_vb.add_child(_hero_ai_lbl)

	# 12/12 Coverage Mini-Grid
	var cov_hdr := HBoxContainer.new()
	ai_vb.add_child(cov_hdr)
	var cov_t := Label.new()
	cov_t.text = "히어로 맵 기능 커버리지"
	cov_t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cov_t.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	cov_t.add_theme_font_size_override("font_size", 11)
	cov_hdr.add_child(cov_t)
	_hero_cov_count_lbl = Label.new()
	_hero_cov_count_lbl.text = "0 / 12"
	StudioTheme.style_pill_label(_hero_cov_count_lbl, StudioTheme.SURFACE_NODE, StudioTheme.BORDER_CONTROL, StudioTheme.TEXT_MUTED)
	cov_hdr.add_child(_hero_cov_count_lbl)

	var cov_grid := GridContainer.new()
	cov_grid.columns = 3
	cov_grid.add_theme_constant_override("h_separation", 4)
	cov_grid.add_theme_constant_override("v_separation", 4)
	ai_vb.add_child(cov_grid)
	for ci in COVERAGE_ITEMS:
		var ck: String = ci[0]
		var cl := Label.new()
		cl.text = ci[1]
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StudioTheme.style_pill_label(cl, StudioTheme.SURFACE_NODE, StudioTheme.BORDER_BASE, StudioTheme.TEXT_DIM)
		cov_grid.add_child(cl)
		_hero_cov_pills[ck] = cl

	# --- 2. Physics Rig & Reaction Card (v2 Euphoria Physics Lab -> MotionCommands) ---
	var phys_card := PanelContainer.new()
	StudioTheme.style_section_card(phys_card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_CARD)
	_hero_box.add_child(phys_card)

	var p_vb := VBoxContainer.new()
	p_vb.add_theme_constant_override("separation", 5)
	phys_card.add_child(p_vb)

	p_vb.add_child(StudioTheme.make_section_header("물리 리그 반응 · Physics Lab (저널 연동)", "bone", StudioTheme.ACCENT_AMBER_TEXT))

	_phys_drive_lbl = Label.new()
	_phys_drive_lbl.text = "Drive Strength: 0.65"
	_phys_drive_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_SECONDARY)
	_phys_drive_lbl.add_theme_font_size_override("font_size", 11)
	p_vb.add_child(_phys_drive_lbl)

	_phys_drive_slider = HSlider.new()
	_phys_drive_slider.min_value = 0.0
	_phys_drive_slider.max_value = 1.0
	_phys_drive_slider.step = 0.01
	_phys_drive_slider.value = 0.65
	_phys_drive_slider.value_changed.connect(func(v: float):
		_phys_drive_lbl.text = "Drive Strength: %.2f" % v
		_update_physics_rule_hint()
	)
	_phys_drive_slider.drag_ended.connect(func(changed: bool):
		if changed and not _syncing_ui:
			_commit_physics_patch({"strength": _phys_drive_slider.value}, "Drive Strength 조절 (%.2f)" % _phys_drive_slider.value)
	)
	p_vb.add_child(_phys_drive_slider)

	_phys_limit_lbl = Label.new()
	_phys_limit_lbl.text = "Joint Limit: 45°"
	_phys_limit_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_SECONDARY)
	_phys_limit_lbl.add_theme_font_size_override("font_size", 11)
	p_vb.add_child(_phys_limit_lbl)

	_phys_limit_slider = HSlider.new()
	_phys_limit_slider.min_value = 0.0
	_phys_limit_slider.max_value = 120.0
	_phys_limit_slider.step = 1.0
	_phys_limit_slider.value = 45.0
	_phys_limit_slider.value_changed.connect(func(v: float):
		_phys_limit_lbl.text = "Joint Limit: %d°" % int(v)
	)
	_phys_limit_slider.drag_ended.connect(func(changed: bool):
		if changed and not _syncing_ui:
			_commit_physics_patch({"limit": int(_phys_limit_slider.value)}, "Joint Limit 조절 (%d°)" % int(_phys_limit_slider.value))
	)
	p_vb.add_child(_phys_limit_slider)

	_phys_balance_cb = CheckBox.new()
	_phys_balance_cb.text = "Balance (균형 유지 반응 활성)"
	_phys_balance_cb.button_pressed = true
	_phys_balance_cb.toggled.connect(func(v: bool):
		_update_physics_rule_hint()
		if not _syncing_ui:
			_commit_physics_patch({"balance": v}, "Balance 반응 %s" % ("활성" if v else "해제"))
	)
	p_vb.add_child(_phys_balance_cb)

	var imp_row := HBoxContainer.new()
	imp_row.add_theme_constant_override("separation", 6)
	p_vb.add_child(imp_row)

	_phys_impulse_lbl = Label.new()
	_phys_impulse_lbl.text = "Impulse: 0.40"
	_phys_impulse_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	_phys_impulse_lbl.add_theme_font_size_override("font_size", 11)
	imp_row.add_child(_phys_impulse_lbl)

	_phys_impulse_slider = HSlider.new()
	_phys_impulse_slider.min_value = 0.0
	_phys_impulse_slider.max_value = 1.0
	_phys_impulse_slider.step = 0.02
	_phys_impulse_slider.value = 0.40
	_phys_impulse_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phys_impulse_slider.value_changed.connect(func(v: float):
		_phys_impulse_lbl.text = "Impulse: %.2f" % v
		_update_physics_rule_hint()
	)
	imp_row.add_child(_phys_impulse_slider)

	var btn_imp := Button.new()
	btn_imp.text = "충격 적용"
	StudioTheme.style_button(btn_imp, "amber")
	btn_imp.pressed.connect(func():
		if is_instance_valid(_bound_instance) and _bound_instance.has_method("trigger_physics_impulse"):
			_bound_instance.call("trigger_physics_impulse", _phys_impulse_slider.value)
			authoring_changed.emit()
	)
	imp_row.add_child(btn_imp)

	_phys_rule_lbl = Label.new()
	_phys_rule_lbl.text = "반응 예측: Balance (Drive 0.65 ≥ Impulse 0.40)"
	_phys_rule_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_phys_rule_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
	_phys_rule_lbl.add_theme_font_size_override("font_size", 10)
	p_vb.add_child(_phys_rule_lbl)

	# --- 3. Manual Parkour & Lua Scenarios Card ---
	var lua_card := PanelContainer.new()
	StudioTheme.style_section_card(lua_card, StudioTheme.BORDER_BASE, StudioTheme.SURFACE_CARD)
	_hero_box.add_child(lua_card)

	var lua_vb := VBoxContainer.new()
	lua_vb.add_theme_constant_override("separation", 6)
	lua_card.add_child(lua_vb)

	lua_vb.add_child(StudioTheme.make_section_header("수동 파쿠르 · Lua 시나리오", "hero", StudioTheme.TEXT_PRIMARY))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	lua_vb.add_child(grid)

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
		StudioTheme.style_button(b, "default")
		var sid: String = s[1]
		b.pressed.connect(func(): _trigger_hero_scenario(sid))
		grid.add_child(b)

	var ev_grid := GridContainer.new()
	ev_grid.columns = 3
	ev_grid.add_theme_constant_override("h_separation", 4)
	ev_grid.add_theme_constant_override("v_separation", 4)
	lua_vb.add_child(ev_grid)

	for ev_name in ["JumpButton", "Action", "WeaponToggle", "Attack", "Strafe"]:
		var b := Button.new()
		b.text = ev_name
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StudioTheme.style_button(b, "chip", StudioTheme.ACCENT_AMBER)
		var ename: String = ev_name
		b.pressed.connect(func(): _raise_hero_event(ename))
		ev_grid.add_child(b)

	_hero_auto_cb = CheckBox.new()
	_hero_auto_cb.text = "자동 파쿠르 투어 순환 (auto_demo)"
	_hero_auto_cb.toggled.connect(func(v: bool):
		if not _syncing_ui and is_instance_valid(_bound_instance):
			_bound_instance.set("auto_demo", v)
	)
	lua_vb.add_child(_hero_auto_cb)

	_hero_lines_cb = CheckBox.new()
	_hero_lines_cb.text = "90개 도킹 라인 오버레이 표시"
	_hero_lines_cb.button_pressed = true
	_hero_lines_cb.toggled.connect(func(v: bool):
		if not _syncing_ui:
			docking_lines_toggled.emit(v)
	)
	lua_vb.add_child(_hero_lines_cb)

	_hero_status_lbl = Label.new()
	_hero_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_status_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
	_hero_status_lbl.add_theme_font_size_override("font_size", 11)
	lua_vb.add_child(_hero_status_lbl)

	_hero_vars_lbl = Label.new()
	_hero_vars_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_vars_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	_hero_vars_lbl.add_theme_font_size_override("font_size", 11)
	lua_vb.add_child(_hero_vars_lbl)


func _build_quad_section(parent: VBoxContainer) -> void:
	_quad_box = VBoxContainer.new()
	_quad_box.add_theme_constant_override("separation", 8)
	parent.add_child(_quad_box)

	# Gait & Speed Card
	var ctrl_card := PanelContainer.new()
	StudioTheme.style_section_card(ctrl_card, StudioTheme.ACCENT_TEAL, StudioTheme.SURFACE_CARD)
	_quad_box.add_child(ctrl_card)

	var cvb := VBoxContainer.new()
	cvb.add_theme_constant_override("separation", 6)
	ctrl_card.add_child(cvb)

	cvb.add_child(StudioTheme.make_section_header("4족 절차적 Locomotor 보행 모드", "quadruped", StudioTheme.ACCENT_TEAL_TEXT))

	# 5-Button Segmented Gait Bar
	var seg_row := HBoxContainer.new()
	seg_row.add_theme_constant_override("separation", 3)
	cvb.add_child(seg_row)

	for g in ["auto", "walk", "trot", "pace", "gallop"]:
		var b := Button.new()
		b.text = g.capitalize()
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StudioTheme.style_button(b, "tab", StudioTheme.ACCENT_TEAL)
		var gk: String = g
		b.pressed.connect(func(): _set_quad_gait(gk))
		seg_row.add_child(b)
		_quad_gait_btns[gk] = b

	var spd_row := HBoxContainer.new()
	cvb.add_child(spd_row)
	var spd_t := Label.new()
	spd_t.text = "목표 이동 속도"
	spd_t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spd_t.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	spd_t.add_theme_font_size_override("font_size", 11)
	spd_row.add_child(spd_t)

	_quad_speed_lbl = Label.new()
	_quad_speed_lbl.text = "2.60 m/s"
	_quad_speed_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_AMBER_TEXT)
	_quad_speed_lbl.add_theme_font_size_override("font_size", 14)
	spd_row.add_child(_quad_speed_lbl)

	_quad_speed_slider = HSlider.new()
	_quad_speed_slider.min_value = 0.0
	_quad_speed_slider.max_value = 5.5
	_quad_speed_slider.step = 0.05
	_quad_speed_slider.value = 2.6
	_quad_speed_slider.value_changed.connect(func(v: float):
		_quad_speed_lbl.text = "%.2f m/s" % v
		if not _syncing_ui and is_instance_valid(_bound_instance) and _bound_instance.has_method("set_quad_speed"):
			_bound_instance.call("set_quad_speed", v)
	)
	cvb.add_child(_quad_speed_slider)

	_quad_auto_cb = CheckBox.new()
	_quad_auto_cb.text = "제자리 순환 보행 활성 (auto_demo)"
	_quad_auto_cb.toggled.connect(func(v: bool):
		if not _syncing_ui and is_instance_valid(_bound_instance):
			_bound_instance.set("auto_demo", v)
	)
	cvb.add_child(_quad_auto_cb)

	# 2x2 Visual 4-Foot Contact Grid (FL / FR / HL / HR)
	var foot_card := PanelContainer.new()
	StudioTheme.style_section_card(foot_card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_CARD)
	_quad_box.add_child(foot_card)

	var fvb := VBoxContainer.new()
	fvb.add_theme_constant_override("separation", 6)
	foot_card.add_child(fvb)

	fvb.add_child(StudioTheme.make_section_header("실시간 4족 접지 상태 (Foot Lock)", "focus", StudioTheme.TEXT_PRIMARY))

	var foot_grid := GridContainer.new()
	foot_grid.columns = 2
	foot_grid.add_theme_constant_override("h_separation", 6)
	foot_grid.add_theme_constant_override("v_separation", 6)
	fvb.add_child(foot_grid)

	for leg_spec in [["FL", "앞왼발 · FL"], ["FR", "앞오른발 · FR"], ["HL", "뒷왼발 · HL"], ["HR", "뒷오른발 · HR"]]:
		var lkey: String = leg_spec[0]
		var fp := PanelContainer.new()
		fp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		StudioTheme.style_foot_card(fp, true)
		foot_grid.add_child(fp)

		var lvb := VBoxContainer.new()
		lvb.add_theme_constant_override("separation", 2)
		fp.add_child(lvb)

		var lt := Label.new()
		lt.text = leg_spec[1]
		lt.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
		lt.add_theme_font_size_override("font_size", 10)
		lvb.add_child(lt)

		var ls := Label.new()
		ls.text = "PLANTED"
		ls.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
		ls.add_theme_font_size_override("font_size", 12)
		lvb.add_child(ls)

		_quad_foot_panels[lkey] = {"panel": fp, "status_lbl": ls}

	_quad_telemetry_lbl = Label.new()
	_quad_telemetry_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quad_telemetry_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	_quad_telemetry_lbl.add_theme_font_size_override("font_size", 11)
	fvb.add_child(_quad_telemetry_lbl)


func _build_char_section(parent: VBoxContainer) -> void:
	_char_box = VBoxContainer.new()
	_char_box.add_theme_constant_override("separation", 8)
	parent.add_child(_char_box)

	# Asset & Clip Selection Card
	var asset_card := PanelContainer.new()
	StudioTheme.style_section_card(asset_card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_CARD)
	_char_box.add_child(asset_card)

	var avb := VBoxContainer.new()
	avb.add_theme_constant_override("separation", 6)
	asset_card.add_child(avb)

	avb.add_child(StudioTheme.make_section_header("내재화 캐릭터 로스터 (28종 GLB/RES)", "character", StudioTheme.TEXT_PRIMARY))

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
	avb.add_child(_char_opt)

	_clip_opt = OptionButton.new()
	_clip_opt.clip_text = true
	_clip_opt.item_selected.connect(func(idx: int):
		if _syncing_ui or not is_instance_valid(_bound_instance) or idx < 0:
			return
		var cname := _clip_opt.get_item_text(idx)
		if _bound_instance.has_method("select_clip"):
			_bound_instance.call("select_clip", cname)
	)
	avb.add_child(_clip_opt)

	# 2-Column Segmented Backend Switcher
	var seg_row := HBoxContainer.new()
	seg_row.add_theme_constant_override("separation", 4)
	avb.add_child(seg_row)

	_btn_float32 = Button.new()
	_btn_float32.text = "Float32 Player"
	_btn_float32.toggle_mode = true
	_btn_float32.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_button(_btn_float32, "tab", StudioTheme.SEMANTIC_INFO)
	_btn_float32.pressed.connect(func(): _set_char_quantized(false))
	seg_row.add_child(_btn_float32)

	_btn_quant16 = Button.new()
	_btn_quant16.text = "16-bit Quantized"
	_btn_quant16.toggle_mode = true
	_btn_quant16.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_button(_btn_quant16, "tab", StudioTheme.ACCENT_TEAL)
	_btn_quant16.pressed.connect(func(): _set_char_quantized(true))
	seg_row.add_child(_btn_quant16)

	# Backend Status Banner (Native C++ vs Web GDScript Fallback)
	_backend_banner = PanelContainer.new()
	StudioTheme.style_banner(_backend_banner, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_DIM)
	avb.add_child(_backend_banner)

	_backend_banner_lbl = Label.new()
	_backend_banner_lbl.text = "백엔드 상태 확인 중..."
	_backend_banner_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_backend_banner_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
	_backend_banner_lbl.add_theme_font_size_override("font_size", 11)
	_backend_banner.add_child(_backend_banner_lbl)

	# 2x2 KPI Metric Cards
	var kpi_grid := GridContainer.new()
	kpi_grid.columns = 2
	kpi_grid.add_theme_constant_override("h_separation", 6)
	kpi_grid.add_theme_constant_override("v_separation", 6)
	_char_box.add_child(kpi_grid)

	_kpi_pos_lbl = _add_kpi_card(kpi_grid, "Max Pos Err", "0.000 mm", StudioTheme.ACCENT_TEAL)
	_kpi_rot_lbl = _add_kpi_card(kpi_grid, "Max Rot Err", "0.000°", StudioTheme.SEMANTIC_INFO)
	_kpi_world_lbl = _add_kpi_card(kpi_grid, "World FK Err", "0.000 mm", StudioTheme.ACCENT_AMBER)
	_kpi_mem_lbl = _add_kpi_card(kpi_grid, "메모리 절감률", "0.0%", StudioTheme.SEMANTIC_SUCCESS)

	# 200-Agent C++ Benchmark Card
	var bench_card := PanelContainer.new()
	StudioTheme.style_section_card(bench_card, StudioTheme.BORDER_NODE, StudioTheme.SURFACE_CARD)
	_char_box.add_child(bench_card)

	var bvb := VBoxContainer.new()
	bvb.add_theme_constant_override("separation", 6)
	bench_card.add_child(bvb)

	var bench_btn := Button.new()
	bench_btn.text = "200-에이전트 C++ 크라우드 벤치마크"
	bench_btn.icon = StudioTheme.get_icon("benchmark", StudioTheme.ACCENT_AMBER_TEXT, 14)
	StudioTheme.style_button(bench_btn, "amber")
	bench_btn.pressed.connect(_on_run_crowd_bench)
	bvb.add_child(bench_btn)

	_char_bench_lbl = Label.new()
	_char_bench_lbl.text = "200-에이전트 병렬 포즈 평가(ms/tick)를 측정합니다."
	_char_bench_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_char_bench_lbl.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	_char_bench_lbl.add_theme_font_size_override("font_size", 11)
	bvb.add_child(_char_bench_lbl)


func _add_kpi_card(parent: GridContainer, title_txt: String, init_val: String, accent: Color) -> Label:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StudioTheme.style_kpi_card(p, accent)
	parent.add_child(p)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	p.add_child(vb)

	var t := Label.new()
	t.text = title_txt
	t.add_theme_color_override("font_color", StudioTheme.TEXT_MUTED)
	t.add_theme_font_size_override("font_size", 10)
	vb.add_child(t)

	var v := Label.new()
	v.text = init_val
	v.add_theme_color_override("font_color", StudioTheme.TEXT_PRIMARY)
	v.add_theme_font_size_override("font_size", 14)
	vb.add_child(v)
	return v


func _update_section_visibility(role: String) -> void:
	_current_role = role
	_empty_box.visible = role.is_empty()
	_hero_box.visible = (role == "hero_arena")
	_quad_box.visible = (role == "quadruped")
	_char_box.visible = (role == "character")


func _update_physics_rule_hint() -> void:
	if _phys_rule_lbl == null:
		return
	var drv := _phys_drive_slider.value
	var imp := _phys_impulse_slider.value
	var bal := _phys_balance_cb.button_pressed
	if not bal or drv < 0.25:
		_phys_rule_lbl.text = "반응 예측: Ragdoll (Balance 해제 또는 Drive < 0.25)"
		_phys_rule_lbl.add_theme_color_override("font_color", StudioTheme.SEMANTIC_DANGER)
	elif drv >= imp:
		_phys_rule_lbl.text = "반응 예측: Balance (Drive %.2f ≥ Impulse %.2f)" % [drv, imp]
		_phys_rule_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
	else:
		_phys_rule_lbl.text = "반응 예측: Stumble (Drive %.2f < Impulse %.2f)" % [drv, imp]
		_phys_rule_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_AMBER_TEXT)


func _commit_physics_patch(values: Dictionary, label_txt: String) -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_motion_authoring"):
		return
	var auth: RefCounted = _bound_instance.call("get_motion_authoring")
	auth.call("apply_user_commands", [{"op": "set_physics", "values": values}], label_txt)
	authoring_changed.emit()


func set_docking_lines_checked(v: bool) -> void:
	if _hero_lines_cb != null:
		_syncing_ui = true
		_hero_lines_cb.button_pressed = v
		_syncing_ui = false


func bind_instance(inst: Node3D) -> void:
	if _hdr_title == null:
		_build_ui()
	_bound_instance = inst
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_state_snapshot"):
		_hdr_title.text = "연결된 인스턴스 없음"
		_hdr_pos_lbl.text = "3D 뷰포트나 계층 도크에서 캐릭터를 선택하세요."
		_hdr_role_pill.text = "미연결"
		_hdr_state_pill.text = "-"
		_update_section_visibility("")
		return

	var snap: Dictionary = _bound_instance.call("get_state_snapshot")
	var role := str(snap.get("role", "character"))
	_update_section_visibility(role)
	_syncing_ui = true
	if role == "hero_arena":
		_hdr_role_pill.text = "Hero + AI"
		StudioTheme.style_pill_label(_hdr_role_pill, StudioTheme.ACCENT_AMBER_DIM, StudioTheme.ACCENT_AMBER, StudioTheme.ACCENT_AMBER_TEXT)
		_hero_auto_cb.button_pressed = bool(snap.get("auto_demo", true))
		_hero_ai_cb.button_pressed = bool(snap.get("ai_driven", false))
		_hero_obs_cb.button_pressed = bool(snap.get("ai_dynamic_obstacle", false))
		_sync_hero_cost_and_flags(snap)
		_sync_physics_from_authoring()
	elif role == "quadruped":
		_hdr_role_pill.text = "Quadruped"
		StudioTheme.style_pill_label(_hdr_role_pill, StudioTheme.ACCENT_TEAL_DIM, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_TEXT)
		_quad_auto_cb.button_pressed = bool(snap.get("auto_demo", true))
		var qspd := float(snap.get("quad_speed", 2.6))
		_quad_speed_slider.value = qspd
		_quad_speed_lbl.text = "%.2f m/s" % qspd
		var qg := str(snap.get("quad_gait", "auto"))
		for k in _quad_gait_btns.keys():
			(_quad_gait_btns[k] as Button).set_pressed_no_signal(k == qg)
	else:
		_hdr_role_pill.text = "Character"
		StudioTheme.style_pill_label(_hdr_role_pill, Color("#19273b"), StudioTheme.SEMANTIC_INFO, Color("#99c7ff"))
		var cid := str(snap.get("character_id", "soldier"))
		var idx := _char_ids.find(cid)
		if idx >= 0:
			_char_opt.select(idx)
		var q16 := bool(snap.get("use_quantized_16bit", false))
		_btn_float32.set_pressed_no_signal(not q16)
		_btn_quant16.set_pressed_no_signal(q16)
		_refresh_clip_options()
	_syncing_ui = false
	update_live()


func _sync_hero_cost_and_flags(snap: Dictionary) -> void:
	var cm := str(snap.get("ai_cost_mode", PathfinderScript.COST_PARKOUR_EXPRESS))
	match cm:
		PathfinderScript.COST_SHORTEST: _hero_cost_opt.select(0)
		PathfinderScript.COST_PREFER_HIGH: _hero_cost_opt.select(1)
		PathfinderScript.COST_TACTICAL_COVER: _hero_cost_opt.select(2)
		_: _hero_cost_opt.select(3)
	var flags := int(snap.get("ai_allowed_flags", SpatialScript.FLAG_ALL))
	for bit in _hero_flag_chips.keys():
		(_hero_flag_chips[bit] as Button).set_pressed_no_signal((flags & int(bit)) != 0)


func _sync_physics_from_authoring() -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("get_motion_authoring"):
		return
	var auth: RefCounted = _bound_instance.call("get_motion_authoring")
	var st: Dictionary = auth.call("motion_read_state")
	var doc: Dictionary = st.get("selected_document", {}) as Dictionary
	var phys: Dictionary = doc.get("physics", {}) as Dictionary
	_phys_drive_slider.value = float(phys.get("strength", 0.65))
	_phys_drive_lbl.text = "Drive Strength: %.2f" % _phys_drive_slider.value
	_phys_limit_slider.value = float(phys.get("limit", 45))
	_phys_limit_lbl.text = "Joint Limit: %d°" % int(_phys_limit_slider.value)
	_phys_balance_cb.button_pressed = bool(phys.get("balance", true))
	_phys_impulse_slider.value = float(phys.get("impulse", 0.40))
	_phys_impulse_lbl.text = "Impulse: %.2f" % _phys_impulse_slider.value
	_update_physics_rule_hint()


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
	_hdr_state_pill.text = str(snap.get("active_state", "Idle"))
	_hdr_pos_lbl.text = "X: %+.2f  Y: %+.2f  Z: %+.2f m  |  %s" % [wp.x, wp.y, wp.z, str(snap.get("active_clip", ""))]

	if role == "hero_arena":
		var dock: Dictionary = snap.get("dock_target", {})
		var dock_str := "#%d (type=%d)" % [int(dock.get("index", -1)), int(dock.get("line_type", -1))] if int(dock.get("index", -1)) >= 0 else "없음"
		_hero_status_lbl.text = "상태: %s · 최근 이벤트: %s\n카메라: %s · 도킹 라인: %s" % [
			str(snap.get("active_state", "Idle")),
			str(snap.get("last_event", "-")),
			str(snap.get("cam_mode", "follow")),
			dock_str,
		]
		var aitel: Dictionary = snap.get("ai_telemetry", {})
		if bool(snap.get("ai_driven", false)) and not aitel.is_empty():
			var next_st := str(snap.get("next_ai_state", ""))
			var next_tag := " · 다음=%s" % next_st if not next_st.is_empty() else ""
			_hero_ai_lbl.text = "%s (%d/%d)\n구간: %s%s · 거리: %.1fm · A*: %.2fms" % [
				str(aitel.get("goal_label", "")),
				int(aitel.get("waypoint_idx", 1)), int(aitel.get("waypoint_total", 1)),
				str(aitel.get("seg_type", "Walk")), next_tag,
				float(aitel.get("path_len_m", 0.0)), float(aitel.get("path_ms", 0.0)),
			]
			var cov: Dictionary = aitel.get("coverage", {})
			var cov_cnt := int(aitel.get("covered_count", 0))
			var cov_tot := int(aitel.get("coverage_total", 12))
			_hero_cov_count_lbl.text = "%d / %d" % [cov_cnt, cov_tot]
			if cov_cnt >= cov_tot:
				StudioTheme.style_pill_label(_hero_cov_count_lbl, StudioTheme.SEMANTIC_SUCCESS_DIM, StudioTheme.SEMANTIC_SUCCESS, Color("#98f5c7"))
			else:
				StudioTheme.style_pill_label(_hero_cov_count_lbl, StudioTheme.ACCENT_TEAL_DIM, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_TEXT)
			for ck in _hero_cov_pills.keys():
				var pl: Label = _hero_cov_pills[ck] as Label
				var hit := bool(cov.get(ck, false))
				if hit:
					StudioTheme.style_pill_label(pl, StudioTheme.ACCENT_TEAL_DIM, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_TEXT)
				else:
					StudioTheme.style_pill_label(pl, StudioTheme.SURFACE_NODE, StudioTheme.BORDER_BASE, StudioTheme.TEXT_DIM)
		var vars: Dictionary = snap.get("variables", {})
		var lines := PackedStringArray()
		for k in ["CharacterSpeed", "Direction", "SwordEquipped", "CoverEdgeAngle", "VaultHeight", "ClimbHeight", "LeapDistance"]:
			if vars.has(k):
				var v = vars[k]
				lines.append("• %s: %s" % [k, "%.2f" % float(v) if (v is float or v is int) else str(v)])
		_hero_vars_lbl.text = "\n".join(lines)
	elif role == "quadruped":
		var feet: Dictionary = snap.get("feet", {})
		for leg in ["FL", "FR", "HL", "HR"]:
			var f: Dictionary = feet.get(leg, {})
			var planted := bool(f.get("planted", true))
			var entry: Dictionary = _quad_foot_panels[leg] as Dictionary
			StudioTheme.style_foot_card(entry["panel"] as PanelContainer, planted)
			var sl: Label = entry["status_lbl"] as Label
			sl.text = "● PLANTED" if planted else "○ SWING"
			sl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT if planted else StudioTheme.ACCENT_AMBER_TEXT)
		_quad_telemetry_lbl.text = "보행: %s · 실속도: %.2f m/s\nPelvis Y: %.3fm · Pitch: %+.1f° · Roll: %+.1f°\n접지 발: %d/4 · 최대 슬립: %.2f mm" % [
			str(snap.get("active_state", "idle")).to_upper(),
			float(snap.get("actual_speed", 0.0)),
			float(snap.get("pelvis_y", 0.78)),
			float(snap.get("pelvis_pitch_deg", 0.0)),
			float(snap.get("pelvis_roll_deg", 0.0)),
			int(snap.get("planted_count", 4)),
			float(snap.get("foot_slip_mm", 0.0)),
		]
	else:
		var native_ok := bool(snap.get("native_gdextension_active", false))
		if native_ok:
			StudioTheme.style_banner(_backend_banner, StudioTheme.ACCENT_TEAL, StudioTheme.ACCENT_TEAL_DIM)
			_backend_banner_lbl.text = "● C++ Native GDExtension 8-Thread 활성 (로컬 포크 엔진)"
			_backend_banner_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_TEAL_TEXT)
		else:
			StudioTheme.style_banner(_backend_banner, StudioTheme.ACCENT_AMBER, StudioTheme.ACCENT_AMBER_DIM)
			_backend_banner_lbl.text = "▲ Web · GDScript 16-bit 폴백 (C++ DLL은 로컬 포크에서 활성)"
			_backend_banner_lbl.add_theme_color_override("font_color", StudioTheme.ACCENT_AMBER_TEXT)

		var cmp: Dictionary = snap.get("compare", {})
		if not cmp.is_empty():
			_kpi_pos_lbl.text = "%.3f mm" % float(cmp.get("max_pos_mm", 0.0))
			_kpi_rot_lbl.text = "%.3f°" % float(cmp.get("max_rot_deg", 0.0))
			_kpi_world_lbl.text = "%.3f mm" % float(cmp.get("max_world_mm", 0.0))
			_kpi_mem_lbl.text = "%.1f%% (%.0f KB)" % [float(cmp.get("saving_pct", 0.0)), float(cmp.get("resident_kb", 0.0))]


func _trigger_hero_scenario(sid: String) -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("trigger_hero_scenario"):
		return
	_bound_instance.set("auto_demo", false)
	_syncing_ui = true
	_hero_auto_cb.button_pressed = false
	_hero_ai_cb.button_pressed = false
	_syncing_ui = false
	_bound_instance.call("trigger_hero_scenario", sid)
	update_live()


func _raise_hero_event(ename: String) -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("raise_hero_event"):
		return
	_bound_instance.set("auto_demo", false)
	_syncing_ui = true
	_hero_auto_cb.button_pressed = false
	_hero_ai_cb.button_pressed = false
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


func _set_char_quantized(enabled: bool) -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("set_use_quantized_16bit"):
		return
	_bound_instance.call("set_use_quantized_16bit", enabled)
	_btn_float32.set_pressed_no_signal(not enabled)
	_btn_quant16.set_pressed_no_signal(enabled)
	update_live()


func _on_run_crowd_bench() -> void:
	if not is_instance_valid(_bound_instance) or not _bound_instance.has_method("run_crowd_benchmark_200"):
		return
	var res: Dictionary = _bound_instance.call("run_crowd_benchmark_200")
	if res.is_empty():
		_char_bench_lbl.text = "벤치마크 실행 불가 (클립 없음)"
		return
	_char_bench_lbl.text = "200 Agents × %d bones/tick → %.3f ms/tick (%s)" % [
		int(res.get("bones_per_tick", 0)),
		float(res.get("ms", 0.0)),
		"C++ Native 8T" if bool(res.get("native", false)) else "GDScript Fallback",
	]
