@tool
extends Control
## Interactive Morpheme / AnimationTree-style Bezier Animation Flow Graph Canvas.
## Automatically adapts its node graph to the currently selected 3D instance's
## role (Hero 10-Lua State Machine, Procedural Quadruped Locomotor pipeline, or
## 28-Character Float32 vs 16-bit C++ evaluation pipeline). Clicking a node
## drives the bound 3D character instance live in Godot's standard 3D Viewport.

signal node_clicked(node_id: String)

var _role: String = "hero_arena"
var _active_node_id: String = "Idle"
var _sub_label: String = ""
var _nodes: Array[Dictionary] = []
var _edges: Array = []
var _node_rects: Dictionary = {}
var _hover_id: String = ""

const HERO_NODES := [
	{"id": "Idle", "label": "Idle", "sub": "기본 대기", "pos": Vector2(0.10, 0.48)},
	{"id": "Run", "label": "Run", "sub": "로코모션", "pos": Vector2(0.28, 0.24)},
	{"id": "Strafe", "label": "Strafe", "sub": "전투 보법", "pos": Vector2(0.28, 0.74)},
	{"id": "Attack", "label": "Attack", "sub": "검기 콤보", "pos": Vector2(0.47, 0.74)},
	{"id": "Cover", "label": "Cover", "sub": "엄폐 도킹", "pos": Vector2(0.47, 0.22)},
	{"id": "Jump", "label": "Jump / Fall", "sub": "점프·낙하", "pos": Vector2(0.65, 0.50)},
	{"id": "Vault", "label": "Vault", "sub": "장애물 넘기", "pos": Vector2(0.83, 0.20)},
	{"id": "Hanging", "label": "Hanging", "sub": "난간 매달림", "pos": Vector2(0.83, 0.50)},
	{"id": "ClimbUp", "label": "ClimbUp", "sub": "난간 등반", "pos": Vector2(0.95, 0.50)},
	{"id": "Leap", "label": "Leap", "sub": "플랫폼 도약", "pos": Vector2(0.83, 0.80)},
]

const HERO_EDGES := [
	["Idle", "Run"], ["Run", "Idle"], ["Idle", "Strafe"], ["Strafe", "Attack"],
	["Idle", "Cover"], ["Run", "Cover"], ["Run", "Jump"], ["Idle", "Jump"],
	["Jump", "Vault"], ["Jump", "Hanging"], ["Hanging", "ClimbUp"], ["Jump", "Leap"],
	["Vault", "Idle"], ["ClimbUp", "Idle"], ["Leap", "Idle"],
]

const QUAD_NODES := [
	{"id": "walk", "label": "Walk", "sub": "4-Beat Lateral", "pos": Vector2(0.14, 0.22)},
	{"id": "trot", "label": "Trot", "sub": "Diagonal Pairs", "pos": Vector2(0.14, 0.52)},
	{"id": "pace", "label": "Pace", "sub": "Ipsilateral", "pos": Vector2(0.14, 0.82)},
	{"id": "gallop", "label": "Gallop", "sub": "Rotary Sprint", "pos": Vector2(0.36, 0.52)},
	{"id": "foot_lock", "label": "Foot Set", "sub": "0.0mm World-Lock", "pos": Vector2(0.60, 0.34)},
	{"id": "pelvis_ik", "label": "Pelvis & Spine", "sub": "Roll/Pitch + S-Wave", "pos": Vector2(0.60, 0.72)},
	{"id": "two_bone_ik", "label": "4-Limb 2B IK", "sub": "28본 Skeleton3D", "pos": Vector2(0.86, 0.52)},
]

const QUAD_EDGES := [
	["walk", "foot_lock"], ["trot", "foot_lock"], ["pace", "foot_lock"], ["gallop", "foot_lock"],
	["walk", "pelvis_ik"], ["trot", "pelvis_ik"], ["gallop", "pelvis_ik"],
	["foot_lock", "two_bone_ik"], ["pelvis_ik", "two_bone_ik"],
]

const CHAR_NODES := [
	{"id": "source_res", "label": "Native .res", "sub": "내재화 클립", "pos": Vector2(0.14, 0.50)},
	{"id": "float32", "label": "Float32 Player", "sub": "Godot 표준 평가", "pos": Vector2(0.42, 0.26)},
	{"id": "quant16", "label": "16-bit C++", "sub": "QuantizedClip", "pos": Vector2(0.42, 0.74)},
	{"id": "parity", "label": "Pose Parity", "sub": "오차·메모리 비교", "pos": Vector2(0.68, 0.50)},
	{"id": "output", "label": "Skeleton3D", "sub": "3D 뷰포트 스키닝", "pos": Vector2(0.89, 0.50)},
]

const CHAR_EDGES := [
	["source_res", "float32"], ["source_res", "quant16"],
	["float32", "parity"], ["quant16", "parity"],
	["parity", "output"],
]


func _init() -> void:
	custom_minimum_size = Vector2(360, 140)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
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


