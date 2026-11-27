extends SceneTree
## Automated 1:1 Precision Verification Suite:
## Compares REAL Havok 2015.1.0-r1 C++ Behavior SDK traces against Godot 4.7.2 Port
## across all 5 canonical Hero & Behavior scenarios (1,445 ticks @ 60 Hz, 48 events)
## on event timing (Δtick/Δms), state transitions, clip local time, root XZ/Yaw,
## landmark bone positions (mm), zero .hkt runtime dependency, and interactive viewer UI.

const Runner := preload("res://compare/behavior_1to1_runner.gd")
const Store := preload("res://characters/character_store.gd")
const COMPARE_SCENE := "res://compare/havok_1to1_compare.tscn"
const REAL_MANIFEST_JSON := "res://compare/assets/havok_real_demo_manifest.json"
const HERO_CONTACT_SHEET := "res://compare/assets/havok_real_hero_contact_sheet.png"
const SOLDIER_CONTACT_SHEET := "res://compare/assets/havok_real_soldier_contact_sheet.png"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_emit("START", {"suite": "animation_havok_behavior_1to1", "engine": Engine.get_version_info().get("hash", "")})
	_verify_sdk_free_assets()
	_verify_all_five_scenarios()
	_verify_interactive_viewer()
	_verify_real_havok_47_demos_dataset()
	Runner.clear_caches()
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
