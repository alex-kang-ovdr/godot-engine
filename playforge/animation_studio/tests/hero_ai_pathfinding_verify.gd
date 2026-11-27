extends SceneTree
## Headless regression verification for AI Pathfinding-Driven Hero Full-Map Demo
## (Havok Spatial Analysis + Multi-Layer NavGraph + Traversal UserEdges +
## A* CostModifiers + AI+Behavior Autonomous Execution).

const DemoScene := preload("res://hero/ai/hero_ai_demo.tscn")
const SpatialScript := preload("res://hero/ai/hero_spatial_analysis.gd")
const PathfinderScript := preload("res://hero/ai/hero_ai_pathfinder.gd")

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
	call_deferred("_run")


func _run() -> void:
	_emit({"status": "START", "engine": Engine.get_version_info().get("hash", "")})
	var demo := DemoScene.instantiate()
	root.add_child(demo)
	await process_frame
	await physics_frame
	await physics_frame
	demo.set_playing(false)

	var sp = demo.spatial
	var pf = demo.pathfinder
	var dr = demo.driver
	var ctrl = demo.controller
	var st: Dictionary = sp.stats

	# 1. Spatial Analysis extracts multi-layer NavGraph and ALL 6 traversal UserEdge categories
	var sp_ok := (
		int(st.get("nav_nodes", 0)) >= 400
		and int(st.get("vault_edges", 0)) >= 10
		and int(st.get("climb_edges", 0)) >= 12
		and int(st.get("leap_edges", 0)) >= 4
		and int(st.get("drop_edges", 0)) >= 8
		and int(st.get("cover_walk_edges", 0)) >= 10
		and int(st.get("cover_roll_edges", 0)) >= 4
	)
	_check("spatial_analysis_all_6_traversal_types", sp_ok, JSON.stringify(st))

	# 2. 3D Multi-Elevation A* finds path from Courtyard (Y=0m) to Summit (Y=10.25m)
	pf.allowed_flags = SpatialScript.FLAG_ALL
	pf.cost_mode = PathfinderScript.COST_PREFER_HIGH
	var p_summit: Dictionary = pf.find_path(Vector3(-44.0, 0.0, 21.5), Vector3(3.4, 10.25, 49.2))
	var summit_trav: Dictionary = p_summit.get("traversal_counts", {})
	var summit_ok := bool(p_summit.get("ok", false)) and int(summit_trav.get("ClimbUp", 0)) >= 2 and int(summit_trav.get("Leap", 0)) >= 1
	_check("astar_ground_to_10m_summit_climb_and_leap", summit_ok, "ms=%.2f len=%.1f trav=%s" % [float(p_summit.get("ms", 0.0)), float(p_summit.get("length_m", 0.0)), JSON.stringify(summit_trav)])

	# 3. PreferHighPlacesCostModifier routes at significantly higher average altitude than Shortest
	pf.cost_mode = PathfinderScript.COST_SHORTEST
	var p_low: Dictionary = pf.find_path(Vector3(-44.0, 0.0, 21.5), Vector3(-10.0, 0.0, 53.0))
	pf.cost_mode = PathfinderScript.COST_PREFER_HIGH
	var p_high: Dictionary = pf.find_path(Vector3(-44.0, 0.0, 21.5), Vector3(-10.0, 0.0, 53.0))
	var high_ok := bool(p_low.get("ok", false)) and bool(p_high.get("ok", false)) and float(p_high.get("avg_y", 0.0)) > float(p_low.get("avg_y", 0.0)) + 0.8
	_check("cost_modifier_prefer_high_places", high_ok, "shortest_avg_y=%.2f prefer_high_avg_y=%.2f" % [float(p_low.get("avg_y", 0.0)), float(p_high.get("avg_y", 0.0))])

	# 4. TacticalCoverCostModifier routes through CoverWalk / CoverRoll edges
	pf.cost_mode = PathfinderScript.COST_TACTICAL_COVER
	var p_cov: Dictionary = pf.find_path(Vector3(-3.0, 0.0, 17.5), Vector3(-16.0, 0.0, 6.0))
	var cov_trav: Dictionary = p_cov.get("traversal_counts", {})
	var cov_ok := bool(p_cov.get("ok", false)) and (int(cov_trav.get("CoverWalk", 0)) + int(cov_trav.get("CoverRoll", 0))) >= 2
	_check("cost_modifier_tactical_cover_routing", cov_ok, "trav=%s" % JSON.stringify(cov_trav))

	# 5. Traversal Filter Flag disables unreachable Summit when FLAG_CLIMB is removed
	pf.allowed_flags = SpatialScript.FLAG_ALL & ~SpatialScript.FLAG_CLIMB
	pf.cost_mode = PathfinderScript.COST_SHORTEST
	var p_no_climb: Dictionary = pf.find_path(Vector3(0.0, 0.0, 0.0), Vector3(3.4, 10.25, 49.2))
	var filter_ok := not bool(p_no_climb.get("ok", false))
	_check("traversal_flag_filter_blocks_climb_only_summit", filter_ok, "ok_without_climb=%s" % str(p_no_climb.get("ok", false)))
	pf.allowed_flags = SpatialScript.FLAG_ALL

	# 6. Dynamic Obstacle Silhouette reroutes path cleanly around moving blocker
	pf.cost_mode = PathfinderScript.COST_SHORTEST
	pf.dynamic_obstacles = []
	var p_clear: Dictionary = pf.find_path(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 12.0))
	pf.dynamic_obstacles = [{"pos": Vector3(0.0, 0.0, 6.0), "radius": 2.4}]
	var p_avoid: Dictionary = pf.find_path(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 12.0))
	var min_clear_d := 999.0
	for pt in (p_avoid.get("points", PackedVector3Array()) as PackedVector3Array):
		min_clear_d = minf(min_clear_d, Vector2(pt.x - 0.0, pt.z - 6.0).length())
	var dyn_ok := bool(p_clear.get("ok", false)) and bool(p_avoid.get("ok", false)) and min_clear_d >= 1.8
	_check("dynamic_obstacle_silhouette_reroute", dyn_ok, "clear_len=%.2f avoid_len=%.2f min_dist=%.2f" % [float(p_clear.get("length_m", 0.0)), float(p_avoid.get("length_m", 0.0)), min_clear_d])
	pf.dynamic_obstacles = []

	# 7. LIVE AI + Behavior Autonomous Full-Map Grand Tour execution (ZERO teleports!)
	dr.reset_coverage()
	dr.start_mission("grand_tour", true)
	var dt := 1.0 / 30.0
	var max_ticks := 4500 # up to 150s simulated time at 30 Hz
	var completed_all := false
	for tick in max_ticks:
		dr.step(dt, demo._skeleton, demo._raycast_world)
		var tel: Dictionary = dr.get_telemetry()
		if int(tel["completed_waypoints"]) >= 9 and int(tel["covered_count"]) >= 12:
			completed_all = true
			break

	var final_tel: Dictionary = dr.get_telemetry()
	var cov: Dictionary = final_tel["coverage"]
	_check(
		"ai_driven_grand_tour_full_map_vertical_span",
		float(final_tel["highest_y"]) >= 9.6 and float(final_tel["lowest_y"]) <= -2.5,
		"lowest_y=%.2f highest_y=%.2f wps=%d" % [float(final_tel["lowest_y"]), float(final_tel["highest_y"]), int(final_tel["completed_waypoints"])]
	)
	_check(
		"ai_driven_grand_tour_covers_all_hero_features",
		bool(cov.get("locomotion", false))
		and bool(cov.get("cover_low", false))
		and bool(cov.get("cover_high", false))
		and bool(cov.get("cover_roll", false))
		and bool(cov.get("vault", false))
		and bool(cov.get("climb_up", false))
		and bool(cov.get("leap", false))
		and bool(cov.get("drop_down", false))
		and bool(cov.get("trench_pit", false))
		and bool(cov.get("summit_10m", false))
		and bool(cov.get("combat_strafe", false)),
		"covered=%d/%d completed=%s cov=%s" % [int(final_tel["covered_count"]), int(final_tel["coverage_total"]), str(completed_all), JSON.stringify(cov)]
	)

	_emit({"status": "SUMMARY", "pass": _passed, "fail": _failed})
	quit(0 if _failed == 0 else 1)
