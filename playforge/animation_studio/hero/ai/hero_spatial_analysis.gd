@tool
class_name HeroSpatialAnalysis
extends RefCounted
## Havok AI Spatial Analysis (hkaiTraversalAnalysis + hkaiTraversalAnnotationLibrary
## + hkaiUserEdgeUtils + Gdc2009AiCoverPointManager) implemented natively in Godot.
##
## Analyzes `res://hero/assets/hero_environment.glb` walkable surfaces across ALL
## elevation tiers (Y = -3.0m sunken pit up to Y = +10.25m summit) and all 90
## Hero docking lines to automatically build:
##   1. Multi-layer 2.5D NavMesh graph (walkable nodes + slope/step edges)
##   2. Annotated Traversal UserEdges:
##        - TRAVERSAL_VAULT       (hkaiVaultAnalyzer)
##        - TRAVERSAL_CLIMB_UP    (hkaiClimbUpAnalyzer)
##        - TRAVERSAL_LEAP        (hkaiJumpAnalyzer)
##        - TRAVERSAL_DROP_DOWN   (hkaiDropDownAnalyzer)
##        - TRAVERSAL_COVER_WALK  (Tactical Cover Slide)
##        - TRAVERSAL_COVER_ROLL  (Cover-to-Cover Roll)
##   3. Visual debug meshes mirroring hkaiNavMeshViewer & hkaiTraversalAnnotationViewer.

const ENV_GLB_PATH := "res://hero/assets/hero_environment.glb"
const LinesScript := preload("res://hero/arena/hero_lua_lines.gd")

const TRAVERSAL_WALK := 0
const TRAVERSAL_VAULT := 1
const TRAVERSAL_CLIMB_UP := 2
const TRAVERSAL_LEAP := 3
const TRAVERSAL_DROP_DOWN := 4
const TRAVERSAL_COVER_WALK := 5
const TRAVERSAL_COVER_ROLL := 6

const FLAG_VAULT := 1
const FLAG_CLIMB := 2
const FLAG_LEAP := 4
const FLAG_DROP := 8
const FLAG_COVER := 16
const FLAG_ALL := 31

const GRID_STEP := 2.0
const TRI_BUCKET := 4.0

var nav_nodes: Array[Dictionary] = []
var adjacency: Array = [] # Array of Array[Dictionary]: {to, cost, type, user_edge_idx}
var user_edges: Array[Dictionary] = []
var cover_points: Array[Dictionary] = []
var walkable_tris: Array[Dictionary] = [] # {v0, v1, v2, normal}
var stats: Dictionary = {}

var _tri_grid: Dictionary = {} # Vector2i -> Array[int]
var _cell_nodes: Dictionary = {} # Vector2i -> Array[int] (multi-layer nodes at XZ cell)
var _lines: Array[Dictionary] = []


static func traversal_name(t: int) -> String:
	match t:
		TRAVERSAL_WALK: return "Walk"
		TRAVERSAL_VAULT: return "Vault"
		TRAVERSAL_CLIMB_UP: return "ClimbUp"
		TRAVERSAL_LEAP: return "Leap"
		TRAVERSAL_DROP_DOWN: return "DropDown"
		TRAVERSAL_COVER_WALK: return "CoverWalk"
		TRAVERSAL_COVER_ROLL: return "CoverRoll"
		_: return "Unknown"


static func traversal_flag(t: int) -> int:
	match t:
		TRAVERSAL_VAULT: return FLAG_VAULT
		TRAVERSAL_CLIMB_UP: return FLAG_CLIMB
		TRAVERSAL_LEAP: return FLAG_LEAP
		TRAVERSAL_DROP_DOWN: return FLAG_DROP
		TRAVERSAL_COVER_WALK, TRAVERSAL_COVER_ROLL: return FLAG_COVER
		_: return 0


static func traversal_color(t: int) -> Color:
	match t:
		TRAVERSAL_VAULT: return Color("#f59e0b")
		TRAVERSAL_CLIMB_UP: return Color("#38bdf8")
		TRAVERSAL_LEAP: return Color("#e879f9")
		TRAVERSAL_DROP_DOWN: return Color("#4ade80")
		TRAVERSAL_COVER_WALK: return Color("#ef4444")
		TRAVERSAL_COVER_ROLL: return Color("#22c55e")
		_: return Color("#22d3ee")


