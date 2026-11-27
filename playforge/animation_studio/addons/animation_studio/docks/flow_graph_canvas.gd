@tool
extends Control
## Interactive Morpheme / AnimationTree-style Bezier Animation Flow Graph Canvas (Design v3).
## Implements all 5 node states from design-tokens.json:
##   - default, hover, active (left 4px amber accent bar + top-right amber dot + teal border),
##     ai_planned_next (dashed amber border + "AI 예정" badge), and arrowheads + blend durations.

const StudioTheme := preload("res://addons/animation_studio/ui/studio_theme.gd")

signal node_clicked(node_id: String)

var _role: String = "hero_arena"
var _active_node_id: String = "Idle"
var _next_ai_node_id: String = ""
var _sub_label: String = ""
var _transition_durations: Dictionary = {} # "From->To" -> float
var _nodes: Array[Dictionary] = []
var _edges: Array = []
var _node_rects: Dictionary = {}
var _hover_id: String = ""

var _sb_default: StyleBoxFlat = null
var _sb_hover: StyleBoxFlat = null
var _sb_active: StyleBoxFlat = null
var _sb_ai_next: StyleBoxFlat = null

const HERO_NODES := [
	{"id": "Idle", "label": "Idle", "cat": "LOCOMOTION", "sub": "기본 대기", "pos": Vector2(0.09, 0.50)},
	{"id": "Run", "label": "Run", "cat": "LOCOMOTION", "sub": "로코모션", "pos": Vector2(0.27, 0.24)},
	{"id": "Strafe", "label": "Strafe", "cat": "COMBAT", "sub": "전투 보법", "pos": Vector2(0.27, 0.76)},
	{"id": "Attack", "label": "Attack", "cat": "COMBAT", "sub": "검기 콤보", "pos": Vector2(0.46, 0.76)},
	{"id": "Cover", "label": "Cover", "cat": "TACTICAL", "sub": "엄폐 도킹", "pos": Vector2(0.46, 0.22)},
	{"id": "Jump", "label": "Jump / Fall", "cat": "TRAVERSAL", "sub": "점프·낙하", "pos": Vector2(0.64, 0.50)},
	{"id": "Vault", "label": "Vault", "cat": "TRAVERSAL", "sub": "장애물 넘기", "pos": Vector2(0.82, 0.20)},
	{"id": "Hanging", "label": "Hanging", "cat": "TRAVERSAL", "sub": "난간 매달림", "pos": Vector2(0.81, 0.50)},
	{"id": "ClimbUp", "label": "ClimbUp", "cat": "TRAVERSAL", "sub": "난간 등반", "pos": Vector2(0.95, 0.50)},
	{"id": "Leap", "label": "Leap", "cat": "TRAVERSAL", "sub": "플랫폼 도약", "pos": Vector2(0.82, 0.80)},
]

const HERO_EDGES := [
	["Idle", "Run"], ["Run", "Idle"], ["Idle", "Strafe"], ["Strafe", "Attack"],
	["Idle", "Cover"], ["Run", "Cover"], ["Run", "Jump"], ["Idle", "Jump"],
	["Jump", "Vault"], ["Jump", "Hanging"], ["Hanging", "ClimbUp"], ["Jump", "Leap"],
	["Vault", "Idle"], ["ClimbUp", "Idle"], ["Leap", "Idle"],
]

const QUAD_NODES := [
	{"id": "walk", "label": "Walk", "cat": "GAIT STATE", "sub": "4-Beat Lateral", "pos": Vector2(0.13, 0.20)},
	{"id": "trot", "label": "Trot", "cat": "GAIT STATE", "sub": "Diagonal Pairs", "pos": Vector2(0.13, 0.50)},
	{"id": "pace", "label": "Pace", "cat": "GAIT STATE", "sub": "Ipsilateral", "pos": Vector2(0.13, 0.80)},
	{"id": "gallop", "label": "Gallop", "cat": "GAIT STATE", "sub": "Rotary Sprint", "pos": Vector2(0.35, 0.50)},
	{"id": "foot_lock", "label": "Foot Set", "cat": "IK SOLVER", "sub": "0.0mm World-Lock", "pos": Vector2(0.60, 0.32)},
	{"id": "pelvis_ik", "label": "Pelvis & Spine", "cat": "IK SOLVER", "sub": "Roll/Pitch S-Wave", "pos": Vector2(0.60, 0.72)},
	{"id": "two_bone_ik", "label": "4-Limb 2B IK", "cat": "OUTPUT", "sub": "28본 Skeleton3D", "pos": Vector2(0.87, 0.50)},
]

