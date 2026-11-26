extends SceneTree
## Headless verification for Stage 2:
## 1) Single-slot upper-body masked attack during locomotion
## 2) Quintic inertialization (single-clip base eval + transition continuity + convergence)
## 3) Graph highlight metadata and skeleton_updated Rewind ring buffer + determinism

const PoseBuffer = preload("res://addons/animation_studio/pose_buffer.gd")
const STEP := 1.0 / 60.0

var failures := 0


func _initialize() -> void:
	run.call_deferred()


func report(label: String, valid: bool, details: Dictionary = {}) -> void:
	if not valid:
		failures += 1
	print("PFTEST ", JSON.stringify({"test": label, "status": "PASS" if valid else "FAIL", "detail": JSON.stringify(details)}))


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))
	change_scene_to_file("res://demo/graph_studio.tscn")
	await scene_changed
	var studio = current_scene
	studio.set_running(false)
	await process_frame

	var skel: Skeleton3D = studio.skeleton
	var mask: PackedFloat32Array = studio.upper_mask

	# 1. Verify upper-body branch mask separates Spine subtree from legs.
	var spine_idx := skel.find_bone(&"Spine")
	var hand_idx := skel.find_bone(&"Hand.R")
	var hip_l_idx := skel.find_bone(&"HipLeft")
	var hip_r_idx := skel.find_bone(&"HipRight")
	var mask_ok := spine_idx >= 0 and hand_idx >= 0 and hip_l_idx >= 0 and hip_r_idx >= 0 \
		and mask[spine_idx] > 0.5 and mask[hand_idx] > 0.5 and mask[hip_l_idx] < 0.5 and mask[hip_r_idx] < 0.5
	report("upper-body branch mask isolates spine subtree from legs", mask_ok, {
		"spine": mask[spine_idx] if spine_idx >= 0 else -1.0,
		"hand_r": mask[hand_idx] if hand_idx >= 0 else -1.0,
		"hip_l": mask[hip_l_idx] if hip_l_idx >= 0 else -1.0,
		"hip_r": mask[hip_r_idx] if hip_r_idx >= 0 else -1.0,
	})

	# 2 & 3. Run deterministic scenario twice for determinism + feature checks.
	var run1 := await _run_scenario(studio)
	var run2 := await _run_scenario(studio)

	# Upper-body attack while moving: lower body identical to pure move, upper body diverges.
	report("upper-body attack preserves lower-body locomotion pose",
		run1.lower_diff_rad < 1e-4 and run1.lower_diff_pos < 1e-4,
		{"lower_rot_rad": run1.lower_diff_rad, "lower_pos_m": run1.lower_diff_pos})
	report("upper-body attack drives upper-body bones during movement",
		run1.upper_diff_rad > 0.35,
		{"upper_rot_rad": run1.upper_diff_rad})
	report("attack slot auto-completes and returns to single-clip base",
		run1.post_attack_slot_weight < 1e-4 and run1.post_attack_clips == 1,
		{"slot_weight": run1.post_attack_slot_weight, "clips": run1.post_attack_clips})
	report("attack slot cancellation blends out cleanly",
		run1.cancelled_cleanly,
		{"cancel_ticks": run1.cancel_ticks})

	# Inertialization checks: strictly 1 base clip evaluated, smooth transition, clean convergence.
	report("inertial transition evaluates strictly 1 base clip per tick",
		run1.max_base_clips_during_inertial == 1,
		{"max_base_clips": run1.max_base_clips_during_inertial})
	report("inertial transition reduces pose jump vs hard cut",
		run1.inertial_jump_rad < run1.hard_cut_jump_rad * 0.25 and run1.hard_cut_jump_rad > 0.15,
		{"inertial_jump_rad": run1.inertial_jump_rad, "hard_cut_jump_rad": run1.hard_cut_jump_rad})
	report("inertial transition converges to pure target pose",
		run1.post_inertial_diff_rad < 1e-4 and not run1.post_inertial_active,
		{"diff_rad": run1.post_inertial_diff_rad, "still_active": run1.post_inertial_active})

	# Graph highlight metadata checks.
	report("graph highlight exposes inertial and slot active nodes",
		run1.saw_inertial_node and run1.saw_slot_node and run1.highlight_cleared,
		{"saw_inertial": run1.saw_inertial_node, "saw_slot": run1.saw_slot_node, "cleared": run1.highlight_cleared})

	# Rewind capture, ring buffer cap, and scrub restoration.
	report("rewind recorder captures via skeleton_updated within fixed capacity",
		run1.rewind_count == studio.recorder.capacity and run1.rewind_total > studio.recorder.capacity,
		{"buffered": run1.rewind_count, "capacity": studio.recorder.capacity, "total": run1.rewind_total})
	report("rewind scrub restores exact pose and root transform",
		run1.scrub_pose_err_rad < 1e-4 and run1.scrub_root_err_m < 1e-4,
		{"pose_err_rad": run1.scrub_pose_err_rad, "root_err_m": run1.scrub_root_err_m})

	# Determinism across two identical replays.
	var det_diff: Dictionary = run1.final_pose.max_diff(run2.final_pose)
	var det_ok: bool = det_diff.max_rot_rad < 1e-5 and det_diff.max_pos_m < 1e-5 \
		and run1.final_root.distance_to(run2.final_root) < 1e-5 \
		and run1.state_trace == run2.state_trace
	report("identical input replay is deterministic", det_ok, {
		"rot_diff_rad": det_diff.max_rot_rad, "pos_diff_m": det_diff.max_pos_m,
		"root_diff_m": run1.final_root.distance_to(run2.final_root)
	})

	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)


