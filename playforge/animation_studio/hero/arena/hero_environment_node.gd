@tool
class_name HeroEnvironmentNode
extends Node3D
## Reusable @tool Node3D that loads the extracted Havok Hero test background map
## (`res://hero/assets/hero_environment.glb`), builds exact ConcavePolygonShape3D
## trimesh collision, applies a calibrated anti-blowout CompleteMap + 1m grid shader,
## and renders all 90 restored `hero_lines.lua` color-coded docking lines.

const ENV_GLB_PATH := "res://hero/assets/hero_environment.glb"
const LinesScript := preload("res://hero/arena/hero_lua_lines.gd")

const ENV_SHADER_CODE := """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 tint_color : source_color = vec3(0.64, 0.69, 0.75);
uniform float grid_strength : hint_range(0.0, 0.4) = 0.22;
uniform float roughness_val : hint_range(0.0, 1.0) = 0.92;

varying vec3 v_world_pos;
varying vec3 v_world_nrm;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 tex = texture(albedo_tex, UV).rgb;
	// Preserve vivid parkour color stripes (red/green/blue/yellow/orange) while toning down bright white floor
	float sat = max(tex.r, max(tex.g, tex.b)) - min(tex.r, min(tex.g, tex.b));
	vec3 col = mix(tex * tint_color, tex * vec3(0.95, 0.95, 0.95), smoothstep(0.12, 0.35, sat));

	// Subtle 1m architectural floor grid on horizontal surfaces for clear ground-contact depth cues
	float is_floor = smoothstep(0.7, 0.95, abs(v_world_nrm.y));
	vec2 g1 = abs(fract(v_world_pos.xz - 0.5) - 0.5) / max(fwidth(v_world_pos.xz), vec2(0.002));
	float line1 = 1.0 - clamp(min(g1.x, g1.y), 0.0, 1.0);
	vec2 g5 = abs(fract(v_world_pos.xz * 0.2 - 0.5) - 0.5) / max(fwidth(v_world_pos.xz * 0.2), vec2(0.002));
	float line5 = 1.0 - clamp(min(g5.x, g5.y), 0.0, 1.0);
	float grid = max(line1 * 0.55, line5 * 0.95) * is_floor * grid_strength;
	col = mix(col, col * 0.62, grid);

	ALBEDO = col;
	ROUGHNESS = roughness_val;
	METALLIC = 0.0;
}
"""

@export var show_docking_lines: bool = true:
	set(value):
		show_docking_lines = value
		if is_instance_valid(_debug_lines_mesh):
			_debug_lines_mesh.visible = value

var env_stats: Dictionary = {"meshes": 0, "verts": 0, "tris": 0}
var line_world: LinesScript = LinesScript.new()

var _geometry_root: Node3D = null
var _debug_lines_mesh: MeshInstance3D = null
var _last_hl_index: int = -2


func _ready() -> void:
	line_world.load_lines()
	_rebuild_environment()
	refresh_docking_lines(-1)


func _rebuild_environment() -> void:
	if is_instance_valid(_geometry_root):
		_geometry_root.queue_free()
	_geometry_root = Node3D.new()
	_geometry_root.name = "HeroEnvRuntime"
	add_child(_geometry_root)

	env_stats = {"meshes": 0, "verts": 0, "tris": 0}
	if not FileAccess.file_exists(ENV_GLB_PATH):
		return
	var bytes := FileAccess.get_file_as_bytes(ENV_GLB_PATH)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if doc.append_from_buffer(bytes, "", st) != OK:
		return
	var scene := doc.generate_scene(st)
	if scene == null:
		return

	var mesh_nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	mesh_nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))

	var body := StaticBody3D.new()
	body.name = "EnvironmentCollision"
	_geometry_root.add_child(body)

	var shader := Shader.new()
	shader.code = ENV_SHADER_CODE

	var all_faces := PackedVector3Array()
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

		var vis := MeshInstance3D.new()
		vis.name = src.name
		vis.mesh = src_mesh
		vis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for si in src_mesh.get_surface_count():
			var mat := src_mesh.surface_get_material(si)
			if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
				var smat := ShaderMaterial.new()
				smat.shader = shader
				smat.set_shader_parameter("albedo_tex", (mat as BaseMaterial3D).albedo_texture)
				vis.set_surface_override_material(si, smat)
		_geometry_root.add_child(vis)

		var faces := src_mesh.get_faces()
		all_faces.append_array(faces)
		env_stats["meshes"] = int(env_stats["meshes"]) + 1
		for s in src_mesh.get_surface_count():
			env_stats["verts"] = int(env_stats["verts"]) + src_mesh.surface_get_array_len(s)
		env_stats["tris"] = int(env_stats["tris"]) + faces.size() / 3

	if not all_faces.is_empty():
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(all_faces)
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
	scene.free()

	_debug_lines_mesh = MeshInstance3D.new()
	_debug_lines_mesh.name = "DockingLines3D"
	var lmat := StandardMaterial3D.new()
	lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lmat.vertex_color_use_as_albedo = true
	_debug_lines_mesh.material_override = lmat
	_debug_lines_mesh.visible = show_docking_lines
	_geometry_root.add_child(_debug_lines_mesh)


func refresh_docking_lines(highlight_index: int = -1) -> void:
	if not is_instance_valid(_debug_lines_mesh):
		return
	if highlight_index != _last_hl_index:
		_last_hl_index = highlight_index
		_debug_lines_mesh.mesh = line_world.build_debug_lines_mesh(highlight_index)
	_debug_lines_mesh.visible = show_docking_lines
