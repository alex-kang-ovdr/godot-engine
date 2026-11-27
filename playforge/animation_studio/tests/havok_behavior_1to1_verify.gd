extends SceneTree
## Automated 1:1 Precision Verification Suite:
## Compares REAL Havok 2015.1.0-r1 C++ Behavior SDK traces against Godot 4.7.2 Port
## across all 5 canonical Hero & Behavior scenarios (1,445 ticks @ 60 Hz, 48 events)
## on event timing (Δtick/Δms), state transitions, clip local time, root XZ/Yaw,
## landmark bone positions (mm), zero .hkt runtime dependency, and interactive viewer UI.

const Runner := preload("res://compare/behavior_1to1_runner.gd")
const Store := preload("res://characters/character_store.gd")
const Standards := preload("res://catalog/havok_demo_standards.gd")
const HavokDemoEnv := preload("res://compare/havok_demo_environment.gd")
const HavokRagdollRt := preload("res://compare/havok_ragdoll_runtime.gd")
const COMPARE_SCENE := "res://compare/havok_1to1_compare.tscn"
const REAL_MANIFEST_JSON := "res://compare/assets/havok_real_demo_manifest.json"
const HERO_CONTACT_SHEET := "res://compare/assets/havok_real_hero_contact_sheet.png"
const SOLDIER_CONTACT_SHEET := "res://compare/assets/havok_real_soldier_contact_sheet.png"
const COMPARE_47_REPORT_JSON := "res://compare/assets/havok_47_1to1_report.json"
const COMPARE_47_HERO_SHEET := "res://compare/assets/havok_vs_godot_hero_1to1_sheet.png"
const COMPARE_47_SOLDIER_SHEET := "res://compare/assets/havok_vs_godot_soldier_1to1_sheet.png"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_emit("START", {"suite": "animation_havok_behavior_1to1", "engine": Engine.get_version_info().get("hash", "")})
	_verify_sdk_free_assets()
	_verify_all_five_scenarios()
	_verify_interactive_viewer()
	_verify_real_havok_47_demos_dataset()
	_verify_47_demos_1to1_comparison_report()
	await _verify_restored_environments_and_ragdoll()
	Runner.clear_caches()
	HavokDemoEnv.clear_caches()
	HavokRagdollRt.clear_caches()
	Store.clear_caches()
	_emit("SUMMARY", {"suite": "animation_havok_behavior_1to1", "pass": _pass, "fail": _fail})
	quit(1 if _fail > 0 else 0)


func _verify_sdk_free_assets() -> void:
	var ref_ok := FileAccess.file_exists(Runner.REFERENCE_JSON)
	var ref_text := FileAccess.get_file_as_string(Runner.REFERENCE_JSON) if ref_ok else ""
	var has_hkt := ref_text.find(".hkt") >= 0
	_check("reference_json_sdk_free", ref_ok and not has_hkt and ref_text.length() > 10000,
		"bytes=%d has_hkt=%s" % [ref_text.length(), str(has_hkt)])

	var dock_ok := ResourceLoader.exists(Runner.HERO_DOCKING_CLIP_RES)
	var soldier_ok := ResourceLoader.exists(Runner.SOLDIER_IDLE_READY_RES)
	_check("internalized_behavior_clips_exist", dock_ok and soldier_ok,
		"hero_docking=%s soldier_idle_ready=%s" % [str(dock_ok), str(soldier_ok)])


