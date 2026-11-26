extends SceneTree
## Headless verification for the Procedural Quadruped Locomotor Studio
## (Unreal Engine Locomotor reference: 28 bones, 0 clips, Walk/Trot/Pace/Gallop,
## zero foot sliding, uneven terrain pitch/roll & 4-limb FBIK, 14-step authoring replay + rewind).

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

	change_scene_to_file("res://quadruped/quadruped_locomotor_studio.tscn")
	await scene_changed
	await process_frame
	var studio = current_scene
	studio.set_playing(false)

	# 1. Pure procedural 28-bone rig + 300-tick bake (0 clips)
	report("28-bone procedural quadruped rig builds and bakes 300 ticks with zero clips",
		studio.assets_ready and studio.rig.get_bone_count() == 28 and studio.recorded_frames.size() == 300,
		{"bones": studio.rig.get_bone_count(), "frames": studio.recorded_frames.size()})

	# 2. Authoring replay progression: empty -> wireframe -> body -> terrain -> full + backward rewind
	studio.set_authoring_mode(true)
	await process_frame

	studio.seek_authoring(0.4, true)
	var empty_ok: bool = not studio.bone_wire_inst.visible and not studio.body_attachments[0].visible \
		and not studio.terrain_group.visible and not studio.trail_inst.visible \
		and studio.cursor_overlay.active and studio.cursor_overlay.role_id == "assets"
	report("authoring step 1 starts from empty procedural blueprint", empty_ok)

	studio.seek_authoring(2.4, true)
	var wire_ok: bool = studio.bone_wire_inst.visible and not studio.body_attachments[0].visible \
		and not studio.terrain_group.visible
	report("authoring step 3 reveals 28-bone quadruped wireframe skeleton", wire_ok)

	studio.seek_authoring(3.4, true)
	var body_ok: bool = studio.body_attachments[0].visible and not studio.bone_wire_inst.visible \
		and not studio.terrain_group.visible
	report("authoring step 4 binds articulated creature body meshes", body_ok)

	studio.seek_authoring(11.4, true)
	var full_ok: bool = studio.body_attachments[0].visible and studio.terrain_group.visible \
		and studio.gizmo_inst.visible and studio.trail_inst.visible and studio.build_stage == 5 \
		and studio.log_list.item_count == 12
	report("authoring step 12 completes terrain, FBIK gizmos, and 300-tick trail", full_ok,
		{"stage": studio.build_stage, "logs": studio.log_list.item_count})

	# Backward rewind from 13.5s -> 2.4s must roll back body, terrain, gizmos, trail, and logs
	studio.seek_authoring(13.5, true)
	studio.seek_authoring(2.4, true)
	var rewind_ok: bool = studio.bone_wire_inst.visible and not studio.body_attachments[0].visible \
		and not studio.terrain_group.visible and not studio.gizmo_inst.visible and not studio.trail_inst.visible \
		and studio.log_list.item_count == 3 and studio.scene_tree_list.item_count == 3
	report("authoring replay rewinds cleanly from completion back to 28-bone wireframe", rewind_ok,
		{"logs": studio.log_list.item_count, "nodes": studio.scene_tree_list.item_count})

	# 3. Morpheme network selection & 5-track timeline scrub
	studio.network_canvas.node_selected.emit("node_fbik")
	var attr_ok: bool = "4-Limb FBIK" in studio.inspector_label.text
	studio.gait_timeline.scrub_requested.emit(0.75)
	var scrub_ok: bool = studio.authoring_time > 10.0 and studio.authoring_time < 11.0
	report("Morpheme network click updates Attribute Editor and 5-track timeline scrubs", attr_ok and scrub_ok)

	# 4. Auto course gaits, zero foot sliding, and terrain climb adaptation
	studio.set_authoring_mode(false)
	studio.set_gait_mode("auto")
	studio.set_build_stage(5)
	var seen_gaits: Array[String] = []
	var max_slide_mm := 0.0
	var max_root_y := 0.0
	var max_pitch_deg := 0.0
	var max_dist := 0.0
	for f in studio.recorded_frames:
		var g: String = str(f.gait)
		if not seen_gaits.has(g):
			seen_gaits.append(g)
		max_slide_mm = maxf(max_slide_mm, float(f.max_slide_mm))
		max_root_y = maxf(max_root_y, (f.root_transform as Transform3D).origin.y)
		max_pitch_deg = maxf(max_pitch_deg, absf(float(f.pelvis_pitch_deg)))
		max_dist = maxf(max_dist, (f.root_transform as Transform3D).origin.length())

	report("auto course transitions across Idle, Walk, Trot, and Gallop gaits",
		seen_gaits.has("idle") and seen_gaits.has("walk") and seen_gaits.has("trot") and seen_gaits.has("gallop") and max_dist > 8.0,
		{"gaits": seen_gaits, "distance_m": max_dist})
	report("planted paws lock in world space with zero foot sliding (< 1mm)",
		max_slide_mm < 1.0, {"max_slide_mm": max_slide_mm})
	report("terrain steps and slope elevate root and pitch pelvis naturally",
		max_root_y >= 0.30 and max_pitch_deg > 4.0,
		{"max_root_y_m": max_root_y, "max_pitch_deg": max_pitch_deg})

	# 5. Diagonal Trot pairing verification (FL+HR move together, FR+HL move together)
	studio.set_gait_mode("trot")
	var trot_diag_matches := 0
	var trot_swing_samples := 0
	for tick in range(100, 165):
		var feet: Dictionary = studio.recorded_frames[tick].feet
		var fl: bool = bool(feet["FL"].planted)
		var fr: bool = bool(feet["FR"].planted)
		var hl: bool = bool(feet["HL"].planted)
		var hr: bool = bool(feet["HR"].planted)
		if not fl or not fr or not hl or not hr:
			trot_swing_samples += 1
			if fl == hr and fr == hl:
				trot_diag_matches += 1
	report("Trot gait coordinates diagonal leg pairs (FL+HR / FR+HL)",
		trot_swing_samples > 10 and float(trot_diag_matches) / float(maxi(1, trot_swing_samples)) > 0.75,
		{"diag_matches": trot_diag_matches, "swing_samples": trot_swing_samples})

	# 6. Exact 300-tick rewind pose determinism
	studio.set_gait_mode("auto")
	var max_pose_err := 0.0
	var max_root_err := 0.0
	for t in [299, 240, 185, 115, 55, 0, 150]:
		var frame: Dictionary = studio.scrub_to(t)
		var captured := PoseBuffer.capture_from_skeleton(studio.rig)
		var expected: PoseBuffer = frame.pose
		var diff: Dictionary = captured.max_diff(expected)
		max_pose_err = maxf(max_pose_err, maxf(float(diff.max_pos_m), float(diff.max_rot_rad)))
		max_root_err = maxf(max_root_err, studio.root_node.position.distance_to(frame.root_transform.origin))
	report("300-tick rewind scrubbing restores exact 28-bone pose and root",
		max_pose_err < 1e-5 and max_root_err < 1e-5,
		{"max_pose_err": max_pose_err, "max_root_err_m": max_root_err})

	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)