func set_flow_state(role: String, active_state: String, sub_label: String = "") -> void:
	var dirty := false
	if role != _role:
		_set_graph_for_role(role)
		dirty = true
	var mapped := active_state
	if role == "hero_arena":
		if active_state in ["Falling", "Jump", "Jumping"]:
			mapped = "Jump"
		elif active_state in ["Climb", "ClimbUp"]:
			mapped = "ClimbUp"
		elif active_state in ["Vault", "Vaulting"]:
			mapped = "Vault"
	elif role == "character":
		mapped = "quant16" if active_state.find("16-bit") >= 0 else "float32"
	elif role == "quadruped":
		mapped = active_state.to_lower()
	if mapped != _active_node_id or sub_label != _sub_label:
		_active_node_id = mapped
		_sub_label = sub_label
		dirty = true
	if dirty:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var prev := _hover_id
		_hover_id = _hit_node(event.position)
		if prev != _hover_id:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not _hover_id.is_empty() else Control.CURSOR_ARROW
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := _hit_node(event.position)
		if not hit.is_empty():
			node_clicked.emit(hit)
			accept_event()


func _hit_node(pt: Vector2) -> String:
	for k in _node_rects.keys():
		if (_node_rects[k] as Rect2).has_point(pt):
			return str(k)
	return ""


func _draw() -> void:
	var sz := size
	if sz.x < 40.0 or sz.y < 40.0:
		return

	# Dark blueprint background
	draw_rect(Rect2(Vector2.ZERO, sz), Color("#151a22"), true)
	var step := 24.0
	for x in range(0, int(sz.x), int(step)):
		draw_line(Vector2(x, 0), Vector2(x, sz.y), Color(1, 1, 1, 0.04), 1.0)
	for y in range(0, int(sz.y), int(step)):
		draw_line(Vector2(0, y), Vector2(sz.x, y), Color(1, 1, 1, 0.04), 1.0)

	# Compute node rects
	_node_rects.clear()
	var nw := clampf(sz.x * 0.115, 86.0, 132.0)
	var nh := clampf(sz.y * 0.22, 34.0, 46.0)
	var pad_x := nw * 0.55
	var pad_y := nh * 0.65
	for n in _nodes:
		var p: Vector2 = n["pos"]
		var cx := lerpf(pad_x, sz.x - pad_x, p.x)
		var cy := lerpf(pad_y, sz.y - pad_y, p.y)
		_node_rects[str(n["id"])] = Rect2(cx - nw * 0.5, cy - nh * 0.5, nw, nh)

	# Draw Bezier transition edges
	for e in _edges:
		var a_id := str(e[0])
		var b_id := str(e[1])
		if not _node_rects.has(a_id) or not _node_rects.has(b_id):
			continue
		var ra: Rect2 = _node_rects[a_id]
		var rb: Rect2 = _node_rects[b_id]
		var p0 := ra.get_center()
		var p3 := rb.get_center()
		var dx := maxf(26.0, absf(p3.x - p0.x) * 0.42)
		var p1 := p0 + Vector2(dx if p3.x >= p0.x else -dx, 0.0)
		var p2 := p3 + Vector2(-dx if p3.x >= p0.x else dx, 0.0)
		var active_edge := (a_id == _active_node_id or b_id == _active_node_id)
		var col := Color("#2cc7b8") if active_edge else Color("#4a5a72")
		var width := 2.2 if active_edge else 1.3
		var pts := PackedVector2Array()
		for s in 17:
			var t := float(s) / 16.0
			var omt := 1.0 - t
			pts.append(omt * omt * omt * p0 + 3.0 * omt * omt * t * p1 + 3.0 * omt * t * t * p2 + t * t * t * p3)
		draw_polyline(pts, col, width, true)

	# Draw state nodes
	var font := get_theme_default_font()
	var fs_title := 12
	var fs_sub := 10
	for n in _nodes:
		var nid := str(n["id"])
		var r: Rect2 = _node_rects[nid]
		var is_active := (nid == _active_node_id)
		var is_hover := (nid == _hover_id)
		var bg := Color("#1c3638") if is_active else (Color("#253042") if is_hover else Color("#1e2430"))
		var border := Color("#2cc7b8") if is_active else (Color("#f39c2b") if is_hover else Color("#3c4a60"))
		draw_rect(r, bg, true)
		draw_rect(r, border, false, 2.2 if is_active else 1.2)
		if is_active:
			draw_rect(Rect2(r.position, Vector2(4.0, r.size.y)), Color("#f39c2b"), true)
		if font != null:
			draw_string(font, Vector2(r.position.x + 8.0, r.position.y + 16.0), str(n["label"]), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 12.0, fs_title, Color("#f2f7ff") if is_active else Color("#d2deee"))
			draw_string(font, Vector2(r.position.x + 8.0, r.position.y + r.size.y - 7.0), str(n["sub"]), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 12.0, fs_sub, Color("#7fd6cc") if is_active else Color("#8ba0ba"))

	if font != null and not _sub_label.is_empty():
		draw_string(font, Vector2(10.0, sz.y - 6.0), _sub_label, HORIZONTAL_ALIGNMENT_LEFT, sz.x - 20.0, 11, Color("#96acc4"))