func analyze(lines_arr: Array[Dictionary]) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	_lines = lines_arr
	nav_nodes.clear()
	adjacency.clear()
	user_edges.clear()
	cover_points.clear()
	walkable_tris.clear()
	_tri_grid.clear()
	_cell_nodes.clear()

	_extract_environment_triangles()
	_build_multilayer_navgraph()
	_analyze_vault_traversals()
	_analyze_climb_traversals()
	_analyze_leap_traversals()
	_analyze_dropdown_traversals()
	_analyze_cover_tactical()

	var counts := {
		"vault": 0, "climb": 0, "leap": 0, "drop": 0, "cover_walk": 0, "cover_roll": 0,
	}
	for ue in user_edges:
		match int(ue["type"]):
			TRAVERSAL_VAULT: counts["vault"] = int(counts["vault"]) + 1
			TRAVERSAL_CLIMB_UP: counts["climb"] = int(counts["climb"]) + 1
			TRAVERSAL_LEAP: counts["leap"] = int(counts["leap"]) + 1
			TRAVERSAL_DROP_DOWN: counts["drop"] = int(counts["drop"]) + 1
			TRAVERSAL_COVER_WALK: counts["cover_walk"] = int(counts["cover_walk"]) + 1
			TRAVERSAL_COVER_ROLL: counts["cover_roll"] = int(counts["cover_roll"]) + 1

	var walk_edge_cnt := 0
	for adj in adjacency:
		for e in adj:
			if int(e["type"]) == TRAVERSAL_WALK:
				walk_edge_cnt += 1

	stats = {
		"nav_nodes": nav_nodes.size(),
		"walk_edges": walk_edge_cnt,
		"user_edges": user_edges.size(),
		"cover_points": cover_points.size(),
		"vault_edges": counts["vault"],
		"climb_edges": counts["climb"],
		"leap_edges": counts["leap"],
		"drop_edges": counts["drop"],
		"cover_walk_edges": counts["cover_walk"],
		"cover_roll_edges": counts["cover_roll"],
		"walkable_tris": walkable_tris.size(),
		"bake_ms": float(Time.get_ticks_usec() - t0) / 1000.0,
	}
	return stats


func _extract_environment_triangles() -> void:
	if not FileAccess.file_exists(ENV_GLB_PATH):
		return
	var bytes := FileAccess.get_file_as_bytes(ENV_GLB_PATH)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.handle_binary_image = GLTFState.HANDLE_BINARY_DISCARD_TEXTURES
	if doc.append_from_buffer(bytes, "", st) != OK:
		return
	var scene := doc.generate_scene(st)
	if scene == null:
		return

	var mesh_nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	mesh_nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))

	for src in mesh_nodes:
		var src_mesh: Mesh = null
		if src is MeshInstance3D:
			src_mesh = src.mesh
		elif src.is_class("ImporterMeshInstance3D"):
			var imp = src.get("mesh")
			if imp != null and imp.has_method("get_mesh"):
				src_mesh = imp.call("get_mesh")
		if src_mesh == null:
			continue
		var xform: Transform3D = (src as Node3D).transform if src is Node3D else Transform3D.IDENTITY
		var p: Node = src.get_parent()
		while p != null and p != scene:
			if p is Node3D:
				xform = (p as Node3D).transform * xform
			p = p.get_parent()

		var faces := src_mesh.get_faces()
		for i in range(0, faces.size(), 3):
			var v0 := xform * faces[i]
			var v1 := xform * faces[i + 1]
			var v2 := xform * faces[i + 2]
			var n := (v1 - v0).cross(v2 - v0)
			var nl := n.length()
			if nl < 1e-5:
				continue
			n /= nl
			# Keep both upward walkable surfaces and vertical blockers via full triangle grid
			if n.y < 0.0:
				n = -n
			var t_idx := walkable_tris.size()
			walkable_tris.append({
				"v0": v0, "v1": v1, "v2": v2, "normal": n,
				"walkable": n.y > 0.70,
				"min_x": minf(v0.x, minf(v1.x, v2.x)),
				"max_x": maxf(v0.x, maxf(v1.x, v2.x)),
				"min_y": minf(v0.y, minf(v1.y, v2.y)),
				"max_y": maxf(v0.y, maxf(v1.y, v2.y)),
				"min_z": minf(v0.z, minf(v1.z, v2.z)),
				"max_z": maxf(v0.z, maxf(v1.z, v2.z)),
			})
			var gx0 := int(floor(minf(v0.x, minf(v1.x, v2.x)) / TRI_BUCKET))
			var gx1 := int(floor(maxf(v0.x, maxf(v1.x, v2.x)) / TRI_BUCKET))
			var gz0 := int(floor(minf(v0.z, minf(v1.z, v2.z)) / TRI_BUCKET))
			var gz1 := int(floor(maxf(v0.z, maxf(v1.z, v2.z)) / TRI_BUCKET))
			for gx in range(gx0, gx1 + 1):
				for gz in range(gz0, gz1 + 1):
					var key := Vector2i(gx, gz)
					if not _tri_grid.has(key):
						_tri_grid[key] = []
					(_tri_grid[key] as Array).append(t_idx)
	scene.free()


