@tool
extends Control
## Interactive 2D state-machine diagram for the Hero locomotion authoring
## walkthrough and 255-tick rewind viewer (works in both Godot Editor and runtime).

const BG := Color("#101c1d")
const CARD_LOCKED := Color("#1a2627")
const CARD_IDLE := Color("#233738")
const ACCENT_STATE := Color("#3ec4a7")
const ACCENT_TRANS := Color("#f0a642")
const ACCENT_IK := Color("#5aa2ee")
const EDGE_LOCKED := Color("#2c3c3c")
const EDGE_READY := Color("#526d6b")
const TEXT_LIGHT := Color("#e6f2ec")
const TEXT_DIM := Color("#7d9490")
const TEXT_DARK := Color("#102221")

var build_stage: int = 5
var frame_info: Dictionary = {}


func set_display(stage: int, info: Dictionary) -> void:
	build_stage = clampi(stage, 1, 5)
	frame_info = info
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	var font := get_theme_default_font()
	var fsize := 13

	var state: String = str(frame_info.get("state", "idle"))
	var clip_name: String = str(frame_info.get("clip", "idle"))
	var blend_w: float = float(frame_info.get("outgoing_weight", 0.0))
	var blend_from: String = str(frame_info.get("outgoing_state", ""))
	var stick: Vector2 = frame_info.get("stick", Vector2.ZERO)
	var walk_mod: bool = bool(frame_info.get("walk_modifier", false))
	var cam_deg: float = float(frame_info.get("camera_lead_deg", 0.0))
	var ik_hits: int = int(frame_info.get("ik_hits", 0))

	var r_idle := Rect2(14, 16, 114, 46)
	var r_i2w := Rect2(158, 16, 128, 46)
	var r_walk := Rect2(158, 88, 128, 46)
	var r_run := Rect2(14, 88, 114, 46)
	var r_cam := Rect2(14, 156, 128, 42)
	var r_ik := Rect2(158, 156, 128, 42)

	var s2 := build_stage >= 2
	var s3 := build_stage >= 3
	var s4 := build_stage >= 4

	# State transition edges
	_draw_edge(r_idle.position + Vector2(r_idle.size.x, 23), r_i2w.position + Vector2(0, 23),
		s2, state == "idle_to_walk" and blend_from == "idle" and blend_w > 0.01, "4t")
	_draw_edge(r_i2w.position + Vector2(64, r_i2w.size.y), r_walk.position + Vector2(64, 0),
		s2, state == "walk" and blend_from == "idle_to_walk" and blend_w > 0.01, "26t")
	_draw_edge(r_walk.position + Vector2(0, 23), r_run.position + Vector2(r_run.size.x, 23),
		s3, state == "run" and blend_from == "walk" and blend_w > 0.01, "4t")
	_draw_edge(r_run.position + Vector2(57, 0), r_idle.position + Vector2(57, r_idle.size.y),
		s3, state == "idle" and blend_from == "run" and blend_w > 0.01, "10t")

	# State nodes
	_draw_node(font, fsize, r_idle, "1. Idle", "clip: idle", true, state == "idle", ACCENT_STATE)
	_draw_node(font, fsize, r_i2w, "2. Idle→Walk", "clip: idle_to_walk", s2, state == "idle_to_walk", ACCENT_STATE)
	_draw_node(font, fsize, r_walk, "2. Walking", "clip: walk", s2, state == "walk", ACCENT_STATE)
	_draw_node(font, fsize, r_run, "3. Running", "clip: run", s3, state == "run", ACCENT_STATE)

	# Post-processing pipeline nodes
	var cam_sub := "리드 %+.1f°" % cam_deg if s3 else "미적용 (3단계)"
	_draw_node(font, fsize, r_cam, "3. Camera Lead", cam_sub, s3, s3 and absf(cam_deg) > 0.5, ACCENT_TRANS)
	var ik_sub := "접지 %d/2 · 스윙보존" % ik_hits if s4 else "미적용 (4단계)"
	_draw_node(font, fsize, r_ik, "4. Terrain Foot IK", ik_sub, s4, s4 and ik_hits > 0, ACCENT_IK)

	# Right panel: live joystick & Smoothstep blend readout
	var cx := 346.0
	var cy := 62.0
	var rad := 34.0
	draw_circle(Vector2(cx, cy), rad, Color("#1b2b2c"))
	draw_arc(Vector2(cx, cy), rad, 0.0, TAU, 32, EDGE_READY, 1.5, true)
	draw_line(Vector2(cx - rad, cy), Vector2(cx + rad, cy), EDGE_LOCKED, 1.0)
	draw_line(Vector2(cx, cy - rad), Vector2(cx, cy + rad), EDGE_LOCKED, 1.0)
	var dot := Vector2(cx + stick.x * (rad - 5.0), cy - stick.y * (rad - 5.0))
	draw_line(Vector2(cx, cy), dot, ACCENT_TRANS, 2.0, true)
	draw_circle(dot, 5.0, ACCENT_TRANS)

	if font != null:
		draw_string(font, Vector2(302, 18), "입력 스틱", HORIZONTAL_ALIGNMENT_LEFT, 90, 12, TEXT_DIM)
		draw_string(font, Vector2(302, 114), "LT Walk: %s" % ("ON" if walk_mod else "OFF"),
			HORIZONTAL_ALIGNMENT_LEFT, 100, 12, ACCENT_STATE if walk_mod else TEXT_DIM)
		draw_string(font, Vector2(302, 134), "클립: %s" % clip_name,
			HORIZONTAL_ALIGNMENT_LEFT, 110, 12, TEXT_LIGHT)
		if blend_w > 0.01:
			draw_string(font, Vector2(302, 154), "블렌드: %.0f%%" % ((1.0 - blend_w) * 100.0),
				HORIZONTAL_ALIGNMENT_LEFT, 110, 12, ACCENT_TRANS)
			var bar := Rect2(302, 162, 92, 8)
			draw_rect(bar, CARD_IDLE, true)
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * (1.0 - blend_w), bar.size.y)), ACCENT_TRANS, true)
		else:
			draw_string(font, Vector2(302, 154), "블렌드: 완료", HORIZONTAL_ALIGNMENT_LEFT, 110, 12, TEXT_DIM)


