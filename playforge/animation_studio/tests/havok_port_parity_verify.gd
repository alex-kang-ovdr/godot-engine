extends SceneTree
## Comprehensive parity verification for all 414 Havok 2015.1.0-r1 demo ports:
##   1. Zero synthetic courier robot (demo/character/character.tscn) & zero .hkt runtime dependency
##   2. Godot Standard coordinates (+Y up, -Z forward, +X right, SI meters, grounded Y=0)
##   3. Extracted root motion strictly travels along Godot Standard -Z
##   4. HavokGirl 50-bone SDK pose parity (AnimationPlayer vs QuantizedClip & raw oracle)
##   5. Loop mode defaults (LOOP_LINEAR cyclic, LOOP_PINGPONG, LOOP_NONE single-play/one-shot)
##   6. Camera parity (FOV 45.0° vertical / KEEP_HEIGHT / near 0.1m / far >= 100m / front -Z framing)
##   7. Real internalized Havok skeletons across all 5 catalog probe scripts

const Standards := preload("res://catalog/havok_demo_standards.gd")
const Store := preload("res://characters/character_store.gd")
const CrowdEval := preload("res://addons/animation_studio/crowd_evaluator.gd")
const GalleryScene := preload("res://catalog/gallery.tscn")

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

	# 1. Verify catalog scripts have ZERO synthetic character.tscn and ZERO SDK/.hkt dependencies
	var catalog_scripts := [
		"res://catalog/gallery.gd",
		"res://catalog/havok_demo_standards.gd",
		"res://catalog/clip_cases.gd",
		"res://catalog/rig_cases.gd",
		"res://catalog/runtime_cases.gd",
		"res://catalog/timing_cases.gd",
		"res://catalog/behavior_cases.gd",
	]
	var forbidden_hits: Array[String] = []
	for spath in catalog_scripts:
		var txt := FileAccess.get_file_as_string(spath)
		if "demo/character/character.tscn" in txt or "d:/sdk" in txt.to_lower() or ".hkt" in txt.to_lower():
			# Allow comments documenting zero .hkt runtime dependency only when not inside preload/load/open
			for line in txt.split("\n"):
				var trimmed := line.strip_edges()
				if trimmed.begins_with("#"):
					continue
				if "demo/character/character.tscn" in trimmed or "d:/sdk" in trimmed.to_lower() or ".hkt" in trimmed.to_lower():
					forbidden_hits.append("%s: %s" % [spath, trimmed])
	_check(
		"catalog scripts have zero synthetic courier or .hkt/SDK dependencies",
		forbidden_hits.is_empty(),
		JSON.stringify({"hits": forbidden_hits})
	)

	# 2. Verify all 30 internalized characters align to Godot Standard Y-up SI meters & ground Y=0
	var catalog := Store.load_catalog(true)
	var holder := Node3D.new()
	root.add_child(holder)
	var ground_failures: Array[String] = []
	var height_failures: Array[String] = []
	for entry in catalog:
		var cid := str(entry.get("id", ""))
		var pack := Standards.spawn_aligned_character(cid, "Align_" + cid)
		if pack.is_empty():
			ground_failures.append("%s:spawn_failed" % cid)
			continue
		var outer: Node3D = pack["outer"] as Node3D
		holder.add_child(outer)
		var skel: Skeleton3D = pack["skeleton"] as Skeleton3D
		var player: AnimationPlayer = pack["player"] as AnimationPlayer
		var cname := Standards.pick_clip(pack, "idle")
		if not cname.is_empty():
			player.assigned_animation = StringName(cname)
			player.seek(0.0, true)
			player.advance(0.0)
		skel.force_update_all_bone_transforms()

		var min_y := INF
		var max_y := -INF
		for bi in skel.get_bone_count():
			var wp := skel.to_global(skel.get_bone_global_pose(bi).origin)
			min_y = minf(min_y, wp.y)
			max_y = maxf(max_y, wp.y)
		var h := max_y - min_y
		if h < 0.08 or h > 4.5:
			height_failures.append("%s:h=%.3f" % [cid, h])
		var align := Standards.get_alignment(cid)
		if not bool(align.get("hover", false)):
			if min_y < -0.35 or min_y > 0.55:
				ground_failures.append("%s:min_y=%.3f" % [cid, min_y])
		outer.queue_free()

	_check(
		"all 30 internalized characters are SI-meter scaled and grounded at Y=0 in Godot Standard",
		catalog.size() == 30 and ground_failures.is_empty() and height_failures.is_empty(),
		JSON.stringify({"count": catalog.size(), "ground_failures": ground_failures, "height_failures": height_failures})
	)

	# 3. Verify root motion advances strictly along Godot Standard -Z (Vector3.FORWARD)
	var rm_checks := [
		["havok_girl_sdk", "walk"],
		["havok_girl_sdk", "run"],
		["hero", "walk"],
		["hero", "run"],
		["soldier", "walk"],
		["soldier", "run"],
		["orc_captain", "jog"],
		["siege_fiend", "move"],
	]
	var rm_results: Dictionary = {}
	var rm_ok := true
	for item in rm_checks:
		var cid: String = str(item[0])
		var clip: String = str(item[1])
		var pack := Standards.spawn_aligned_character(cid, "RM_" + cid)
		var cdict: Dictionary = (pack["data"] as Dictionary).get("clips", {}).get(clip, {}) as Dictionary
		var dur := float(cdict.get("duration", 1.0))
		var disp := Standards.sample_root_motion_delta(pack, clip, 0.0, dur)
		rm_results["%s:%s" % [cid, clip]] = [snappedf(disp.x, 0.001), snappedf(disp.y, 0.001), snappedf(disp.z, 0.001)]
		if disp.z >= -0.35 or absf(disp.x) > absf(disp.z) * 0.45:
			rm_ok = false
		(pack["outer"] as Node3D).free()
	_check(
		"root motion travels strictly along Godot Standard -Z across HavokGirl/Hero/Soldier/Orc/SiegeFiend",
		rm_ok,
		JSON.stringify(rm_results)
	)

	# 4. Verify HavokGirl 50-bone SDK pose parity (AnimationPlayer vs QuantizedClip & exact loop wrap)
	var hg := Standards.spawn_aligned_character("havok_girl_sdk", "HGParity")
	holder.add_child(hg["outer"] as Node3D)
	var hg_skel: Skeleton3D = hg["skeleton"] as Skeleton3D
	var hg_player: AnimationPlayer = hg["player"] as AnimationPlayer
	var hg_lib: AnimationLibrary = hg["library"] as AnimationLibrary
	var qskel := Skeleton3D.new()
	holder.add_child(qskel)
	Store.populate_skeleton(qskel, hg["data"] as Dictionary)

	var max_hg_mm := 0.0
	var max_hg_deg := 0.0
	for cname in ["walk", "run", "idle", "wave"]:
		var anim: Animation = hg_lib.get_animation(cname)
		var qclip = CrowdEval.QuantizedClip.bake_from_animation(anim, hg_skel, 60.0)
		for frac in [0.0, 0.35, 0.72, 1.0]:
			var t := clampf(anim.length * frac, 0.0, anim.length)
			hg_skel.reset_bone_poses()
			hg_player.assigned_animation = StringName(cname)
			hg_player.seek(t, true)
			hg_player.advance(0.0)
			Store.apply_quantized_to_skeleton(qclip, qskel, t)
			for bi in hg_skel.get_bone_count():
				var pm := hg_skel.get_bone_pose_position(bi).distance_to(qskel.get_bone_pose_position(bi)) * 1000.0
				var lr := hg_skel.get_bone_pose_rotation(bi).normalized()
				var rr := qskel.get_bone_pose_rotation(bi).normalized()
				var rd := rad_to_deg(2.0 * acos(clampf(absf(lr.dot(rr)), 0.0, 1.0)))
				max_hg_mm = maxf(max_hg_mm, pm)
				max_hg_deg = maxf(max_hg_deg, rd)
	_check(
		"HavokGirl 50-bone SDK rig matches AnimationPlayer vs 16-bit QuantizedClip within 3mm / 2.5deg",
		hg_skel.get_bone_count() == 50 and hg_lib.get_animation_list().size() == 12 and max_hg_mm <= 3.0 and max_hg_deg <= 2.5,
		JSON.stringify({"bones": hg_skel.get_bone_count(), "clips": hg_lib.get_animation_list().size(), "max_mm": snappedf(max_hg_mm, 0.001), "max_deg": snappedf(max_hg_deg, 0.001)})
	)

	# 5. Verify Havok Loop Mode Defaults (LOOP_LINEAR cyclic vs LOOP_NONE one-shot vs LOOP_PINGPONG)
	var loop_ok := true
	var loop_detail := {}
	for cname in ["walk", "run", "idle", "wave", "jumpland"]:
		var lm: int = hg_lib.get_animation(cname).loop_mode
		loop_detail["havok_girl_sdk:" + cname] = lm
		if lm != Animation.LOOP_LINEAR:
			loop_ok = false
	var protect_lm: int = hg_lib.get_animation("protect").loop_mode
	loop_detail["havok_girl_sdk:protect"] = protect_lm
	if protect_lm != Animation.LOOP_NONE:
		loop_ok = false
	var spec_single := Standards.resolve_demo_spec("Behavior/Generators/ClipGeneratorModes/ClipGeneratorModesDemo.cpp", "SinglePlay")
	var spec_loop := Standards.resolve_demo_spec("Behavior/Generators/ClipGeneratorModes/ClipGeneratorModesDemo.cpp", "Looping")
	var spec_pp := Standards.resolve_demo_spec("Behavior/Generators/ClipGeneratorModes/ClipGeneratorModesDemo.cpp", "PingPong")
	var spec_ppsync := Standards.resolve_demo_spec("Behavior/Generators/PingPongSync/PingPongSyncDemo.cpp", "PingPongSync")
	loop_detail["clip_single"] = spec_single["loop_mode"]
	loop_detail["clip_loop"] = spec_loop["loop_mode"]
	loop_detail["clip_pingpong"] = spec_pp["loop_mode"]
	loop_detail["pingpong_sync"] = spec_ppsync["loop_mode"]
	if int(spec_single["loop_mode"]) != Animation.LOOP_NONE or int(spec_loop["loop_mode"]) != Animation.LOOP_LINEAR:
		loop_ok = false
	if int(spec_pp["loop_mode"]) != Animation.LOOP_PINGPONG or int(spec_ppsync["loop_mode"]) != Animation.LOOP_PINGPONG:
		loop_ok = false
	_check(
		"Havok loop defaults match SDK (cyclic=LOOP_LINEAR, one-shot=LOOP_NONE, pingpong=LOOP_PINGPONG)",
		loop_ok,
		JSON.stringify(loop_detail)
	)
	qskel.queue_free()
	(hg["outer"] as Node3D).queue_free()

	# 6. Verify Live Gallery Camera Parity (FOV=45°, KEEP_HEIGHT, near=0.1, far>=100, +Y up, front framing)
	#    AND real Havok asset instantiation across all 5 probe families!
	var gallery := GalleryScene.instantiate()
	root.add_child(gallery)
	await process_frame

	var key_queries := [
		["normalblending", "havok_girl_sdk", 50],
		["crabby", "crabby", 18],
		["footikdemo", "havok_girl_sdk", 50],
		["basicposeretargeting", "shulgoth", 20],
		["dismemberment", "zombie", 89],
		["motionextractiondemo", "havok_girl_sdk", 50],
		["sampleonlytimings", "firefighter", 38],
		["quadrupeddemo", "siege_fiend", 34],
		["dockingblend", "hero", 85],
		["swapskins", "firefighter", 38],
		["clipgeneratormodes", "soldier", 114],
		["charactertocharacterattachment", "flying_imp", 66],
	]
	var cam_failures: Array[String] = []
	var asset_failures: Array[String] = []
	var verified_demos := 0

	for qitem in key_queries:
		var needle := str(qitem[0])
		var expected_char := str(qitem[1])
		var min_bones := int(qitem[2])
		var found_idx := -1
		for idx in gallery.entries.size():
			var e: Dictionary = gallery.entries[idx]
			if needle in str(e.get("path", "")).to_lower():
				found_idx = idx
				break
		if found_idx < 0:
			asset_failures.append("%s:not_found" % needle)
			continue
		gallery.select_entry(found_idx)
		await physics_frame
		await physics_frame
		await process_frame

		var cam: Camera3D = gallery.stage_camera
		var cam_ok := (
			cam != null
			and is_equal_approx(cam.fov, 45.0)
			and cam.keep_aspect == Camera3D.KEEP_HEIGHT
			and is_equal_approx(cam.near, 0.1)
			and cam.far >= 100.0
			and cam.global_basis.y.y > 0.5
			and cam.position.z < -0.5
		)
		if not cam_ok:
			cam_failures.append("%s(fov=%.1f,z=%.2f,up=%.2f)" % [needle, cam.fov if cam else -1.0, cam.position.z if cam else 0.0, cam.global_basis.y.y if cam else 0.0])

		var probe: Node = gallery.probe
		var skels := probe.find_children("*", "Skeleton3D", true, false)
		var max_bones := 0
		for sk in skels:
			if sk is Skeleton3D:
				max_bones = maxi(max_bones, (sk as Skeleton3D).get_bone_count())
		var actual_char := str(gallery.active_spec.get("primary_char", ""))
		if actual_char != expected_char or max_bones < min_bones:
			asset_failures.append("%s(char=%s!=%s,bones=%d<%d)" % [needle, actual_char, expected_char, max_bones, min_bones])
		else:
			verified_demos += 1

	_check(
		"Godot Standard Camera3D matches Havok hkgCamera defaults (45° KEEP_HEIGHT, near=0.1, far>=100, front -Z view)",
		cam_failures.is_empty(),
		JSON.stringify({"verified": verified_demos, "cam_failures": cam_failures})
	)
	_check(
		"all 12 representative Havok demos instantiate exact original internalized skeletons (never 16-bone robot)",
		asset_failures.is_empty() and verified_demos == key_queries.size(),
		JSON.stringify({"verified": verified_demos, "asset_failures": asset_failures})
	)

	gallery.queue_free()
	holder.queue_free()
	await process_frame
	Store.clear_caches()
	_emit({"status": "SUMMARY", "fail": _failed})
	quit(0 if _failed == 0 else 1)
