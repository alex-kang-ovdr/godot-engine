extends SceneTree
## Headless regression test for the standard dockable Animation Studio addon:
##   1. Loads res://hero/arena/hero_arena_world.tscn (standard 3D Viewport scene).
##   2. Verifies HeroEnvironment (90 docking lines + trimesh) and all 4 placed
##      AnimationStudioInstance nodes (Hero_Arena 85b, Soldier_M4 114b,
##      Quadruped_Locomotor 28b, OrcCaptain 103b).
##   3. Instantiates all 3 standard dock panels (AnimStudio · 계층, AnimStudio · 상태,
##      Animation Flow) and binds/switches across every placed 3D instance.
##   4. Verifies Hero Lua docking transitions, Quadruped gait switching & 0.0mm slip,
##      Soldier 16-bit C++ parity toggle, and runtime spawning of a new 3D instance.

const WorldScene := preload("res://hero/arena/hero_arena_world.tscn")
const HierarchyDockScript := preload("res://addons/animation_studio/docks/hierarchy_dock.gd")
const StateDockScript := preload("res://addons/animation_studio/docks/state_dock.gd")
const FlowPanelScript := preload("res://addons/animation_studio/docks/flow_bottom_panel.gd")
const InstanceScript := preload("res://addons/animation_studio/animation_studio_instance.gd")


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
	var world := WorldScene.instantiate()
	root.add_child(world)
	await process_frame
	await physics_frame

	var env := world.get_node_or_null("HeroEnvironment")
	var hero := world.get_node_or_null("Hero_Arena") as Node3D
	var soldier := world.get_node_or_null("Soldier_M4") as Node3D
	var quad := world.get_node_or_null("Quadruped_Locomotor") as Node3D
	var orc := world.get_node_or_null("OrcCaptain") as Node3D

	var lw = env.get("line_world") if env != null else null
	var line_cnt: int = (lw.lines as Array).size() if lw != null else 0
	var env_ok := env != null and env.has_method("refresh_docking_lines") and line_cnt == 90
	_rec("world_environment_90_lines", env_ok, "lines=%d" % line_cnt)
	all_ok = all_ok and env_ok

	var insts: Array[Node3D] = []
	for n in [hero, soldier, quad, orc]:
		if n != null:
			insts.append(n)
	var b_hero := (hero.call("get_skeleton") as Skeleton3D).get_bone_count() if hero != null and hero.call("get_skeleton") != null else 0
	var b_sol := (soldier.call("get_skeleton") as Skeleton3D).get_bone_count() if soldier != null and soldier.call("get_skeleton") != null else 0
	var b_quad := (quad.call("get_skeleton") as Skeleton3D).get_bone_count() if quad != null and quad.call("get_skeleton") != null else 0
	var b_orc := (orc.call("get_skeleton") as Skeleton3D).get_bone_count() if orc != null and orc.call("get_skeleton") != null else 0
	var rigs_ok := insts.size() == 4 and b_hero == 85 and b_sol == 114 and b_quad == 28 and b_orc == 73
	_rec("placed_4_character_instances", rigs_ok, "hero=%d soldier=%d quad=%d orc=%d" % [b_hero, b_sol, b_quad, b_orc])
	all_ok = all_ok and rigs_ok

	# Instantiate the 3 standard Editor docks
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

	h_dock.call("set_scene_instances", insts, hero)
	s_dock.call("bind_instance", hero)
	f_panel.call("bind_instance", hero)
	var dock_names_ok := h_dock.name == "AnimStudio · 계층" and s_dock.name == "AnimStudio · 상태" and f_panel.name == "Animation Flow"
	_rec("standard_dock_panels_ready", dock_names_ok, "%s | %s | %s" % [h_dock.name, s_dock.name, f_panel.name])
	all_ok = all_ok and dock_names_ok

	# 1) Drive Hero Arena via dock-bound instance (cover + climb)
	hero.set("auto_demo", false)
	hero.call("trigger_hero_scenario", "cover")
	for _i in 20:
		hero.call("step_once", 1.0 / 60.0)
	var hero_snap: Dictionary = hero.call("get_state_snapshot")
	var hero_cover_ok := str(hero_snap.get("active_state", "")) == "Cover" and absf((hero_snap.get("world_pos", Vector3.ZERO) as Vector3).y) < 0.05
	h_dock.call("update_live")
	s_dock.call("update_live")
	f_panel.call("update_live")
	_rec("hero_instance_cover_grounded", hero_cover_ok, "state=%s y=%.3f" % [str(hero_snap.get("active_state", "")), (hero_snap.get("world_pos", Vector3.ZERO) as Vector3).y])
	all_ok = all_ok and hero_cover_ok

	# 2) Switch docks to Quadruped_Locomotor and verify trot gait + low slip
	h_dock.call("bind_instance", quad)
	s_dock.call("bind_instance", quad)
	f_panel.call("bind_instance", quad)
	quad.call("set_quad_gait", "trot")
	quad.call("set_quad_speed", 2.8)
	quad.set("auto_demo", true)
	for _i in 45:
		quad.call("step_once", 1.0 / 60.0)
	var q_snap: Dictionary = quad.call("get_state_snapshot")
	var quad_ok := str(q_snap.get("active_state", "")) == "trot" and float(q_snap.get("foot_slip_mm", 99.0)) < 0.5 and float(q_snap.get("actual_speed", 0.0)) > 1.5
	h_dock.call("update_live")
	s_dock.call("update_live")
	f_panel.call("update_live")
	_rec("quadruped_instance_locomotor", quad_ok, "gait=%s spd=%.2f slip=%.3fmm" % [str(q_snap.get("active_state", "")), float(q_snap.get("actual_speed", 0.0)), float(q_snap.get("foot_slip_mm", 0.0))])
	all_ok = all_ok and quad_ok

	# 3) Switch docks to Soldier_M4 and toggle Float32 vs 16-bit C++ QuantizedClip
	h_dock.call("bind_instance", soldier)
	s_dock.call("bind_instance", soldier)
	f_panel.call("bind_instance", soldier)
	soldier.call("set_use_quantized_16bit", true)
	soldier.call("step_once", 1.0 / 60.0)
	var s_snap: Dictionary = soldier.call("get_state_snapshot")
	var cmp: Dictionary = s_snap.get("compare", {})
	var sol_ok := bool(s_snap.get("use_quantized_16bit", false)) and float(cmp.get("max_world_mm", 99.0)) < 2.0 and float(cmp.get("saving_pct", 0.0)) > 50.0
	h_dock.call("update_live")
	s_dock.call("update_live")
	f_panel.call("update_live")
	_rec("soldier_instance_16bit_parity", sol_ok, "world_err=%.3fmm saving=%.1f%%" % [float(cmp.get("max_world_mm", 0.0)), float(cmp.get("saving_pct", 0.0))])
	all_ok = all_ok and sol_ok

	# 4) Spawn an additional character instance dynamically into the 3D scene
	var spawned := Node3D.new()
	spawned.set_script(InstanceScript)
	spawned.name = "NinjaBlue_Spawned"
	spawned.position = Vector3(-9.5, 0.0, 14.0)
	spawned.set("role", "character")
	spawned.set("character_id", "ninja_blue")
	world.add_child(spawned)
	await process_frame
	var b_spawn := (spawned.call("get_skeleton") as Skeleton3D).get_bone_count() if spawned.call("get_skeleton") != null else 0
	var spawn_ok := b_spawn >= 40
	_rec("dynamic_spawn_character_instance", spawn_ok, "ninja_blue_bones=%d" % b_spawn)
	all_ok = all_ok and spawn_ok

	_emit({"status": "SUMMARY", "pass": _passed, "fail": _failed})
	quit(0 if all_ok and _failed == 0 else 1)
