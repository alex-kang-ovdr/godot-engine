@tool
extends Control
## NaturalMotion Morpheme-style 5-Track Quadruped Gait & Authoring Timeline.
## Tracks:
##   1. Authoring (14) : 14 color-coded procedural authoring steps (0..14s)
##   2. Gait Strip     : Idle / Walk / Trot / Pace / Gallop spans (0..299t)
##   3. Front L / R    : FL & FR stance (cyan/green) vs swing (amber) footfall strips
##   4. Hind L / R     : HL & HR stance vs swing footfall strips (shows Trot diagonal pairing!)
##   5. Pelvis Pitch/Y : Continuous terrain climb & vertical bob telemetry curve

signal scrub_requested(normalized_u: float)

const BG := Color("#14181f")
const HEADER_BG := Color("#1c212b")
const ROW_ALT := Color("#181d25")
const BORDER := Color("#2c3442")
const PLAYHEAD := Color("#f39c2b")
const TEXT_LIGHT := Color("#e8f0f8")
const TEXT_DIM := Color("#8796ab")

const ROLE_COLORS := {
	"assets": Color("#2cc7b8"),
	"level": Color("#559ef5"),
	"graph": Color("#f39c2b"),
	"ik": Color("#9b72f2"),
}

const GAIT_COLORS := {
	"idle": Color("#3a4b5c"),
	"walk": Color("#2cc7b8"),
	"trot": Color("#4ca3f7"),
	"pace": Color("#9b72f2"),
	"gallop": Color("#e88c2a"),
}

const LABEL_W := 124.0
const RULER_H := 18.0

var authoring_mode: bool = true
var authoring_time: float = 0.0
var authoring_duration: float = 14.0
var authoring_steps: Array[Dictionary] = []
var recorded_frames: Array[Dictionary] = []
var current_tick: int = 0
var _dragging: bool = false