func sample_walkable_heights(x: float, z: float) -> Array[float]:
	var key := Vector2i(int(floor(x / TRI_BUCKET)), int(floor(z / TRI_BUCKET)))
	var list: Array = _tri_grid.get(key, [])
	var heights: Array[float] = []
	for ti in list:
		var t: Dictionary = walkable_tris[int(ti)]
		if not bool(t["walkable"]):
			continue
		if x < float(t["min_x"]) - 0.02 or x > float(t["max_x"]) + 0.02:
			continue
		if z < float(t["min_z"]) - 0.02 or z > float(t["max_z"]) + 0.02:
			continue
		var v0: Vector3 = t["v0"]
		var v1: Vector3 = t["v1"]
		var v2: Vector3 = t["v2"]
		var dx0 := v1.x - v0.x
		var dz0 := v1.z - v0.z
		var dx1 := v2.x - v0.x
		var dz1 := v2.z - v0.z
		var dx2 := x - v0.x
		var dz2 := z - v0.z
		var denom := dx0 * dz1 - dx1 * dz0
		if absf(denom) < 1e-7:
			continue
		var u := (dx2 * dz1 - dx1 * dz2) / denom
		var v := (dx0 * dz2 - dx2 * dz0) / denom
		if u >= -0.002 and v >= -0.002 and u + v <= 1.002:
			var y := v0.y + u * (v1.y - v0.y) + v * (v2.y - v0.y)
			if y < -3.6: # Below playable sunken pit (-5m outer skirt)
				continue
			var merged := false
			for j in heights.size():
				if absf(heights[j] - y) < 0.35:
					heights[j] = maxf(heights[j], y)
					merged = true
					break
			if not merged:
				heights.append(y)
	heights.sort()
	# Filter out surfaces with low headroom (< 1.5m solid ceiling right above, e.g. ground directly inside solid boxes)
	var valid: Array[float] = []
	for h in heights:
		if not _is_blocked_inside_solid(x, h, z):
			valid.append(h)
	return valid


func _is_blocked_inside_solid(x: float, y: float, z: float) -> bool:
	# Reject ground samples that sit directly inside a thin cover wall or solid box core
	for l in _lines:
		var lt := int(l["line_type"])
		if lt == LinesScript.LINE_TYPE_LOW_WALL or lt == LinesScript.LINE_TYPE_HIGH_WALL:
			var a: Vector3 = l["a"]
			if absf(y - a.y) > 0.5:
				continue
			var cp := LinesScript.closest_point_on_line(l, Vector3(x, y, z))
			var delta := Vector3(x - cp.x, 0.0, z - cp.z)
			var n: Vector3 = l["edge_normal"]
			var along_n := delta.dot(n)
			var tangent := delta - n * along_n
			if tangent.length() < 0.35 and along_n > 0.02 and along_n < 0.65:
				return true
	return false


func sample_highest_below(x: float, y_top: float, z: float) -> Dictionary:
	var hs := sample_walkable_heights(x, z)
	var best_y := -999.0
	for h in hs:
		if h <= y_top + 0.15 and h > best_y:
			best_y = h
	if best_y < -500.0:
		return {"hit": false, "y": 0.0}
	return {"hit": true, "y": best_y}


