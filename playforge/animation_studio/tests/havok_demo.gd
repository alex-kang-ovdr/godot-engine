extends SceneTree

const DEMO_SCENE := "res://demo/animation_lab.tscn"
const TICK := 1.0 / 60.0
const EPSILON := 0.002
const SUITE := "havok_animation_lab"

var failures := 0
var demo: Node3D
var character: Node3D
var skeleton: Skeleton3D
var tool: Node3D
var hand_index := -1
var tool_offset := Transform3D.IDENTITY
var capture_count := 0
var offset_changes := 0
var socket_position_error := 0.0
var socket_basis_failures := 0
var captured_hand_world := Transform3D.IDENTITY
var captured_tool_world := Transform3D.IDENTITY
var captured_tool_relative := Transform3D.IDENTITY


func _initialize() -> void:
	run.call_deferred()


func _check(condition: bool, label: String, detail: Variant = "") -> void:
	if not condition:
		failures += 1
		push_error("HAVOKTEST FAIL %s %s" % [label, detail])
	print("PFTEST " + JSON.stringify({"status": "PASS" if condition else "FAIL", "suite": SUITE, "test": label, "detail": str(detail)}))


func _info(label: String, data: Variant) -> void:
	print("PFTEST " + JSON.stringify({"status": "INFO", "suite": SUITE, "test": label, "data": data}))


func run() -> void:
	print("PFTEST " + JSON.stringify({"status": "START", "suite": SUITE, "engine": Engine.get_version_info().get("hash", ""), "version": Engine.get_version_info().get("string", "")}))
	_check(str(ProjectSettings.get_setting("application/run/main_scene", "")) == DEMO_SCENE, "project main scene points at the public demo", ProjectSettings.get_setting("application/run/main_scene", ""))
	var packed := load(DEMO_SCENE) as PackedScene
	_check(packed != null, "demo scene loads", DEMO_SCENE)
	if packed == null:
		_finish()
		return
	if change_scene_to_packed(packed) != OK:
		_check(false, "demo scene activation succeeded")
		_finish()
		return
	await scene_changed
	demo = current_scene as Node3D
	_check(demo != null, "demo root is Node3D")
	if demo == null:
		_finish()
		return
	# The scene starts live. Pause immediately before yielding so the fixture
	# controls every subsequent advance through the public step_tick API.
	demo.call("set_running", false)
	await process_frame
	_check(root.get_camera_3d() == demo.get_node("Camera3D"), "demo camera retains ownership after platform scene startup")
	character = demo.get("character") as Node3D
	tool = character.call("get_tool") as Node3D if character and character.has_method("get_tool") else null
	skeleton = character.get_node_or_null("Rig") as Skeleton3D if character else null
	_check(character != null and skeleton != null and skeleton.get_node_or_null("Pose") != null, "public character Rig/Pose nodes resolve")
	_check(demo.has_method("set_running") and demo.has_method("step_tick") and demo.has_method("reset_demo") and demo.has_method("set_speed"), "interactive control API exists")
	_check(character.has_method("get_tool") and character.has_method("get_tool_offset") and character.has_method("get_tool_socket_bone_name") and tool != null, "tool socket API exists")
	if not character or not skeleton or not tool:
		_finish()
		return
	var socket_bone: StringName = character.call("get_tool_socket_bone_name")
	hand_index = skeleton.find_bone(socket_bone)
	_check(hand_index >= 0, "configured tool socket bone resolves", socket_bone)
	tool_offset = character.call("get_tool_offset")
	_check(not tool_offset.is_equal_approx(Transform3D.IDENTITY), "tool socket offset is nonidentity", tool_offset)
	skeleton.skeleton_updated.connect(_on_skeleton_updated)
	demo.call("reset_demo")
	demo.call("set_running", false)
	await _wait_for_idle_frames(2)
	_check(not bool(demo.get("running")), "reset preserves paused state")
	_check(float(demo.get("speed")) == 1.0, "reset restores normal speed")
	if hand_index < 0:
		_finish()
		return

	await _check_socket_pose_following()
	await _check_markers_loops_and_rotated_root_motion()
	await _check_pause_reset_and_restart()
	await _check_playback_speeds()
	_info("socket_fit", {"samples": capture_count, "max_position_error": socket_position_error, "basis_failures": socket_basis_failures, "offset_changes": offset_changes})
	_check(socket_position_error <= EPSILON, "socket world position equals same-frame hand pose times offset", socket_position_error)
	_check(socket_basis_failures == 0, "socket world basis equals same-frame hand basis times offset", socket_basis_failures)
	_check(offset_changes == 0, "tool offset stays independent from animated hand transform", offset_changes)
	_finish()


