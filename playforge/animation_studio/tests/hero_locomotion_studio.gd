extends SceneTree
## Headless verification for Hero Locomotion State-Machine Walkthrough & Rewind Studio
## (shared between Godot Editor bottom panel and standalone runtime scene).

const PoseBuffer := preload("res://addons/animation_studio/pose_buffer.gd")

var failures := 0


func _initialize() -> void:
	run.call_deferred()


func report(label: String, valid: bool, details: Dictionary = {}) -> void:
	if not valid:
		failures += 1
	print("PFTEST ", JSON.stringify({"test": label, "status": "PASS" if valid else "FAIL", "detail": JSON.stringify(details)}))


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))

	# 1. Verify editor plugin manifest and script load cleanly.
	var cfg_ok := FileAccess.file_exists("res://addons/animation_studio/plugin.cfg")
	var plugin_script := load("res://addons/animation_studio/editor_plugin.gd") as Script
	report("editor plugin manifest and script load cleanly",
		cfg_ok and plugin_script != null and plugin_script.is_tool())

	# 2. Load the shared studio scene (same scene mounted in Editor bottom panel).
	change_scene_to_file("res://hero/hero_locomotion_studio.tscn")
	await scene_changed
	await process_frame
	var studio = current_scene
	studio.set_playing(false)

	report("Hero studio loads 85-bone rig and bakes 255 ticks",
		studio.assets_ready and studio.rig.get_bone_count() == 85 and studio.recorded_frames.size() == 255,
		{"bones": studio.rig.get_bone_count(), "frames": studio.recorded_frames.size()})

	# 3. Verify authoring stages 1..5 progressively unlock states & subsystems.
	studio.set_build_stage(1)
	var s1_states := _unique_states(studio.recorded_frames)
	report("stage 1 runs Idle state only", s1_states == ["idle"], {"states": s1_states})

	studio.set_build_stage(2)
	var s2_states := _unique_states(studio.recorded_frames)
	report("stage 2 unlocks Idle -> IdleToWalk -> Walk without Run",
		s2_states == ["idle", "idle_to_walk", "walk"], {"states": s2_states})

	studio.set_build_stage(3)
	var s3_states := _unique_states(studio.recorded_frames)
	var s3_max_cam := 0.0
	var s3_ik_hits := 0
	for f in studio.recorded_frames:
		s3_max_cam = maxf(s3_max_cam, absf(float(f.camera_lead_deg)))
		s3_ik_hits += int(f.ik_hits)
	report("stage 3 adds Run + camera lead rotation without Foot IK",
		s3_states == ["idle", "idle_to_walk", "walk", "run"] and s3_max_cam > 5.0 and s3_ik_hits == 0,
		{"states": s3_states, "max_cam_lead_deg": s3_max_cam, "ik_hits": s3_ik_hits})

	studio.set_build_stage(5)
	var s5_ik_hits := 0
	for f in studio.recorded_frames:
		s5_ik_hits += int(f.ik_hits)
	report("stage 5 includes complete state machine + camera lead + Foot IK",
		s5_ik_hits == 255 * 2 and studio.recorded_frames[31].state == "idle_to_walk"
			and studio.recorded_frames[57].state == "walk"
			and studio.recorded_frames[90].state == "run"
			and studio.recorded_frames[202].state == "idle",
		{"ik_hits": s5_ik_hits})

	# 4. Verify Rewind scrubbing across key transition ticks restores exact 85-bone pose & root.
	var max_pose_err := 0.0
	var max_root_err := 0.0
	for target_t in [254, 202, 175, 90, 57, 31, 0, 150]:
		var frame: Dictionary = studio.scrub_to(target_t)
		var captured := PoseBuffer.capture_from_skeleton(studio.rig)
		var expected: PoseBuffer = frame.pose
		var diff: Dictionary = captured.max_diff(expected)
		max_pose_err = maxf(max_pose_err, maxf(float(diff.max_pos_m), float(diff.max_rot_rad)))
		max_root_err = maxf(max_root_err, studio.motion_node.position.distance_to(frame.root_transform.origin))
	report("rewind scrubbing across transition ticks restores exact 85-bone pose and root",
		max_pose_err < 1e-5 and max_root_err < 1e-5,
		{"max_pose_err": max_pose_err, "max_root_err_m": max_root_err})

	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)


func _unique_states(frames: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	for f in frames:
		var st: String = str(f.state)
		if not out.has(st):
			out.append(st)
	return out