func _add_node(pos: Vector3, tag: String = "grid") -> int:
	# Reuse existing node if within 0.45m horizontally and 0.40m vertically
	var c := Vector2i(int(round(pos.x / GRID_STEP)), int(round(pos.z / GRID_STEP)))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var bucket: Array = _cell_nodes.get(Vector2i(c.x + dx, c.y + dz), [])
			for nid in bucket:
				var p: Vector3 = nav_nodes[int(nid)]["pos"]
				if absf(p.y - pos.y) < 0.40 and Vector2(p.x - pos.x, p.z - pos.z).length() < 0.45:
					return int(nid)
	var id := nav_nodes.size()
	nav_nodes.append({
		"id": id,
		"pos": pos,
		"tier_y": snappedf(pos.y, 0.5),
		"tag": tag,
	})
	adjacency.append([])
	if not _cell_nodes.has(c):
		_cell_nodes[c] = []
	(_cell_nodes[c] as Array).append(id)
	return id


func _add_walk_edge(a: int, b: int) -> void:
	if a == b or a < 0 or b < 0:
		return
	var pa: Vector3 = nav_nodes[a]["pos"]
	var pb: Vector3 = nav_nodes[b]["pos"]
	if _segment_crosses_barrier(pa, pb):
		return
	var dist := pa.distance_to(pb)
	(adjacency[a] as Array).append({"to": b, "cost": dist, "type": TRAVERSAL_WALK, "user_edge_idx": -1})
	(adjacency[b] as Array).append({"to": a, "cost": dist, "type": TRAVERSAL_WALK, "user_edge_idx": -1})


func _segment_crosses_barrier(pa: Vector3, pb: Vector3) -> bool:
	var mid_y := (pa.y + pb.y) * 0.5
	var p0 := Vector2(pa.x, pa.z)
	var p1 := Vector2(pb.x, pb.z)
	for l in _lines:
		var lt := int(l["line_type"])
		if lt == LinesScript.LINE_TYPE_LOW_WALL or lt == LinesScript.LINE_TYPE_HIGH_WALL:
			var la: Vector3 = l["a"]
			if absf(mid_y - la.y) > 0.7:
				continue
			var n: Vector3 = l["edge_normal"]
			# Wall core sits at +n * 0.25
			var wa := Vector2(la.x + n.x * 0.25, la.z + n.z * 0.25)
			var wb := Vector2((l["b"] as Vector3).x + n.x * 0.25, (l["b"] as Vector3).z + n.z * 0.25)
			if _segs_intersect_2d(p0, p1, wa, wb):
				return true
		elif lt == LinesScript.LINE_TYPE_RAILING:
			var la: Vector3 = l["a"]
			var lb: Vector3 = l["b"]
			var rail_y := (la.y + lb.y) * 0.5
			if rail_y - mid_y > 0.55 and rail_y - mid_y < 1.85:
				if _segs_intersect_2d(p0, p1, Vector2(la.x, la.z), Vector2(lb.x, lb.z)):
					return true
	return false


static func _segs_intersect_2d(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var r := b - a
	var s := d - c
	var denom := r.x * s.y - r.y * s.x
	if absf(denom) < 1e-6:
		return false
	var qp := c - a
	var t := (qp.x * s.y - qp.y * s.x) / denom
	var u := (qp.x * r.y - qp.y * r.x) / denom
	return t >= 0.02 and t <= 0.98 and u >= -0.05 and u <= 1.05


func _build_multilayer_navgraph() -> void:
	# Sample active playable arena bounds: X in [-60..14], Z in [-32..56]
	for gx in range(-30, 8):
		var x := float(gx) * GRID_STEP
		for gz in range(-16, 29):
			var z := float(gz) * GRID_STEP
			var hs := sample_walkable_heights(x, z)
			for y in hs:
				_add_node(Vector3(x, y, z), "grid")

	# Connect 8-neighbor walkable cells whose height diff fits max step/ramp slope
	var offsets: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1),
	]
	for key in _cell_nodes.keys():
		var c: Vector2i = key
		var list_a: Array = _cell_nodes[c]
		for off: Vector2i in offsets:
			var nb: Vector2i = c + off
			if not _cell_nodes.has(nb):
				continue
			var list_b: Array = _cell_nodes[nb]
			var is_diag: bool = (off.x != 0 and off.y != 0)
			var max_dy := 0.85 if not is_diag else 0.72
			for na in list_a:
				var pa: Vector3 = nav_nodes[int(na)]["pos"]
				for nb_id in list_b:
					var pb: Vector3 = nav_nodes[int(nb_id)]["pos"]
					if absf(pa.y - pb.y) <= max_dy:
						# Verify midpoint has floor support so we never walk across empty air pits!
						var mid := (pa + pb) * 0.5
						var mid_h := sample_highest_below(mid.x, maxf(pa.y, pb.y) + 0.35, mid.z)
						if bool(mid_h["hit"]) and absf(float(mid_h["y"]) - mid.y) <= 0.65:
							_add_walk_edge(int(na), int(nb_id))


