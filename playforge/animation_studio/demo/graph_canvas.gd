extends Control
## Draws the live PoseGraph topology and highlights active states,
## inertial transitions, and masked upper-body slot activity.

const BG := Color("#111e1f")
const NODE_IDLE := Color("#233738")
const NODE_ACTIVE := Color("#3db59e")
const NODE_INERTIAL := Color("#e8a245")
const NODE_SLOT := Color("#5398e6")
const EDGE_DIM := Color("#455c5b")
const TEXT_LIGHT := Color("#e8f4ee")
const TEXT_DARK := Color("#102221")

var snapshot: Dictionary = {}


func set_snapshot(data: Dictionary) -> void:
	snapshot = data
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	var font := get_theme_default_font()
	var fsize := 13

	var state: String = snapshot.get("state", "idle")
	var trans_from: String = snapshot.get("transition_from", "")
	var inertial: bool = snapshot.get("inertial_active", false)
	var inertial_rem: float = snapshot.get("inertial_remaining", 0.0)
	var slot_weight: float = snapshot.get("slot_weight", 0.0)
	var slot_name: String = snapshot.get("slot_name", "")
	var clips_eval: int = snapshot.get("total_clips_evaluated", 0)

	var r_idle := Rect2(16, 18, 96, 40)
	var r_move := Rect2(16, 78, 96, 40)
	var r_inert := Rect2(150, 48, 124, 42)
	var r_slot := Rect2(150, 112, 124, 42)
	var r_out := Rect2(310, 68, 98, 46)

	# Edges
	_draw_edge(r_idle, r_inert, state == "idle" or trans_from == "idle", NODE_INERTIAL if (inertial and trans_from == "idle") else NODE_ACTIVE)
	_draw_edge(r_move, r_inert, state == "move" or trans_from == "move", NODE_INERTIAL if (inertial and trans_from == "move") else NODE_ACTIVE)
	_draw_edge(r_inert, r_out, true, NODE_INERTIAL if inertial else NODE_ACTIVE)
	_draw_edge(r_slot, r_out, slot_weight > 0.001, NODE_SLOT)

	# Nodes
	_draw_node(font, fsize, r_idle, "Idle", "", state == "idle", NODE_ACTIVE)
	_draw_node(font, fsize, r_move, "Move", "", state == "move", NODE_ACTIVE)
	var inert_sub := "%.2fs" % inertial_rem if inertial else "대기"
	_draw_node(font, fsize, r_inert, "Inertialize", inert_sub, inertial, NODE_INERTIAL)
	var slot_sub := "%s %.0f%%" % [slot_name, slot_weight * 100.0] if slot_weight > 0.001 else "비활성"
	_draw_node(font, fsize, r_slot, "Upper Slot", slot_sub, slot_weight > 0.001, NODE_SLOT)
	_draw_node(font, fsize, r_out, "Pose Out", "clips: %d" % clips_eval, true, NODE_ACTIVE)


func _draw_edge(from_rect: Rect2, to_rect: Rect2, active: bool, color: Color) -> void:
	var a := Vector2(from_rect.end.x, from_rect.get_center().y)
	var b := Vector2(to_rect.position.x, to_rect.get_center().y)
	draw_line(a, b, color if active else EDGE_DIM, 3.0 if active else 1.5, true)


func _draw_node(font: Font, fsize: int, rect: Rect2, title: String, sub: String, active: bool, accent: Color) -> void:
	var fill := accent if active else NODE_IDLE
	draw_rect(rect, fill, true)
	draw_rect(rect, accent if active else EDGE_DIM, false, 2.0)
	if font == null:
		return
	var tc := TEXT_DARK if active else TEXT_LIGHT
	draw_string(font, rect.position + Vector2(8, 18), title, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, fsize, tc)
	if not sub.is_empty():
		draw_string(font, rect.position + Vector2(8, 34), sub, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, fsize - 1, tc)
