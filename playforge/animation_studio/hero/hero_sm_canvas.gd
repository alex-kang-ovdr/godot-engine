@tool
extends Control
## NaturalMotion Morpheme Connect-style Animation Network Graph Canvas.
## Renders Control Parameter nodes, the LocomotionSM State Machine group box,
## CameraLead & TwoBone Foot IK pose modifiers, and Output Pose sink with
## curved cubic Bezier pose/parameter wires, live flow pulses, and exact node rects
## for interactive selection and virtual-pointer targeting.

signal node_selected(node_id: String)

const BG_GRID := Color("#13171d")
const GRID_MINOR := Color("#1b212a")
const GRID_MAJOR := Color("#232b36")
const GROUP_BG := Color("#181e27cc")
const GROUP_BORDER := Color("#334054")
const NODE_LOCKED := Color("#1a1f27")
const NODE_IDLE := Color("#222833")
const NODE_HEADER_IDLE := Color("#2b3342")
const ACCENT_STATE := Color("#2cc7b8")
const ACCENT_ACTIVE_FLOW := Color("#f39c2b")
const ACCENT_CP := Color("#9b72f2")
const ACCENT_IK := Color("#4ca3f7")
const ACCENT_OUT := Color("#4ad689")
const EDGE_LOCKED := Color("#2d3645")
const EDGE_READY := Color("#55667d")
const TEXT_LIGHT := Color("#edf3fa")
const TEXT_DIM := Color("#8898ad")
const TEXT_DARK := Color("#10161e")

var build_stage: int = 5
var frame_info: Dictionary = {}
var selected_node_id: String = ""
var _pulse: float = 0.0
var _node_rects: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func _process(delta: float) -> void:
	_pulse += delta * 2.2
	if is_visible_in_tree():
		queue_redraw()


func set_display(stage: int, info: Dictionary) -> void:
	build_stage = clampi(stage, 1, 5)
	frame_info = info
	queue_redraw()


func set_selected_node(node_id: String) -> void:
	selected_node_id = node_id
	queue_redraw()


func get_node_rect(node_key: String) -> Rect2:
	if _node_rects.is_empty():
		_compute_layout()
	return _node_rects.get(node_key, Rect2(Vector2(20, 20), Vector2(120, 48)))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var pos: Vector2 = event.position
		for k in _node_rects:
			if k == "sm_group":
				continue
			var r: Rect2 = _node_rects[k]
			if r.has_point(pos):
				selected_node_id = k
				node_selected.emit(k)
				queue_redraw()
				accept_event()
				return


func _compute_layout() -> void:
	var w := maxf(size.x, 360.0)
	var h := maxf(size.y, 220.0)
	var pad_x := 10.0
	var top_y := 32.0
	var avail_w := maxf(300.0, w - pad_x * 2.0)
	var avail_h := maxf(170.0, h - top_y - 12.0)

	# Strictly fit all 3 Morpheme columns inside avail_w with zero right-edge clipping
	var gap := clampf(avail_w * 0.03, 10.0, 20.0)
	var rem := avail_w - gap * 2.0
	var cp_w := rem * 0.22
	var out_w := rem * 0.27
	var sm_w := rem - cp_w - out_w

	var x_cp := pad_x
	var x_sm := x_cp + cp_w + gap
	var x_out := x_sm + sm_w + gap

	# Left Control Parameter nodes
	var cp_h := clampf(avail_h * 0.44, 64.0, 106.0)
	_node_rects["cp_stick"] = Rect2(x_cp, top_y + 8.0, cp_w, cp_h)
	_node_rects["cp_walk"] = Rect2(x_cp, top_y + cp_h + 22.0, cp_w, clampf(avail_h * 0.28, 46.0, 70.0))

	# Center LocomotionSM State Machine group
	var sm_group := Rect2(x_sm, top_y, sm_w, avail_h)
	_node_rects["sm_group"] = sm_group
	var inner_pad := 10.0
	var col_gap := 14.0
	var row_gap := clampf(avail_h * 0.14, 22.0, 42.0)
	var card_w := maxf(68.0, (sm_w - inner_pad * 2.0 - col_gap) * 0.5)
	var card_h := clampf((avail_h - 42.0 - row_gap) * 0.5, 44.0, 70.0)
	var y_r1 := sm_group.position.y + 28.0
	var y_r2 := y_r1 + card_h + row_gap
	var x_c1 := sm_group.position.x + inner_pad
	var x_c2 := x_c1 + card_w + col_gap

	_node_rects["sm_idle"] = Rect2(x_c1, y_r1, card_w, card_h)
	_node_rects["sm_i2w"] = Rect2(x_c2, y_r1, card_w, card_h)
	_node_rects["sm_walk"] = Rect2(x_c2, y_r2, card_w, card_h)
	_node_rects["sm_run"] = Rect2(x_c1, y_r2, card_w, card_h)

	# Right Pose Modifier Chain (CameraLead -> Foot IK -> Output Pose)
	var chain_h := clampf((avail_h - 28.0) / 3.0, 44.0, 68.0)
	var chain_gap := clampf((avail_h - chain_h * 3.0) * 0.5, 8.0, 20.0)
	_node_rects["sm_cam"] = Rect2(x_out, top_y + 4.0, out_w, chain_h)
	_node_rects["sm_ik"] = Rect2(x_out, top_y + 4.0 + chain_h + chain_gap, out_w, chain_h)
	_node_rects["out_pose"] = Rect2(x_out, top_y + 4.0 + (chain_h + chain_gap) * 2.0, out_w, chain_h)


