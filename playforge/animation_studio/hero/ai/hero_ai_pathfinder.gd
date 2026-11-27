@tool
class_name HeroAiPathfinder
extends RefCounted
## Havok AI A* Pathfinding (hkaiPathfindingUtil::findPath + hkaiAstarCostModifier
## + PreferHighPlacesCostModifier + TacticalCoverCostModifier + Dynamic Silhouettes)
## over the multi-layer HeroSpatialAnalysis NavGraph + Traversal UserEdges.

const SpatialScript := preload("res://hero/ai/hero_spatial_analysis.gd")

const COST_SHORTEST := "shortest"
const COST_PREFER_HIGH := "prefer_high"
const COST_TACTICAL_COVER := "tactical_cover"
const COST_PARKOUR_EXPRESS := "parkour_express"

var spatial: SpatialScript = null
var allowed_flags: int = SpatialScript.FLAG_ALL
var cost_mode: String = COST_SHORTEST
var threat_pos: Vector3 = Vector3(-14.0, 0.0, 14.0)
var dynamic_obstacles: Array = [] # [{pos: Vector3, radius: float}]


func setup(spatial_analysis: SpatialScript) -> void:
	spatial = spatial_analysis


func find_path(start_pos: Vector3, goal_pos: Vector3) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	if spatial == null or spatial.nav_nodes.is_empty():
		return {"ok": false, "segments": [], "points": [], "cost": 0.0, "ms": 0.0}

	var start_id := spatial.find_closest_node(start_pos, 2.5)
	var goal_id := spatial.find_closest_node(goal_pos, 2.5)
	if start_id < 0 or goal_id < 0:
		return {"ok": false, "segments": [], "points": [], "cost": 0.0, "ms": 0.0}

	var n_count := spatial.nav_nodes.size()
	var g_score: PackedFloat32Array = PackedFloat32Array()
	g_score.resize(n_count)
	g_score.fill(1e18)

	var came_from: PackedInt32Array = PackedInt32Array()
	came_from.resize(n_count)
	came_from.fill(-1)

	var came_edge_type: PackedInt32Array = PackedInt32Array()
	came_edge_type.resize(n_count)
	came_edge_type.fill(SpatialScript.TRAVERSAL_WALK)

	var came_ue_idx: PackedInt32Array = PackedInt32Array()
	came_ue_idx.resize(n_count)
	came_ue_idx.fill(-1)

	var closed: PackedByteArray = PackedByteArray()
	closed.resize(n_count)
	closed.fill(0)

	var goal_p: Vector3 = spatial.nav_nodes[goal_id]["pos"]
	g_score[start_id] = 0.0

	# Binary min-heap of [f_score, node_id]
	var heap_f: Array[float] = [start_pos.distance_to(goal_p)]
	var heap_n: Array[int] = [start_id]

	var expanded := 0
	var found := false

	while not heap_n.is_empty():
		var cur := _heap_pop(heap_f, heap_n)
		if closed[cur] != 0:
			continue
		closed[cur] = 1
		expanded += 1
		if cur == goal_id:
			found = true
			break

		var cur_p: Vector3 = spatial.nav_nodes[cur]["pos"]
		var edges: Array = spatial.adjacency[cur]
		for e in edges:
			var nb: int = int(e["to"])
			if closed[nb] != 0:
				continue
			var etype: int = int(e["type"])
			var fl := SpatialScript.traversal_flag(etype)
			if fl != 0 and (allowed_flags & fl) == 0:
				continue

			var nb_p: Vector3 = spatial.nav_nodes[nb]["pos"]
			var step_cost := _modified_edge_cost(cur_p, nb_p, float(e["cost"]), etype)
			if step_cost >= 1e9:
				continue
			var tentative_g := g_score[cur] + step_cost
			if tentative_g < g_score[nb]:
				came_from[nb] = cur
				came_edge_type[nb] = etype
				came_ue_idx[nb] = int(e["user_edge_idx"])
				g_score[nb] = tentative_g
				var h := nb_p.distance_to(goal_p) * _heuristic_weight()
				_heap_push(heap_f, heap_n, tentative_g + h, nb)

	var elapsed_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if not found:
		return {
			"ok": false,
			"start_id": start_id,
			"goal_id": goal_id,
			"expanded": expanded,
			"ms": elapsed_ms,
			"segments": [],
			"points": [],
			"traversal_counts": {},
		}

	# Reconstruct raw edges
	var rev_edges: Array[Dictionary] = []
	var walk_cur := goal_id
	while walk_cur != start_id and walk_cur >= 0:
		var prev := came_from[walk_cur]
		if prev < 0:
			break
		var ue_i := came_ue_idx[walk_cur]
		rev_edges.append({
			"from_node": prev,
			"to_node": walk_cur,
			"from": spatial.nav_nodes[prev]["pos"],
			"to": spatial.nav_nodes[walk_cur]["pos"],
			"type": came_edge_type[walk_cur],
			"user_edge": spatial.user_edges[ue_i] if ue_i >= 0 else {},
		})
		walk_cur = prev
	rev_edges.reverse()

	var segments := _simplify_walk_segments(rev_edges, start_pos, goal_pos)
	var points: PackedVector3Array = PackedVector3Array()
	var trav_counts: Dictionary = {}
	var sum_y := 0.0
	var total_len := 0.0
	for seg in segments:
		var tname := SpatialScript.traversal_name(int(seg["type"]))
		trav_counts[tname] = int(trav_counts.get(tname, 0)) + 1
		var f_p: Vector3 = seg["from"]
		var t_p: Vector3 = seg["to"]
		if points.is_empty():
			points.append(f_p)
		points.append(t_p)
		var seg_l := f_p.distance_to(t_p)
		total_len += seg_l
		sum_y += ((f_p.y + t_p.y) * 0.5) * seg_l

	return {
		"ok": true,
		"start_id": start_id,
		"goal_id": goal_id,
		"expanded": expanded,
		"cost": g_score[goal_id],
		"length_m": total_len,
		"avg_y": sum_y / maxf(0.01, total_len),
		"ms": elapsed_ms,
		"segments": segments,
		"points": points,
		"traversal_counts": trav_counts,
		"cost_mode": cost_mode,
	}


