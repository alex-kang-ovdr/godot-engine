@tool
extends Control
## NaturalMotion Morpheme Connect-style Multi-Track Timeline & Event Tracks.
## Visualizes Authoring Steps (0..14s), Locomotion State spans (0..254t),
## Smoothstep Transition/Blend events, and Left/Right Foot IK contact/swing tracks
## with a live synchronized playhead and direct click/drag scrubbing.

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

const STATE_COLORS := {
	"idle": Color("#3a4b5c"),
	"idle_to_walk": Color("#2d8f86"),
	"walk": Color("#2cc7b8"),
	"run": Color("#e88c2a"),
}

const LABEL_W := 124.0
const RULER_H := 20.0

var authoring_mode: bool = true
var authoring_time: float = 0.0
var authoring_duration: float = 14.0
var authoring_steps: Array[Dictionary] = []
var recorded_frames: Array[Dictionary] = []
var current_tick: int = 0
var _dragging: bool = false


func _ready() -> void:
	custom_minimum_size = Vector2(320.0, 74.0)
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
	var u := clampf((mouse_x - LABEL_W) / track_w, 0.0, 1.0)
	scrub_requested.emit(u)


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	draw_rect(Rect2(0.0, 0.0, LABEL_W, size.y), HEADER_BG, true)
	draw_rect(Rect2(0.0, 0.0, size.x, RULER_H), Color("#1e2430"), true)
	draw_line(Vector2(LABEL_W, 0.0), Vector2(LABEL_W, size.y), BORDER, 1.2)
	draw_line(Vector2(0.0, RULER_H), Vector2(size.x, RULER_H), BORDER, 1.0)

	var track_x := LABEL_W
	var track_w := maxf(40.0, size.x - LABEL_W - 8.0)
	var body_h := maxf(40.0, size.y - RULER_H)
	var row_h := body_h * 0.25
	var labels := ["Authoring (14)", "State Strip", "Blend / Events", "Foot IK L / R"]

	for r in 4:
		var ry := RULER_H + float(r) * row_h
		if r % 2 == 1:
			draw_rect(Rect2(track_x, ry, track_w, row_h), ROW_ALT, true)
		draw_line(Vector2(0.0, ry + row_h), Vector2(size.x, ry + row_h), BORDER, 1.0)
		if font != null:
			draw_string(font, Vector2(8.0, ry + row_h * 0.65), labels[r], HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 12.0, 11,
				TEXT_LIGHT if (r == 0 and authoring_mode) or (r == 1 and not authoring_mode) else TEXT_DIM)

	# Ruler ticks
	if font != null:
		draw_string(font, Vector2(8.0, 14.0), "EVENT TRACKS", HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 12.0, 10, Color("#f39c2b"))
		if authoring_mode:
			var step_cnt := maxi(1, authoring_steps.size())
			for i in step_cnt + 1:
				var x := track_x + track_w * (float(i) / float(step_cnt))
				draw_line(Vector2(x, 12.0), Vector2(x, RULER_H), BORDER, 1.0)
				if i < step_cnt:
					draw_string(font, Vector2(x + 3.0, 14.0), "%ds" % i, HORIZONTAL_ALIGNMENT_LEFT, 28.0, 10, TEXT_DIM)
		else:
			for tick in [0, 31, 57, 90, 150, 202, 254]:
				var x := track_x + track_w * (float(tick) / 254.0)
				draw_line(Vector2(x, 10.0), Vector2(x, RULER_H), BORDER, 1.0)
				draw_string(font, Vector2(x + 2.0, 14.0), "t%d" % tick, HORIZONTAL_ALIGNMENT_LEFT, 32.0, 10, TEXT_DIM)

	# Row 0: 14 Authoring Steps blocks
	var r0_y := RULER_H + 3.0
	var r0_h := maxf(8.0, row_h - 6.0)
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
				draw_rect(Rect2(bx, r0_y, bw, r0_h), Color("#ffffff"), false, 1.4)
			if font != null and bw >= 16.0:
				draw_string(font, Vector2(bx + 4.0, r0_y + r0_h * 0.72), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, bw - 4.0, 10,
					Color("#0d131a") if alpha > 0.5 else TEXT_DIM)

	# Row 1: Locomotion State Spans (0..254)
	var total_f := maxi(1, recorded_frames.size())
	var r1_y := RULER_H + row_h + 3.0
	var r1_h := maxf(8.0, row_h - 6.0)
	if not recorded_frames.is_empty():
		var seg_start := 0
		var seg_state := str(recorded_frames[0].state)
		for i in range(1, total_f + 1):
			var st := str(recorded_frames[i].state) if i < total_f else "__END__"
			if st != seg_state:
				var sx := track_x + track_w * (float(seg_start) / float(total_f))
				var sw := maxf(2.0, track_w * (float(i - seg_start) / float(total_f)) - 1.0)
				var scol: Color = STATE_COLORS.get(seg_state, Color("#4b5f73"))
				draw_rect(Rect2(sx, r1_y, sw, r1_h), scol, true)
				if font != null and sw >= 28.0:
					draw_string(font, Vector2(sx + 4.0, r1_y + r1_h * 0.72), seg_state, HORIZONTAL_ALIGNMENT_LEFT, sw - 6.0, 10, Color("#0f161f"))
				seg_start = i
				seg_state = st

	# Row 2: Blend Envelopes & Transition Diamonds
	var r2_y := RULER_H + row_h * 2.0 + 3.0
	var r2_h := maxf(8.0, row_h - 6.0)
	if not recorded_frames.is_empty():
		var prev_st := str(recorded_frames[0].state)
		for i in total_f:
			var f: Dictionary = recorded_frames[i]
			var bx := track_x + track_w * (float(i) / float(total_f))
			var bw := maxf(1.5, track_w / float(total_f))
			var ow := float(f.get("outgoing_weight", 0.0))
			if ow > 0.01:
				var h_env := r2_h * ow
				draw_rect(Rect2(bx, r2_y + r2_h - h_env, bw, h_env), Color(0.95, 0.61, 0.17, 0.72), true)
			var st := str(f.state)
			if i > 0 and st != prev_st:
				var cy := r2_y + r2_h * 0.5
				draw_colored_polygon(PackedVector2Array([
					Vector2(bx, cy - 5.0), Vector2(bx + 4.5, cy), Vector2(bx, cy + 5.0), Vector2(bx - 4.5, cy)
				]), Color("#ffe08a"))
			prev_st = st

	# Row 3: Foot IK Contact / Swing Track
	var r3_y := RULER_H + row_h * 3.0 + 3.0
	var r3_h := maxf(8.0, row_h - 6.0)
	if not recorded_frames.is_empty():
		var half_h := maxf(3.0, r3_h * 0.45)
		for i in total_f:
			var f: Dictionary = recorded_frames[i]
			var bx := track_x + track_w * (float(i) / float(total_f))
			var bw := maxf(1.5, track_w / float(total_f))
			var hits := int(f.get("ik_hits", 0))
			var off := float(f.get("ik_offset_mm", 0.0))
			if hits > 0:
				var c_l := Color("#4ad689") if off > 1.0 else Color("#2f6e56")
				var c_r := Color("#4ca3f7") if hits >= 2 else Color("#2d4766")
				draw_rect(Rect2(bx, r3_y, bw, half_h), c_l, true)
				draw_rect(Rect2(bx, r3_y + half_h + 1.0, bw, half_h), c_r, true)

	# Synchronized Playhead(s)
	var auth_u := clampf(authoring_time / authoring_duration, 0.0, 1.0)
	var tick_u := clampf(float(current_tick) / float(maxi(1, total_f - 1)), 0.0, 1.0)
	if authoring_mode:
		# Primary orange playhead for authoring step track
		var px := track_x + track_w * auth_u
		draw_line(Vector2(px, 0.0), Vector2(px, RULER_H + row_h), PLAYHEAD, 2.2)
		draw_colored_polygon(PackedVector2Array([Vector2(px - 5.0, 0.0), Vector2(px + 5.0, 0.0), Vector2(px, 8.0)]), PLAYHEAD)
		# Secondary cyan playhead showing mapped 255-tick preview pose on tracks 1..3
		var tx := track_x + track_w * tick_u
		draw_line(Vector2(tx, RULER_H + row_h), Vector2(tx, size.y), Color("#2cc7b8"), 2.0)
	else:
		var px := track_x + track_w * tick_u
		draw_line(Vector2(px, 0.0), Vector2(px, size.y), PLAYHEAD, 2.2)
		draw_colored_polygon(PackedVector2Array([Vector2(px - 5.0, 0.0), Vector2(px + 5.0, 0.0), Vector2(px, 8.0)]), PLAYHEAD)
