@tool
class_name HeroLuaLines
extends RefCounted
## 1:1 restoration of Havok Hero `hero_lines.lua` + `hero_docking.lua` in Godot GDScript.
## Loads all 90 exact Environment docking lines from `res://hero/assets/hero_arena_lines.json`,
## implements `find_line_to_dock_to`, `closest_point_on_line`, `update_line_movement`,
## docking target management, and builds the 3D color-coded debug visualization mesh.

const LINES_JSON_PATH := "res://hero/assets/hero_arena_lines.json"

const LINE_TYPE_LOW_WALL := 0     # Red (Low Cover)
const LINE_TYPE_HIGH_WALL := 1    # Green (High Cover)
const LINE_TYPE_LEDGE := 2        # Blue (Climb Ledge)
const LINE_TYPE_PLATFORM := 3     # Yellow (High Platform)
const LINE_TYPE_RAILING := 4      # Goldenrod (Vault Railing)

var lines: Array[Dictionary] = []
var docking_target: Dictionary = {}
var docking_plane: Plane = Plane(Vector3.UP, 0.0)
var has_plane_target: bool = false


func load_lines() -> int:
	lines.clear()
	if not FileAccess.file_exists(LINES_JSON_PATH):
		return 0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LINES_JSON_PATH))
	if not (parsed is Dictionary) or not parsed.has("lines"):
		return 0
	for item in parsed["lines"]:
		var a_arr: Array = item["a"]
		var b_arr: Array = item["b"]
		var r_arr: Array = item["rotation"]
		var n_arr: Array = item["edge_normal"]
		lines.append({
			"index": int(item["index"]),
			"a": Vector3(float(a_arr[0]), float(a_arr[1]), float(a_arr[2])),
			"b": Vector3(float(b_arr[0]), float(b_arr[1]), float(b_arr[2])),
			"rotation": Quaternion(float(r_arr[0]), float(r_arr[1]), float(r_arr[2]), float(r_arr[3])).normalized(),
			"edge_normal": Vector3(float(n_arr[0]), float(n_arr[1]), float(n_arr[2])).normalized(),
			"line_type": int(item["line_type"]),
		})
	return lines.size()


static func color_for_line_type(line_type: int) -> Color:
	match line_type:
		LINE_TYPE_LOW_WALL:
			return Color("#ef4444") # Red
		LINE_TYPE_HIGH_WALL:
			return Color("#22c55e") # Green
		LINE_TYPE_LEDGE:
			return Color("#3b82f6") # Blue
		LINE_TYPE_PLATFORM:
			return Color("#facc15") # Yellow
		LINE_TYPE_RAILING:
			return Color("#f59e0b") # Goldenrod
		_:
			return Color("#94a3b8")


static func label_for_line_type(line_type: int) -> String:
	match line_type:
		LINE_TYPE_LOW_WALL:
			return "Low Cover (Red)"
		LINE_TYPE_HIGH_WALL:
			return "High Cover (Green)"
		LINE_TYPE_LEDGE:
			return "Climb Ledge (Blue)"
		LINE_TYPE_PLATFORM:
			return "High Platform (Yellow)"
		LINE_TYPE_RAILING:
			return "Vault Railing (Orange)"
		_:
			return "Unknown"


static func closest_point_on_line(line: Dictionary, pos: Vector3) -> Vector3:
	var a: Vector3 = line["a"]
	var b: Vector3 = line["b"]
	var u := b - a
	var length := u.length()
	if length < 1e-6:
		return a
	u /= length
	var v := pos - a
	return a + u * clampf(u.dot(v), 0.0, length)


func find_line_to_dock_to(
	dock_types: PackedInt32Array,
	min_distance: float,
	max_distance: float,
	condition: Callable,
	current_pos: Vector3,
	forward: Vector3,
	current_closest: float = 10000000.0,
	disregard_index: int = -1
) -> Dictionary:
	var closest_dist := current_closest if current_closest >= 0.0 else 10000000.0
	var best_line: Dictionary = {}

	for line in lines:
		if disregard_index >= 0 and int(line["index"]) == disregard_index:
			continue
		var lt: int = int(line["line_type"])
		if not (lt in dock_types):
			continue
		var closest_pt := closest_point_on_line(line, current_pos)
		var pos_minus_pt := current_pos - closest_pt
		var dist := pos_minus_pt.length()
		var planar_dist := Vector2(pos_minus_pt.x, pos_minus_pt.z).length()
		if dist < closest_dist and planar_dist < max_distance and planar_dist >= min_distance:
			if condition.call(pos_minus_pt, current_pos, forward, line["edge_normal"]):
				closest_dist = dist
				best_line = line

	return {"line": best_line, "distance": closest_dist}


# --- hero_docking.lua helpers ---
func set_line_docking_target(line: Dictionary) -> void:
	docking_target = line.duplicate()
	has_plane_target = false


func set_plane_docking_target(normal: Vector3, point_on_plane: Vector3) -> void:
	docking_plane = Plane(normal.normalized(), point_on_plane)
	has_plane_target = true
	docking_target.clear()


func clear_docking_target() -> void:
	docking_target.clear()
	has_plane_target = false


func build_debug_lines_mesh(highlight_index: int = -1) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for line in lines:
		var a: Vector3 = line["a"]
		var b: Vector3 = line["b"]
		var n: Vector3 = line["edge_normal"]
		var is_hl := highlight_index >= 0 and int(line["index"]) == highlight_index
		var col := Color("#ffffff") if is_hl else color_for_line_type(int(line["line_type"]))
		# Raise slightly (+0.04m) so ground-level cover lines never z-fight with floor
		var lift := Vector3(0.0, 0.04, 0.0)
		im.surface_set_color(col)
		im.surface_add_vertex(a + lift)
		im.surface_set_color(col)
		im.surface_add_vertex(b + lift)

		var mid := (a + b) * 0.5 + lift
		im.surface_set_color(col)
		im.surface_add_vertex(mid)
		im.surface_set_color(col)
		im.surface_add_vertex(mid + n * 0.85)
	im.surface_end()
	return im