func _latest_pose(studio) -> PoseBuffer:
	var count: int = studio.recorder.get_frame_count()
	if count > 0:
		var frame: Dictionary = studio.recorder.get_frame(count - 1)
		if frame.has("pose"):
			return frame.pose
	return PoseBuffer.capture_from_skeleton(studio.skeleton)


func _run_scenario(studio) -> Dictionary:
	studio.reset_demo()
	studio.set_running(false)
	var skel: Skeleton3D = studio.skeleton
	var mask: PackedFloat32Array = studio.upper_mask

	var state_trace: Array[String] = []
	var saw_slot_node := false
	var saw_inertial_node := false
	var max_base_clips_during_inertial := 0

	# Phase A: Move for 15 ticks (0.25s) to reach peak leg/arm stride pose.
	for _i in 15:
		var s: Dictionary = await studio.step_tick_await()
		state_trace.append(s.state + ":" + str(s.total_clips_evaluated))

	# Trigger upper-body attack while moving.
	studio.trigger_attack()
	var attack_peak_pose: PoseBuffer = null
	var attack_peak_time := 0.0
	for t in 40:
		var s: Dictionary = await studio.step_tick_await()
		state_trace.append(s.state + ":" + str(s.total_clips_evaluated))
		if "Slot:attack" in s.active_nodes:
			saw_slot_node = true
		if t == 10:
			attack_peak_pose = _latest_pose(studio)
			attack_peak_time = float(s.state_time)

	var pure_move_pose := PoseBuffer.new()
	pure_move_pose.sample_animation(studio.move_anim, skel, attack_peak_time, false, &"Root")
	var lower_diff: Dictionary = attack_peak_pose.max_diff(pure_move_pose, mask, true)
	var upper_diff: Dictionary = attack_peak_pose.max_diff(pure_move_pose, mask, false)

	var post_attack: Dictionary = await studio.step_tick_await()
	var post_attack_slot_weight: float = float(post_attack.slot_weight)
	var post_attack_clips: int = int(post_attack.total_clips_evaluated)

	# Test mid-attack cancellation.
	studio.trigger_attack()
	for _i in 6:
		await studio.step_tick_await()
	studio.cancel_attack()
	var cancel_ticks := 0
	for _i in 15:
		var s: Dictionary = await studio.step_tick_await()
		cancel_ticks += 1
		if float(s.slot_weight) <= 1e-4:
			break
	var cancelled_cleanly: bool = not studio.graph.is_slot_active()

	# Phase B: Advance to high-angle stride tick then trigger inertial transition to idle.
	for _i in 8:
		await studio.step_tick_await()
	var before_trans_pose := _latest_pose(studio)
	var pure_idle_start := PoseBuffer.new()
	pure_idle_start.sample_animation(studio.idle_anim, skel, 0.0, false, &"Root")
	var hard_cut_jump_rad: float = before_trans_pose.max_diff(pure_idle_start).max_rot_rad

	studio.graph.transition_to(&"idle", 0.20)
	var first_trans_snap: Dictionary = await studio.step_tick_await()
	var first_trans_pose := _latest_pose(studio)
	var inertial_jump_rad: float = before_trans_pose.max_diff(first_trans_pose).max_rot_rad
	max_base_clips_during_inertial = maxi(max_base_clips_during_inertial, int(first_trans_snap.base_clips_evaluated))
	if "Inertialize" in first_trans_snap.active_nodes:
		saw_inertial_node = true

	var last_snap: Dictionary = first_trans_snap
	for _i in 20:
		last_snap = await studio.step_tick_await()
		if bool(last_snap.inertial_active):
			max_base_clips_during_inertial = maxi(max_base_clips_during_inertial, int(last_snap.base_clips_evaluated))
			if "Inertialize" in last_snap.active_nodes:
				saw_inertial_node = true

	var post_inertial_pose := _latest_pose(studio)
	var pure_idle_now := PoseBuffer.new()
	pure_idle_now.sample_animation(studio.idle_anim, skel, float(last_snap.state_time), false, &"Root")
	var post_inertial_diff_rad: float = post_inertial_pose.max_diff(pure_idle_now).max_rot_rad
	var highlight_cleared: bool = (not ("Inertialize" in last_snap.active_nodes)) and (not ("Slot:attack" in last_snap.active_nodes))

	# Phase C: Push past ring buffer capacity (300) to verify fixed capacity wrap-around.
	for _i in studio.recorder.capacity + 30:
		if studio.recorder.get_total_recorded() > studio.recorder.capacity + 25:
			break
		await studio.step_tick_await()
	var final_pose := _latest_pose(studio)
	var final_root: Vector3 = studio.character.global_position

	# Scrub back to a recorded frame inside the ring buffer and verify exact restoration.
	var target_logical := 40
	var recorded_frame: Dictionary = studio.recorder.get_frame(target_logical)
	var expected_pose: PoseBuffer = recorded_frame.pose
	var expected_root: Vector3 = recorded_frame.root_transform.origin
	studio.scrub_to(target_logical)
	var scrubbed_pose := PoseBuffer.capture_from_skeleton(skel)
	var scrubbed_root: Vector3 = studio.character.global_position
	var scrub_diff: Dictionary = scrubbed_pose.max_diff(expected_pose)

	return {
		"lower_diff_rad": lower_diff.max_rot_rad,
		"lower_diff_pos": lower_diff.max_pos_m,
		"upper_diff_rad": upper_diff.max_rot_rad,
		"post_attack_slot_weight": post_attack_slot_weight,
		"post_attack_clips": post_attack_clips,
		"cancelled_cleanly": cancelled_cleanly,
		"cancel_ticks": cancel_ticks,
		"max_base_clips_during_inertial": max_base_clips_during_inertial,
		"inertial_jump_rad": inertial_jump_rad,
		"hard_cut_jump_rad": hard_cut_jump_rad,
		"post_inertial_diff_rad": post_inertial_diff_rad,
		"post_inertial_active": bool(last_snap.inertial_active),
		"saw_inertial_node": saw_inertial_node,
		"saw_slot_node": saw_slot_node,
		"highlight_cleared": highlight_cleared,
		"rewind_count": studio.recorder.get_frame_count(),
		"rewind_total": studio.recorder.get_total_recorded(),
		"scrub_pose_err_rad": scrub_diff.max_rot_rad,
		"scrub_root_err_m": scrubbed_root.distance_to(expected_root),
		"final_pose": final_pose,
		"final_root": final_root,
		"state_trace": state_trace,
	}
