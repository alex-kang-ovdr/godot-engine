extends SceneTree

const Gallery := preload("res://catalog/gallery.tscn")

var failed := 0

func _initialize() -> void:
	run.call_deferred()


func record(test: String, ok: bool, detail: String = "") -> void:
	if not ok:
		failed += 1
	print("PFTEST ", JSON.stringify({"test": test, "status": "PASS" if ok else "FAIL", "detail": detail}))


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))
	change_scene_to_file("res://demo/animation_lab.tscn")
	await scene_changed
	current_scene.get_node("HUD/%Gallery").pressed.emit()
	await scene_changed
	var lab = current_scene
	record("motion lab opens gallery", lab.scene_file_path == Gallery.resource_path)
	record("catalog has animation and behavior cases", not lab.entries.is_empty())
	var paths := {}
	var anim_count := 0
	var beh_count := 0
	for index in lab.entries.size():
		lab.select_entry(index)
		await physics_frame
		await physics_frame
		await process_frame
		var item: Dictionary = lab.entries[index]
		paths[item.path] = true
		var prod := str(item.get("product", "animation")).to_lower()
		if prod == "behavior":
			beh_count += 1
		else:
			anim_count += 1
		var ok: bool = lab.selected_index == index and is_instance_valid(lab.probe)
		if ok:
			ok = not str(lab.probe.status_text()).strip_edges().is_empty() and not lab.probe.find_children("*", "VisualInstance3D", true, false).is_empty()
		var source := str(item.path).to_lower()
		var script_path: String = lab.probe.get_script().resource_path if ok else ""
		if ok and script_path.ends_with("/behavior_cases.gd"):
			var probe = lab.probe
			match probe.family:
				"hero_showcase":
					ok = probe.hero_instance != null and probe.hero_instance.rig.get_bone_count() == 85
				"docking":
					ok = probe.dock_dist < probe.dock_start_dist
				"quadruped_ik":
					ok = probe.foot_hits >= 2 and not probe.find_children("*", "TwoBoneIK3D", true, false).is_empty()
				"driver_ik":
					ok = probe.controller != null or not probe.find_children("*", "TwoBoneIK3D", true, false).is_empty()
				"ragdoll_driver":
					ok = not probe.ragdoll_joints.is_empty() and absf(probe.ragdoll_torque) > 0.01
				"modifier":
					ok = probe.attached_obj != null or not probe.find_children("*", "LookAtModifier3D", true, false).is_empty()
				"retargeting":
					ok = not probe.find_children("*", "RetargetModifier3D", true, false).is_empty()
				"save_state":
					ok = probe.recorder.get_frame_count() >= 1 and probe.restore_err_rad < 1e-4
				"determinism":
					ok = probe.determinism_diff_rad < 1e-5
				"swap_skins":
					ok = probe.skin_swaps >= 1
				"crowd":
					ok = probe.crowd_skels.size() == probe.crowd_count and probe.crowd_evaluator != null
				"generator":
					ok = probe.generator_mode != "" and (probe.generator_mode != "blender_tree" or not probe.find_children("*", "AnimationTree", true, false).is_empty())
				"state_machine":
					ok = probe.state_transitions >= 1 and (not ("returntoprevious" in source) or probe.returned_to_prev)
				"partial_stagger":
					ok = probe.graph != null and probe.graph.is_slot_active()
		else:
			if ok and "/blending/" in source:
				ok = not lab.probe.find_children("*", "AnimationTree", true, false).is_empty()
			if ok and "/ragdoll/" in source:
				ok = not lab.probe.find_children("*", "PhysicalBoneSimulator3D", true, false).is_empty()
			if ok and "/retargeting/" in source and not "multithread" in source:
				ok = not lab.probe.find_children("*", "RetargetModifier3D", true, false).is_empty()
			if ok and script_path.ends_with("/runtime_cases.gd"):
				var probe = lab.probe
				match probe.family:
					"worker":
						ok = probe.samples.size() == 48 and probe.samples[3].origin.y > 0.4 and probe.max_difference < 0.00001
					"skin":
						ok = probe.rig.get_bone_count() >= 2 and probe.rig.get_bone_pose_rotation(1).get_angle() > 0.001
					"actor":
						ok = probe.traveled > 0.0 and probe.actor.tool.is_inside_tree()
			if ok and script_path.ends_with("/timing_cases.gd"):
				ok = lab.probe.evaluations > 0 and lab.probe.poses[1].is_normalized()
		record("%d %s" % [index, item.name], ok, item.path)
	record("catalog includes both Animation and Behavior demos", anim_count >= 270 and beh_count >= 130,
		"animation=%d behavior=%d" % [anim_count, beh_count])
	lab.products.select(2)
	lab.products.item_selected.emit(2)
	record("product filter selects Behavior demos only", lab.listing.item_count == beh_count)
	lab.products.select(0)
	lab.products.item_selected.emit(0)
	lab.search.text = "no-such-havok-example"
	lab.search.text_changed.emit(lab.search.text)
	record("empty search removes active scene", lab.selected_index == -1 and lab.listing.item_count == 0)
	lab.search.text = ""
	lab.search.text_changed.emit(lab.search.text)
	record("cleared search restores catalog", lab.selected_index == 0 and lab.listing.item_count == lab.entries.size())
	lab.families.select(1)
	lab.families.item_selected.emit(1)
	record("family filter narrows choices", lab.listing.item_count > 0 and lab.listing.item_count < lab.entries.size())
	print("PFTEST ", JSON.stringify({"status": "INFO", "test": "coverage", "data": {
		"entries": lab.entries.size(), "animation": anim_count, "behavior": beh_count, "sources": paths.size()
	}}))
	lab.back.pressed.emit()
	await scene_changed
	record("gallery returns to motion lab", current_scene.scene_file_path == "res://demo/animation_lab.tscn")
	var store_script := preload("res://characters/character_store.gd")
	store_script.clear_caches()
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failed}))
	quit(1 if failed else 0)