func _verify_all_five_scenarios() -> void:
	var thresholds := {
		"hero_locomotion_flat": {
			"events": 27, "max_dtick": 0, "state_pct": 100.0,
			"clip_max_ms": 0.5, "root_xz_max_mm": 1.0, "yaw_max_deg": 0.2,
			"pose_rms_mm": 1.5, "pose_max_mm": 15.0,
		},
		"hero_docking_blend": {
			"events": 5, "max_dtick": 0, "state_pct": 100.0,
			"clip_max_ms": 0.5, "root_xz_max_mm": 0.1, "yaw_max_deg": 0.1,
			"pose_rms_mm": 1.0, "pose_max_mm": 5.0,
		},
		"soldier_clip_modes": {
			"events": 5, "max_dtick": 0, "state_pct": 100.0,
			"clip_max_ms": 0.5, "root_xz_max_mm": 0.1, "yaw_max_deg": 0.1,
			"pose_rms_mm": 1.0, "pose_max_mm": 5.0,
		},
		"soldier_return_to_prev": {
			"events": 5, "max_dtick": 0, "state_pct": 100.0,
			"clip_max_ms": 0.5, "root_xz_max_mm": 0.1, "yaw_max_deg": 0.1,
			"pose_rms_mm": 2.0, "pose_max_mm": 20.0,
		},
		"quadruped_siegefiend": {
			"events": 6, "max_dtick": 0, "state_pct": 100.0,
			"clip_max_ms": 0.5, "root_xz_max_mm": 90.0, "yaw_max_deg": 5.0,
			"pelvis_pose_rms_mm": 10.0,
		},
	}

	var total_ticks := 0
	var total_events := 0
	var total_matched := 0
	var worst_event_dtick := 0

	for sc_id in Runner.SCENARIO_ORDER:
		var res := Runner.run_scenario(sc_id, "", false)
		var m: Dictionary = res.get("metrics", {}) as Dictionary
		var th: Dictionary = thresholds[sc_id] as Dictionary

		total_ticks += int(m.get("ticks", 0))
		total_events += int(m.get("havok_events", 0))
		total_matched += int(m.get("matched_events", 0))
		worst_event_dtick = maxi(worst_event_dtick, int(m.get("max_event_dtick", 99)))

		var ev_ok := (
			int(m.get("havok_events", -1)) == int(th["events"])
			and int(m.get("matched_events", -1)) == int(th["events"])
			and int(m.get("unmatched_havok_events", 1)) == 0
			and int(m.get("unmatched_godot_events", 1)) == 0
			and int(m.get("max_event_dtick", 99)) <= int(th["max_dtick"])
		)
		_check("%s_event_timing_exact" % sc_id, ev_ok,
			"matched=%d/%d unmatched_h=%d unmatched_g=%d max_dtick=%d (%.2fms)" % [
				int(m.get("matched_events", 0)), int(m.get("havok_events", 0)),
				int(m.get("unmatched_havok_events", 0)), int(m.get("unmatched_godot_events", 0)),
				int(m.get("max_event_dtick", 99)), float(m.get("max_event_dms", 999.0)),
			])

		var st_ok := float(m.get("state_match_pct", 0.0)) >= float(th["state_pct"])
		var cl_ok := float(m.get("clip_max_ms", 999.0)) <= float(th["clip_max_ms"])
		_check("%s_state_and_clip_timing" % sc_id, st_ok and cl_ok,
			"state=%.2f%% (%d/%d) clip_rms=%.2fms clip_max=%.2fms" % [
				float(m.get("state_match_pct", 0.0)), int(m.get("state_match_ticks", 0)),
				int(m.get("ticks", 0)), float(m.get("clip_rms_ms", 999.0)), float(m.get("clip_max_ms", 999.0)),
			])

		var pos_ok := (
			float(m.get("root_xz_max_mm", 9999.0)) <= float(th["root_xz_max_mm"])
			and float(m.get("yaw_max_deg", 999.0)) <= float(th["yaw_max_deg"])
		)
		if th.has("pose_rms_mm"):
			pos_ok = pos_ok and float(m.get("pose_landmark_rms_mm", 9999.0)) <= float(th["pose_rms_mm"])
			pos_ok = pos_ok and float(m.get("pose_landmark_max_mm", 9999.0)) <= float(th["pose_max_mm"])
		if th.has("pelvis_pose_rms_mm"):
			var lms: Dictionary = m.get("landmarks", {}) as Dictionary
			var pelv_rms := float((lms.get("Bip01 Pelvis", {}) as Dictionary).get("pose_rms_mm", 9999.0))
			pos_ok = pos_ok and pelv_rms <= float(th["pelvis_pose_rms_mm"])
		_check("%s_root_and_landmark_position" % sc_id, pos_ok,
			"root_xz_rms=%.2fmm root_xz_max=%.2fmm yaw_max=%.2fdeg pose_rms=%.2fmm pose_max=%.2fmm" % [
				float(m.get("root_xz_rms_mm", 9999.0)), float(m.get("root_xz_max_mm", 9999.0)),
				float(m.get("yaw_max_deg", 999.0)), float(m.get("pose_landmark_rms_mm", 9999.0)),
				float(m.get("pose_landmark_max_mm", 9999.0)),
			])

	_check("aggregate_5_scenarios_1445_ticks_48_events",
		total_ticks == 1445 and total_events == 48 and total_matched == 48 and worst_event_dtick == 0,
		"ticks=%d matched_events=%d/%d worst_dtick=%d" % [total_ticks, total_matched, total_events, worst_event_dtick])