func _draw() -> void:
	_compute_layout()
	var font := get_theme_default_font()

	# 1. Morpheme Dark Blueprint Grid
	draw_rect(Rect2(Vector2.ZERO, size), BG_GRID, true)
	var step_minor := 24.0
	var x := 0.0
	while x < size.x:
		var is_major := int(round(x / step_minor)) % 5 == 0
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), GRID_MAJOR if is_major else GRID_MINOR, 1.0)
		x += step_minor
	var y := 0.0
	while y < size.y:
		var is_major := int(round(y / step_minor)) % 5 == 0
		draw_line(Vector2(0.0, y), Vector2(size.x, y), GRID_MAJOR if is_major else GRID_MINOR, 1.0)
		y += step_minor

	# Top Network Breadcrumb Header Bar
	draw_rect(Rect2(0.0, 0.0, size.x, 26.0), Color("#1b2029ee"), true)
	draw_line(Vector2(0.0, 26.0), Vector2(size.x, 26.0), Color("#2d3646"), 1.0)

	var state: String = str(frame_info.get("state", "idle"))
	var clip_name: String = str(frame_info.get("clip", "idle"))
	var blend_w: float = float(frame_info.get("outgoing_weight", 0.0))
	var blend_from: String = str(frame_info.get("outgoing_state", ""))
	var stick: Vector2 = frame_info.get("stick", Vector2.ZERO)
	var walk_mod: bool = bool(frame_info.get("walk_modifier", false))
	var cam_deg: float = float(frame_info.get("camera_lead_deg", 0.0))
	var ik_hits: int = int(frame_info.get("ik_hits", 0))
	var ik_mm: float = float(frame_info.get("ik_offset_mm", 0.0))

	if font != null:
		draw_string(font, Vector2(10.0, 17.0), "Network  /  HeroRoot  /  LocomotionSM", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, TEXT_LIGHT)
		var status_str := "Active: %s  |  Clip: %s  |  %s" % [
			state.to_upper(),
			clip_name,
			("Blend %.0f%%" % ((1.0 - blend_w) * 100.0)) if blend_w > 0.01 else "Steady",
		]
		var sw := font.get_string_size(status_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(font, Vector2(maxf(250.0, size.x - sw - 12.0), 17.0), status_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			ACCENT_ACTIVE_FLOW if blend_w > 0.01 else ACCENT_STATE)

	var s2 := build_stage >= 2
	var s3 := build_stage >= 3
	var s4 := build_stage >= 4

	var r_cp_stick: Rect2 = _node_rects["cp_stick"]
	var r_cp_walk: Rect2 = _node_rects["cp_walk"]
	var r_sm_group: Rect2 = _node_rects["sm_group"]
	var r_idle: Rect2 = _node_rects["sm_idle"]
	var r_i2w: Rect2 = _node_rects["sm_i2w"]
	var r_walk: Rect2 = _node_rects["sm_walk"]
	var r_run: Rect2 = _node_rects["sm_run"]
	var r_cam: Rect2 = _node_rects["sm_cam"]
	var r_ik: Rect2 = _node_rects["sm_ik"]
	var r_out: Rect2 = _node_rects["out_pose"]

	# 2. LocomotionSM Group Box
	draw_rect(r_sm_group, GROUP_BG, true)
	draw_rect(Rect2(r_sm_group.position, Vector2(r_sm_group.size.x, 22.0)), Color("#232c3aee"), true)
	draw_rect(r_sm_group, GROUP_BORDER, false, 1.5)
	if font != null:
		draw_string(font, r_sm_group.position + Vector2(10.0, 15.0),
			"State Machine : LocomotionSM  (Stage %d/5)" % build_stage, HORIZONTAL_ALIGNMENT_LEFT, r_sm_group.size.x - 16.0, 11, Color("#b6c6dc"))

	# 3. Bezier Wires: Control Parameters -> LocomotionSM
	var stick_active := stick.length_squared() > 0.01
	_draw_bezier_wire(
		Vector2(r_cp_stick.end.x, r_cp_stick.get_center().y),
		Vector2(r_sm_group.position.x, r_sm_group.position.y + r_sm_group.size.y * 0.34),
		ACCENT_CP if stick_active else EDGE_READY, stick_active, true
	)
	_draw_bezier_wire(
		Vector2(r_cp_walk.end.x, r_cp_walk.get_center().y),
		Vector2(r_sm_group.position.x, r_sm_group.position.y + r_sm_group.size.y * 0.68),
		ACCENT_CP if walk_mod else EDGE_READY, walk_mod, true
	)

	# 4. State Transition Edges inside LocomotionSM
	_draw_transition(
		Vector2(r_idle.end.x, r_idle.get_center().y),
		Vector2(r_i2w.position.x, r_i2w.get_center().y),
		s2, state == "idle_to_walk" and blend_from == "idle" and blend_w > 0.01, "4t", font
	)
	_draw_transition(
		Vector2(r_i2w.get_center().x, r_i2w.end.y),
		Vector2(r_walk.get_center().x, r_walk.position.y),
		s2, state == "walk" and blend_from == "idle_to_walk" and blend_w > 0.01, "26t", font
	)
	_draw_transition(
		Vector2(r_walk.position.x, r_walk.get_center().y),
		Vector2(r_run.end.x, r_run.get_center().y),
		s3, state == "run" and blend_from == "walk" and blend_w > 0.01, "4t", font
	)
	_draw_transition(
		Vector2(r_run.get_center().x, r_run.position.y),
		Vector2(r_idle.get_center().x, r_idle.end.y),
		s3, state == "idle" and blend_from == "run" and blend_w > 0.01, "10t", font
	)

	# 5. Pose Pipeline Wires: LocomotionSM -> CameraLead -> TwoBone Foot IK -> Output Pose
	var sm_out_pin := Vector2(r_sm_group.end.x, r_sm_group.position.y + r_sm_group.size.y * 0.5)
	_draw_bezier_wire(sm_out_pin, Vector2(r_cam.position.x, r_cam.get_center().y),
		ACCENT_ACTIVE_FLOW if s3 else EDGE_READY, s3, false)
	_draw_bezier_wire(Vector2(r_cam.get_center().x, r_cam.end.y), Vector2(r_ik.get_center().x, r_ik.position.y),
		ACCENT_IK if s4 else EDGE_READY, s4, false, true)
	_draw_bezier_wire(Vector2(r_ik.get_center().x, r_ik.end.y), Vector2(r_out.get_center().x, r_out.position.y),
		ACCENT_OUT, true, false, true)

	# 6. Draw Control Parameter Nodes
	_draw_cp_stick_node(font, r_cp_stick, stick, stick_active)
	_draw_morpheme_node(font, "cp_walk", r_cp_walk, "CP: WalkTrigger",
		"LT: %s" % ("ON (Walk)" if walk_mod else "OFF (Run)"),
		true, walk_mod, ACCENT_CP, false, true)

	# 7. Draw State Machine Nodes
	_draw_morpheme_node(font, "sm_idle", r_idle, "1. Idle", "clip: idle", true, state == "idle", ACCENT_STATE, true, true)
	_draw_morpheme_node(font, "sm_i2w", r_i2w, "2. Idle→Walk", "clip: idle_to_walk", s2, state == "idle_to_walk", ACCENT_STATE, true, true)
	_draw_morpheme_node(font, "sm_walk", r_walk, "2. Walking", "clip: walk", s2, state == "walk", ACCENT_STATE, true, true)
	_draw_morpheme_node(font, "sm_run", r_run, "3. Running", "clip: run", s3, state == "run", ACCENT_STATE, true, true)

	# 8. Draw Pose Modifier Chain & Output Pose Sink
	var cam_sub := "Lead %+.1f°" % cam_deg if s3 else "Stage 3 잠금"
	_draw_morpheme_node(font, "sm_cam", r_cam, "3. CameraLead", cam_sub, s3, s3 and absf(cam_deg) > 0.4, ACCENT_ACTIVE_FLOW, true, true)
	var ik_sub := "접지 %d/2 · %.1fmm" % [ik_hits, ik_mm] if s4 else "Stage 4 잠금"
	_draw_morpheme_node(font, "sm_ik", r_ik, "4. TwoBone Foot IK", ik_sub, s4, s4 and ik_hits > 0, ACCENT_IK, true, true)
	_draw_morpheme_node(font, "out_pose", r_out, "Output Pose", "85 Bones · 60 Hz", true, true, ACCENT_OUT, true, false)

	# Blend bar inside SM group bottom when blending
	if font != null and blend_w > 0.01:
		var bw := minf(160.0, r_sm_group.size.x - 24.0)
		var bar := Rect2(r_sm_group.get_center().x - bw * 0.5, r_sm_group.end.y - 12.0, bw, 6.0)
		draw_rect(bar, Color("#11161d"), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * (1.0 - blend_w), bar.size.y)), ACCENT_ACTIVE_FLOW, true)


