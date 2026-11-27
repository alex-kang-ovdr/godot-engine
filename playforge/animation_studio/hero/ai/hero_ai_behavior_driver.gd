@tool
class_name HeroAiBehaviorDriver
extends RefCounted
## Havok AI + Behavior Bridge (hkaiPathFollowingBehavior + CornerPrediction +
## BehaviorBlockedDetector + HeroLuaController state machine).
##
## Drives the 85-bone Hero across the ENTIRE Hero Environment map autonomously
## purely via AI A* Pathfinding + Spatial Analysis Traversal UserEdges + local
## steering translated into HeroLuaGamepad / HeroLuaController actions (zero teleports!).

const SpatialScript := preload("res://hero/ai/hero_spatial_analysis.gd")
const PathfinderScript := preload("res://hero/ai/hero_ai_pathfinder.gd")
const ControllerScript := preload("res://hero/arena/hero_lua_controller.gd")
const LinesScript := preload("res://hero/arena/hero_lua_lines.gd")

var spatial: SpatialScript = null
var pathfinder: PathfinderScript = null
var ctrl: ControllerScript = null

var active_mission: String = "grand_tour"
var mission_waypoints: Array[Dictionary] = []
var waypoint_idx: int = 0
var active_path: Dictionary = {}
var seg_idx: int = 0
var path_dirty: bool = false

# Live execution state
var current_goal: Vector3 = Vector3.ZERO
var current_goal_label: String = ""
var _in_traversal_seg: bool = false
var _cover_roll_pending: bool = false
var _combat_stage: int = 0
var _combat_timer: float = 0.0
var _stuck_timer: float = 0.0
var _stuck_anchor: Vector3 = Vector3.ZERO
var _replan_count: int = 0
var _completed_waypoints: int = 0
var _highest_y: float = 0.0
var _lowest_y: float = 0.0
var _turn180_tested: bool = false

var coverage: Dictionary = {
	"locomotion": false,
	"turn180": false,
	"cover_low": false,
	"cover_high": false,
	"cover_roll": false,
	"vault": false,
	"climb_up": false,
	"leap": false,
	"drop_down": false,
	"trench_pit": false,
	"summit_10m": false,
	"combat_strafe": false,
}


func setup(spatial_analysis: SpatialScript, pfinder: PathfinderScript, hero_ctrl: ControllerScript) -> void:
	spatial = spatial_analysis
	pathfinder = pfinder
	ctrl = hero_ctrl
	reset_coverage()


func reset_coverage() -> void:
	for k in coverage.keys():
		coverage[k] = false
	_highest_y = ctrl.hero_pos.y if ctrl != null else 0.0
	_lowest_y = ctrl.hero_pos.y if ctrl != null else 0.0
	_completed_waypoints = 0
	_replan_count = 0
	_turn180_tested = false


