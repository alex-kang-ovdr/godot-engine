@tool
extends Control
## NaturalMotion Morpheme-style Control Rig Network Graph for Procedural Quadruped Locomotor
## (modeled after Unreal Engine's Procedural Animation with a Locomotor tutorial).
## Displays Control Parameters (Velocity/Yaw, GaitPreset), Locomotor Node Group
## (Foot Set 0 Front L/R, Foot Set 1 Hind L/R, Gait Scheduler, Pelvis Dynamics),
## and Post-Solve Chain (4-Limb FBIK, Terrain Raycast, Output Pose 28 Bones).

signal node_selected(node_id: String)

const BG_GRID := Color("#13171d")
const GRID_MINOR := Color("#1b212a")
const GRID_MAJOR := Color("#232b36")
const GROUP_BG := Color("#181e27cc")
const GROUP_BORDER := Color("#334054")
const NODE_LOCKED := Color("#1a1f27")
const NODE_IDLE := Color("#222833")
const NODE_HEADER_IDLE := Color("#2b3342")
const ACCENT_GAIT := Color("#2cc7b8")
const ACCENT_FLOW := Color("#f39c2b")
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
			if k == "loco_group":
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
	var top_y := 30.0
	var avail_w := maxf(300.0, w - pad_x * 2.0)
	var avail_h := maxf(166.0, h - top_y - 10.0)

	var gap := clampf(avail_w * 0.03, 10.0, 20.0)
	var rem := avail_w - gap * 2.0
	var cp_w := rem * 0.22
	var out_w := rem * 0.27
	var loco_w := rem - cp_w - out_w

	var x_cp := pad_x
	var x_loco := x_cp + cp_w + gap
	var x_out := x_loco + loco_w + gap

	# Left Control Parameter nodes
	var cp_h := clampf(avail_h * 0.44, 62.0, 102.0)
	_node_rects["cp_vel"] = Rect2(x_cp, top_y + 8.0, cp_w, cp_h)
	_node_rects["cp_gait"] = Rect2(x_cp, top_y + cp_h + 20.0, cp_w, clampf(avail_h * 0.30, 46.0, 72.0))

	# Center Locomotor Node Group (UE Control Rig Locomotor equivalent)
	var loco_group := Rect2(x_loco, top_y, loco_w, avail_h)
	_node_rects["loco_group"] = loco_group
	var inner_pad := 10.0
	var col_gap := 14.0
	var row_gap := clampf(avail_h * 0.12, 18.0, 36.0)
	var card_w := maxf(68.0, (loco_w - inner_pad * 2.0 - col_gap) * 0.5)
	var card_h := clampf((avail_h - 40.0 - row_gap) * 0.5, 44.0, 72.0)
	var y_r1 := loco_group.position.y + 28.0
	var y_r2 := y_r1 + card_h + row_gap
	var x_c1 := loco_group.position.x + inner_pad
	var x_c2 := x_c1 + card_w + col_gap

	_node_rects["loco_front"] = Rect2(x_c1, y_r1, card_w, card_h)
	_node_rects["loco_hind"] = Rect2(x_c2, y_r1, card_w, card_h)
	_node_rects["loco_gait"] = Rect2(x_c1, y_r2, card_w, card_h)
	_node_rects["loco_pelvis"] = Rect2(x_c2, y_r2, card_w, card_h)

	# Right Pose Pipeline: Terrain Raycast -> 4-Limb FBIK -> Output Pose
	var chain_h := clampf((avail_h - 24.0) / 3.0, 42.0, 66.0)
	var chain_gap := clampf((avail_h - chain_h * 3.0) * 0.5, 8.0, 18.0)
	_node_rects["node_terrain"] = Rect2(x_out, top_y + 4.0, out_w, chain_h)
	_node_rects["node_fbik"] = Rect2(x_out, top_y + 4.0 + chain_h + chain_gap, out_w, chain_h)
	_node_rects["node_out"] = Rect2(x_out, top_y + 4.0 + (chain_h + chain_gap) * 2.0, out_w, chain_h)


