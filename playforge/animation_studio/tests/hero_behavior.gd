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
		var states := {}
		var max_move := 0.0
		var hits := 0
		var adjustments := 0
		var raised_ground := 0
		var max_yaw := 0.0
		for frame in first:
			states[frame.state] = true
			max_move = maxf(max_move, first_frame.root.distance_to(frame.root))
			max_yaw = maxf(max_yaw, absf(frame.yaw))
			for leg in 2:
				if frame.hits[leg]:
					hits += 1
					raised_ground += int(frame.targets[leg].y > 0.12)
					var before: float = frame.before[leg].distance_to(frame.targets[leg])
					var after: float = frame.feet[leg].distance_to(frame.targets[leg])
					adjustments += int(before - after > 0.005)
		report("no-input, walk, run and stop", first_frame.state == "idle" and end_frame.state == "idle"
			and states.has("walk") and states.has("run") and max_move > 1.0, {"states": states.keys(), "distance_m": max_move})
		report("direction input rotates locomotion root", max_yaw > 0.7, {"max_rad": max_yaw})
		report("terrain rays produce raised contacts", hits >= TICKS and raised_ground > 0, {"contacts": hits, "raised": raised_ground})
		report("IK moves ankles toward terrain targets", adjustments >= 20, {"adjusted_ankles": adjustments})
		report("fixed-input replay repeatable", first == second)
		hero.get_node("%Behavior").pressed.emit()
		report("switch back to clip comparison", hero.locomotion == null and not hero.selected.is_empty())
		print("PFTEST ", JSON.stringify({"status": "INFO", "test": "behavior replay", "data": {
			"ticks": first.size(), "first_state": first_frame.state, "last_state": end_frame.state
		}}))
		if "--native" in OS.get_cmdline_user_args():
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
	var max_root := 0.0
	var max_feet := 0.0
	var same_inputs := true
	for i in TICKS:
		var actual := frames[i]
		var expected: Dictionary = raw.frames[i]
		same_inputs = same_inputs and actual.stick.is_equal_approx(Vector2(expected.stick[0], expected.stick[1]))
		same_inputs = same_inputs and is_equal_approx(actual.trigger, float(expected.get("trigger", -1.0)))
		state_differences += int(actual.state != expected.state)
		max_root = maxf(max_root, actual.root.distance_to(Hero.vector(expected.root)))
		for leg in 2:
			max_feet = maxf(max_feet, actual.feet[leg].distance_to(Hero.vector(expected.feet[leg])))
	report("same per-tick inputs as Havok", same_inputs)
	report("same movement states as Havok", state_differences == 0, {"different_ticks": state_differences})
	report("Havok root position parity", max_root <= POSITION_TOLERANCE, {"max_m": max_root})
	report("Havok ankle position parity", max_feet <= POSITION_TOLERANCE, {"max_m": max_feet})
