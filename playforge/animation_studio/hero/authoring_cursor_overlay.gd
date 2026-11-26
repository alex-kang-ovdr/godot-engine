@tool
extends Control
## Virtual pointer overlay modeled after PlayForge's Tappy Chicken showcase
## replay (EditorCursorOverlay): renders animated role cursor, phase chip,
## caption badge, click ripple, and live highlight rectangle over target widgets.

const BG_BADGE := Color("#1c2938ee")
const TEXT_LIGHT := Color("#eef6f2")

const ROLES := {
	"assets": {"label": "에셋", "color": Color("#46d1b6")},
	"level": {"label": "리그·씬", "color": Color("#68b5ff")},
	"graph": {"label": "상태머신", "color": Color("#f4a842")},
	"ik": {"label": "물리·IK", "color": Color("#c994ff")},
}

const PHASES := {
	"search": {"label": "탐색", "symbol": "◎", "color": Color("#99c5f0")},
	"target": {"label": "대상", "symbol": "◈", "color": Color("#7fdbf0")},
	"execute": {"label": "실행", "symbol": "▶", "color": Color("#ffc979")},
	"change": {"label": "변경", "symbol": "↔", "color": Color("#dcadff")},
	"success": {"label": "완료", "symbol": "✓", "color": Color("#9ae6ae")},
}

var active := false
var pointer_pos := Vector2(180.0, 140.0)
var target_pos := Vector2(180.0, 140.0)
var target_rect := Rect2()
var role_id := "assets"
var phase_id := "search"
var caption := ""
var target_label := ""
var click_pulse := 0.0
var _pulse_clock := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 100


func present(p_active: bool, p_role: String, p_phase: String, p_caption: String, p_rect: Rect2, p_target_label: String, p_click_pulse: float, instant := false) -> void:
	active = p_active
	role_id = p_role if ROLES.has(p_role) else "assets"
	phase_id = p_phase if PHASES.has(p_phase) else "search"
	caption = p_caption
	target_rect = p_rect
	target_label = p_target_label
	click_pulse = clampf(p_click_pulse, 0.0, 1.0)
	if p_rect.size.x > 1.0 and p_rect.size.y > 1.0:
		target_pos = p_rect.position + Vector2(minf(p_rect.size.x * 0.65, p_rect.size.x - 14.0), p_rect.size.y * 0.5)
	if instant:
		pointer_pos = target_pos
	queue_redraw()


func _process(delta: float) -> void:
	if not active:
		return
	_pulse_clock += delta
	var smooth := 1.0 - exp(-delta * 14.0)
	pointer_pos = pointer_pos.lerp(target_pos, smooth)
	queue_redraw()


func _draw() -> void:
	if not active:
		return
	var font := get_theme_default_font()
	var role_meta: Dictionary = ROLES.get(role_id, ROLES["assets"])
	var phase_meta: Dictionary = PHASES.get(phase_id, PHASES["search"])
	var accent: Color = role_meta.color
	var phase_col: Color = phase_meta.color

	# 1. Target widget highlight rectangle with subtle pulse
	if target_rect.size.x > 2.0 and target_rect.size.y > 2.0:
		var pad := 3.0 + 1.5 * sin(_pulse_clock * 6.0)
		var hl := target_rect.grow(pad)
		draw_rect(hl, Color(accent.r, accent.g, accent.b, 0.13), true)
		draw_rect(hl, accent, false, 2.4)
		if font != null and not target_label.is_empty():
			var tag_pos := Vector2(hl.position.x, maxf(14.0, hl.position.y - 5.0))
			var tw := font.get_string_size(target_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 10.0
			draw_rect(Rect2(tag_pos.x, tag_pos.y - 13.0, tw, 16.0), Color(accent.r, accent.g, accent.b, 0.92), true)
			draw_string(font, Vector2(tag_pos.x + 5.0, tag_pos.y - 1.0), target_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#102022"))

	# 2. Click ripple ring at cursor tip
	if click_pulse > 0.01:
		var r := 6.0 + (1.0 - click_pulse) * 28.0
		var alpha := click_pulse * 0.85
		draw_arc(pointer_pos, r, 0.0, TAU, 28, Color(phase_col.r, phase_col.g, phase_col.b, alpha), 2.5, true)
		draw_circle(pointer_pos, 4.0 * click_pulse, Color(phase_col.r, phase_col.g, phase_col.b, alpha * 0.6))

	# 3. Crisp vector arrow cursor (1.35x showcase scale)
	var s := 1.35
	var tip := pointer_pos
	var poly := PackedVector2Array([
		tip,
		tip + Vector2(0.0, 18.0) * s,
		tip + Vector2(4.6, 13.8) * s,
		tip + Vector2(8.5, 20.5) * s,
		tip + Vector2(11.2, 19.0) * s,
		tip + Vector2(7.3, 12.2) * s,
		tip + Vector2(13.2, 12.2) * s,
	])
	var shadow := PackedVector2Array()
	for pt in poly:
		shadow.append(pt + Vector2(2.0, 2.0))
	draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.45))
	draw_colored_polygon(poly, accent)
	draw_polyline(poly + PackedVector2Array([poly[0]]), Color("#0e1922"), 1.6, true)

	# 4. Role + phase + caption floating pill next to cursor
	if font != null:
		var badge_title := "%s  %s %s" % [role_meta.label, phase_meta.symbol, phase_meta.label]
		var w1 := font.get_string_size(badge_title, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var w2 := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var box_w := clampf(maxf(w1, w2) + 20.0, 150.0, 340.0)
		var box_h := 44.0
		var bx := tip.x + 18.0
		var by := tip.y + 12.0
		if bx + box_w > size.x - 10.0:
			bx = maxf(8.0, tip.x - box_w - 14.0)
		if by + box_h > size.y - 10.0:
			by = maxf(8.0, tip.y - box_h - 14.0)
		var pill := Rect2(bx, by, box_w, box_h)
		draw_rect(pill, BG_BADGE, true)
		draw_rect(pill, accent, false, 1.8)
		draw_rect(Rect2(bx, by, 4.0, box_h), accent, true)
		draw_string(font, Vector2(bx + 10.0, by + 16.0), badge_title, HORIZONTAL_ALIGNMENT_LEFT, box_w - 14.0, 12, phase_col)
		draw_string(font, Vector2(bx + 10.0, by + 35.0), caption, HORIZONTAL_ALIGNMENT_LEFT, box_w - 14.0, 12, TEXT_LIGHT)