const QUAD_EDGES := [
	["walk", "foot_lock"], ["trot", "foot_lock"], ["pace", "foot_lock"], ["gallop", "foot_lock"],
	["walk", "pelvis_ik"], ["trot", "pelvis_ik"], ["gallop", "pelvis_ik"],
	["foot_lock", "two_bone_ik"], ["pelvis_ik", "two_bone_ik"],
]

const CHAR_NODES := [
	{"id": "source_res", "label": "Native .res", "cat": "SOURCE", "sub": "내재화 클립", "pos": Vector2(0.13, 0.50)},
	{"id": "float32", "label": "Float32 Player", "cat": "EVALUATOR", "sub": "Godot 표준 평가", "pos": Vector2(0.41, 0.26)},
	{"id": "quant16", "label": "16-bit C++", "cat": "EVALUATOR", "sub": "QuantizedClip", "pos": Vector2(0.41, 0.74)},
	{"id": "parity", "label": "Pose Parity", "cat": "ANALYZER", "sub": "오차·메모리 비교", "pos": Vector2(0.68, 0.50)},
	{"id": "output", "label": "Skeleton3D", "cat": "OUTPUT", "sub": "3D 뷰포트 스키닝", "pos": Vector2(0.89, 0.50)},
]

const CHAR_EDGES := [
	["source_res", "float32"], ["source_res", "quant16"],
	["float32", "parity"], ["quant16", "parity"],
	["parity", "output"],
]


func _init() -> void:
	custom_minimum_size = Vector2(360, 150)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	_sb_default = StudioTheme.make_box(StudioTheme.SURFACE_NODE, StudioTheme.BORDER_NODE, 5, 1, 0, 0)
	_sb_hover = StudioTheme.make_box(StudioTheme.SURFACE_NODE_HOVER, StudioTheme.ACCENT_AMBER, 5, 1, 0, 0)
	_sb_active = StudioTheme.make_box(StudioTheme.SURFACE_NODE_ACTIVE, StudioTheme.ACCENT_TEAL, 5, 2, 0, 0)
	_sb_ai_next = StudioTheme.make_box(Color("#24221d"), Color(0.95, 0.61, 0.17, 0.35), 5, 1, 0, 0)
	_set_graph_for_role("hero_arena")


func _set_graph_for_role(role: String) -> void:
	_role = role
	_nodes.clear()
	_edges.clear()
	match role:
		"hero_arena":
			for n in HERO_NODES:
				_nodes.append(n)
			_edges = HERO_EDGES.duplicate()
		"quadruped":
			for n in QUAD_NODES:
				_nodes.append(n)
			_edges = QUAD_EDGES.duplicate()
		_:
			for n in CHAR_NODES:
				_nodes.append(n)
			_edges = CHAR_EDGES.duplicate()
	queue_redraw()


func set_transition_durations(transitions: Array) -> void:
	_transition_durations.clear()
	for item in transitions:
		if item is Dictionary:
			var d: Dictionary = item as Dictionary
			var key := "%s->%s" % [str(d.get("from", "")), str(d.get("to", ""))]
			_transition_durations[key] = float(d.get("duration", 0.2))
	queue_redraw()


