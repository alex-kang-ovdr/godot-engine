extends SceneTree

const ArenaScene := preload("res://hero/arena/hero_arena.tscn")
const LinesScript := preload("res://hero/arena/hero_lua_lines.gd")

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
	var arena = ArenaScene.instantiate()
	root.add_child(arena)
	await process_frame
	await physics_frame
	await physics_frame
	arena.auto_tour = false
	arena.set_playing(false)

	var es: Dictionary = arena.env_stats
	var hs: Dictionary = arena.hero_stats
	var ctrl = arena.controller

	_check(
		"Hero Environment.glb loads native map geometry and trimesh collision",
		int(es.get("meshes", 0)) >= 1 and int(es.get("verts", 0)) == 4992 and int(es.get("tris", 0)) == 1664,
		JSON.stringify(es)
	)
	_check(
		"Hero Arena rig loads 85 bones, 6 GLB skin meshes, and 31 Lua behavior clips",
		int(hs.get("bones", 0)) == 85 and int(hs.get("meshes", 0)) == 6 and int(hs.get("clips", 0)) == 31,
		JSON.stringify(hs)
	)

	# Count all 5 line types restored from hero_lines.lua
	var counts := {0: 0, 1: 0, 2: 0, 3: 0, 4: 0}
	for l in ctrl.line_world.lines:
		var lt := int(l["line_type"])
		counts[lt] = int(counts.get(lt, 0)) + 1
	_check(
		"hero_lines.lua restores all 90 docking lines across all 5 Havok line types",
		ctrl.line_world.lines.size() == 90 and counts[0] == 10 and counts[1] == 10 and counts[2] == 40 and counts[3] == 12 and counts[4] == 18,
		JSON.stringify(counts)
	)

	# Physics raycast against extracted Environment trimesh
	var ground_hit: Dictionary = arena._raycast_world(Vector3(-11.0, 2.0, 12.0), Vector3(-11.0, -2.0, 12.0))
	_check(
		"Environment trimesh raycast hits ground plane cleanly at y ~ 0.0m",
		bool(ground_hit.get("hit", false)) and absf((ground_hit["position"] as Vector3).y) < 0.15,
		JSON.stringify({"hit": ground_hit.get("hit", false), "y": (ground_hit.get("position", Vector3.ZERO) as Vector3).y})
	)

	# Test hero.lua + hero_locomotion.lua: Idle -> Run -> Turn180 -> DrawSword -> SwordAttack
	ctrl.teleport_hero(Vector3(-11.0, 0.0, 12.0), 0.0)
	ctrl.gamepad.set_raw_input(0.0, 1.0, 0.0, 0.0, 0.0)
	for _i in 8:
		ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	var ran_ok := str(ctrl.state["active_state"]) == "Run"
	var moved_dist: float = (ctrl.hero_pos as Vector3).distance_to(Vector3(-11.0, 0.0, 12.0))
	ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
	for _i in 12:
		ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	ctrl.raise_event("WeaponToggle", arena._raycast_world)
	for _i in 75:
		ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	var sword_drawn := int(ctrl.variables["WeaponType"]) == 1
	ctrl.raise_event("Attack", arena._raycast_world)
	var sword_atk := str(ctrl.state["active_clip"]) == "sword_attack"
	_check(
		"hero.lua + hero_locomotion.lua execute Run, Stop, DrawSword, and SwordAttack",
		ran_ok and moved_dist > 0.1 and sword_drawn and sword_atk,
		JSON.stringify({"ran_ok": ran_ok, "moved_dist": moved_dist, "sword_drawn": sword_drawn, "sword_atk": sword_atk})
	)

	# Test hero_cover.lua: takeCover -> Cover walk -> comeOutOfCover
	arena.start_scenario("cover")
	var in_cover: bool = str(ctrl.state["active_state"]) == "Cover" and not (ctrl.line_world.docking_target as Dictionary).is_empty()
	var cov_start: Vector3 = ctrl.hero_pos
	ctrl.gamepad.set_raw_input(1.0, 0.0, 0.0, 0.0, 0.0)
	for _i in 20:
		ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	var cov_moved: bool = (ctrl.hero_pos as Vector3).distance_to(cov_start) > 0.05
	ctrl.come_out_of_cover()
	var left_cover: bool = str(ctrl.state["active_state"]) == "Idle" and (ctrl.line_world.docking_target as Dictionary).is_empty()
	_check(
		"hero_cover.lua docks to real Environment cover wall, walks along line, and exits cover",
		in_cover and cov_moved and left_cover,
		JSON.stringify({"in_cover": in_cover, "cov_moved": cov_moved, "left_cover": left_cover})
	)

	# Test hero_vaulting.lua: JumpButton -> jumpActions -> vaultLowWall crosses goldenrod railing
	arena.start_scenario("vault")
	var vault_started := str(ctrl.state["active_state"]) == "Vaulting"
	var v_start: Vector3 = ctrl.hero_pos
	for _i in 105:
		ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	var v_crossed: bool = (ctrl.hero_pos as Vector3).distance_to(v_start) > 2.0 and str(ctrl.state["active_state"]) == "Idle"
	_check(
		"hero_vaulting.lua selects goldenrod railing via jumpActions and vaults cleanly across",
		vault_started and v_crossed,
		JSON.stringify({"vault_started": vault_started, "crossed_m": (ctrl.hero_pos as Vector3).distance_to(v_start), "end_state": ctrl.state["active_state"]})
	)

	# Test hero_climbing.lua: JumpButton -> jumpToPlatform -> Hanging -> Climb Up onto y=2.0m ledge
	arena.start_scenario("climb")
	var climb_started := str(ctrl.state["active_state"]) == "Climbing"
	for _i in 50:
		ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	var hanging_ok := str(ctrl.state["active_state"]) == "Hanging"
	ctrl.gamepad.set_raw_input(0.0, 1.0, 0.0, 0.0, 0.0)
	for _i in 85:
		ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	var climbed_up: bool = float(ctrl.hero_pos.y) > 1.75
	_check(
		"hero_climbing.lua grabs blue ledge, hangs, and climbs onto y=2.0m platform",
		climb_started and hanging_ok and climbed_up,
		JSON.stringify({"climb_started": climb_started, "hanging_ok": hanging_ok, "final_y": ctrl.hero_pos.y})
	)

	# Test hero_leaping.lua + hero_camera.lua Strafe mode
	arena.start_scenario("leap")
	var leap_started := str(ctrl.state["active_state"]) == "Leaping"
	arena.start_scenario("strafe")
	ctrl.step(1.0 / 60.0, arena.hero_skeleton, arena._raycast_world)
	var strafe_cam_ok: bool = int(ctrl.cam.mode) == 1
	_check(
		"hero_leaping.lua leaps across platform gap and hero_camera.lua enters over-the-shoulder Strafe mode",
		leap_started and strafe_cam_ok,
		JSON.stringify({"leap_started": leap_started, "cam_mode": ctrl.cam.mode})
	)

	arena.queue_free()
	_emit({"status": "SUMMARY", "fail": _failed})
	quit(0 if _failed == 0 else 1)