func _on_skeleton_updated() -> void:
	if not is_instance_valid(demo) or not is_instance_valid(character) or not is_instance_valid(skeleton) or not is_instance_valid(tool) or hand_index < 0:
		return
	var live_offset: Transform3D = character.call("get_tool_offset")
	if not live_offset.is_equal_approx(tool_offset):
		offset_changes += 1
	captured_hand_world = skeleton.global_transform * skeleton.get_bone_global_pose(hand_index)
	var expected_tool_world := captured_hand_world * tool_offset
	captured_tool_world = tool.global_transform
	captured_tool_relative = character.global_transform.affine_inverse() * captured_tool_world
	socket_position_error = maxf(socket_position_error, expected_tool_world.origin.distance_to(captured_tool_world.origin))
	if not expected_tool_world.basis.is_equal_approx(captured_tool_world.basis):
		socket_basis_failures += 1
	capture_count += 1


func _check_socket_pose_following() -> void:
	demo.call("reset_demo")
	demo.call("set_running", false)
	await _wait_for_idle_frames(2)
	var samples_before := capture_count
	await _step_and_capture()
	var initial_relative := captured_tool_relative
	var initial_pose := captured_hand_world
	for _tick in 29:
		await _step_and_idle()
	var later_relative := captured_tool_relative
	var later_pose := captured_hand_world
	_check(capture_count >= samples_before + 30, "manual ticks produce deferred skeleton samples", "samples=%d" % capture_count)
	var moved := initial_relative.origin.distance_to(later_relative.origin) > 0.01 or not initial_relative.basis.is_equal_approx(later_relative.basis)
	_check(moved, "tool follows actual hand movement across poses", "initial_hand=%s later_hand=%s initial_tool=%s later_tool=%s" % [initial_pose, later_pose, initial_relative, later_relative])
	_check(not tool_offset.is_equal_approx(Transform3D.IDENTITY), "socket movement test uses nonidentity local offset")


func _check_markers_loops_and_rotated_root_motion() -> void:
	demo.call("reset_demo")
	demo.call("set_running", false)
	character.rotation = Vector3(0.0, PI / 2.0, 0.0)
	var start_world := character.global_position
	for tick in 14:
		await _step_and_idle()
	_check(int(demo.get("left_steps")) == 0 and int(demo.get("right_steps")) == 0, "no marker fires before first quarter-cycle", "L=%d R=%d" % [demo.get("left_steps"), demo.get("right_steps")])
	await _step_and_idle()
	_check(int(demo.get("left_steps")) == 1 and int(demo.get("right_steps")) == 0, "left marker fires on quarter-cycle boundary", "L=%d R=%d" % [demo.get("left_steps"), demo.get("right_steps")])
	for _tick in 29:
		await _step_and_idle()
	_check(int(demo.get("right_steps")) == 0, "right marker remains pending before three-quarter boundary")
	await _step_and_idle()
	_check(int(demo.get("left_steps")) == 1 and int(demo.get("right_steps")) == 1, "right marker fires on three-quarter boundary", "L=%d R=%d" % [demo.get("left_steps"), demo.get("right_steps")])
	for _tick in 15:
		await _step_and_idle()
	_check(int(demo.get("left_steps")) == 1 and int(demo.get("right_steps")) == 1, "loop boundary does not duplicate markers")
	for _tick in 15:
		await _step_and_idle()
	_check(int(demo.get("left_steps")) == 2 and int(demo.get("right_steps")) == 1, "next loop quarter marker fires once")
	for _tick in 30:
		await _step_and_idle()
	_check(int(demo.get("right_steps")) == 2, "next loop three-quarter marker fires once")
	for _tick in 15:
		await _step_and_idle()
	var displacement := character.global_position - start_world
	_check(int(demo.get("left_steps")) == 2 and int(demo.get("right_steps")) == 2, "two loops emit exactly two markers per side", "L=%d R=%d" % [demo.get("left_steps"), demo.get("right_steps")])
	_check(is_equal_approx(float(demo.get("distance_traveled")), 2.4), "two root-motion cycles accumulate 2.4 units", demo.get("distance_traveled"))
	_check(displacement.distance_to(Vector3(0.0, 0.0, -2.4)) <= 0.02, "local +X root motion follows rotated actor heading", displacement)
	_check(socket_position_error <= EPSILON and socket_basis_failures == 0, "rotated same-frame socket pose remains correct", "position_error=%s basis_failures=%d" % [socket_position_error, socket_basis_failures])