func _connect_portal_node(pos: Vector3, tag: String) -> int:
	var id := _add_node(pos, tag)
	var p: Vector3 = nav_nodes[id]["pos"]
	var c := Vector2i(int(round(p.x / GRID_STEP)), int(round(p.z / GRID_STEP)))
	var connected := 0
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var bucket: Array = _cell_nodes.get(Vector2i(c.x + dx, c.y + dz), [])
			for nid in bucket:
				var other := int(nid)
				if other == id:
					continue
				var q: Vector3 = nav_nodes[other]["pos"]
				var hd := Vector2(p.x - q.x, p.z - q.z).length()
				if hd <= 3.1 and absf(p.y - q.y) <= 0.65:
					if not _segment_crosses_barrier(p, q):
						var dist := p.distance_to(q)
						(adjacency[id] as Array).append({"to": other, "cost": dist, "type": TRAVERSAL_WALK, "user_edge_idx": -1})
						(adjacency[other] as Array).append({"to": id, "cost": dist, "type": TRAVERSAL_WALK, "user_edge_idx": -1})
						connected += 1
	return id


func _register_user_edge(
	from_node: int,
	to_node: int,
	trav_type: int,
	base_cost: float,
	line: Dictionary,
	meta: Dictionary = {}
) -> int:
	if from_node < 0 or to_node < 0 or from_node == to_node:
		return -1
	var ue_idx := user_edges.size()
	var entry := {
		"index": ue_idx,
		"from_node": from_node,
		"to_node": to_node,
		"from_pos": nav_nodes[from_node]["pos"],
		"to_pos": nav_nodes[to_node]["pos"],
		"type": trav_type,
		"base_cost": base_cost,
		"line_index": int(line.get("index", -1)),
		"line": line,
		"meta": meta,
	}
	user_edges.append(entry)
	(adjacency[from_node] as Array).append({
		"to": to_node,
		"cost": base_cost,
		"type": trav_type,
		"user_edge_idx": ue_idx,
	})
	return ue_idx


# --- Analyzer 1: hkaiVaultAnalyzer (Orange Railings TYPE 4) ---
func _analyze_vault_traversals() -> void:
	for line in _lines:
		if int(line["line_type"]) != LinesScript.LINE_TYPE_RAILING:
			continue
		var a: Vector3 = line["a"]
		var b: Vector3 = line["b"]
		if absf(a.y - b.y) > 0.25:
			continue # Skip steeply sloped stair banisters
		var mid := (a + b) * 0.5
		var n: Vector3 = line["edge_normal"]
		var p_pos := mid + n * 1.45
		var p_neg := mid - n * 1.45
		var h_pos := sample_highest_below(p_pos.x, mid.y - 0.35, p_pos.z)
		var h_neg := sample_highest_below(p_neg.x, mid.y - 0.35, p_neg.z)
		if not bool(h_pos["hit"]) or not bool(h_neg["hit"]):
			continue
		var y_pos := float(h_pos["y"])
		var y_neg := float(h_neg["y"])
		var wall_h_pos := mid.y - y_pos
		var wall_h_neg := mid.y - y_neg
		if wall_h_pos >= 0.70 and wall_h_pos <= 1.55 and wall_h_neg >= 0.70 and wall_h_neg <= 1.55:
			var n_pos := _connect_portal_node(Vector3(p_pos.x, y_pos, p_pos.z), "vault_portal")
			var n_neg := _connect_portal_node(Vector3(p_neg.x, y_neg, p_neg.z), "vault_portal")
			var meta := {"hand_plant": mid, "barrier_h": maxf(wall_h_pos, wall_h_neg)}
			_register_user_edge(n_pos, n_neg, TRAVERSAL_VAULT, 2.2, line, meta)
			_register_user_edge(n_neg, n_pos, TRAVERSAL_VAULT, 2.2, line, meta)