func _draw() -> void:
	_compute_layout()
	var font := get_theme_default_font()

	# Blueprint Grid
	draw_rect(Rect2(Vector2.ZERO, size), BG_GRID, true)
	var x := 0.0
	while x < size.x:
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), GRID_MAJOR if int(round(x / 24.0)) % 5 == 0 else GRID_MINOR, 1.0)
		x += 24.0
	var y := 0.0
	while y < size.y:
		draw_line(Vector2(0.0, y), Vector2(size.x, y), GRID_MAJOR if int(round(y / 24.0)) % 5 == 0 else GRID_MINOR, 1.0)
		y += 24.0

	# Top Network Breadcrumb
	draw_rect(Rect2(0.0, 0.0, size.x, 24.0), Color("#1b2029ee"), true)
	draw_line(Vector2(0.0, 24.0), Vector2(size.x, 24.0), Color("#2d3646"), 1.0)

	var gait: String = str(frame_info.get("gait", "idle"))
	var speed: float = float(frame_info.get("speed", 0.0))
	var phase: float = float(frame_info.get("cycle_phase", 0.0))
	var pitch_deg: float = float(frame_info.get("pelvis_pitch_deg", 0.0))
	var roll_deg: float = float(frame_info.get("pelvis_roll_deg", 0.0))
	var planted: int = int(frame_info.get("planted_count", 4))
	var slide_mm: float = float(frame_info.get("max_slide_mm", 0.0))
	var feet: Dictionary = frame_info.get("feet", {})

	if font != null:
		draw_string(font, Vector2(10.0, 16.0), "ControlRig  /  Quadruped  /  Locomotor + FBIK", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_LIGHT)
		var st_str := "Gait: %s  |  %.2f m/s  |  Slide %.1fmm" % [gait.to_upper(), speed, slide_mm]
		var sw := font.get_string_size(st_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(font, Vector2(maxf(250.0, size.x - sw - 10.0), 16.0), st_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			ACCENT_FLOW if gait == "gallop" else ACCENT_GAIT)

	var s2 := build_stage >= 2
	var s3 := build_stage >= 3
	var s4 := build_stage >= 4

	var r_cp_vel: Rect2 = _node_rects["cp_vel"]
	var r_cp_gait: Rect2 = _node_rects["cp_gait"]
	var r_group: Rect2 = _node_rects["loco_group"]
	var r_front: Rect2 = _node_rects["loco_front"]
	var r_hind: Rect2 = _node_rects["loco_hind"]
	var r_gait: Rect2 = _node_rects["loco_gait"]
	var r_pelvis: Rect2 = _node_rects["loco_pelvis"]
	var r_terrain: Rect2 = _node_rects["node_terrain"]
	var r_fbik: Rect2 = _node_rects["node_fbik"]
	var r_out: Rect2 = _node_rects["node_out"]

	# Locomotor Node Group Box
	draw_rect(r_group, GROUP_BG, true)
	draw_rect(Rect2(r_group.position, Vector2(r_group.size.x, 22.0)), Color("#232c3aee"), true)
	draw_rect(r_group, GROUP_BORDER, false, 1.5)
	if font != null:
		draw_string(font, r_group.position + Vector2(10.0, 15.0),
			"Control Rig : Locomotor Node  (0 Clips)", HORIZONTAL_ALIGNMENT_LEFT, r_group.size.x - 16.0, 11, Color("#b6c6dc"))

	# Bezier Wires: CPs -> Locomotor Group -> Terrain -> FBIK -> Output
	var moving := speed > 0.1
	_draw_wire(Vector2(r_cp_vel.end.x, r_cp_vel.get_center().y), Vector2(r_group.position.x, r_group.position.y + r_group.size.y * 0.32),
		ACCENT_CP if moving else EDGE_READY, moving, true)
	_draw_wire(Vector2(r_cp_gait.end.x, r_cp_gait.get_center().y), Vector2(r_group.position.x, r_group.position.y + r_group.size.y * 0.68),
		ACCENT_CP if s2 else EDGE_READY, s2, true)

	# Internal links inside Locomotor
	_draw_wire(Vector2(r_gait.get_center().x, r_gait.position.y), Vector2(r_front.get_center().x, r_front.end.y),
		ACCENT_GAIT if moving else EDGE_READY, moving, false, true)
	_draw_wire(Vector2(r_gait.end.x, r_gait.get_center().y), Vector2(r_pelvis.position.x, r_pelvis.get_center().y),
		ACCENT_FLOW if s3 else EDGE_READY, s3, false, false)
	_draw_wire(Vector2(r_hind.get_center().x, r_hind.end.y), Vector2(r_pelvis.get_center().x, r_pelvis.position.y),
		ACCENT_GAIT if s3 else EDGE_READY, s3, false, true)

	# Output chain wires
	var group_out := Vector2(r_group.end.x, r_group.position.y + r_group.size.y * 0.5)
	_draw_wire(group_out, Vector2(r_terrain.position.x, r_terrain.get_center().y),
		ACCENT_IK if s4 else EDGE_READY, s4, false)
	_draw_wire(Vector2(r_terrain.get_center().x, r_terrain.end.y), Vector2(r_fbik.get_center().x, r_fbik.position.y),
		ACCENT_IK if s4 else EDGE_READY, s4, false, true)
	_draw_wire(Vector2(r_fbik.get_center().x, r_fbik.end.y), Vector2(r_out.get_center().x, r_out.position.y),
		ACCENT_OUT, true, false, true)

	# Left CP Nodes
	_draw_vel_node(font, r_cp_vel, speed, phase, moving)
	_draw_node(font, "cp_gait", r_cp_gait, "CP: GaitPreset",
		"Active: %s" % gait.to_upper(), true, moving, ACCENT_CP, false, true)

	# Foot contact statuses for Foot Sets
	var fl_p := bool(feet.get("FL", {}).get("planted", true))
	var fr_p := bool(feet.get("FR", {}).get("planted", true))
	var hl_p := bool(feet.get("HL", {}).get("planted", true))
	var hr_p := bool(feet.get("HR", {}).get("planted", true))

	_draw_footset_node(font, "loco_front", r_front, "Foot Set 0 · Front", "FL", fl_p, "FR", fr_p, true, moving)
	_draw_footset_node(font, "loco_hind", r_hind, "Foot Set 1 · Hind", "HL", hl_p, "HR", hr_p, true, moving)

	var gait_sub := "Phase %.0f%% · %s" % [phase * 100.0, gait]
	_draw_node(font, "loco_gait", r_gait, "Gait Scheduler", gait_sub, true, moving, ACCENT_FLOW, true, true)

	var pelv_sub := "P%+.0f° R%+.0f°" % [pitch_deg, roll_deg] if s3 else "Stage 3 잠금"
	_draw_node(font, "loco_pelvis", r_pelvis, "Pelvis & Spine", pelv_sub, s3, s3 and (absf(pitch_deg) > 1.0 or moving), ACCENT_FLOW, true, true)

	# Right Pose Pipeline
	_draw_node(font, "node_terrain", r_terrain, "Terrain Raycast",
		"Step/Slope 적응" if s4 else "Stage 4 잠금", s4, s4, ACCENT_IK, true, true)
	_draw_node(font, "node_fbik", r_fbik, "4-Limb FBIK",
		"접지 %d/4 · Pole" % planted if s4 else "Stage 4 잠금", s4, s4, ACCENT_IK, true, true)
	_draw_node(font, "node_out", r_out, "Output Pose", "28 Bones · Procedural", true, true, ACCENT_OUT, true, false)


func _draw_vel_node(font: Font, rect: Rect2, speed: float, phase: float, active: bool) -> void:
	var head_h := 19.0
	var is_sel := selected_node_id == "cp_vel"
	draw_rect(rect, NODE_IDLE, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, head_h)), ACCENT_CP if active else Color("#352c4d"), true)
	draw_rect(rect, Color("#ffffff") if is_sel else (ACCENT_CP if active else EDGE_READY), false, 2.0 if (is_sel or active) else 1.2)
	if font != null:
		draw_string(font, rect.position + Vector2(6.0, 13.0), "CP: Velocity", HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10.0, 10,
			TEXT_DARK if active else TEXT_LIGHT)
	# Gait phase clock dial inside CP node
	var r := minf((rect.size.y - head_h - 12.0) * 0.48, 24.0)
	var cx := rect.position.x + r + 10.0
	var cy := rect.position.y + head_h + (rect.size.y - head_h) * 0.5
	draw_circle(Vector2(cx, cy), r, Color("#12161d"))
	draw_arc(Vector2(cx, cy), r, 0.0, TAU, 28, EDGE_READY, 1.2, true)
	var ang := phase * TAU - PI * 0.5
	var tip := Vector2(cx + cos(ang) * (r - 3.0), cy + sin(ang) * (r - 3.0))
	draw_line(Vector2(cx, cy), tip, ACCENT_FLOW, 2.0, true)
	draw_circle(tip, 3.5, ACCENT_FLOW)
	if font != null and rect.size.x > 96.0:
		var tx := cx + r + 7.0
		draw_string(font, Vector2(tx, cy - 2.0), "%.1fm/s" % speed, HORIZONTAL_ALIGNMENT_LEFT, rect.end.x - tx - 4.0, 10, TEXT_LIGHT)
		draw_string(font, Vector2(tx, cy + 11.0), "φ %.2f" % phase, HORIZONTAL_ALIGNMENT_LEFT, rect.end.x - tx - 4.0, 10, TEXT_DIM)
	_draw_diamond(Vector2(rect.end.x, rect.get_center().y), 4.2, ACCENT_CP)