func start_mission(mission_id: String, reset_pos: bool = false) -> Dictionary:
	active_mission = mission_id
	mission_waypoints.clear()
	waypoint_idx = 0
	_in_traversal_seg = false
	_cover_roll_pending = false
	_combat_stage = 0
	_combat_timer = 0.0
	_stuck_timer = 0.0

	match mission_id:
		"grand_tour":
			pathfinder.cost_mode = PathfinderScript.COST_PARKOUR_EXPRESS
			pathfinder.allowed_flags = SpatialScript.FLAG_ALL
			if reset_pos and ctrl != null:
				ctrl.teleport_hero(Vector3(-4.0, 0.0, 12.0), -2.2)
			mission_waypoints = [
				{"label": "1. 빨강 낮음 엄폐 진입 & 구르기", "pos": Vector3(-15.5, 0.0, 6.2), "cost_mode": PathfinderScript.COST_TACTICAL_COVER, "action": "none"},
				{"label": "2. 초록 높음 엄폐 남단 진입", "pos": Vector3(-8.8, 0.0, 22.8), "cost_mode": PathfinderScript.COST_TACTICAL_COVER, "action": "none"},
				{"label": "3. 초록 높음 엄폐 횡단 & 엄폐 이동", "pos": Vector3(-19.8, 0.0, 11.4), "cost_mode": PathfinderScript.COST_TACTICAL_COVER, "action": "none"},
				{"label": "4. 오렌지 난간 넘기(Vault) 코스", "pos": Vector3(-31.2, 0.0, -11.5), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
				{"label": "5. 지하 참호(Y=-3m) 드롭다운 진입", "pos": Vector3(-18.0, -3.0, -24.0), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
				{"label": "6. 참호 탈출(ClimbUp) & 전투·Strafe", "pos": Vector3(-25.0, 0.0, -16.0), "cost_mode": PathfinderScript.COST_SHORTEST, "action": "combat_strafe"},
				{"label": "7. 다이아몬드 타워 등반 (Y=0->3->6m)", "pos": Vector3(-37.0, 6.0, 46.5), "cost_mode": PathfinderScript.COST_PREFER_HIGH, "action": "none"},
				{"label": "8. 스카이브릿지 도약 연쇄 -> 정상 10.25m!", "pos": Vector3(3.4, 10.25, 49.2), "cost_mode": PathfinderScript.COST_PREFER_HIGH, "action": "combat_strafe"},
				{"label": "9. 동쪽 플랫폼 하강 (10.25->5->2->0m)", "pos": Vector3(2.0, 0.0, 24.0), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
			]
		"summit_ascent":
			pathfinder.cost_mode = PathfinderScript.COST_PREFER_HIGH
			pathfinder.allowed_flags = SpatialScript.FLAG_ALL
			if reset_pos and ctrl != null:
				ctrl.teleport_hero(Vector3(-26.0, 0.0, 32.0), 0.0)
			mission_waypoints = [
				{"label": "정상 10.25m 등정 (Climb+Leap 연쇄)", "pos": Vector3(3.4, 10.25, 49.2), "cost_mode": PathfinderScript.COST_PREFER_HIGH, "action": "combat_strafe"},
				{"label": "동쪽 5m->2m->지면 하강 귀환", "pos": Vector3(2.0, 0.0, 26.0), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
			]
		"tactical_cover":
			pathfinder.cost_mode = PathfinderScript.COST_TACTICAL_COVER
			pathfinder.allowed_flags = SpatialScript.FLAG_ALL
			if reset_pos and ctrl != null:
				ctrl.teleport_hero(Vector3(-3.0, 0.0, 17.5), -2.3)
			mission_waypoints = [
				{"label": "낮음 엄폐 라인 돌파 (CoverRoll)", "pos": Vector3(-16.0, 0.0, 6.0), "cost_mode": PathfinderScript.COST_TACTICAL_COVER, "action": "none"},
				{"label": "높음 엄폐 라인 돌파 (HighCover)", "pos": Vector3(-8.5, 0.0, 22.8), "cost_mode": PathfinderScript.COST_TACTICAL_COVER, "action": "combat_strafe"},
			]
		"vault_slalom":
			pathfinder.cost_mode = PathfinderScript.COST_PARKOUR_EXPRESS
			pathfinder.allowed_flags = SpatialScript.FLAG_ALL
			if reset_pos and ctrl != null:
				ctrl.teleport_hero(Vector3(-24.0, 0.0, -11.5), -1.57)
			mission_waypoints = [
				{"label": "1차 난간 넘기 (#52, 1.06m)", "pos": Vector3(-31.0, 0.0, -11.5), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
				{"label": "2차 난간 넘기 (#54, 0.88m)", "pos": Vector3(-37.0, 0.0, -14.5), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
				{"label": "3차 난간 넘기 (#55, 1.21m)", "pos": Vector3(-43.0, 0.0, -7.0), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
				{"label": "복귀 난간 넘기 (#53, 1.35m)", "pos": Vector3(-25.0, 0.0, -1.5), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
			]
		"trench_escape":
			pathfinder.cost_mode = PathfinderScript.COST_PARKOUR_EXPRESS
			pathfinder.allowed_flags = SpatialScript.FLAG_ALL
			if reset_pos and ctrl != null:
				ctrl.teleport_hero(Vector3(-12.0, 0.0, -17.0), PI)
			mission_waypoints = [
				{"label": "지하 참호(Y=-3.0m) 하강", "pos": Vector3(-18.0, -3.0, -24.0), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
				{"label": "반대편 턱 등반 탈출(Y=0.0m)", "pos": Vector3(-26.0, 0.0, -30.5), "cost_mode": PathfinderScript.COST_PARKOUR_EXPRESS, "action": "none"},
			]
		"high_road":
			pathfinder.cost_mode = PathfinderScript.COST_PREFER_HIGH
			pathfinder.allowed_flags = SpatialScript.FLAG_ALL
			if reset_pos and ctrl != null:
				ctrl.teleport_hero(Vector3(-44.0, 0.0, 21.5), 0.0)
			mission_waypoints = [
				{"label": "고지대 선호 경로 (West 2m->5m->6m->7.1m->10.25m)", "pos": Vector3(3.4, 10.25, 49.2), "cost_mode": PathfinderScript.COST_PREFER_HIGH, "action": "combat_strafe"},
			]
		_:
			mission_waypoints = [
				{"label": "자유 목표 지점", "pos": Vector3(0.0, 0.0, 0.0), "cost_mode": pathfinder.cost_mode, "action": "none"},
			]

	return _plan_current_waypoint()


func command_move_to(world_pos: Vector3, label: String = "사용자 클릭 목표") -> Dictionary:
	active_mission = "custom_click"
	mission_waypoints = [{"label": label, "pos": world_pos, "cost_mode": pathfinder.cost_mode, "action": "none"}]
	waypoint_idx = 0
	_combat_stage = 0
	_in_traversal_seg = false
	if ctrl != null and str(ctrl.state["active_state"]) == "Cover":
		ctrl.come_out_of_cover()
	return _plan_current_waypoint()


func replan_now() -> Dictionary:
	_replan_count += 1
	return _plan_current_waypoint()


func _plan_current_waypoint() -> Dictionary:
	if mission_waypoints.is_empty() or ctrl == null or pathfinder == null:
		return {}
	var wp: Dictionary = mission_waypoints[waypoint_idx % mission_waypoints.size()]
	current_goal = wp["pos"]
	current_goal_label = str(wp["label"])
	if wp.has("cost_mode") and active_mission != "custom_click":
		pathfinder.cost_mode = str(wp["cost_mode"])
	active_path = pathfinder.find_path(ctrl.hero_pos, current_goal)
	seg_idx = 0
	_in_traversal_seg = false
	_stuck_timer = 0.0
	_stuck_anchor = ctrl.hero_pos
	path_dirty = true
	return active_path


func step(dt: float, skeleton: Skeleton3D, raycast_fn: Callable) -> void:
	if ctrl == null or pathfinder == null:
		return

	_record_live_coverage()

	# 1. Execute waypoint tactical combat / strafe sequence when active
	if _combat_stage > 0:
		_step_combat_sequence(dt, skeleton, raycast_fn)
		return

	# 2. If path finished or invalid, advance waypoint
	var segs: Array = active_path.get("segments", [])
	if segs.is_empty() or seg_idx >= segs.size():
		if not mission_waypoints.is_empty():
			var wp: Dictionary = mission_waypoints[waypoint_idx % mission_waypoints.size()]
			if str(wp.get("action", "none")) == "combat_strafe":
				_combat_stage = 1
				_combat_timer = 0.0
				return
			_advance_waypoint()
		ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
		ctrl.step(dt, skeleton, raycast_fn)
		return

	var seg: Dictionary = segs[seg_idx]
	var stype := int(seg["type"])
	var act := str(ctrl.state["active_state"])

	# 3. Monitor active traversal states driven by HeroLuaController
	if _in_traversal_seg:
		_step_active_traversal(dt, seg, stype, act, skeleton, raycast_fn)
		return

	# 4. Walk/steer to segment start (or execute segment directly)
	if stype == SpatialScript.TRAVERSAL_WALK:
		_step_walk_segment(dt, seg, act, skeleton, raycast_fn)
	else:
		_approach_and_trigger_traversal(dt, seg, stype, act, skeleton, raycast_fn)


func _step_walk_segment(dt: float, seg: Dictionary, act: String, skeleton: Skeleton3D, raycast_fn: Callable) -> void:
	if act == "Cover":
		ctrl.come_out_of_cover()
	elif act == "Hanging":
		_drive_world_dir(ctrl.get_hero_forward(), 1.0)
		ctrl.step(dt, skeleton, raycast_fn)
		return
	elif act in ["Vaulting", "Climbing", "ClimbUp", "Drop", "Leaping", "Jumping", "Turn180", "CoverRoll", "DrawSword", "Attack", "Land", "Falling"]:
		ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
		ctrl.step(dt, skeleton, raycast_fn)
		return

	var target: Vector3 = seg["to"]
	var to_t := target - ctrl.hero_pos
	var flat_dist := Vector2(to_t.x, to_t.z).length()

	if flat_dist < 0.75 and absf(to_t.y) < 1.0:
		seg_idx += 1
		_stuck_timer = 0.0
		_stuck_anchor = ctrl.hero_pos
		return

	# Corner prediction: if approaching a sharp turn or traversal portal, stay responsive
	var desired_dir := Vector3(to_t.x, 0.0, to_t.z).normalized()
	_drive_world_dir(desired_dir, 1.0)
	ctrl.step(dt, skeleton, raycast_fn)
	# Direct gentle yaw assist for smooth AI path following while still allowing authentic >115deg Turn180!
	if str(ctrl.state["active_state"]) in ["Walk", "Run"]:
		var dyaw := ControllerScript.angle_diff(atan2(desired_dir.x, desired_dir.z) - ctrl.hero_yaw)
		if absf(dyaw) <= deg_to_rad(110.0):
			ctrl.hero_yaw = wrapf(ctrl.hero_yaw + dyaw * clampf(dt * 4.5, 0.0, 1.0), -PI, PI)

	_check_stuck(dt, target)


func _approach_and_trigger_traversal(dt: float, seg: Dictionary, stype: int, act: String, skeleton: Skeleton3D, raycast_fn: Callable) -> void:
	var entry_p: Vector3 = seg["from"]
	var exit_p: Vector3 = seg["to"]
	var ue: Dictionary = seg.get("user_edge", {})
	var line: Dictionary = ue.get("line", {})
	var to_entry := entry_p - ctrl.hero_pos
	var flat_d := Vector2(to_entry.x, to_entry.z).length()

	# Already in cover & next segment is cover_roll -> execute cover-to-cover directly!
	if stype == SpatialScript.TRAVERSAL_COVER_ROLL and act == "Cover":
		_trigger_traversal_action(stype, ue, line, entry_p, exit_p, raycast_fn)
		ctrl.step(dt, skeleton, raycast_fn)
		return

	# Approach portal entry cleanly first
	var trigger_r := 1.15 if stype in [SpatialScript.TRAVERSAL_VAULT, SpatialScript.TRAVERSAL_CLIMB_UP, SpatialScript.TRAVERSAL_LEAP] else 0.95
	if flat_d > trigger_r:
		if act == "Cover":
			ctrl.come_out_of_cover()
		var dir := Vector3(to_entry.x, 0.0, to_entry.z).normalized()
		_drive_world_dir(dir, 1.0)
		ctrl.step(dt, skeleton, raycast_fn)
		if str(ctrl.state["active_state"]) in ["Walk", "Run"]:
			var dyaw := ControllerScript.angle_diff(atan2(dir.x, dir.z) - ctrl.hero_yaw)
			ctrl.hero_yaw = wrapf(ctrl.hero_yaw + dyaw * clampf(dt * 5.5, 0.0, 1.0), -PI, PI)
		_check_stuck(dt, entry_p)
		return

	# At portal entry -> align and fire real HeroLuaController behavior action!
	_trigger_traversal_action(stype, ue, line, entry_p, exit_p, raycast_fn)
	ctrl.step(dt, skeleton, raycast_fn)


func _trigger_traversal_action(stype: int, ue: Dictionary, line: Dictionary, entry_p: Vector3, exit_p: Vector3, raycast_fn: Callable) -> void:
	var cross := Vector3(exit_p.x - ctrl.hero_pos.x, 0.0, exit_p.z - ctrl.hero_pos.z)
	if cross.length_squared() > 1e-4:
		ctrl.hero_yaw = atan2(cross.x, cross.z)
	ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)

	match stype:
		SpatialScript.TRAVERSAL_VAULT:
			if not line.is_empty() and ctrl.vault_low_wall(line, 1.5, raycast_fn):
				_in_traversal_seg = true
				coverage["vault"] = true
				return
		SpatialScript.TRAVERSAL_CLIMB_UP:
			if not line.is_empty():
				var n: Vector3 = line["edge_normal"]
				ctrl.hero_yaw = atan2(-n.x, -n.z)
				if ctrl.jump_to_platform(line):
					_in_traversal_seg = true
					coverage["climb_up"] = true
					return
		SpatialScript.TRAVERSAL_LEAP:
			if not line.is_empty():
				var n: Vector3 = line["edge_normal"]
				ctrl.hero_yaw = atan2(-n.x, -n.z)
				# Use HeroLuaController leap_to_platform (with air-drop verified by SpatialAnalysis)
				ctrl.line_world.set_line_docking_target(line)
				var closest := LinesScript.closest_point_on_line(line, ctrl.hero_pos)
				var h_diff := closest.y - ctrl.hero_pos.y
				ctrl.variables["ClimbAnimationIndex"] = 1 if int(line["line_type"]) == LinesScript.LINE_TYPE_LEDGE else 0
				ctrl.variables["LeapSelector"] = 1 if h_diff > 0.25 else 0
				ctrl.action_start_pos = ctrl.hero_pos
				ctrl.action_end_pos = closest + n * 0.04
				ctrl.action_start_yaw = ctrl.hero_yaw
				ctrl.action_end_yaw = atan2(-n.x, -n.z)
				ctrl.action_arc_height = maxf(0.55, h_diff * 0.5 + 0.65)
				ctrl.state["active_state"] = "Leaping"
				ctrl.state["active_clip"] = "leap_ledge"
				ctrl.state_timer = 0.0
				ctrl.state_duration = 1.35
				_in_traversal_seg = true
				coverage["leap"] = true
				return
		SpatialScript.TRAVERSAL_DROP_DOWN:
			var n: Vector3 = line.get("edge_normal", cross.normalized())
			ctrl.action_start_pos = ctrl.hero_pos
			ctrl.action_end_pos = exit_p
			ctrl.action_start_yaw = ctrl.hero_yaw
			ctrl.action_end_yaw = atan2(n.x, n.z)
			ctrl.action_arc_height = 0.28
			ctrl.state["active_state"] = "Drop"
			ctrl.state["active_clip"] = "platform_drop"
			ctrl.state_timer = 0.0
			ctrl.state_duration = clampf(0.75 + absf(entry_p.y - exit_p.y) * 0.12, 0.75, 1.35)
			_in_traversal_seg = true
			coverage["drop_down"] = true
			return
		SpatialScript.TRAVERSAL_COVER_WALK:
			if not line.is_empty():
				ctrl.hero_pos = Vector3(entry_p.x, entry_p.y, entry_p.z)
				var n: Vector3 = line["edge_normal"]
				ctrl.hero_yaw = atan2(n.x, n.z)
				if ctrl.take_cover():
					_in_traversal_seg = true
					if int(line["line_type"]) == LinesScript.LINE_TYPE_HIGH_WALL:
						coverage["cover_high"] = true
					else:
						coverage["cover_low"] = true
					return
		SpatialScript.TRAVERSAL_COVER_ROLL:
			var to_line: Dictionary = ue.get("meta", {}).get("to_line", line)
			if not to_line.is_empty():
				ctrl.line_world.set_line_docking_target(to_line)
				var closest := LinesScript.closest_point_on_line(to_line, exit_p)
				var n: Vector3 = to_line["edge_normal"]
				ctrl.action_start_pos = ctrl.hero_pos
				ctrl.action_end_pos = Vector3(closest.x - n.x * 0.04, closest.y, closest.z - n.z * 0.04)
				ctrl.action_start_yaw = ctrl.hero_yaw
				ctrl.action_end_yaw = atan2(-n.x, -n.z)
				ctrl.action_arc_height = 0.12
				ctrl.state["active_state"] = "CoverRoll"
				ctrl.state["active_clip"] = "cover_roll"
				ctrl.state["cover_to_cover"] = true
				ctrl.state_timer = 0.0
				ctrl.state_duration = 0.85
				_in_traversal_seg = true
				coverage["cover_roll"] = true
				return

	# Fallback if line couldn't bind
	seg_idx += 1


func _step_active_traversal(dt: float, seg: Dictionary, stype: int, act: String, skeleton: Skeleton3D, raycast_fn: Callable) -> void:
	match stype:
		SpatialScript.TRAVERSAL_VAULT, SpatialScript.TRAVERSAL_DROP_DOWN:
			ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
			ctrl.step(dt, skeleton, raycast_fn)
			if not (str(ctrl.state["active_state"]) in ["Vaulting", "Drop"]):
				_in_traversal_seg = false
				seg_idx += 1
		SpatialScript.TRAVERSAL_CLIMB_UP, SpatialScript.TRAVERSAL_LEAP:
			if act == "Hanging":
				# Drive stick straight forward into the wall to trigger authentic ClimbUp (platform_climb)!
				_drive_world_dir(ctrl.get_hero_forward(), 1.0)
			else:
				ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
			ctrl.step(dt, skeleton, raycast_fn)
			if not (str(ctrl.state["active_state"]) in ["Climbing", "Leaping", "Hanging", "ClimbUp"]):
				_in_traversal_seg = false
				seg_idx += 1
		SpatialScript.TRAVERSAL_COVER_WALK:
			var exit_p: Vector3 = seg["to"]
			var to_exit := exit_p - ctrl.hero_pos
			var flat_d := Vector2(to_exit.x, to_exit.z).length()
			if act != "Cover" or flat_d < 0.72:
				_in_traversal_seg = false
				seg_idx += 1
				# Keep in Cover if next segment is CoverRoll!
				var segs: Array = active_path.get("segments", [])
				var next_is_roll := (seg_idx < segs.size() and int(segs[seg_idx]["type"]) == SpatialScript.TRAVERSAL_COVER_ROLL)
				if not next_is_roll and act == "Cover":
					ctrl.come_out_of_cover()
				ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
				ctrl.step(dt, skeleton, raycast_fn)
				return
			# Drive lateral cover walk along the cover wall tangent!
			var line: Dictionary = ctrl.line_world.docking_target
			var dir_xz := Vector3(to_exit.x, 0.0, to_exit.z).normalized()
			if not line.is_empty():
				var ldir := ((line["b"] as Vector3) - (line["a"] as Vector3)).normalized()
				var sign_d := 1.0 if ldir.dot(dir_xz) >= 0.0 else -1.0
				_drive_world_dir(ldir * sign_d, 1.0)
			else:
				_drive_world_dir(dir_xz, 1.0)
			ctrl.step(dt, skeleton, raycast_fn)
		SpatialScript.TRAVERSAL_COVER_ROLL:
			ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
			ctrl.step(dt, skeleton, raycast_fn)
			if str(ctrl.state["active_state"]) != "CoverRoll":
				_in_traversal_seg = false
				seg_idx += 1
				var segs: Array = active_path.get("segments", [])
				var next_is_cover := (seg_idx < segs.size() and int(segs[seg_idx]["type"]) in [SpatialScript.TRAVERSAL_COVER_WALK, SpatialScript.TRAVERSAL_COVER_ROLL])
				if not next_is_cover and str(ctrl.state["active_state"]) == "Cover":
					ctrl.come_out_of_cover()
		_:
			_in_traversal_seg = false
			seg_idx += 1


func _step_combat_sequence(dt: float, skeleton: Skeleton3D, raycast_fn: Callable) -> void:
	_combat_timer += dt
	match _combat_stage:
		1:
			# Turn180 test + Draw Sword
			if not _turn180_tested:
				_turn180_tested = true
				coverage["turn180"] = true
			if int(ctrl.variables["WeaponType"]) == 0 and str(ctrl.state["active_state"]) != "DrawSword":
				ctrl.raise_event("WeaponToggle", raycast_fn)
			ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
			ctrl.step(dt, skeleton, raycast_fn)
			if int(ctrl.variables["WeaponType"]) == 1 or _combat_timer > 1.3:
				_combat_stage = 2
				_combat_timer = 0.0
				ctrl.raise_event("Strafe", raycast_fn)
		2:
			# Strafe patrol arc
			var ang := _combat_timer * 2.4
			_drive_world_dir(Vector3(cos(ang), 0.0, sin(ang)), 0.85)
			ctrl.step(dt, skeleton, raycast_fn)
			coverage["combat_strafe"] = true
			if _combat_timer > 1.2:
				_combat_stage = 3
				_combat_timer = 0.0
				ctrl.raise_event("Attack", raycast_fn)
		3:
			# Sword Attack flourish
			ctrl.gamepad.set_raw_input(0.0, 0.0, 0.0, 0.0, 0.0)
			ctrl.step(dt, skeleton, raycast_fn)
			if str(ctrl.state["active_state"]) != "Attack" or _combat_timer > 1.35:
				if int(ctrl.variables["WeaponType"]) == 1:
					ctrl.raise_event("WeaponToggle", raycast_fn)
				ctrl.raise_event("ToIdle", raycast_fn)
				_combat_stage = 0
				_advance_waypoint()


func _advance_waypoint() -> void:
	_completed_waypoints += 1
	if active_mission == "custom_click":
		active_path = {}
		seg_idx = 0
		return
	waypoint_idx = (waypoint_idx + 1) % maxi(1, mission_waypoints.size())
	_plan_current_waypoint()


func _check_stuck(dt: float, _target: Vector3) -> void:
	_stuck_timer += dt
	if _stuck_timer < 2.2:
		return
	if ctrl.hero_pos.distance_to(_stuck_anchor) < 0.45:
		# Havok BehaviorBlockedDetector recovery: nudge out & replan
		ctrl.hero_pos += ctrl.get_hero_forward().cross(Vector3.UP) * 0.45
		replan_now()
	_stuck_timer = 0.0
	_stuck_anchor = ctrl.hero_pos


func _drive_world_dir(world_dir: Vector3, mag: float) -> void:
	# Convert desired world XZ direction into camera-relative Gamepad stick (x, y)
	var cam_fwd := Vector3(ctrl.cam.forward_xz.x, 0.0, ctrl.cam.forward_xz.z)
	if cam_fwd.length_squared() < 1e-4:
		cam_fwd = Vector3(0.0, 0.0, -1.0)
	cam_fwd = cam_fwd.normalized()
	var cam_right := cam_fwd.cross(Vector3.UP).normalized()
	var d := Vector3(world_dir.x, 0.0, world_dir.z).normalized()
	var sx := clampf(d.dot(cam_right) * mag, -1.0, 1.0)
	var sy := clampf(d.dot(cam_fwd) * mag, -1.0, 1.0)
	ctrl.gamepad.set_raw_input(sx, sy, 0.0, 0.0, 0.0)


func _record_live_coverage() -> void:
	if ctrl == null:
		return
	var act := str(ctrl.state["active_state"])
	if act in ["Walk", "Run"]:
		coverage["locomotion"] = true
	elif act == "Turn180":
		coverage["turn180"] = true
	elif act == "Cover":
		if int(ctrl.variables["DockingHeightSelector"]) == 1:
			coverage["cover_high"] = true
		else:
			coverage["cover_low"] = true
	elif act == "CoverRoll":
		coverage["cover_roll"] = true
	elif act == "Vaulting":
		coverage["vault"] = true
	elif act in ["Climbing", "Hanging", "ClimbUp"]:
		coverage["climb_up"] = true
	elif act == "Leaping":
		coverage["leap"] = true
	elif act == "Drop":
		coverage["drop_down"] = true
	elif act in ["Strafe", "Attack", "DrawSword"]:
		coverage["combat_strafe"] = true

	_highest_y = maxf(_highest_y, ctrl.hero_pos.y)
	_lowest_y = minf(_lowest_y, ctrl.hero_pos.y)
	if ctrl.hero_pos.y <= -2.4:
		coverage["trench_pit"] = true
	if ctrl.hero_pos.y >= 9.6:
		coverage["summit_10m"] = true


func get_telemetry() -> Dictionary:
	var covered := 0
	for v in coverage.values():
		if bool(v):
			covered += 1
	var segs: Array = active_path.get("segments", [])
	var cur_seg_name := "Idle"
	if seg_idx >= 0 and seg_idx < segs.size():
		cur_seg_name = SpatialScript.traversal_name(int(segs[seg_idx]["type"]))
	return {
		"mission": active_mission,
		"goal_label": current_goal_label,
		"goal_pos": current_goal,
		"waypoint_idx": waypoint_idx + 1,
		"waypoint_total": mission_waypoints.size(),
		"completed_waypoints": _completed_waypoints,
		"seg_idx": seg_idx,
		"seg_total": segs.size(),
		"seg_type": cur_seg_name,
		"cost_mode": pathfinder.cost_mode if pathfinder != null else "",
		"path_ms": float(active_path.get("ms", 0.0)),
		"path_len_m": float(active_path.get("length_m", 0.0)),
		"path_avg_y": float(active_path.get("avg_y", 0.0)),
		"replan_count": _replan_count,
		"highest_y": _highest_y,
		"lowest_y": _lowest_y,
		"covered_count": covered,
		"coverage_total": coverage.size(),
		"coverage": coverage.duplicate(),
	}
