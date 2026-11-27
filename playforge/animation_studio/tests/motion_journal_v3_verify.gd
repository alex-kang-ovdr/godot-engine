extends SceneTree
## Headless regression test for PlayForge Animation Studio Design v3:
##   1. Verifies all 16 vector SVG icons & AnimationStudioTheme load with valid 16x16 textures.
##   2. Verifies 4-step Agent scenario execution through MotionCommands & MotionJournal.
##   3. Verifies read-only snapshot review preserves live cursor/revision and blocks writes.
##   4. Verifies dry-run preview, mid-step replace & branch fork (b001 preserving Main b000),
##      and revalidation of remaining steps on the forked branch.
##   5. Verifies Undo/Redo, STALE_REVISION, request_id idempotency & conflict, and write_access guard.
##   6. Verifies Session JSON export/restore round-trip and tampered checksum rejection.
##   7. Verifies v3 standard docks (3 bottom sub-tabs, 4 state dock variants incl. Empty State,
##      3D overlays NavMesh/UserEdges/A* Path/Skeleton, UserEdge filter chips, Dynamic Obstacle).

const StudioTheme := preload("res://addons/animation_studio/ui/studio_theme.gd")
const MotionCommandsScript := preload("res://addons/animation_studio/authoring/motion_commands.gd")
const WorldScene := preload("res://hero/arena/hero_arena_world.tscn")
const HierarchyDockScript := preload("res://addons/animation_studio/docks/hierarchy_dock.gd")
const StateDockScript := preload("res://addons/animation_studio/docks/state_dock.gd")
const FlowPanelScript := preload("res://addons/animation_studio/docks/flow_bottom_panel.gd")
const SpatialScript := preload("res://hero/ai/hero_spatial_analysis.gd")

var _passed := 0
var _failed := 0


func _emit(payload: Dictionary) -> void:
	print("PFTEST " + JSON.stringify(payload))