func _draw_cp_stick_node(font: Font, rect: Rect2, stick: Vector2, active: bool) -> void:
	var header_h := 20.0
	var is_sel := selected_node_id == "cp_stick"
	draw_rect(rect, NODE_IDLE, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, header_h)), ACCENT_CP if active else Color("#352c4d"), true)
	draw_rect(rect, Color("#ffffff") if is_sel else (ACCENT_CP if active else EDGE_READY), false, 2.0 if is_sel or active else 1.2)
	if font != null:
		draw_string(font, rect.position + Vector2(7.0, 14.0), "CP: MoveStick", HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 14.0, 11,
			TEXT_DARK if active else TEXT_LIGHT)
	# Mini vector joystick inside CP node
	var pad_r := minf((rect.size.y - header_h - 14.0) * 0.48, 26.0)
	var cx := rect.position.x + pad_r + 12.0
	var cy := rect.position.y + header_h + (rect.size.y - header_h) * 0.5
	draw_circle(Vector2(cx, cy), pad_r, Color("#12161d"))
	draw_arc(Vector2(cx, cy), pad_r, 0.0, TAU, 28, EDGE_READY, 1.2, true)
	draw_line(Vector2(cx - pad_r, cy), Vector2(cx + pad_r, cy), GRID_MAJOR, 1.0)
	draw_line(Vector2(cx, cy - pad_r), Vector2(cx, cy + pad_r), GRID_MAJOR, 1.0)
	var dot := Vector2(cx + stick.x * (pad_r - 4.0), cy - stick.y * (pad_r - 4.0))
	draw_line(Vector2(cx, cy), dot, ACCENT_ACTIVE_FLOW, 2.0, true)
	draw_circle(dot, 4.0, ACCENT_ACTIVE_FLOW)
	if font != null and rect.size.x > 110.0:
		var tx := cx + pad_r + 8.0
		draw_string(font, Vector2(tx, cy - 3.0), "X:%+.1f" % stick.x, HORIZONTAL_ALIGNMENT_LEFT, 54.0, 10, TEXT_DIM)
		draw_string(font, Vector2(tx, cy + 11.0), "Y:%+.1f" % stick.y, HORIZONTAL_ALIGNMENT_LEFT, 54.0, 10, TEXT_DIM)
	# Output CP diamond pin
	_draw_diamond(Vector2(rect.end.x, rect.get_center().y), 4.5, ACCENT_CP)