func _verify_interactive_viewer() -> void:
	var packed := ResourceLoader.load(COMPARE_SCENE) as PackedScene
	_check("viewer_scene_loads", packed != null, COMPARE_SCENE)
	if packed == null:
		return
	var viewer := packed.instantiate()
	root.add_child(viewer)
	viewer.ensure_initialized()
	viewer.set_playing(false)
	var all_ok := true
	for sc_id in Runner.SCENARIO_ORDER:
		viewer.load_scenario(sc_id)
		var summary: Dictionary = viewer.get_comparison_summary()
		if int(summary.get("ticks", 0)) <= 0:
			all_ok = false
		viewer.set_tick(mini(30, int(summary.get("ticks", 1)) - 1))
		viewer.set_compare_mode("side_by_side")
		viewer.set_compare_mode("overlap")
		viewer.set_camera_preset(3)
		viewer.set_camera_preset(0)
	_check("viewer_switches_all_5_scenarios_and_modes", all_ok, "5 scenarios + overlap/side_by_side + camera presets")
	viewer.cleanup()
	root.remove_child(viewer)
	viewer.free()


func _verify_real_havok_47_demos_dataset() -> void:
	var exists := FileAccess.file_exists(REAL_MANIFEST_JSON)
	_check("real_havok_manifest_exists", exists, REAL_MANIFEST_JSON)
	if not exists:
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REAL_MANIFEST_JSON))
	var ok_dict := parsed is Dictionary
	if not ok_dict:
		_check("real_havok_manifest_valid_json", false, "invalid json")
		return
	var manifest: Dictionary = parsed as Dictionary
	var totals: Dictionary = manifest.get("totals", {}) as Dictionary
	var demos: Array = manifest.get("demos", []) as Array

	var counts_ok := (
		int(totals.get("registered_demos", 0)) == 47
		and int(totals.get("captured_ok", 0)) == 47
		and int(totals.get("cross_process_deterministic_ok", 0)) == 47
		and int(totals.get("all_shots_non_blank_ok", 0)) == 47
		and int(totals.get("hero_demos", 0)) == 25
		and int(totals.get("soldier_demos", 0)) == 22
		and int(totals.get("failures", 1)) == 0
		and demos.size() == 47
	)
	_check("real_havok_47_demos_100pct_deterministic_and_non_blank", counts_ok,
		"captured=%d/47 det=%d/47 non_blank=%d/47 hero=%d soldier=%d shots=%d frames=%d events=%d" % [
			int(totals.get("captured_ok", 0)),
			int(totals.get("cross_process_deterministic_ok", 0)),
			int(totals.get("all_shots_non_blank_ok", 0)),
			int(totals.get("hero_demos", 0)),
			int(totals.get("soldier_demos", 0)),
			int(totals.get("total_screenshots", 0)),
			int(totals.get("total_frames_simulated", 0)),
			int(totals.get("total_events_recorded", 0)),
		])

	var by_path: Dictionary = {}
	var all_entries_valid := true
	for item in demos:
		if not (item is Dictionary):
			all_entries_valid = false
			continue
		var d: Dictionary = item as Dictionary
		by_path[String(d.get("menu_path", ""))] = d
		if int(d.get("hz", 0)) != 60 or String(d.get("final_pose_hash", "")).length() != 16:
			all_entries_valid = false
		if not bool(d.get("cross_process_deterministic", false)) or not bool(d.get("all_shots_non_blank", false)):
			all_entries_valid = false
		if (d.get("keyframes", []) as Array).is_empty():
			all_entries_valid = false

	var seeded_hash := String((by_path.get("Behavior/UseCase/SymbolLinking/Seeded", {}) as Dictionary).get("final_pose_hash", ""))
	var unseeded_hash := String((by_path.get("Behavior/UseCase/SymbolLinking/Unseeded", {}) as Dictionary).get("final_pose_hash", ""))
	var hero_ok := int((by_path.get("Behavior/ShowCase/Hero", {}) as Dictionary).get("executed_ticks", 0)) == 600
	var clip_ok := int((by_path.get("Behavior/Api/Generators/ClipGenerator/ClipGeneratorModes", {}) as Dictionary).get("total_events", 0)) == 6
	var save_ok := int((by_path.get("Behavior/Test/Feature/SaveBehaviorState", {}) as Dictionary).get("executed_ticks", 0)) == 180
	_check("real_havok_47_demos_telemetry_and_parity",
		all_entries_valid and hero_ok and clip_ok and save_ok and not seeded_hash.is_empty() and seeded_hash == unseeded_hash,
		"hero_600f=%s clip_6ev=%s save_180f=%s seeded==unseeded=%s" % [str(hero_ok), str(clip_ok), str(save_ok), str(seeded_hash == unseeded_hash)])

	var hero_img := Image.load_from_file(ProjectSettings.globalize_path(HERO_CONTACT_SHEET))
	var soldier_img := Image.load_from_file(ProjectSettings.globalize_path(SOLDIER_CONTACT_SHEET))
	var sheets_ok := (
		hero_img != null and hero_img.get_width() >= 1000 and hero_img.get_height() >= 1000
		and soldier_img != null and soldier_img.get_width() >= 1000 and soldier_img.get_height() >= 1000
	)
	_check("real_havok_contact_sheets_valid", sheets_ok,
		"hero=%dx%d soldier=%dx%d" % [
			hero_img.get_width() if hero_img != null else 0,
			hero_img.get_height() if hero_img != null else 0,
			soldier_img.get_width() if soldier_img != null else 0,
			soldier_img.get_height() if soldier_img != null else 0,
		])