func _draw_footset_node(font: Font, node_id: String, rect: Rect2, title: String,
		l_lbl: String, l_planted: bool, r_lbl: String, r_planted: bool, unlocked: bool, active: bool) -> void:
	var head_h := 19.0
	var is_sel := selected_node_id == node_id
	var any_swing := not l_planted or not r_planted
	var accent := ACCENT_FLOW if any_swing else ACCENT_GAIT
	draw_rect(rect, NODE_IDLE if unlocked else NODE_LOCKED, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, head_h)), accent if active else NODE_HEADER_IDLE, true)
	draw_rect(rect, Color("#ffffff") if is_sel else (accent if active else EDGE_READY), false, 2.0 if (is_sel or active) else 1.2)
	if font != null:
		draw_string(font, rect.position + Vector2(6.0, 13.0), title, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10.0, 10,
			TEXT_DARK if active else TEXT_LIGHT)
	# Two live paw contact pills inside the Foot Set card
	var bw := (rect.size.x - 18.0) * 0.5
	var bh := minf(20.0, rect.size.y - head_h - 10.0)
	var by := rect.position.y + head_h + (rect.size.y - head_h - bh) * 0.5
	var pills := [
		{"x": rect.position.x + 6.0, "lbl": l_lbl, "p": l_planted},
		{"x": rect.position.x + 12.0 + bw, "lbl": r_lbl, "p": r_planted},
	]
	for item in pills:
		var col := Color("#2f9e66") if item.p else Color("#e08b26")
		var pr := Rect2(item.x, by, bw, bh)
		draw_rect(pr, col, true)
		if font != null:
			draw_string(font, pr.position + Vector2(4.0, bh * 0.72),
				"%s:%s" % [item.lbl, "접지" if item.p else "스윙"], HORIZONTAL_ALIGNMENT_LEFT, bw - 4.0, 10, TEXT_DARK)