func _ready() -> void:
	custom_minimum_size = Vector2(320.0, 80.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func set_timeline_state(p_authoring_mode: bool, p_auth_time: float, p_auth_dur: float,
		p_steps: Array[Dictionary], p_frames: Array[Dictionary], p_tick: int) -> void:
	authoring_mode = p_authoring_mode
	authoring_time = p_auth_time
	authoring_duration = maxf(0.01, p_auth_dur)
	authoring_steps = p_steps
	recorded_frames = p_frames
	current_tick = p_tick
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.position.x >= LABEL_W:
			_dragging = true
			_emit_scrub(event.position.x)
			accept_event()
		elif not event.pressed:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		_emit_scrub(event.position.x)
		accept_event()


func _emit_scrub(mouse_x: float) -> void:
	var track_w := maxf(1.0, size.x - LABEL_W - 8.0)
	scrub_requested.emit(clampf((mouse_x - LABEL_W) / track_w, 0.0, 1.0))


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	draw_rect(Rect2(0.0, 0.0, LABEL_W, size.y), HEADER_BG, true)
	draw_rect(Rect2(0.0, 0.0, size.x, RULER_H), Color("#1e2430"), true)
	draw_line(Vector2(LABEL_W, 0.0), Vector2(LABEL_W, size.y), BORDER, 1.2)
	draw_line(Vector2(0.0, RULER_H), Vector2(size.x, RULER_H), BORDER, 1.0)

	var track_x := LABEL_W
	var track_w := maxf(40.0, size.x - LABEL_W - 8.0)
	var body_h := maxf(45.0, size.y - RULER_H)
	var row_h := body_h / 5.0
	var labels := ["Authoring (14)", "Gait Strip", "Front FL / FR", "Hind HL / HR", "Pelvis Pitch"]

	for r in 5:
		var ry := RULER_H + float(r) * row_h
		if r % 2 == 1:
			draw_rect(Rect2(track_x, ry, track_w, row_h), ROW_ALT, true)
		draw_line(Vector2(0.0, ry + row_h), Vector2(size.x, ry + row_h), BORDER, 1.0)
		if font != null:
			draw_string(font, Vector2(8.0, ry + row_h * 0.72), labels[r], HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 12.0, 10,
				TEXT_LIGHT if (r == 0 and authoring_mode) or (r == 1 and not authoring_mode) else TEXT_DIM)

	# Ruler
	if font != null:
		draw_string(font, Vector2(8.0, 13.0), "GAIT TRACKS", HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 12.0, 10, Color("#f39c2b"))
		if authoring_mode:
			var sc := maxi(1, authoring_steps.size())
			for i in sc + 1:
				var x := track_x + track_w * (float(i) / float(sc))
				draw_line(Vector2(x, 10.0), Vector2(x, RULER_H), BORDER, 1.0)
				if i < sc:
					draw_string(font, Vector2(x + 3.0, 13.0), "%ds" % i, HORIZONTAL_ALIGNMENT_LEFT, 26.0, 9, TEXT_DIM)
		else:
			for tick in [0, 25, 95, 170, 220, 270, 299]:
				var x := track_x + track_w * (float(tick) / 299.0)
				draw_line(Vector2(x, 10.0), Vector2(x, RULER_H), BORDER, 1.0)
				draw_string(font, Vector2(x + 2.0, 13.0), "t%d" % tick, HORIZONTAL_ALIGNMENT_LEFT, 32.0, 9, TEXT_DIM)

	# Row 0: Authoring Steps (14)
	var r0_y := RULER_H + 2.0
	var r0_h := maxf(6.0, row_h - 4.0)
	if not authoring_steps.is_empty():
		var cnt := authoring_steps.size()
		var cur_step := clampi(int(floor(authoring_time / (authoring_duration / float(cnt)))), 0, cnt - 1)
		for i in cnt:
			var s: Dictionary = authoring_steps[i]
			var bx := track_x + track_w * (float(i) / float(cnt))
			var bw := maxf(4.0, track_w / float(cnt) - 2.0)
			var col: Color = ROLE_COLORS.get(str(s.get("role", "assets")), Color("#2cc7b8"))
			var alpha := 0.92 if (authoring_mode and i == cur_step) else (0.55 if i <= cur_step else 0.22)
			draw_rect(Rect2(bx, r0_y, bw, r0_h), Color(col.r, col.g, col.b, alpha), true)
			if authoring_mode and i == cur_step:
				draw_rect(Rect2(bx, r0_y, bw, r0_h), Color("#ffffff"), false, 1.3)
			if font != null and bw >= 14.0:
				draw_string(font, Vector2(bx + 3.0, r0_y + r0_h * 0.78), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, bw - 3.0, 9,
					Color("#0d131a") if alpha > 0.5 else TEXT_DIM)

	var total_f := maxi(1, recorded_frames.size())
	if not recorded_frames.is_empty():
		# Row 1: Gait Strip
		var r1_y := RULER_H + row_h + 2.0
		var r1_h := maxf(6.0, row_h - 4.0)
		var seg_start := 0
		var seg_gait := str(recorded_frames[0].gait)
		for i in range(1, total_f + 1):
			var g := str(recorded_frames[i].gait) if i < total_f else "__END__"
			if g != seg_gait:
				var sx := track_x + track_w * (float(seg_start) / float(total_f))
				var sw := maxf(2.0, track_w * (float(i - seg_start) / float(total_f)) - 1.0)
				draw_rect(Rect2(sx, r1_y, sw, r1_h), GAIT_COLORS.get(seg_gait, Color("#4b5f73")), true)
				if font != null and sw >= 26.0:
					draw_string(font, Vector2(sx + 4.0, r1_y + r1_h * 0.78), seg_gait, HORIZONTAL_ALIGNMENT_LEFT, sw - 6.0, 9, Color("#0f161f"))
				seg_start = i
				seg_gait = g

		# Row 2 (Front FL/FR) & Row 3 (Hind HL/HR): Stance (cyan/green) vs Swing (orange) footfall strips!
		var pair_specs := [
			{"row": 2, "top": "FL", "bot": "FR", "c_top": Color("#2cc7b8"), "c_bot": Color("#4ad689")},
			{"row": 3, "top": "HL", "bot": "HR", "c_top": Color("#4ca3f7"), "c_bot": Color("#9b72f2")},
		]
		for ps in pair_specs:
			var ry := RULER_H + row_h * float(ps.row) + 2.0
			var hh := maxf(2.5, (row_h - 5.0) * 0.5)
			for i in total_f:
				var feet: Dictionary = recorded_frames[i].feet
				var bx := track_x + track_w * (float(i) / float(total_f))
				var bw := maxf(1.4, track_w / float(total_f))
				var tp := bool(feet.get(ps.top, {}).get("planted", true))
				var bp := bool(feet.get(ps.bot, {}).get("planted", true))
				draw_rect(Rect2(bx, ry, bw, hh), ps.c_top if tp else Color("#f39c2b"), true)
				draw_rect(Rect2(bx, ry + hh + 1.0, bw, hh), ps.c_bot if bp else Color("#f39c2b"), true)

		# Row 4: Pelvis Pitch Curve
		var r4_y := RULER_H + row_h * 4.0 + 2.0
		var r4_h := maxf(6.0, row_h - 4.0)
		var mid_y := r4_y + r4_h * 0.5
		draw_line(Vector2(track_x, mid_y), Vector2(track_x + track_w, mid_y), Color("#2a3444"), 1.0)
		var pts := PackedVector2Array()
		for i in total_f:
			var px := track_x + track_w * (float(i) / float(maxi(1, total_f - 1)))
			var pitch_n := clampf(float(recorded_frames[i].pelvis_pitch_deg) / 22.0, -1.0, 1.0)
			pts.append(Vector2(px, mid_y - pitch_n * (r4_h * 0.45)))
		if pts.size() >= 2:
			draw_polyline(pts, Color("#4ad689"), 1.6, true)

	# Synchronized Playhead(s)
	var auth_u := clampf(authoring_time / authoring_duration, 0.0, 1.0)
	var tick_u := clampf(float(current_tick) / float(maxi(1, total_f - 1)), 0.0, 1.0)
	if authoring_mode:
		var px := track_x + track_w * auth_u
		draw_line(Vector2(px, 0.0), Vector2(px, RULER_H + row_h), PLAYHEAD, 2.2)
		draw_colored_polygon(PackedVector2Array([Vector2(px - 5.0, 0.0), Vector2(px + 5.0, 0.0), Vector2(px, 7.0)]), PLAYHEAD)
		var tx := track_x + track_w * tick_u
		draw_line(Vector2(tx, RULER_H + row_h), Vector2(tx, size.y), Color("#2cc7b8"), 2.0)
	else:
		var px := track_x + track_w * tick_u
		draw_line(Vector2(px, 0.0), Vector2(px, size.y), PLAYHEAD, 2.2)
		draw_colored_polygon(PackedVector2Array([Vector2(px - 5.0, 0.0), Vector2(px + 5.0, 0.0), Vector2(px, 7.0)]), PLAYHEAD)