func _draw_morpheme_node(font: Font, node_id: String, rect: Rect2, title: String, subtitle: String,
		unlocked: bool, active: bool, accent: Color, has_in_pin: bool, has_out_pin: bool) -> void:
	var header_h := 20.0
	var is_sel := selected_node_id == node_id
	var body_col := NODE_IDLE if unlocked else NODE_LOCKED
	var head_col := accent if (unlocked and active) else (NODE_HEADER_IDLE if unlocked else Color("#1c222c"))
	draw_rect(rect, body_col, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, header_h)), head_col, true)
	if unlocked and active:
		draw_rect(rect.grow(1.5), Color(accent.r, accent.g, accent.b, 0.16), true)
	var border_col := Color("#ffffff") if is_sel else (accent if (unlocked and active) else (EDGE_READY if unlocked else EDGE_LOCKED))
	draw_rect(rect, border_col, false, 2.0 if (is_sel or active) else 1.2)
	if has_in_pin:
		draw_circle(Vector2(rect.position.x, rect.get_center().y), 3.8, accent if active else EDGE_READY)
	if has_out_pin:
		draw_circle(Vector2(rect.end.x, rect.get_center().y), 3.8, accent if active else EDGE_READY)
	if font != null:
		var title_col := TEXT_DARK if (unlocked and active) else (TEXT_LIGHT if unlocked else TEXT_DIM)
		var sub_col := TEXT_LIGHT if (unlocked and active) else TEXT_DIM
		draw_string(font, rect.position + Vector2(8.0, 14.0), title, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 14.0, 11, title_col)
		draw_string(font, rect.position + Vector2(8.0, header_h + minf(20.0, (rect.size.y - header_h) * 0.65)),
			subtitle, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 14.0, 11, sub_col)