func _check_pause_reset_and_restart() -> void:
	demo.call("reset_demo")
	demo.call("set_running", false)
	for _tick in 20:
		await _step_and_idle()
	_check(int(demo.get("left_steps")) == 1 and int(demo.get("right_steps")) == 0, "partial run reaches only left marker")
	demo.call("set_running", true)
	await physics_frame
	demo.call("set_running", false)
	var frozen_position := player_time()
	var frozen_distance := float(demo.get("distance_traveled"))
	var frozen_left := int(demo.get("left_steps"))
	var frozen_right := int(demo.get("right_steps"))
	await _wait_for_idle_frames(4)
	_check(is_equal_approx(player_time(), frozen_position) and is_equal_approx(float(demo.get("distance_traveled")), frozen_distance) and int(demo.get("left_steps")) == frozen_left and int(demo.get("right_steps")) == frozen_right, "pause remains frozen across idle and physics frames")
	var paused_time := player_time()
	demo.call("step_tick")
	await _wait_for_idle_frames(2)
	_check(is_equal_approx(player_time(), paused_time + TICK), "explicit step_tick advances once while paused", player_time())
	demo.call("reset_demo")
	await _wait_for_idle_frames(2)
	_check(not bool(demo.get("running")) and float(demo.get("speed")) == 1.0 and int(demo.get("left_steps")) == 0 and int(demo.get("right_steps")) == 0 and is_zero_approx(float(demo.get("distance_traveled"))) and character.transform.is_equal_approx(Transform3D.IDENTITY), "reset clears progress, position, and heading while preserving pause")
	for _tick in 60:
		await _step_and_idle()
	_check(int(demo.get("left_steps")) == 1 and int(demo.get("right_steps")) == 1, "restart plays both markers from the beginning", "L=%d R=%d" % [demo.get("left_steps"), demo.get("right_steps")])
	_check(is_equal_approx(float(demo.get("distance_traveled")), 1.2), "restart accumulates one root-motion cycle")


func _check_playback_speeds() -> void:
	for speed_case: Dictionary in [
		{"speed": 0.5, "left_tick": 30, "right_tick": 90, "cycle_ticks": 120},
		{"speed": 1.0, "left_tick": 15, "right_tick": 45, "cycle_ticks": 60},
		{"speed": 2.0, "left_tick": 8, "right_tick": 23, "cycle_ticks": 30},
	]:
		var rate_label := "%.1fx" % speed_case.speed
		demo.call("reset_demo")
		demo.call("set_running", false)
		demo.call("set_speed", speed_case.speed)
		_check(is_equal_approx(float(demo.get("speed")), speed_case.speed), "speed setter applies supported rate", speed_case.speed)
		for tick in range(1, speed_case.cycle_ticks + 1):
			await _step_and_idle()
			if tick == speed_case.left_tick - 1:
				_check(int(demo.get("left_steps")) == 0, "%s left marker pending before scaled boundary" % rate_label, "tick=%d" % tick)
			if tick == speed_case.left_tick:
				_check(int(demo.get("left_steps")) == 1, "%s left marker crosses scaled boundary once" % rate_label, "tick=%d" % tick)
			if tick == speed_case.right_tick - 1:
				_check(int(demo.get("right_steps")) == 0, "%s right marker pending before scaled boundary" % rate_label, "tick=%d" % tick)
			if tick == speed_case.right_tick:
				_check(int(demo.get("right_steps")) == 1, "%s right marker crosses scaled boundary once" % rate_label, "tick=%d" % tick)
		_check(int(demo.get("left_steps")) == 1 and int(demo.get("right_steps")) == 1, "%s cycle emits one marker each" % rate_label, speed_case)
		_check(is_equal_approx(float(demo.get("distance_traveled")), 1.2), "%s cycle retains 1.2-unit displacement" % rate_label, "distance=%s" % demo.get("distance_traveled"))
	demo.call("reset_demo")
	_check(is_equal_approx(float(demo.get("speed")), 1.0), "reset returns playback speed to one")


func _step_and_capture() -> void:
	var before := capture_count
	demo.call("step_tick")
	await _wait_for_capture(before)


func _step_and_idle() -> void:
	var before := capture_count
	demo.call("step_tick")
	var captured := await _await_capture(before)
	if not captured:
		_check(false, "manual tick produced deferred skeleton update")


func _wait_for_capture(previous_count: int) -> void:
	_check(await _await_capture(previous_count), "Skeleton3D emitted deferred same-frame update")


func _await_capture(previous_count: int) -> bool:
	for _frame in 8:
		if capture_count > previous_count:
			return true
		await process_frame
	return capture_count > previous_count


func _wait_for_idle_frames(count: int) -> void:
	for _frame in count:
		await process_frame
		await physics_frame


func player_time() -> float:
	var player := character.get_node("Player") as AnimationPlayer
	return player.current_animation_position


func _finish() -> void:
	print("PFTEST " + JSON.stringify({"status": "SUMMARY", "suite": SUITE, "fail": failures}))
	quit(1 if failures > 0 else 0)
