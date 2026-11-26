extends SceneTree

const Hero := preload("res://hero/hero.gd")
const TRACE := "res://hero/generated/behavior_trace.json"
const TICKS := 255
const STEP := 1.0 / 60.0
const POSITION_TOLERANCE := 0.01
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func report(label: String, valid: bool, details: Dictionary = {}) -> void:
	if not valid:
		failures += 1
	print("PFTEST ", JSON.stringify({"test": label, "status": "PASS" if valid else "FAIL", "detail": JSON.stringify(details)}))


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))
	change_scene_to_file("res://hero/hero.tscn")
	await scene_changed
	var hero := current_scene as Hero
	hero.set_physics_process(false)
	hero.get_node("%Behavior").pressed.emit()
	var available := hero.locomotion != null and hero.terrain_ik != null
	report("Hero behavior mode available", available)
	if available:
		var first := await simulate(hero)
		var second := await simulate(hero)
		var first_frame: Dictionary = first.front()
		var end_frame: Dictionary = first.back()
		var transitions: Array[Dictionary] = []
		var max_move := 0.0
		var hits := 0
		var adjustments := 0
		var max_yaw := 0.0
		for tick in first.size():
			var frame := first[tick]
			record_transition(transitions, frame.state, tick)
			max_move = maxf(max_move, first_frame.root.distance_to(frame.root))
			max_yaw = maxf(max_yaw, absf(angle_difference(first_frame.yaw, frame.yaw)))
			for leg in 2:
				if frame.hits[leg]:
					hits += 1
					var before: float = frame.before[leg].distance_to(frame.targets[leg])
					var after: float = frame.feet[leg].distance_to(frame.targets[leg])
					adjustments += int(before - after > 0.005)
		report("Havok locomotion transition timing", transitions == [
			{"state": "idle", "tick": 0}, {"state": "idle_to_walk", "tick": 31}, {"state": "walk", "tick": 57},
			{"state": "run", "tick": 90}, {"state": "idle", "tick": 202}
		] and max_move > 1.0, {"transitions": transitions, "distance_m": max_move})
		report("idle blends out remaining movement and stops", first[202].root.distance_to(end_frame.root) > 0.05
			and first[220].root.is_equal_approx(end_frame.root))
		report("direction input rotates locomotion root", max_yaw > 0.7, {"max_rad": max_yaw})
		report("forward and right input follow Havok world axes", first[149].root.z < -1.0
			and first[194].root.x < first[150].root.x - 1.0)
		report("terrain rays produce contacts during replay", hits >= TICKS, {"contacts": hits})
		await physics_frame
		await physics_frame
		# Probe the existing raised surface independently of the recorded movement path.
		var step := hero.terrain_root.find_child("FirstStep", true, false) as Node3D
		var motion := hero.rig.get_parent() as Node3D
		motion.global_position = Vector3(step.global_position.x, 0.0, step.global_position.z)
		var step_sample := hero.advance_behavior(Vector2.ZERO, STEP, false)
		var raised := 0
		for leg in 2:
			raised += int(step_sample.hits[leg] and step_sample.targets[leg].y > 0.12)
		report("terrain rays detect raised step", raised > 0, {"raised_feet": raised})
		report("IK moves ankles toward terrain targets", adjustments >= 20, {"adjusted_ankles": adjustments})
		report("fixed-input replay repeatable", first == second)
		hero.get_node("%Behavior").pressed.emit()
		report("switch back to clip comparison", hero.locomotion == null and not hero.selected.is_empty())
		print("PFTEST ", JSON.stringify({"status": "INFO", "test": "behavior replay", "data": {
			"ticks": first.size(), "first_state": first_frame.state, "last_state": end_frame.state
		}}))
		if "--native" in OS.get_cmdline_user_args():
			var entry_clip: Dictionary = hero.data.clips.get("idle_to_walk", {})
			var source_path: String = entry_clip.get("source", {}).get("path", "")
			report("native comparison uses the SDK walk entry clip", source_path.ends_with("/Walk/Walk_Face_180.hkt"))
			compare_native(first)
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)


func simulate(hero: Hero) -> Array[Dictionary]:
	await physics_frame
	await physics_frame
	var frames: Array[Dictionary] = []
	for tick in TICKS:
		await physics_frame
		var stick := Hero.replay_input(tick)
		var frame := hero.advance_behavior(stick, STEP, Hero.replay_walk_modifier(tick))
		frames.append({
			"stick": stick, "trigger": float(Hero.replay_walk_modifier(tick)),
			"state": frame.state, "root": hero.rig.global_position,
			"yaw": hero.rig.global_rotation.y, "feet": frame.feet, "hits": frame.hits,
			"targets": frame.targets, "before": frame.before_ik
		})
	hero.get_node("%Behavior").pressed.emit()
	hero.get_node("%Behavior").pressed.emit()
	return frames


func compare_native(frames: Array[Dictionary]) -> void:
	var raw = JSON.parse_string(FileAccess.get_file_as_string(TRACE)) if FileAccess.file_exists(TRACE) else null
	var available: bool = raw is Dictionary and raw.get("hz") == 60 and raw.get("fixture") == "hero-step-slope-v1" and raw.get("frames", []).size() == TICKS
	report("Havok SDK behavior trace available for this scenario", available, {"trace": TRACE})
	if not available:
		return
	var state_differences := 0
	var same_inputs := true
	var godot_transitions: Array[Dictionary] = []
	var havok_transitions: Array[Dictionary] = []
	var position_errors: Array[Dictionary] = []
	var channels := ["root", "left_ankle", "right_ankle"]
	for channel in channels:
		position_errors.append({"max_m": 0.0, "peak_tick": 0, "sum_squared": 0.0})
	for i in TICKS:
		var actual := frames[i]
		var expected: Dictionary = raw.frames[i]
		same_inputs = same_inputs and actual.stick.is_equal_approx(Vector2(expected.stick[0], expected.stick[1]))
		same_inputs = same_inputs and is_equal_approx(actual.trigger, float(expected.get("trigger", -1.0)))
		state_differences += int(actual.state != expected.state)
		record_transition(godot_transitions, actual.state, i)
		record_transition(havok_transitions, expected.state, i)
		var actual_points: Array[Vector3] = [actual.root, actual.feet[0], actual.feet[1]]
		var expected_points := [expected.root, expected.feet[0], expected.feet[1]]
		for channel in channels.size():
			var distance := actual_points[channel].distance_to(Hero.vector(expected_points[channel]))
			var stats := position_errors[channel]
			stats.sum_squared += distance * distance
			if distance > stats.max_m:
				stats.max_m = distance
				stats.peak_tick = i
			if i == TICKS - 1:
				var point := actual_points[channel]
				stats.final_m = distance
				stats.godot_final = [point.x, point.y, point.z]
				stats.havok_final = expected_points[channel]
	report("same per-tick inputs as Havok", same_inputs)
	report("same movement states as Havok", state_differences == 0, {
		"different_ticks": state_differences, "godot_transitions": godot_transitions, "havok_transitions": havok_transitions
	})
	for channel in channels.size():
		var stats := position_errors[channel]
		stats.rms_m = sqrt(stats.sum_squared / TICKS)
		stats.erase("sum_squared")
		report(channels[channel] + " position parity", stats.max_m <= POSITION_TOLERANCE, stats)


func record_transition(transitions: Array[Dictionary], state: String, tick: int) -> void:
	if transitions.is_empty() or transitions.back().state != state:
		transitions.append({"state": state, "tick": tick})