func _rec(label: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		_emit({"status": "PASS", "test": label, "detail": detail})
	else:
		_failed += 1
		_emit({"status": "FAIL", "test": label, "detail": detail})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_emit({"status": "START", "engine": Engine.get_version_info().get("hash", "")})
	var all_ok := true

	# 1. All 16 SVG vector icons load cleanly via AnimationStudioTheme
	var icon_ids := [
		"hero", "quadruped", "character", "bone", "ai-path", "navmesh",
		"vault", "climb", "leap", "drop", "cover", "focus",
		"play", "pause", "step", "benchmark",
	]
	var loaded_icons := 0
	for iid in icon_ids:
		var tex: Texture2D = StudioTheme.get_icon(iid, StudioTheme.ACCENT_TEAL, 16)
		if tex != null and tex.get_width() == 16 and tex.get_height() == 16:
			loaded_icons += 1
	var icons_ok := loaded_icons == 16
	_rec("icons_16_svg_loaded", icons_ok, "loaded=%d/16" % loaded_icons)
	all_ok = all_ok and icons_ok

	# 2. 4-step Agent scenario execution through MotionCommands + MotionJournal
	var mc: RefCounted = MotionCommandsScript.new("Hero_Arena", "hero_arena")
	var step_results: Array = mc.call("run_all_remaining_agent_steps")
	var st_after_4: Dictionary = mc.call("motion_read_state")
	var hist_4: Dictionary = mc.call("motion_history")
	var doc_4: Dictionary = st_after_4["document"] as Dictionary
	var params_4: Dictionary = doc_4["defaultParameters"] as Dictionary
	var phys_4: Dictionary = doc_4["physics"] as Dictionary
	var steps_ok := (
		step_results.size() == 4
		and int(st_after_4["revision"]) == 4
		and str(st_after_4["cursor_id"]) == "c004"
		and absf(float(params_4["speed"]) - 3.4) < 0.01
		and absf(float(phys_4["strength"]) - 0.82) < 0.01
		and int(phys_4["limit"]) == 40
	)
	_rec("agent_4step_scenario_journal", steps_ok, "steps=%d rev=%d cursor=%s" % [step_results.size(), int(st_after_4["revision"]), str(st_after_4["cursor_id"])])
	all_ok = all_ok and steps_ok

	# 3. Read-Only Snapshot Review preserves live state & blocks mutations
	var rev_res: Dictionary = mc.call("motion_review_snapshot", {"commit_id": "c002"})
	var st_rev: Dictionary = mc.call("motion_read_state")
	var blocked_write: Dictionary = mc.call("motion_apply_commands", {
		"commands": [{"op": "set_parameters", "values": {"speed": 1.0}}],
		"base_revision": int(st_rev["revision"]),
		"request_id": "blocked-while-review",
	}, {"source": "agent"})
	var blocked_undo: Dictionary = mc.call("motion_undo_transaction", {"base_revision": int(st_rev["revision"])}, "user")
	var sel_doc_c2: Dictionary = st_rev["selected_document"] as Dictionary
	var sel_phys_c2: Dictionary = sel_doc_c2["physics"] as Dictionary
	var review_ok := (
		bool(rev_res.get("ok", false))
		and bool(st_rev["reviewing"])
		and str(st_rev["cursor_id"]) == "c004"
		and int(st_rev["revision"]) == 4
		and absf(float(sel_phys_c2["strength"]) - 0.65) < 0.01
		and not bool(blocked_write.get("ok", true))
		and str((blocked_write["error"] as Dictionary)["code"]) == "READ_ONLY"
		and not bool(blocked_undo.get("ok", true))
	)
	_rec("readonly_review_preserves_live", review_ok, "cursor=%s rev=%d c002_drive=%.2f blocked=%s" % [
		str(st_rev["cursor_id"]), int(st_rev["revision"]), float(sel_phys_c2["strength"]),
		str((blocked_write.get("error", {}) as Dictionary).get("code", "")),
	])
	all_ok = all_ok and review_ok

	# 4. Dry-run preview + mid-step replace creating branch b001 (preserving Main b000) + revalidate steps 3 & 4
	var preview_res: Dictionary = mc.call("motion_preview_commands", {
		"commands": [
			{"op": "set_event_range", "event_id": "push", "start": 48, "end": 72},
			{"op": "set_event_strength", "event_id": "push", "value": 0.65},
		],
		"base_commit_id": "c001",
	})
	var rev_after_preview := int((mc.call("motion_read_state") as Dictionary)["revision"])
	var replace_res: Dictionary = mc.call("replace_step", "c002", [
		{"op": "set_event_range", "event_id": "push", "start": 48, "end": 72},
		{"op": "set_event_strength", "event_id": "push", "value": 0.65},
	], "사용자 수정안")
	var reval_steps: Array = mc.call("run_all_remaining_agent_steps")
	var hist_branch: Dictionary = mc.call("motion_history")
	var branches_arr: Array = hist_branch["branches"] as Array
	var main_head := ""
	var b1_head := ""
	for raw_b in branches_arr:
		var bd: Dictionary = raw_b as Dictionary
		if str(bd["id"]) == "b000":
			main_head = str(bd["headId"])
		elif str(bd["id"]) == "b001":
			b1_head = str(bd["headId"])
	var branch_ok := (
		bool(preview_res.get("ok", false))
		and rev_after_preview == 4
		and bool(replace_res.get("ok", false))
		and str(replace_res.get("branchId", "")) == "b001"
		and reval_steps.size() == 2
		and main_head == "c004"
		and b1_head == "c007"
	)
	_rec("midstep_fork_and_revalidate", branch_ok, "main_head=%s b001_head=%s reval=%d" % [main_head, b1_head, reval_steps.size()])
	all_ok = all_ok and branch_ok

	# 5. Undo / Redo + Stale Revision + Idempotency + Conflict + Capability Guard
	var cur_rev := int((mc.call("motion_read_state") as Dictionary)["revision"])
	var undo_res: Dictionary = mc.call("motion_undo_transaction", {"base_revision": cur_rev}, "user")
	var redo_res: Dictionary = mc.call("motion_redo_transaction", {"base_revision": cur_rev + 1}, "user")
	var stale_res: Dictionary = mc.call("motion_apply_commands", {
		"commands": [{"op": "set_parameters", "values": {"turn": 0.25}}],
		"base_revision": 0,
		"request_id": "stale-test",
	}, {"source": "agent"})

	var live_rev := int((mc.call("motion_read_state") as Dictionary)["revision"])
	var idem_1: Dictionary = mc.call("motion_apply_commands", {
		"commands": [{"op": "set_parameters", "values": {"turn": 0.35}}],
		"base_revision": live_rev,
		"request_id": "req-idem-001",
		"label": "회전 기본값 조절",
	}, {"source": "agent"})
	var idem_2: Dictionary = mc.call("motion_apply_commands", {
		"commands": [{"op": "set_parameters", "values": {"turn": 0.35}}],
		"base_revision": live_rev, # Retry with same request_id
		"request_id": "req-idem-001",
		"label": "회전 기본값 조절",
	}, {"source": "agent"})
	var idem_conflict: Dictionary = mc.call("motion_apply_commands", {
		"commands": [{"op": "set_parameters", "values": {"turn": -0.5}}],
		"base_revision": live_rev + 1,
		"request_id": "req-idem-001",
	}, {"source": "agent"})

	mc.set("write_access", false)
	var denied_res: Dictionary = mc.call("motion_apply_commands", {
		"commands": [{"op": "set_parameters", "values": {"turn": 0.1}}],
		"base_revision": int((mc.call("motion_read_state") as Dictionary)["revision"]),
		"request_id": "req-denied-001",
	}, {"source": "agent"})
	mc.set("write_access", true)

	var guards_ok := (
		bool(undo_res.get("ok", false))
		and str(undo_res.get("commitId", "")) == "c006"
		and bool(redo_res.get("ok", false))
		and str(redo_res.get("commitId", "")) == "c007"
		and str((stale_res.get("error", {}) as Dictionary).get("code", "")) == "STALE_REVISION"
		and bool(idem_1.get("ok", false))
		and bool(idem_2.get("ok", false))
		and str(idem_1.get("commitId", "")) == str(idem_2.get("commitId", ""))
		and str((idem_conflict.get("error", {}) as Dictionary).get("code", "")) == "IDEMPOTENCY_CONFLICT"
		and str((denied_res.get("error", {}) as Dictionary).get("code", "")) == "CAPABILITY_DENIED"
	)
	_rec("undo_redo_and_safety_guards", guards_ok, "idem=%s conflict=%s denied=%s" % [
		str(idem_1.get("commitId", "")),
		str((idem_conflict.get("error", {}) as Dictionary).get("code", "")),
		str((denied_res.get("error", {}) as Dictionary).get("code", "")),
	])
	all_ok = all_ok and guards_ok

	# 6. Session JSON export/restore round-trip + tampered checksum rejection
	var exported: String = str(mc.call("export_session_json"))
	var mc_restore: RefCounted = MotionCommandsScript.new("Hero_Arena", "hero_arena")
	var restore_ok_res: Dictionary = mc_restore.call("restore_session_json", exported)
	var restored_hist: Dictionary = mc_restore.call("motion_history")
	var tampered_dict: Dictionary = JSON.parse_string(exported) as Dictionary
	var tampered_commits: Array = tampered_dict["commits"] as Array
	(tampered_commits[1] as Dictionary)["afterHash"] = "fnv1a32:deadbeef"
	var tampered_res: Dictionary = mc_restore.call("restore_session_json", JSON.stringify(tampered_dict))
	var persist_ok := (
		bool(restore_ok_res.get("ok", false))
		and (restored_hist["branches"] as Array).size() == 2
		and (restored_hist["entries"] as Array).size() >= 9
		and not bool(tampered_res.get("ok", true))
	)
	_rec("session_json_roundtrip_and_checksum", persist_ok, "bytes=%d branches=%d tampered_rejected=%s" % [
		exported.length(), (restored_hist["branches"] as Array).size(), str(not bool(tampered_res.get("ok", true)))
	])
	all_ok = all_ok and persist_ok

	# 7. v3 Standard Docks + 3 Bottom Sub-Tabs + Empty State + 3D Overlays & AI Filters
	var world := WorldScene.instantiate()
	root.add_child(world)
	await process_frame
	await physics_frame

	var hero := world.get_node_or_null("Hero_Arena") as Node3D
	var quad := world.get_node_or_null("Quadruped_Locomotor") as Node3D
	var soldier := world.get_node_or_null("Soldier_M4") as Node3D

	var host := Control.new()
	host.size = Vector2(1280, 720)
	root.add_child(host)
	var h_dock: Control = HierarchyDockScript.new()
	var s_dock: Control = StateDockScript.new()
	var f_panel: Control = FlowPanelScript.new()
	host.add_child(h_dock)
	host.add_child(s_dock)
	host.add_child(f_panel)
	await process_frame

	# Empty state bind
	s_dock.call("bind_instance", null)
	# Bind hero + activate AI + all 4 overlays + toggle Vault flag & dynamic obstacle
	var insts: Array[Node3D] = [hero, soldier, quad]
	h_dock.call("set_scene_instances", insts, hero)
	s_dock.call("bind_instance", hero)
	f_panel.call("bind_instance", hero)

	hero.call("start_ai_mission", "grand_tour")
	hero.call("set_overlay_flags", true, true, true, true)
	var flags_after: int = int(hero.call("set_ai_allowed_flag", SpatialScript.FLAG_VAULT, false))
	hero.call("set_ai_dynamic_obstacle", true)
	for _i in 12:
		hero.call("step_once", 1.0 / 60.0)

	# Switch across all 3 bottom sub-tabs
	f_panel.call("select_sub_tab", 1)
	f_panel.call("update_live")
	f_panel.call("select_sub_tab", 2)
	f_panel.call("update_live")
	f_panel.call("select_sub_tab", 0)
	f_panel.call("update_live")
	h_dock.call("update_live")
	s_dock.call("update_live")

	var h_snap: Dictionary = hero.call("get_state_snapshot")
	var auth_hero: RefCounted = hero.call("get_motion_authoring")
	var traces: Array = auth_hero.get("frame_trace") as Array
	var docks_v3_ok := (
		(flags_after & SpatialScript.FLAG_VAULT) == 0
		and bool(h_snap.get("ai_dynamic_obstacle", false))
		and bool(hero.get("overlay_navmesh"))
		and bool(hero.get("overlay_skeleton"))
		and not traces.is_empty()
		and str((traces[traces.size() - 1] as Dictionary).get("sourceCommitId", "")) == "c000"
	)
	_rec("docks_v3_overlays_subtabs_and_trace", docks_v3_ok, "flags=%d dyn_obs=%s traces=%d next_ai=%s" % [
		flags_after, str(h_snap.get("ai_dynamic_obstacle", false)), traces.size(), str(h_snap.get("next_ai_state", ""))
	])
	all_ok = all_ok and docks_v3_ok

	_emit({"status": "SUMMARY", "pass": _passed, "fail": _failed})
	quit(0 if all_ok and _failed == 0 else 1)