func set_flow_state(role: String, active_state: String, sub_label: String = "", next_ai_state: String = "") -> void:
	var dirty := false
	if role != _role:
		_set_graph_for_role(role)
		dirty = true
	var mapped := active_state
	if role == "hero_arena":
		if active_state in ["Falling", "Jump", "Jumping", "Drop"]:
			mapped = "Jump"
		elif active_state in ["Climb", "ClimbUp", "Climbing"]:
			mapped = "ClimbUp"
		elif active_state in ["Vault", "Vaulting"]:
			mapped = "Vault"
		elif active_state in ["Leaping", "Leap"]:
			mapped = "Leap"
		elif active_state in ["CoverRoll", "Cover"]:
			mapped = "Cover"
	elif role == "character":
		mapped = "quant16" if active_state.find("16-bit") >= 0 else "float32"
	elif role == "quadruped":
		mapped = active_state.to_lower()
	if mapped != _active_node_id or sub_label != _sub_label or next_ai_state != _next_ai_node_id:
		_active_node_id = mapped
		_next_ai_node_id = next_ai_state
		_sub_label = sub_label
		dirty = true
	if dirty:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var prev := _hover_id
		_hover_id = _hit_node((event as InputEventMouseMotion).position)
		if prev != _hover_id:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not _hover_id.is_empty() else Control.CURSOR_ARROW
			queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var hit := _hit_node(mb.position)
			if not hit.is_empty():
				node_clicked.emit(hit)
				accept_event()


func _hit_node(pt: Vector2) -> String:
	for k in _node_rects.keys():
		if (_node_rects[k] as Rect2).has_point(pt):
			return str(k)
	return ""


func _draw_dashed_rect(r: Rect2, col: Color, width: float = 1.6, dash: float = 6.0, gap: float = 4.0) -> void:
	var corners := [
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	]
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var seg_len := a.distance_to(b)
		var dir := (b - a) / maxf(0.001, seg_len)
		var cur := 0.0
		while cur < seg_len:
			var nxt := minf(seg_len, cur + dash)
			draw_line(a + dir * cur, a + dir * nxt, col, width, true)
			cur += dash + gap