func _verify_47_demos_1to1_comparison_report() -> void:
	var exists := FileAccess.file_exists(COMPARE_47_REPORT_JSON)
	_check("compare_47_1to1_report_exists", exists, COMPARE_47_REPORT_JSON)
	if not exists:
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(COMPARE_47_REPORT_JSON))
	if not (parsed is Dictionary):
		_check("compare_47_1to1_totals_and_fixes", false, "invalid json")
		return
	var report: Dictionary = parsed as Dictionary
	var totals: Dictionary = report.get("totals", {}) as Dictionary
	var demos: Array = report.get("demos", []) as Array
	var by_path: Dictionary = {}
	for d_raw in demos:
		if d_raw is Dictionary:
			by_path[String((d_raw as Dictionary).get("menu_path", ""))] = d_raw

	var ref_pose: Dictionary = by_path.get("Behavior/Api/Generators/ReferencePoseGenerator", {}) as Dictionary
	var sim_trans: Dictionary = by_path.get("Behavior/Test/Feature/SimultaneousTransitionTest", {}) as Dictionary
	var cc_proxy: Dictionary = by_path.get("Behavior/Api/Drivers/CharacterControllerDriver/Character Proxy", {}) as Dictionary
	var cc_jump: Dictionary = by_path.get("Behavior/Api/Drivers/CharacterControllerDriver/Character Rigid Body With Jump", {}) as Dictionary

	var totals_ok := (
		int(totals.get("total_demos", 0)) == 47
		and int(totals.get("asset_rig_match_count", 0)) == 47
		and int(totals.get("landmarks_full_match_count", 0)) == 47
		and int(totals.get("non_blank_pairs", 0)) == 47
		and int(totals.get("total_ticks_compared", 0)) == 15665
		and int(totals.get("tier_a_count", 0)) >= 27
		and int(totals.get("tier_a_sub2mm_count", 0)) >= 18
		and int(totals.get("tier_ab_count", 0)) >= 43
		and int(totals.get("total_events_matched", 0)) == 1545
		and float(totals.get("state_match_mean_pct", 0.0)) >= 99.9
		and float(totals.get("catalog_pose_rms_median_mm", 999.0)) <= 10.0
		and float(totals.get("soldier_pose_rms_median_mm", 999.0)) <= 5.0
		and float(ref_pose.get("catalog_pose_rms_mm", 999.0)) <= 0.5
		and String(sim_trans.get("godot_char", "")) == "soldier"
		and int(sim_trans.get("godot_bones", 0)) == 114
		and float(cc_proxy.get("godot_max_disp_m", 999.0)) <= 15.0
		and float(cc_jump.get("godot_max_disp_m", 999.0)) <= 15.0
	)
	_check("compare_47_1to1_totals_and_fixes", totals_ok,
		"asset=%d/47 tierA=%d(<=2mm:%d) tierB=%d tierAB=%d/47 ev=%d/1545 st=%.1f%% med=%.1fmm(sol=%.1fmm) ref=%.1fmm" % [
			int(totals.get("asset_rig_match_count", 0)),
			int(totals.get("tier_a_count", 0)),
			int(totals.get("tier_a_sub2mm_count", 0)),
			int(totals.get("tier_b_count", 0)),
			int(totals.get("tier_ab_count", 0)),
			int(totals.get("total_events_matched", 0)),
			float(totals.get("state_match_mean_pct", 0.0)),
			float(totals.get("catalog_pose_rms_median_mm", 999.0)),
			float(totals.get("soldier_pose_rms_median_mm", 999.0)),
			float(ref_pose.get("catalog_pose_rms_mm", 999.0)),
		])

	var h_img := Image.load_from_file(ProjectSettings.globalize_path(COMPARE_47_HERO_SHEET))
	var s_img := Image.load_from_file(ProjectSettings.globalize_path(COMPARE_47_SOLDIER_SHEET))
	var sheets_ok := (
		h_img != null and h_img.get_width() >= 1500 and h_img.get_height() >= 1000
		and s_img != null and s_img.get_width() >= 1500 and s_img.get_height() >= 1000
	)
	_check("compare_47_1to1_contact_sheets_valid", sheets_ok,
		"hero_1to1=%dx%d soldier_1to1=%dx%d" % [
			h_img.get_width() if h_img != null else 0,
			h_img.get_height() if h_img != null else 0,
			s_img.get_width() if s_img != null else 0,
			s_img.get_height() if s_img != null else 0,
		])