# --- Analyzer 2: hkaiClimbUpAnalyzer (Blue Ledges & Yellow Platforms TYPE 2/3) ---
func _analyze_climb_traversals() -> void:
	for line in _lines:
		var lt := int(line["line_type"])
		if lt != LinesScript.LINE_TYPE_LEDGE and lt != LinesScript.LINE_TYPE_PLATFORM:
			continue
		var a: Vector3 = line["a"]
		var b: Vector3 = line["b"]
		var mid := (a + b) * 0.5
		var n: Vector3 = line["edge_normal"]
		var front_probe := mid + n * 1.35
		var top_probe := mid - n * 0.85
		var h_front := sample_highest_below(front_probe.x, mid.y - 0.35, front_probe.z)
		var h_top := sample_highest_below(top_probe.x, mid.y + 0.50, top_probe.z)
		if not bool(h_front["hit"]) or not bool(h_top["hit"]):
			continue
		var fy := float(h_front["y"])
		var ty := float(h_top["y"])
		var dy := ty - fy
		if dy >= 1.0 and dy <= 3.95 and absf(ty - mid.y) <= 0.45:
			var n_bot := _connect_portal_node(Vector3(front_probe.x, fy, front_probe.z), "climb_bot")
			var n_top := _connect_portal_node(Vector3(top_probe.x, ty, top_probe.z), "climb_top")
			_register_user_edge(n_bot, n_top, TRAVERSAL_CLIMB_UP, 2.8 + dy * 0.4, line, {
				"lip": mid, "climb_height": dy, "edge_normal": n,
			})


# --- Analyzer 3: hkaiJumpAnalyzer (Platform-to-Platform Skybridge Leaps) ---
func _analyze_leap_traversals() -> void:
	var ledges: Array[Dictionary] = []
	for line in _lines:
		var lt := int(line["line_type"])
		if lt == LinesScript.LINE_TYPE_LEDGE or lt == LinesScript.LINE_TYPE_PLATFORM:
			if ((line["a"] as Vector3).y + (line["b"] as Vector3).y) * 0.5 >= 1.8:
				ledges.append(line)

	for i in ledges.size():
		var la: Dictionary = ledges[i]
		var ma: Vector3 = ((la["a"] as Vector3) + (la["b"] as Vector3)) * 0.5
		var na: Vector3 = la["edge_normal"]
		for j in ledges.size():
			if i == j:
				continue
			var lb: Dictionary = ledges[j]
			var mb: Vector3 = ((lb["a"] as Vector3) + (lb["b"] as Vector3)) * 0.5
			var nb: Vector3 = lb["edge_normal"]
			# Facing opposite edges across an air gap
			if na.dot(nb) > -0.55:
				continue
			var diff := mb - ma
			var horiz := Vector2(diff.x, diff.z).length()
			if horiz < 1.6 or horiz > 6.2:
				continue
			var dir_xz := Vector3(diff.x, 0.0, diff.z).normalized()
			if dir_xz.dot(na) < 0.72 or dir_xz.dot(nb) > -0.72:
				continue
			var dy := mb.y - ma.y
			if dy < -3.5 or dy > 1.85:
				continue
			# Verify genuine air gap at midpoint
			var mid_air := (ma + mb) * 0.5
			var h_mid := sample_highest_below(mid_air.x, minf(ma.y, mb.y) - 0.25, mid_air.z)
			if bool(h_mid["hit"]) and minf(ma.y, mb.y) - float(h_mid["y"]) < 1.2:
				continue
			var takeoff := ma - na * 0.85
			var land := mb - nb * 0.85
			var h_from := sample_highest_below(takeoff.x, ma.y + 0.45, takeoff.z)
			var h_to := sample_highest_below(land.x, mb.y + 0.45, land.z)
			if not bool(h_from["hit"]) or not bool(h_to["hit"]):
				continue
			var nf := _connect_portal_node(Vector3(takeoff.x, float(h_from["y"]), takeoff.z), "leap_from")
			var nt := _connect_portal_node(Vector3(land.x, float(h_to["y"]), land.z), "leap_to")
			_register_user_edge(nf, nt, TRAVERSAL_LEAP, 2.5 + horiz * 0.55, lb, {
				"takeoff_line": la,
				"target_line": lb,
				"gap_dist": horiz,
				"delta_y": dy,
				"lip": mb,
			})