func _heuristic_weight() -> float:
	if cost_mode == COST_TACTICAL_COVER or cost_mode == COST_PARKOUR_EXPRESS:
		return 0.35 # Keep A* admissible when edges are discounted
	return 1.0


func _modified_edge_cost(a: Vector3, b: Vector3, base_cost: float, etype: int) -> float:
	# Dynamic obstacle silhouettes (hkaiDynamicPathfinding)
	var mid := (a + b) * 0.5
	for obs in dynamic_obstacles:
		var op: Vector3 = obs.get("pos", Vector3.ZERO)
		var r: float = float(obs.get("radius", 1.8))
		if absf(mid.y - op.y) < 1.8 and Vector2(mid.x - op.x, mid.z - op.z).length() < r:
			return 1e10

	match cost_mode:
		COST_PREFER_HIGH:
			# Exact Havok SpatialAnalysisDemo.cpp PreferHighPlacesCostModifier:
			# penalty = max(0, ceiling - avgHeight) * travelDist * multiplier
			var ceiling := 10.5
			var avg_y := (a.y + b.y) * 0.5
			var dist := a.distance_to(b)
			var penalty := maxf(0.0, ceiling - avg_y) * dist * 0.55
			if etype == SpatialScript.TRAVERSAL_CLIMB_UP or etype == SpatialScript.TRAVERSAL_LEAP:
				return base_cost * 0.55 + penalty * 0.25
			return base_cost + penalty
		COST_TACTICAL_COVER:
			if etype == SpatialScript.TRAVERSAL_COVER_WALK or etype == SpatialScript.TRAVERSAL_COVER_ROLL:
				return base_cost * 0.28
			var threat_d := Vector2(mid.x - threat_pos.x, mid.z - threat_pos.z).length()
			var expose_pen := clampf(14.0 - threat_d, 0.0, 14.0) * 0.45
			return base_cost + expose_pen
		COST_PARKOUR_EXPRESS:
			if etype != SpatialScript.TRAVERSAL_WALK:
				return base_cost * 0.42
			return base_cost * 1.15
		_:
			return base_cost