func _verify_restored_environments_and_ragdoll() -> void:
	# 1. Verify all offline-extracted official Havok environment assets exist & load cleanly (zero .hkt runtime dep)
	var sky_tex := HavokDemoEnv.get_skybox_texture()
	var sky_ok := sky_tex != null and sky_tex.get_width() == 1024 and sky_tex.get_height() == 512
	var lvl_exists := FileAccess.file_exists(HavokDemoEnv.HK_ANIM_LEVEL_GLB)
	var att_exists := FileAccess.file_exists(HavokDemoEnv.ATTACHMENT_SCENE_GLB)
	var props := HavokDemoEnv.get_attachment_props()
	var props_ok := not props.is_empty() and not bool(props.get("contains_sdk_hkt_runtime_dep", true)) and (props.get("bodies", []) as Array).size() == 7
	_check("extracted_official_environments_sdk_free", sky_ok and lvl_exists and att_exists and props_ok,
		"sky=%s hkAnimLevel=%s attachmentScene=%s props_bodies=%d" % [
			str(sky_ok), str(lvl_exists), str(att_exists), (props.get("bodies", []) as Array).size()])

	# 2. Verify HavokDemoEnvironment builds all 10 official scene archetypes without errors
	var env_node := HavokDemoEnv.new()
	env_node.name = "VerifyHavokEnv"
	root.add_child(env_node)
	var env_samples := [
		["Behavior/ShowCase/Hero", "Behavior/ShowCase/Hero/HeroDemo.cpp", "hero", "hero_environment"],
		["Behavior/Api/Drivers/CharacterControllerDriver/Character Proxy", "Behavior/Api/Drivers/CharacterControllerDriver/CharacterControllerDriverDemo.cpp", "hero", "hk_anim_level_cc"],
		["Behavior/Api/Drivers/FootIkDriver/Foot Ik", "Behavior/Api/Drivers/FootIkDriver/FootIkDriverDemo.cpp", "hero", "hk_anim_level_footik"],
		["Behavior/Api/Modifiers/AttachmentModifier/CharacterToObject/Keyframe Attachments", "Behavior/Api/Modifiers/AttachmentModifier/CharacterToObject/CharacterToObjectAttachmentDemo.cpp", "hero", "attachment_scene"],
		["Behavior/Api/Docking/DockingBlend", "Behavior/Api/Docking/DockingBlend/DockingBlendDemo.cpp", "hero", "docking_blend"],
		["Behavior/Api/Docking/DockingConstrainedMotion", "Behavior/Api/Docking/DockingConstrainedMotion/DockingConstrainedMotionDemo.cpp", "hero", "docking_constrained"],
		["Behavior/Api/Docking/DockingMovingTarget", "Behavior/Api/Docking/DockingMovingTarget/DockingMovingTargetDemo.cpp", "hero", "docking_moving"],
		["Behavior/Api/Docking/DockingMultipleTargets", "Behavior/Api/Docking/DockingMultipleTargets/DockingMultipleTargetsDemo.cpp", "hero", "docking_multiple"],
		["Behavior/Test/Feature/MovingPlatforms/MovingPlatforms - Character Proxy", "Behavior/Test/Feature/MovingPlatforms/MovingPlatforms.cpp", "hero", "moving_platforms"],
		["Behavior/Api/Drivers/RagdollDriver/ControlPalettes", "Behavior/Api/Drivers/RagdollDriver/ControlPalettes/ControlPalettesDemo.cpp", "soldier", "studio"],
	]
	var env_ok := true
	for smp in env_samples:
		var got := env_node.configure_for_demo(str(smp[0]), str(smp[1]), str(smp[2]))
		env_node.step(1.0 / 60.0)
		if got != str(smp[3]) or env_node.stage_root.get_child_count() == 0:
			env_ok = false
	_check("havok_demo_environment_all_10_archetypes", env_ok, "10/10 official Havok level & procedural scenes")

	# 3. Verify extracted official Soldier Ragdoll Spec (17 bones, 15 bodies, 14 constraints, 4 mappers, 19 behavior controls)
	var rspec := HavokRagdollRt.load_spec()
	var spec_ok := (
		not rspec.is_empty()
		and not bool(rspec.get("contains_sdk_hkt_runtime_dep", true))
		and int(rspec.get("bone_count", 0)) == 17
		and int(rspec.get("body_count", 0)) == 15
		and int(rspec.get("constraint_count", 0)) == 14
		and (rspec.get("mappers", []) as Array).size() == 4
		and (rspec.get("behavior_controls", []) as Array).size() == 19
	)
	_check("official_soldier_ragdoll_spec_complete", spec_ok,
		"bones=%d bodies=%d joints=%d mappers=%d controls=%d" % [
			int(rspec.get("bone_count", 0)),
			int(rspec.get("body_count", 0)),
			int(rspec.get("constraint_count", 0)),
			(rspec.get("mappers", []) as Array).size(),
			(rspec.get("behavior_controls", []) as Array).size(),
		])

	# 4. Verify live 15-RigidBody3D + 14-Generic6DOFJoint3D physics collapse over official studio floor!
	env_node.configure_for_demo("Behavior/Api/Drivers/RagdollDriver/MultipleControllers", "Behavior/Api/Drivers/RagdollDriver/MultipleControllers/MultipleControllersDemo.cpp", "soldier")
	var sol_pack := Standards.spawn_aligned_character("soldier", "VerifyRagdollSoldier", Animation.LOOP_LINEAR)
	var sol_outer: Node3D = sol_pack["outer"] as Node3D
	var sol_skel: Skeleton3D = sol_pack["skeleton"] as Skeleton3D
	(sol_pack["player"] as AnimationPlayer).active = false
	root.add_child(sol_outer)
	var rag := HavokRagdollRt.new()
	rag.name = "VerifyHavokRagdoll"
	root.add_child(rag)
	var built := rag.setup(sol_skel, "Behavior/Api/Drivers/RagdollDriver/MultipleControllers", true)
	await physics_frame
	var start_y := rag.bodies[0].global_position.y if not rag.bodies.is_empty() else 0.0
	rag.step(1.0 / 60.0, sol_skel, "", 80, ["GoFullRagdoll"])
	for _i in 90:
		await physics_frame
		rag.step(1.0 / 60.0, sol_skel, "", 81 + _i, [])
	var end_y := rag.bodies[0].global_position.y if not rag.bodies.is_empty() else 0.0
	var collapse_ok := built and rag.bodies.size() == 15 and rag.joints.size() == 14 and start_y > 0.80 and end_y < 0.55 and end_y > 0.03 and is_finite(end_y)
	_check("havok_multibody_ragdoll_real_physics_collapse", collapse_ok,
		"bodies=%d joints=%d pelvis_y=%.3fm->%.3fm" % [rag.bodies.size(), rag.joints.size(), start_y, end_y])

	root.remove_child(rag)
	rag.free()
	root.remove_child(sol_outer)
	sol_outer.free()
	root.remove_child(env_node)
	env_node.free()


func _check(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_emit("PASS", {"suite": "animation_havok_behavior_1to1", "test": name, "detail": detail})
	else:
		_fail += 1
		_emit("FAIL", {"suite": "animation_havok_behavior_1to1", "test": name, "detail": detail})


func _emit(status: String, payload: Dictionary) -> void:
	payload["status"] = status
	print("PFTEST " + JSON.stringify(payload))