# --- Analyzer 4: hkaiDropDownAnalyzer (Ledges -> Lower Platforms & Sunken Trench) ---
func _analyze_dropdown_traversals() -> void:
	for line in _lines:
		var lt := int(line["line_type"])
		if lt != LinesScript.LINE_TYPE_LEDGE and lt != LinesScript.LINE_TYPE_PLATFORM:
			continue
		var mid := ((line["a"] as Vector3) + (line["b"] as Vector3)) * 0.5
		var n: Vector3 = line["edge_normal"]
		var top_probe := mid - n * 0.85
		var h_top := sample_highest_below(top_probe.x, mid.y + 0.50, top_probe.z)
		if not bool(h_top["hit"]) or absf(float(h_top["y"]) - mid.y) > 0.45:
			continue
		# Probe 1.5m and 3.4m ahead for direct drop or stepping down to adjacent platform (e.g., 10.25m -> 5.0m)
		var dist_probes: Array[float] = [1.45, 3.45]
		for dist_ahead: float in dist_probes:
			var drop_probe: Vector3 = mid + n * dist_ahead
			var h_bot := sample_highest_below(drop_probe.x, mid.y - 0.50, drop_probe.z)
			if not bool(h_bot["hit"]):
				continue
			var drop_h := float(h_top["y"]) - float(h_bot["y"])
			if drop_h >= 1.2 and drop_h <= 6.2:
				var n_top := _connect_portal_node(Vector3(top_probe.x, float(h_top["y"]), top_probe.z), "drop_top")
				var n_bot := _connect_portal_node(Vector3(drop_probe.x, float(h_bot["y"]), drop_probe.z), "drop_bot")
				_register_user_edge(n_top, n_bot, TRAVERSAL_DROP_DOWN, 2.0 + drop_h * 0.35, line, {
					"lip": mid, "drop_height": drop_h, "edge_normal": n,
				})
				break


# --- Analyzer 5: Tactical Cover Points, Cover Walk & Cover-to-Cover Roll ---
func _analyze_cover_tactical() -> void:
	var cover_lines: Array[Dictionary] = []
	for line in _lines:
		var lt := int(line["line_type"])
		if lt == LinesScript.LINE_TYPE_LOW_WALL or lt == LinesScript.LINE_TYPE_HIGH_WALL:
			cover_lines.append(line)

	var line_endpoints: Dictionary = {} # line_index -> {a_node, b_node, line}
	for line in cover_lines:
		var a: Vector3 = line["a"]
		var b: Vector3 = line["b"]
		var n: Vector3 = line["edge_normal"]
		var length := a.distance_to(b)
		var p_a := Vector3(a.x - n.x * 0.55, a.y, a.z - n.z * 0.55)
		var p_b := Vector3(b.x - n.x * 0.55, b.y, b.z - n.z * 0.55)
		var na := _connect_portal_node(p_a, "cover_pt")
		var nb := _connect_portal_node(p_b, "cover_pt")
		line_endpoints[int(line["index"])] = {"a_node": na, "b_node": nb, "a_pos": p_a, "b_pos": p_b, "line": line}
		cover_points.append({
			"line_index": int(line["index"]),
			"high": int(line["line_type"]) == LinesScript.LINE_TYPE_HIGH_WALL,
			"mid": ((p_a + p_b) * 0.5),
			"normal": n,
			"node_a": na,
			"node_b": nb,
		})
		if length >= 1.2 and na != nb:
			var meta := {"high": int(line["line_type"]) == LinesScript.LINE_TYPE_HIGH_WALL}
			_register_user_edge(na, nb, TRAVERSAL_COVER_WALK, length * 0.85, line, meta)
			_register_user_edge(nb, na, TRAVERSAL_COVER_WALK, length * 0.85, line, meta)

	# Connect collinear cover-to-cover roll gaps (same facing normal, gap 1.2..5.8m)
	var keys := line_endpoints.keys()
	for i in keys.size():
		var ea: Dictionary = line_endpoints[keys[i]]
		var la: Dictionary = ea["line"]
		var na_vec: Vector3 = la["edge_normal"]
		for j in range(i + 1, keys.size()):
			var eb: Dictionary = line_endpoints[keys[j]]
			var lb: Dictionary = eb["line"]
			if int(la["line_type"]) != int(lb["line_type"]):
				continue
			if na_vec.dot(lb["edge_normal"] as Vector3) < 0.85:
				continue
			# Find closest pair of endpoints across the gap
			var best_d := 999.0
			var best_pair := [-1, -1]
			var pts_a := [[int(ea["a_node"]), ea["a_pos"]], [int(ea["b_node"]), ea["b_pos"]]]
			var pts_b := [[int(eb["a_node"]), eb["a_pos"]], [int(eb["b_node"]), eb["b_pos"]]]
			for pa in pts_a:
				for pb in pts_b:
					var d: float = (pa[1] as Vector3).distance_to(pb[1] as Vector3)
					if d < best_d:
						best_d = d
						best_pair = [int(pa[0]), int(pb[0])]
			if best_d >= 1.0 and best_d <= 5.8:
				# Confirm collinear (small normal offset between walls)
				var dvec: Vector3 = (nav_nodes[best_pair[1]]["pos"] as Vector3) - (nav_nodes[best_pair[0]]["pos"] as Vector3)
				if absf(dvec.dot(na_vec)) < 0.65:
					_register_user_edge(best_pair[0], best_pair[1], TRAVERSAL_COVER_ROLL, best_d * 0.9, lb, {"from_line": la, "to_line": lb})
					_register_user_edge(best_pair[1], best_pair[0], TRAVERSAL_COVER_ROLL, best_d * 0.9, la, {"from_line": lb, "to_line": la})