func _simplify_walk_segments(raw_edges: Array[Dictionary], start_pos: Vector3, goal_pos: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if raw_edges.is_empty():
		if start_pos.distance_to(goal_pos) > 0.2:
			out.append({"from": start_pos, "to": goal_pos, "type": SpatialScript.TRAVERSAL_WALK, "user_edge": {}})
		return out

	var i := 0
	while i < raw_edges.size():
		var e: Dictionary = raw_edges[i]
		if int(e["type"]) != SpatialScript.TRAVERSAL_WALK:
			out.append(e)
			i += 1
			continue
		# Merge collinear flat walk edges for smooth steering
		var run_start: Vector3 = e["from"]
		var run_end: Vector3 = e["to"]
		var dir := (run_end - run_start).normalized()
		i += 1
		while i < raw_edges.size() and int(raw_edges[i]["type"]) == SpatialScript.TRAVERSAL_WALK:
			var nxt: Vector3 = raw_edges[i]["to"]
			var ndir := (nxt - run_end).normalized()
			if ndir.dot(dir) > 0.965 and absf(nxt.y - run_end.y) < 0.25 and run_start.distance_to(nxt) < 8.0:
				run_end = nxt
				i += 1
			else:
				break
		out.append({
			"from": run_start,
			"to": run_end,
			"type": SpatialScript.TRAVERSAL_WALK,
			"user_edge": {},
		})

	# Snap final walk endpoint to exact requested goal if close & same tier
	if not out.is_empty() and int(out[out.size() - 1]["type"]) == SpatialScript.TRAVERSAL_WALK:
		var last_to: Vector3 = out[out.size() - 1]["to"]
		if absf(last_to.y - goal_pos.y) < 0.5 and last_to.distance_to(goal_pos) < 2.2:
			out[out.size() - 1]["to"] = goal_pos
	return out


func build_path_mesh(path_result: Dictionary) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	var segs: Array = path_result.get("segments", [])
	if segs.is_empty():
		return im
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for seg in segs:
		var p0: Vector3 = (seg["from"] as Vector3) + Vector3(0.0, 0.24, 0.0)
		var p1: Vector3 = (seg["to"] as Vector3) + Vector3(0.0, 0.24, 0.0)
		var t := int(seg["type"])
		var col := Color("#fde047") if t == SpatialScript.TRAVERSAL_WALK else SpatialScript.traversal_color(t).lightened(0.25)
		var arc_h := 0.0
		match t:
			SpatialScript.TRAVERSAL_VAULT: arc_h = 1.35
			SpatialScript.TRAVERSAL_CLIMB_UP: arc_h = 0.70
			SpatialScript.TRAVERSAL_LEAP: arc_h = 1.50
			SpatialScript.TRAVERSAL_DROP_DOWN: arc_h = 0.50
			SpatialScript.TRAVERSAL_COVER_ROLL: arc_h = 0.50
		var steps := 10 if arc_h > 0.01 else 1
		var prev := p0
		for s in range(1, steps + 1):
			var u := float(s) / float(steps)
			var cur := p0.lerp(p1, u)
			if arc_h > 0.01:
				cur.y += sin(u * PI) * arc_h
			# Draw thick double-line ribbon for high visibility in 3D viewport
			var offs: Array[float] = [0.0, 0.06]
			for off_y: float in offs:
				im.surface_set_color(col)
				im.surface_add_vertex(prev + Vector3(0.0, off_y, 0.0))
				im.surface_set_color(col)
				im.surface_add_vertex(cur + Vector3(0.0, off_y, 0.0))
			prev = cur
	im.surface_end()
	return im


static func _heap_push(hf: Array[float], hn: Array[int], f: float, n: int) -> void:
	hf.append(f)
	hn.append(n)
	var i := hf.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if hf[p] <= hf[i]:
			break
		var tf := hf[p]; hf[p] = hf[i]; hf[i] = tf
		var tn := hn[p]; hn[p] = hn[i]; hn[i] = tn
		i = p


static func _heap_pop(hf: Array[float], hn: Array[int]) -> int:
	var top := hn[0]
	var last_f: float = hf.pop_back()
	var last_n: int = hn.pop_back()
	if not hf.is_empty():
		hf[0] = last_f
		hn[0] = last_n
		var sz := hf.size()
		var i := 0
		while true:
			var l := (i << 1) + 1
			var r := l + 1
			var sm := i
			if l < sz and hf[l] < hf[sm]:
				sm = l
			if r < sz and hf[r] < hf[sm]:
				sm = r
			if sm == i:
				break
			var tf := hf[i]; hf[i] = hf[sm]; hf[sm] = tf
			var tn := hn[i]; hn[i] = hn[sm]; hn[sm] = tn
			i = sm
	return top