func _draw() -> void:
	var sz := size
	if sz.x < 40.0 or sz.y < 40.0:
		return

	# Blueprint dark canvas + subtle 24px grid
	draw_rect(Rect2(Vector2.ZERO, sz), StudioTheme.BG_CANVAS, true)
	var step := 24
	for x in range(0, int(sz.x), step):
		draw_line(Vector2(x, 0), Vector2(x, sz.y), Color(1, 1, 1, 0.035), 1.0)
	for y in range(0, int(sz.y), step):
		draw_line(Vector2(0, y), Vector2(sz.x, y), Color(1, 1, 1, 0.035), 1.0)

	# Compute node rects
	_node_rects.clear()
	var nw := clampf(sz.x * 0.12, 92.0, 140.0)
	var nh := clampf(sz.y * 0.22, 34.0, 44.0)
	var pad_x := nw * 0.56
	var pad_y := nh * 0.56
	for n in _nodes:
		var p: Vector2 = n["pos"]
		var cx := lerpf(pad_x, sz.x - pad_x, p.x)
		var cy := lerpf(pad_y, sz.y - pad_y - 14.0, p.y)
		_node_rects[str(n["id"])] = Rect2(cx - nw * 0.5, cy - nh * 0.5, nw, nh)

	var font := get_theme_default_font()

	# Draw Bezier transition connectors with arrowheads + duration labels
	for e in _edges:
		var a_id := str(e[0])
		var b_id := str(e[1])
		if not _node_rects.has(a_id) or not _node_rects.has(b_id):
			continue
		var ra: Rect2 = _node_rects[a_id]
		var rb: Rect2 = _node_rects[b_id]
		var forward := rb.get_center().x >= ra.get_center().x
		var p0 := Vector2(ra.end.x if forward else ra.position.x, ra.get_center().y)
		var p3 := Vector2(rb.position.x if forward else rb.end.x, rb.get_center().y)
		var dx := maxf(24.0, absf(p3.x - p0.x) * 0.44)
		var p1 := p0 + Vector2(dx if forward else -dx, 0.0)
		var p2 := p3 + Vector2(-dx if forward else dx, 0.0)
		var active_edge := (a_id == _active_node_id or b_id == _active_node_id)
		var ai_edge := (not _next_ai_node_id.is_empty() and b_id == _next_ai_node_id)
		var col := StudioTheme.ACCENT_AMBER if ai_edge else (StudioTheme.ACCENT_TEAL if active_edge else Color("#4a5a72"))
		var width := 2.2 if (active_edge or ai_edge) else 1.25

		var pts := PackedVector2Array()
		for s in 17:
			var t := float(s) / 16.0
			var omt := 1.0 - t
			pts.append(omt * omt * omt * p0 + 3.0 * omt * omt * t * p1 + 3.0 * omt * t * t * p2 + t * t * t * p3)
		draw_polyline(pts, col, width, true)

		# Arrowhead at p3
		var tip := pts[pts.size() - 1]
		var prev_pt := pts[pts.size() - 2]
		var dir := (tip - prev_pt).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var arrow := PackedVector2Array([tip, tip - dir * 6.5 + perp * 3.2, tip - dir * 6.5 - perp * 3.2])
		draw_colored_polygon(arrow, col)

		var tkey := "%s->%s" % [a_id, b_id]
		if font != null and _transition_durations.has(tkey):
			var mid := pts[8]
			draw_string(font, mid + Vector2(-14.0, -4.0), "%.2fs" % float(_transition_durations[tkey]), HORIZONTAL_ALIGNMENT_LEFT, 48.0, 9, StudioTheme.ACCENT_AMBER_TEXT if active_edge else StudioTheme.TEXT_DIM)

	# Draw rounded state nodes
	for n in _nodes:
		var nid := str(n["id"])
		var r: Rect2 = _node_rects[nid]
		var is_active := (nid == _active_node_id)
		var is_hover := (nid == _hover_id)
		var is_ai_next := (not is_active and not _next_ai_node_id.is_empty() and nid == _next_ai_node_id)

		if is_active:
			draw_style_box(_sb_active, r)
			draw_rect(Rect2(r.position + Vector2(1.0, 2.0), Vector2(4.0, r.size.y - 4.0)), StudioTheme.ACCENT_AMBER, true)
			draw_circle(Vector2(r.end.x - 9.0, r.position.y + 9.0), 3.2, StudioTheme.ACCENT_AMBER)
		elif is_ai_next:
			draw_style_box(_sb_ai_next, r)
			_draw_dashed_rect(r, StudioTheme.ACCENT_AMBER, 1.8, 6.0, 4.0)
			if font != null:
				var pill := Rect2(r.end.x - 42.0, r.position.y - 9.0, 40.0, 14.0)
				draw_rect(pill, StudioTheme.ACCENT_AMBER_DIM, true)
				draw_rect(pill, StudioTheme.ACCENT_AMBER, false, 1.0)
				draw_string(font, pill.position + Vector2(4.0, 10.0), "AI 예정", HORIZONTAL_ALIGNMENT_LEFT, 36.0, 9, StudioTheme.ACCENT_AMBER_TEXT)
		elif is_hover:
			draw_style_box(_sb_hover, r)
		else:
			draw_style_box(_sb_default, r)

		if font != null:
			var x_off := 10.0 if is_active else 8.0
			draw_string(font, Vector2(r.position.x + x_off, r.position.y + 10.0), str(n.get("cat", "STATE")), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - x_off - 14.0, 8, StudioTheme.ACCENT_TEAL_TEXT if is_active else StudioTheme.TEXT_DIM)
			draw_string(font, Vector2(r.position.x + x_off, r.position.y + 23.0), str(n["label"]), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - x_off - 8.0, 11, StudioTheme.TEXT_PRIMARY if is_active else StudioTheme.TEXT_SECONDARY)
			draw_string(font, Vector2(r.position.x + x_off, r.position.y + r.size.y - 4.0), str(n["sub"]), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - x_off - 8.0, 9, StudioTheme.ACCENT_TEAL_TEXT if is_active else StudioTheme.TEXT_MUTED)

	if font != null and not _sub_label.is_empty():
		draw_string(font, Vector2(10.0, sz.y - 5.0), _sub_label, HORIZONTAL_ALIGNMENT_LEFT, sz.x - 20.0, 10, StudioTheme.TEXT_MUTED)