func find_closest_node(pos: Vector3, max_y_diff: float = 2.0) -> int:
	var best_id := -1
	var best_score := 1e18
	for n in nav_nodes:
		var p: Vector3 = n["pos"]
		var dy := absf(p.y - pos.y)
		if dy > max_y_diff:
			continue
		var sc := p.distance_squared_to(pos) + dy * dy * 4.0
		if sc < best_score:
			best_score = sc
			best_id = int(n["id"])
	if best_id < 0:
		for n in nav_nodes:
			var sc := (n["pos"] as Vector3).distance_squared_to(pos)
			if sc < best_score:
				best_score = sc
				best_id = int(n["id"])
	return best_id


# --- Havok-style hkaiNavMeshViewer + hkaiTraversalAnnotationViewer Meshes ---
func build_navmesh_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lift := Vector3(0.0, 0.06, 0.0)
	for t in walkable_tris:
		if not bool(t["walkable"]):
			continue
		var v0: Vector3 = t["v0"]
		var v1: Vector3 = t["v1"]
		var v2: Vector3 = t["v2"]
		var avg_y := (v0.y + v1.y + v2.y) / 3.0
		if avg_y < -3.6:
			continue
		# Color elevation tiers subtly (cyan ground, blue mid, violet summit, teal sunken pit)
		var col := Color(0.10, 0.72, 0.85, 0.22)
		if avg_y < -0.5:
			col = Color(0.12, 0.82, 0.58, 0.30)
		elif avg_y >= 8.5:
			col = Color(0.96, 0.76, 0.18, 0.34)
		elif avg_y >= 4.5:
			col = Color(0.56, 0.44, 0.96, 0.28)
		elif avg_y >= 1.5:
			col = Color(0.22, 0.56, 0.96, 0.26)
		st.set_color(col)
		st.add_vertex(v0 + lift)
		st.set_color(col)
		st.add_vertex(v1 + lift)
		st.set_color(col)
		st.add_vertex(v2 + lift)
	return st.commit()


func build_annotations_mesh(filter_flags: int = FLAG_ALL) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for ue in user_edges:
		var t := int(ue["type"])
		var fl := traversal_flag(t)
		if fl != 0 and (filter_flags & fl) == 0:
			continue
		var p0: Vector3 = (ue["from_pos"] as Vector3) + Vector3(0.0, 0.14, 0.0)
		var p1: Vector3 = (ue["to_pos"] as Vector3) + Vector3(0.0, 0.14, 0.0)
		var col := traversal_color(t)
		var arc_h := 0.35
		match t:
			TRAVERSAL_VAULT: arc_h = 1.25
			TRAVERSAL_CLIMB_UP: arc_h = 0.65
			TRAVERSAL_LEAP: arc_h = 1.35
			TRAVERSAL_DROP_DOWN: arc_h = 0.45
			TRAVERSAL_COVER_WALK: arc_h = 0.12
			TRAVERSAL_COVER_ROLL: arc_h = 0.45
		var segs := 8
		var prev := p0
		for s in range(1, segs + 1):
			var u := float(s) / float(segs)
			var cur := p0.lerp(p1, u)
			cur.y += sin(u * PI) * arc_h
			im.surface_set_color(col)
			im.surface_add_vertex(prev)
			im.surface_set_color(col)
			im.surface_add_vertex(cur)
			prev = cur
	im.surface_end()
	return im
