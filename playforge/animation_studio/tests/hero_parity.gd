extends SceneTree

var failures := 0


func _initialize() -> void:
	run.call_deferred()


func report(label: String, valid: bool, details: Dictionary = {}) -> void:
	if not valid:
		failures += 1
	print("PFTEST ", JSON.stringify({"test": label, "status": "PASS" if valid else "FAIL", "detail": JSON.stringify(details)}))


func angle_between(a: Quaternion, b: Quaternion) -> float:
	var d := a.normalized().inverse() * b.normalized()
	return 2.0 * atan2(Vector3(d.x, d.y, d.z).length(), absf(d.w))


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))
	change_scene_to_file("res://demo/animation_lab.tscn")
	await scene_changed
	current_scene.get_node("HUD/%HeroSample").pressed.emit()
	await scene_changed
	var hero = current_scene
	hero.set_running(false)
	var reference_path := "res://hero/generated/oracle.json"
	var ready: bool = not hero.selected.is_empty() and FileAccess.file_exists(reference_path)
	report("original Hero playback and native reference available", ready)
	if ready:
		var oracle: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(reference_path))
		report("all exported clips have reference samples", oracle.clips.size() >= 3 and oracle.clips.size() == hero.data.clips.size())
		var meshes: Array[Node] = hero.rig.find_children("*", "MeshInstance3D", false, false)
		var textured := 0
		var skin_info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://hero/generated/hero_skin.json"))
		var bound: bool = not meshes.is_empty() and skin_info.get("rig_sha256") == hero.data.skeleton.source.sha256
		for mesh: MeshInstance3D in meshes:
			bound = bound and mesh.get_node_or_null(mesh.skeleton) == hero.rig and mesh.skin.get_bind_count() > 0
			for j in mesh.mesh.get_surface_count():
				var material := mesh.get_active_material(j) as BaseMaterial3D
				if material and material.albedo_texture:
					textured += 1
		report("original Hero skinned geometry loaded", bound and hero.skin_problem.is_empty() and hero.skin_surfaces == 10 and textured > 0, {
			"surfaces": hero.skin_surfaces, "vertices": hero.skin_vertices, "textured_surfaces": textured})
		# Independently composed model-space positions from the SDK Rig.hkt rest hierarchy, in meters.
		var landmarks := {
			"Head": Vector3(0.0, 1.773590, 0.021750),
			"LeftArmPalm": Vector3(0.581545, 1.274187, 0.048824),
			"RightLegFoot": Vector3(-0.138781, 0.116797, -0.077003)
		}
		var rest_error := 0.0
		for bone_name in landmarks:
			var index: int = hero.rig.find_bone(bone_name)
			if index < 0:
				rest_error = INF
				break
			rest_error = maxf(rest_error, hero.rig.get_bone_global_rest(index).origin.distance_to(landmarks[bone_name]))
		report("original Hero bind pose and coordinate basis", hero.rig.get_bone_count() == 85 and rest_error < 0.0001, {"max_m": rest_error})
		for key in oracle.clips:
			compare_clip(hero, key, oracle.clips[key])
		hero.select_clip("walk")
		hero.set_running(true)
		hero.get_node("%Reference").pressed.emit()
		hero.get_node("%Reference").pressed.emit()
		var reference_time: float = oracle.clips.walk.samples[1].time
		var paused_on_sample: bool = not hero.running and is_equal_approx(hero.elapsed, reference_time)
		hero.get_node("%Step").pressed.emit()
		report("native sample selection and fixed frame step", paused_on_sample and is_equal_approx(hero.elapsed, reference_time + 1.0 / 60.0))
	hero.get_node("%Back").pressed.emit()
	await scene_changed
	report("Hero playback returns to motion lab", current_scene.scene_file_path == "res://demo/animation_lab.tscn")
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)


func compare_clip(hero, key: String, reference: Dictionary) -> void:
	hero.select_clip(key)
	var pos_error := 0.0
	var rot_error := 0.0
	var scale_error := 0.0
	var root_error := 0.0
	var root_angle_error := 0.0
	var count := 0
	var clip: Dictionary = hero.data.clips[key]
	var holdouts := 0
	var valid: bool = key == hero.selected and reference.source_sha256 == clip.source.sha256 and reference.source_sha256.length() == 64
	valid = valid and reference.samples.size() >= 3 and is_zero_approx(reference.samples[0].time) and is_equal_approx(reference.samples[-1].time, clip.duration)
	for sample in reference.samples:
		var frame: float = sample.time * (clip.source.originalFrames - 1) / clip.duration
		if absf(frame - roundf(frame)) > 0.001:
			holdouts += 1
		hero.sample_at(sample.time)
		if sample.pose.size() != hero.rig.get_bone_count():
			valid = false
			continue
		for i in sample.pose.size():
			var expected: Dictionary = sample.pose[i]
			pos_error = maxf(pos_error, hero.rig.get_bone_pose_position(i).distance_to(hero.vector(expected.translation)))
			rot_error = maxf(rot_error, angle_between(hero.rig.get_bone_pose_rotation(i), hero.rotation(expected.rotation)))
			scale_error = maxf(scale_error, hero.rig.get_bone_pose_scale(i).distance_to(hero.vector(expected.scale)))
			count += 1
		var motion: Node3D = hero.get_node("Motion")
		root_error = maxf(root_error, motion.position.distance_to(hero.vector(sample.root.translation)))
		root_angle_error = maxf(root_angle_error, angle_between(motion.quaternion, hero.rotation(sample.root.rotation)))
	valid = valid and holdouts > 0 and count > 0 and pos_error <= 0.001 and rot_error <= 0.005 and scale_error <= 0.001 and root_error <= 0.001 and root_angle_error <= 0.005
	report(key + " original pose and extracted movement", valid, {
		"bone_samples": count, "holdout_times": holdouts, "max_position_m": pos_error, "max_rotation_rad": rot_error,
		"max_scale": scale_error, "max_root_m": root_error, "max_root_rad": root_angle_error})
