extends SceneTree

const Store := preload("res://characters/character_store.gd")
const CrowdEval := preload("res://addons/animation_studio/crowd_evaluator.gd")
const ShowcaseScene := preload("res://characters/character_showcase.tscn")

var _passed := 0
var _failed := 0


func _emit(payload: Dictionary) -> void:
	print("PFTEST " + JSON.stringify(payload))


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		_emit({"status": "PASS", "test": label, "detail": detail})
	else:
		_failed += 1
		_emit({"status": "FAIL", "test": label, "detail": detail})


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_emit({"status": "START", "engine": Engine.get_version_info().get("hash", "")})
	var catalog := Store.load_catalog(true)
	_check("unified catalog lists all 30 internalized characters", catalog.size() == 30, JSON.stringify({"count": catalog.size()}))

	var loaded_count := 0
	var total_bones := 0
	var total_meshes := 0
	var total_verts := 0
	var total_clips := 0
	var worst_pos_mm := 0.0
	var worst_rot_deg := 0.0
	var worst_char := ""
	var min_saving_pct := 100.0
	var failures: Array[String] = []

	var holder := Node3D.new()
	root.add_child(holder)

	var native_available := CrowdEval.native_available()

	for entry in catalog:
		var cid := str(entry.get("id", ""))
		var glb_path := str(entry.get("glb_path", ""))
		var mot_path := str(entry.get("motion_path", ""))
		if not FileAccess.file_exists(glb_path) or not ResourceLoader.exists(mot_path):
			failures.append("%s:missing_files" % cid)
			continue

		var rig := Store.build_rig(cid, "Verify_" + cid)
		if rig.is_empty():
			failures.append("%s:build_rig_failed" % cid)
			continue
		holder.add_child(rig["root"])

		var skel: Skeleton3D = rig["skeleton"]
		var skin_info: Dictionary = rig["skin_info"]
		var bc := skel.get_bone_count()
		var mc := int(skin_info.get("meshes", 0))
		var vc := int(skin_info.get("vertices", 0))
		if bc != int(entry.get("bones", -1)) or mc <= 0 or vc <= 0:
			failures.append("%s:rig_mismatch(b=%d,m=%d,v=%d)" % [cid, bc, mc, vc])
			rig["root"].queue_free()
			continue

		# Clone skeleton to compare AnimationPlayer vs 16-bit QuantizedClip
		var qskel := Skeleton3D.new()
		holder.add_child(qskel)
		Store.populate_skeleton(qskel, rig["data"])

		var lib: AnimationLibrary = rig["library"]
		var player: AnimationPlayer = rig["player"]
		var clip_names: Array = entry.get("clips", [])

		for c_idx in clip_names.size():
			var cname := str(clip_names[c_idx])
			if not lib.has_animation(cname):
				failures.append("%s:%s:missing_clip" % [cid, cname])
				continue
			var anim: Animation = lib.get_animation(cname)
			var qclip = CrowdEval.QuantizedClip.bake_from_animation(anim, skel, 60.0)
			var res_bytes: int = qclip.resident_bytes()
			var uncomp_bytes: int = CrowdEval.QuantizedClip.uncompressed_bytes(qclip.bone_count, qclip.key_count)
			var saving_pct := (1.0 - float(res_bytes) / maxf(1.0, float(uncomp_bytes))) * 100.0
			min_saving_pct = minf(min_saving_pct, saving_pct)

			# Sample start, middle, and near-end (inside [0, length) to match LOOP_LINEAR wrap semantics)
			for frac in [0.0, 0.43, 0.98]:
				var t := clampf(anim.length * frac, 0.0, anim.length)
				skel.reset_bone_poses()
				player.assigned_animation = cname
				player.seek(t, true)
				player.advance(0.0)
				Store.apply_quantized_to_skeleton(qclip, qskel, t)
				for bi in bc:
					var pm := skel.get_bone_pose_position(bi).distance_to(qskel.get_bone_pose_position(bi)) * 1000.0
					var lr := skel.get_bone_pose_rotation(bi).normalized()
					var rr := qskel.get_bone_pose_rotation(bi).normalized()
					var rd := rad_to_deg(2.0 * acos(clampf(absf(lr.dot(rr)), 0.0, 1.0)))
					if pm > worst_pos_mm:
						worst_pos_mm = pm
						worst_char = "%s:%s@%.2f" % [cid, cname, t]
					if rd > worst_rot_deg:
						worst_rot_deg = rd
			total_clips += 1

		loaded_count += 1
		total_bones += bc
		total_meshes += mc
		total_verts += vc
		qskel.queue_free()
		rig["root"].queue_free()

	_emit({
		"status": "INFO",
		"test": "character_roster_summary",
		"data": {
			"characters": loaded_count,
			"total_bones": total_bones,
			"total_meshes": total_meshes,
			"total_vertices": total_verts,
			"total_clips": total_clips,
			"worst_pos_mm": worst_pos_mm,
			"worst_rot_deg": worst_rot_deg,
			"worst_case": worst_char,
			"min_memory_saving_pct": min_saving_pct,
			"native_cpp": native_available,
		},
	})

	_check(
		"all 30 characters load native .res + .glb cleanly with zero SDK dependency",
		loaded_count == 30 and failures.is_empty(),
		JSON.stringify({"loaded": loaded_count, "failures": failures})
	)
	_check(
		"all 30 characters x all clips match AnimationPlayer vs 16-bit C++ within 5mm / 2.5deg",
		worst_pos_mm <= 5.0 and worst_rot_deg <= 2.5,
		JSON.stringify({"worst_pos_mm": worst_pos_mm, "worst_rot_deg": worst_rot_deg, "worst_case": worst_char})
	)
	_check(
		"all 30 characters achieve >= 65% QuantizedClip memory reduction",
		min_saving_pct >= 65.0,
		JSON.stringify({"min_saving_pct": min_saving_pct})
	)

	# Verify interactive CharacterShowcase scene switching across categories & modes
	var showcase = ShowcaseScene.instantiate()
	root.add_child(showcase)
	await process_frame
	showcase.set_playing(false)
	var switch_ok := true
	for cid in ["orc_captain", "orc_troll", "havok_girl", "firefighter", "fetid_hulk", "gingerbread", "soldier"]:
		showcase.select_character(cid)
		await process_frame
		var m: Dictionary = showcase.get_last_metrics()
		if str(m.get("char_id", "")) != cid or float(m.get("max_pos_mm", 99.0)) > 5.0:
			switch_ok = false
			break
	showcase.set_display_mode("parade")
	await process_frame
	var parade_count: int = showcase.parade_rigs.size()
	showcase.queue_free()
	holder.queue_free()
	await process_frame
	Store.clear_caches()

	_check(
		"CharacterShowcase switches seamlessly across categories and launches multi-character parade",
		switch_ok and parade_count >= 5,
		JSON.stringify({"switch_ok": switch_ok, "parade_count": parade_count})
	)

	_emit({"status": "SUMMARY", "fail": _failed})
	quit(0 if _failed == 0 else 1)
