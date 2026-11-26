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
	record("catalog has animation cases", not lab.entries.is_empty())
	var paths := {}
	for index in lab.entries.size():
		lab.select_entry(index)
		await physics_frame
		await physics_frame
		await process_frame
		var item: Dictionary = lab.entries[index]
		paths[item.path] = true
		var ok: bool = lab.selected_index == index and is_instance_valid(lab.probe)
		if ok:
			ok = not str(lab.probe.status_text()).strip_edges().is_empty() and not lab.probe.find_children("*", "VisualInstance3D", true, false).is_empty()
		var source := str(item.path).to_lower()
		if ok and "/blending/" in source:
			ok = not lab.probe.find_children("*", "AnimationTree", true, false).is_empty()
		if ok and "/ragdoll/" in source:
			ok = not lab.probe.find_children("*", "PhysicalBoneSimulator3D", true, false).is_empty()
		if ok and "/retargeting/" in source and not "multithread" in source:
			ok = not lab.probe.find_children("*", "RetargetModifier3D", true, false).is_empty()
		if ok and lab.probe.get_script().resource_path.ends_with("/runtime_cases.gd"):
			var probe = lab.probe
			match probe.family:
				"worker":
					ok = probe.samples.size() == 48 and probe.samples[3].origin.y > 0.4 and probe.max_difference < 0.00001
				"skin":
					ok = probe.rig.get_bone_count() == 2 and probe.rig.get_bone_pose_rotation(1).get_angle() > 0.001
				"actor":
					ok = probe.traveled > 0.0 and probe.actor.tool.is_inside_tree()
		if ok and lab.probe.get_script().resource_path.ends_with("/timing_cases.gd"):
			ok = lab.probe.evaluations > 0 and lab.probe.poses[1].is_normalized()
		record("%d %s" % [index, item.name], ok, item.path)
	lab.search.text = "no-such-havok-example"
	lab.search.text_changed.emit(lab.search.text)
	record("empty search removes active scene", lab.selected_index == -1 and lab.listing.item_count == 0)
	lab.search.text = ""
	lab.search.text_changed.emit(lab.search.text)
	record("cleared search restores catalog", lab.selected_index == 0 and lab.listing.item_count == lab.entries.size())
	lab.families.select(1)
	lab.families.item_selected.emit(1)
	record("family filter narrows choices", lab.listing.item_count > 0 and lab.listing.item_count < lab.entries.size())
	print("PFTEST ", JSON.stringify({"status": "INFO", "test": "coverage", "data": {"entries": lab.entries.size(), "sources": paths.size()}}))
	lab.back.pressed.emit()
	await scene_changed
	record("gallery returns to motion lab", current_scene.scene_file_path == "res://demo/animation_lab.tscn")
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failed}))
	quit(1 if failed else 0)