func _draw_node(font: Font, node_id: String, rect: Rect2, title: String, subtitle: String,
		unlocked: bool, active: bool, accent: Color, has_in: bool, has_out: bool) -> void:
	var head_h := 19.0
	var is_sel := selected_node_id == node_id
	draw_rect(rect, NODE_IDLE if unlocked else NODE_LOCKED, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, head_h)),
		accent if (unlocked and active) else (NODE_HEADER_IDLE if unlocked else Color("#1c222c")), true)
	if unlocked and active:
		draw_rect(rect.grow(1.5), Color(accent.r, accent.g, accent.b, 0.14), true)
	draw_rect(rect, Color("#ffffff") if is_sel else (accent if (unlocked and active) else (EDGE_READY if unlocked else EDGE_LOCKED)),
		false, 2.0 if (is_sel or active) else 1.2)
	if has_in:
		draw_circle(Vector2(rect.position.x, rect.get_center().y), 3.6, accent if active else EDGE_READY)
	if has_out:
		draw_circle(Vector2(rect.end.x, rect.get_center().y), 3.6, accent if active else EDGE_READY)
	if font != null:
		draw_string(font, rect.position + Vector2(7.0, 13.0), title, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 12.0, 10,
			TEXT_DARK if (unlocked and active) else (TEXT_LIGHT if unlocked else TEXT_DIM))
		draw_string(font, rect.position + Vector2(7.0, head_h + minf(19.0, (rect.size.y - head_h) * 0.65)),
			subtitle, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 12.0, 10,
			TEXT_LIGHT if (unlocked and active) else TEXT_DIM)


func _draw_wire(a: Vector2, b: Vector2, col: Color, active: bool, is_param: bool, vertical := false) -> void:
	var c1: Vector2
	var c2: Vector2
	if vertical:
		var dy := maxf(12.0, absf(b.y - a.y) * 0.5)
		c1 = a + Vector2(0.0, dy)
		c2 = b - Vector2(0.0, dy)
	else:
		var dx := maxf(16.0, absf(b.x - a.x) * 0.45)
		c1 = a + Vector2(dx, 0.0)
		c2 = b - Vector2(dx, 0.0)
	var pts := PackedVector2Array()
	for i in 17:
		var t := float(i) / 16.0
		var mt := 1.0 - t
		pts.append(mt * mt * mt * a + 3.0 * mt * mt * t * c1 + 3.0 * mt * t * t * c2 + t * t * t * b)
	draw_polyline(pts, col, 2.3 if active else 1.3, true)
	if active:
		var u := fposmod(_pulse * (0.75 if is_param else 1.0), 1.0)
		var mu := 1.0 - u
		var pt := mu * mu * mu * a + 3.0 * mu * mu * u * c1 + 3.0 * mu * u * u * c2 + u * u * u * b
		draw_circle(pt, 3.2, Color("#ffffff") if not is_param else Color("#e2d0ff"))


func _draw_diamond(center: Vector2, r: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -r), center + Vector2(r, 0.0), center + Vector2(0.0, r), center + Vector2(-r, 0.0)
	]), col)