func _draw_transition(from_pt: Vector2, to_pt: Vector2, unlocked: bool, active: bool, tag: String, font: Font) -> void:
	var col := ACCENT_ACTIVE_FLOW if active else (EDGE_READY if unlocked else EDGE_LOCKED)
	var width := 2.8 if active else 1.5
	draw_line(from_pt, to_pt, col, width, true)
	var dir := (to_pt - from_pt).normalized()
	var perp := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([to_pt, to_pt - dir * 8.0 + perp * 4.5, to_pt - dir * 8.0 - perp * 4.5]), col)
	if active:
		var u := fposmod(_pulse, 1.0)
		draw_circle(from_pt.lerp(to_pt, u), 4.0, Color("#fff3d1"))
	if font != null and unlocked:
		var mid := (from_pt + to_pt) * 0.5
		draw_rect(Rect2(mid.x - 12.0, mid.y - 8.0, 24.0, 14.0), Color("#131820dd"), true)
		draw_string(font, mid + Vector2(-9.0, 3.0), tag, HORIZONTAL_ALIGNMENT_LEFT, 24.0, 10,
			ACCENT_ACTIVE_FLOW if active else TEXT_DIM)


func _draw_bezier_wire(a: Vector2, b: Vector2, col: Color, active: bool, is_param: bool, vertical := false) -> void:
	var c1: Vector2
	var c2: Vector2
	if vertical:
		var dy := maxf(14.0, absf(b.y - a.y) * 0.5)
		c1 = a + Vector2(0.0, dy)
		c2 = b - Vector2(0.0, dy)
	else:
		var dx := maxf(18.0, absf(b.x - a.x) * 0.45)
		c1 = a + Vector2(dx, 0.0)
		c2 = b - Vector2(dx, 0.0)
	var pts := PackedVector2Array()
	var segs := 16
	for i in segs + 1:
		var t := float(i) / float(segs)
		pts.append(_cubic_bezier(a, c1, c2, b, t))
	draw_polyline(pts, col, 2.4 if active else 1.4, true)
	if active:
		var u := fposmod(_pulse * (0.75 if is_param else 1.0), 1.0)
		draw_circle(_cubic_bezier(a, c1, c2, b, u), 3.4, Color("#ffffff") if not is_param else Color("#e2d0ff"))


func _cubic_bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var mt := 1.0 - t
	return mt * mt * mt * p0 + 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t * p3


func _draw_diamond(center: Vector2, r: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -r),
		center + Vector2(r, 0.0),
		center + Vector2(0.0, r),
		center + Vector2(-r, 0.0),
	]), col)