func _draw_edge(a: Vector2, b: Vector2, unlocked: bool, active: bool, tag: String) -> void:
	var col := ACCENT_TRANS if active else (EDGE_READY if unlocked else EDGE_LOCKED)
	var width := 3.0 if active else (1.8 if unlocked else 1.0)
	draw_line(a, b, col, width, true)
	var dir := (b - a).normalized()
	var perp := Vector2(-dir.y, dir.x)
	var tip := b - dir * 2.0
	draw_colored_polygon(PackedVector2Array([tip, tip - dir * 8.0 + perp * 4.0, tip - dir * 8.0 - perp * 4.0]), col)
	var font := get_theme_default_font()
	if font != null and unlocked and not tag.is_empty():
		var mid := (a + b) * 0.5 + Vector2(-10, -4)
		draw_string(font, mid, tag, HORIZONTAL_ALIGNMENT_LEFT, 36, 10, ACCENT_TRANS if active else TEXT_DIM)


func _draw_node(font: Font, fsize: int, rect: Rect2, title: String, sub: String, unlocked: bool, active: bool, accent: Color) -> void:
	var fill := accent if active else (CARD_IDLE if unlocked else CARD_LOCKED)
	var border := accent if active else (EDGE_READY if unlocked else EDGE_LOCKED)
	draw_rect(rect, fill, true)
	draw_rect(rect, border, false, 2.2 if active else 1.2)
	if font == null:
		return
	var tc := TEXT_DARK if active else (TEXT_LIGHT if unlocked else TEXT_DIM)
	draw_string(font, rect.position + Vector2(8, 17), title, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 14, fsize, tc)
	draw_string(font, rect.position + Vector2(8, 34), sub, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 14, fsize - 2, tc)
