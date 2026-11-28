@tool
class_name HavokDemoEnvironment
extends Node3D
## Official Havok 2015.1.0-r1 Background, Skybox, Level Geometry & Procedural Prop Restorer.
##
## Reproduces the EXACT official Havok SDK DX11 environments across all 47 Hero & Soldier
## Behavior demos with ZERO runtime `.hkt` dependency using offline-extracted native assets:
##   - Official Skybox: `res://compare/assets/havok_default_skybox.png`
##       (stitched from Resources/Common/Graphics/defaultskybox_{UP,DN,LF,RT,FR,BK}.png, 12-edge MSE=0.35)
##   - Level 1 (Hero Parkour Arena): `res://hero/assets/hero_environment.glb`
##       (#29 ShowCase/Hero, #40 BehaviorViewers, #43 OnDemandAssetLoading)
##   - Level 2 (Stone Dungeon / Staircase): `res://compare/assets/env_hk_anim_level.glb`
##       (#04..#07 CharacterControllerDriver, #08..#10 FootIkDriver)
##   - Level 3 (Checker Floor & Dynamic Skulls): `res://compare/assets/env_attachment_scene.glb`
##       (#19 Keyframe Attachments, #20 Ragdoll Attachments, #45/#46 SymbolLinking)
##   - Procedural Docking & MovingPlatform Scenes (#00..#03, #32..#33):
##       Exact SDK .cpp `BehaviorUtils::createDemoBox` / `createDemoCapsule` extents, positions,
##       purple keyframed material, and `DockingMovingTargetDemo::getKeyframeTransform(t)`.
##   - Official Studio Floor (all remaining Soldier & Hero demos):
##       Flat Havok `createDemoBox` floor with real StaticBody3D collision at Y = 0.0.

const Standards := preload("res://catalog/havok_demo_standards.gd")
const HeroEnvNode := preload("res://hero/arena/hero_environment_node.gd")
const HkbMods := preload("res://addons/animation_studio/hkb/hkb_modifiers.gd")

const SKYBOX_PNG := "res://compare/assets/havok_default_skybox.png"
const EXTRA_SKYBOXES := {
	"default": "res://compare/assets/havok_default_skybox.png",
	"boardwalk": "res://compare/assets/skyboxes/sky_boardwalk.png",
	"clouds": "res://compare/assets/skyboxes/sky_clouds.png",
	"dockblur": "res://compare/assets/skyboxes/sky_dockblur.png",
	"duskfair": "res://compare/assets/skyboxes/sky_duskfair.png",
	"duskfair_180": "res://compare/assets/skyboxes/sky_duskfair_180.png",
	"duskfair_270": "res://compare/assets/skyboxes/sky_duskfair_270.png",
	"meadowblur": "res://compare/assets/skyboxes/sky_meadowblur.png",
	"roomblur": "res://compare/assets/skyboxes/sky_roomblur.png",
	"sincity": "res://compare/assets/skyboxes/sky_sincity.png",
	"skyboxemptyspace": "res://compare/assets/skyboxes/sky_skyboxemptyspace.png",
	"skynin": "res://compare/assets/skyboxes/sky_skynin.png",
	"skyrays": "res://compare/assets/skyboxes/sky_skyrays.png",
	"subwayblur": "res://compare/assets/skyboxes/sky_subwayblur.png",
}
const HK_ANIM_LEVEL_GLB := "res://compare/assets/env_hk_anim_level.glb"
const ATTACHMENT_SCENE_GLB := "res://compare/assets/env_attachment_scene.glb"
const ATTACHMENT_PROPS_JSON := "res://compare/assets/env_attachment_props.json"
const DOOR_RIG_SPEC_JSON := "res://compare/assets/prop_door_rig_spec.json"
const EXTRA_ENV_GLBS := {
	"hk_gdc_level": "res://compare/assets/env_hk_gdc_level.glb",
	"ninja_environment": "res://compare/assets/env_ninja_environment.glb",
	"climbing_wall": "res://compare/assets/env_climbing_wall.glb",
	"foot_ik_runway": "res://compare/assets/env_foot_ik_runway.glb",
	"anim_seesaw": "res://compare/assets/env_anim_seesaw.glb",
	"anim_bricks": "res://compare/assets/env_anim_bricks.glb",
	"orcs_grid": "res://compare/assets/env_orcs_grid.glb",
	"penetration_landscape": "res://compare/assets/env_penetration_landscape.glb",
	"boar_rig": "res://compare/assets/prop_boar_rig.glb",
	"penetration_rig": "res://compare/assets/prop_penetration_rig.glb",
	"swordfight_dummy": "res://compare/assets/prop_swordfight_dummy.glb",
	"teapot": "res://compare/assets/prop_teapot.glb",
}

static var _sky_tex_cache: Dictionary = {}
static var _glb_mesh_cache: Dictionary = {}
static var _attachment_props_cache: Dictionary = {}

var env_kind: String = "studio"
var world_env: WorldEnvironment
var key_light: DirectionalLight3D
var fill_light: DirectionalLight3D
var stage_root: Node3D
var level_pivot: Node3D
var moving_platform: Node3D
var moving_capsule: Node3D
var proxy_capsule_mesh: MeshInstance3D
var attachment_manager: HkbMods.HkbAttachmentManager = null
var dynamic_props: Array[RigidBody3D] = []
var _moving_platform_mode: String = ""
var _env_time: float = 0.0
var _proxy_target: Node3D = null


static func clear_caches() -> void:
	_sky_tex_cache.clear()
	_glb_mesh_cache.clear()
	_attachment_props_cache.clear()


static func get_skybox_texture(sky_id: String = "default") -> ImageTexture:
	var path := str(EXTRA_SKYBOXES.get(sky_id.to_lower(), SKYBOX_PNG))
	if _sky_tex_cache.has(path):
		return _sky_tex_cache[path] as ImageTexture
	if not FileAccess.file_exists(path):
		path = SKYBOX_PNG
		if not FileAccess.file_exists(path):
			return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null or img.is_empty():
		return null
	var tex := ImageTexture.create_from_image(img)
	_sky_tex_cache[path] = tex
	return tex


static func _load_glb_meshes(glb_path: String) -> Array[Dictionary]:
	if _glb_mesh_cache.has(glb_path):
		return _glb_mesh_cache[glb_path] as Array[Dictionary]
	var out: Array[Dictionary] = []
	if not FileAccess.file_exists(glb_path):
		return out
	var bytes := FileAccess.get_file_as_bytes(glb_path)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if doc.append_from_buffer(bytes, "", st) != OK:
		return out
	var scene := doc.generate_scene(st)
	if scene == null:
		return out
	var nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))
	for src in nodes:
		var m: Mesh = null
		if src is MeshInstance3D:
			m = (src as MeshInstance3D).mesh
		elif src.is_class("ImporterMeshInstance3D"):
			var imp = src.get("mesh")
			if imp != null and imp.has_method("get_mesh"):
				m = imp.call("get_mesh")
		if m == null:
			continue
		out.append({"name": src.name, "mesh": m})
	scene.free()
	_glb_mesh_cache[glb_path] = out
	return out


static func get_attachment_props() -> Dictionary:
	if not _attachment_props_cache.is_empty():
		return _attachment_props_cache
	if FileAccess.file_exists(ATTACHMENT_PROPS_JSON):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ATTACHMENT_PROPS_JSON))
		if parsed is Dictionary:
			_attachment_props_cache = parsed as Dictionary
	return _attachment_props_cache


func setup_lighting_and_sky() -> void:
	if world_env != null and is_instance_valid(world_env):
		return
	var env := Environment.new()
	var sky_tex := get_skybox_texture()
	if sky_tex != null:
		var sky_mat := PanoramaSkyMaterial.new()
		sky_mat.panorama = sky_tex
		sky_mat.filter = true
		var sky := Sky.new()
		sky.sky_material = sky_mat
		env.background_mode = Environment.BG_SKY
		env.sky = sky
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.36, 0.30, 0.42, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.86, 0.88, 0.92)
	env.ambient_light_energy = 0.72
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	world_env = WorldEnvironment.new()
	world_env.name = "HavokWorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	# Match hkDefaultDemo::setSoleDirectionLight + subtle fill so characters & textured rooms match DX11
	key_light = DirectionalLight3D.new()
	key_light.name = "HavokKeyLight"
	key_light.light_energy = 1.15
	key_light.light_color = Color(1.0, 0.99, 0.97)
	key_light.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
	key_light.shadow_enabled = false
	add_child(key_light)

	fill_light = DirectionalLight3D.new()
	fill_light.name = "HavokFillLight"
	fill_light.light_energy = 0.42
	fill_light.light_color = Color(0.82, 0.88, 0.98)
	fill_light.rotation_degrees = Vector3(-22.0, 145.0, 0.0)
	add_child(fill_light)

	stage_root = Node3D.new()
	stage_root.name = "HavokEnvStage"
	add_child(stage_root)


func clear_stage() -> void:
	if stage_root == null:
		return
	for c in stage_root.get_children():
		stage_root.remove_child(c)
		c.queue_free()
	level_pivot = null
	moving_platform = null
	moving_capsule = null
	proxy_capsule_mesh = null
	_moving_platform_mode = ""
	_env_time = 0.0
	_proxy_target = null


static func classify_env_kind(menu_path: String, demo_path: String) -> String:
	var mp := menu_path.to_lower()
	var dp := demo_path.to_lower()
	if mp == "behavior/showcase/hero" or "behaviorviewers" in dp or "ondemandassetloading" in dp:
		return "hero_environment"
	if "charactercontrollerdriver" in dp:
		return "hk_anim_level_cc"
	if "footikdriver" in dp:
		return "hk_anim_level_footik"
	if "charactertoobject" in dp or "symbollinking" in dp:
		return "attachment_scene"
	if "dockingblend" in dp:
		return "docking_blend"
	if "dockingconstrainedmotion" in dp:
		return "docking_constrained"
	if "dockingmovingtarget" in dp:
		return "docking_moving"
	if "dockingmultipletargets" in dp:
		return "docking_multiple"
	if "movingplatforms" in dp:
		return "moving_platforms"
	if "bodyik" in dp or "climbing" in dp:
		return "climbing_wall"
	if "ninja" in dp or "ninja" in mp:
		return "ninja_environment"
	if "orcs" in dp or "animationsets" in dp:
		return "orcs_grid"
	if "gdc" in dp or "handik" in dp or "firefighter" in dp:
		return "hk_gdc_level"
	if "penetration" in dp:
		return "penetration_landscape"
	if "seesaw" in dp:
		return "anim_seesaw"
	if "footik" in dp or "footplacement" in dp:
		return "foot_ik_runway"
	return "studio"


func set_skybox(sky_id: String) -> void:
	if world_env == null or world_env.environment == null:
		return
	var tex := get_skybox_texture(sky_id)
	if tex != null and world_env.environment.sky != null and world_env.environment.sky.sky_material is PanoramaSkyMaterial:
		(world_env.environment.sky.sky_material as PanoramaSkyMaterial).panorama = tex


func configure_for_demo(
	menu_path: String,
	demo_path: String,
	primary_char: String = "hero",
	proxy_target: Node3D = null,
	hero_world_offset_godot: Vector3 = Vector3.ZERO
) -> String:
	setup_lighting_and_sky()
	clear_stage()
	dynamic_props.clear()
	attachment_manager = null
	env_kind = classify_env_kind(menu_path, demo_path)
	_proxy_target = proxy_target

	# Tune skybox & lighting per demo family
	if env_kind == "ninja_environment":
		set_skybox("skynin")
	elif env_kind == "climbing_wall":
		set_skybox("clouds")
	elif env_kind == "orcs_grid":
		set_skybox("duskfair")
	elif env_kind == "hk_gdc_level":
		set_skybox("boardwalk")
	else:
		set_skybox("default")

	if world_env != null and world_env.environment != null:
		world_env.environment.sky_rotation = Vector3(0.0, 3.25 if primary_char == "soldier" else 0.15, 0.0)
		world_env.environment.ambient_light_energy = 0.88 if env_kind.begins_with("hk_anim_level") else 0.65

	match env_kind:
		"hero_environment":
			_build_hero_environment()
		"hk_anim_level_cc":
			var anchor := hero_world_offset_godot if hero_world_offset_godot.length() > 0.1 else Vector3(11.5, 4.76, 6.0)
			_build_hk_anim_level(anchor, true)
		"hk_anim_level_footik":
			var anchor := hero_world_offset_godot if hero_world_offset_godot.length() > 0.1 else Vector3(-2.0, 4.50, 10.0)
			_build_hk_anim_level(anchor, false)
		"attachment_scene":
			_build_attachment_scene(primary_char)
		"docking_blend":
			_build_docking_blend()
		"docking_constrained":
			_build_docking_constrained()
		"docking_moving":
			_build_docking_moving()
		"docking_multiple":
			_build_docking_multiple()
		"moving_platforms":
			_build_moving_platforms()
		"hk_gdc_level", "ninja_environment", "climbing_wall", "foot_ik_runway", "anim_seesaw", "anim_bricks", "orcs_grid", "penetration_landscape":
			_build_extra_sdk_env(env_kind, primary_char)
		_:
			_build_studio_floor(primary_char)

	return env_kind


func step(dt: float, actor_node: Node3D = null) -> void:
	_env_time += dt
	if _moving_platform_mode == "docking_moving" and moving_platform != null:
		# Exact DockingMovingTargetDemo::getKeyframeTransform(t) converted to Godot Standard
		var t := _env_time
		var bob_y := 0.25 * (1.0 - cos(4.0 * t))
		moving_platform.position.y = -0.5 + bob_y
		moving_platform.rotation.y = t * 0.65
	elif _moving_platform_mode == "moving_platforms" and moving_platform != null:
		# Exact MovingPlatforms.cpp: angVel = 0.1 rad/s around worldUp
		moving_platform.rotation.y = _env_time * 0.1

	if proxy_capsule_mesh != null and is_instance_valid(proxy_capsule_mesh):
		var follow := actor_node if (actor_node != null and is_instance_valid(actor_node)) else _proxy_target
		if follow != null and is_instance_valid(follow):
			proxy_capsule_mesh.global_position = follow.global_position + Vector3(0.0, 0.90, 0.0)


func align_level_to_havok_frame(actor_pos_godot: Vector3, hk_root_g: Vector3, rot_y: float) -> void:
	## Aligns extracted level geometry (`hero_environment`, `env_hk_anim_level`, `env_attachment_scene`)
	## rigidly so that Havok world point `hk_root_g` maps exactly to `actor_pos_godot`
	## with yaw alignment `rot_y` (matches Havok DX11 character-to-environment relative placement!).
	if level_pivot == null or not is_instance_valid(level_pivot):
		return
	level_pivot.position = actor_pos_godot
	level_pivot.rotation = Vector3(0.0, rot_y, 0.0)
	var inner := level_pivot.get_node_or_null("HkAnimLevelOffset")
	if inner is Node3D:
		(inner as Node3D).position = -hk_root_g
	else:
		# For hero_environment / attachment_scene, shift direct level child by -hk_root_g (clamping Y if floor at 0)
		for ch in level_pivot.get_children():
			if ch is Node3D:
				(ch as Node3D).position = Vector3(-hk_root_g.x, -hk_root_g.y if env_kind.begins_with("hk_anim_level") else 0.0, -hk_root_g.z)


func _add_static_box(
	parent: Node3D,
	size: Vector3,
	pos: Vector3,
	color: Color,
	with_collision: bool = true,
	roughness: float = 0.92
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = 0.0
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)
	if with_collision:
		var sb := StaticBody3D.new()
		sb.collision_layer = 1
		sb.collision_mask = 0
		sb.position = pos
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		sb.add_child(cs)
		parent.add_child(sb)
	return mi


func _add_static_capsule(
	parent: Node3D,
	radius: float,
	height: float,
	pos: Vector3,
	color: Color,
	with_collision: bool = true
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = height
	cm.radial_segments = 16
	cm.rings = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.82
	mat.metallic = 0.05
	cm.material = mat
	mi.mesh = cm
	mi.position = pos
	parent.add_child(mi)
	if with_collision:
		var sb := StaticBody3D.new()
		sb.collision_layer = 1
		sb.collision_mask = 0
		sb.position = pos
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = radius
		cap.height = height
		cs.shape = cap
		sb.add_child(cs)
		parent.add_child(sb)
	return mi


func _add_red_proxy_capsule() -> void:
	# Matches BehaviorUtils::setCharacterDisplayMode semi-transparent red/orange proxy capsule in Havok DX11
	proxy_capsule_mesh = MeshInstance3D.new()
	proxy_capsule_mesh.name = "HavokCharacterProxyDisplay"
	var cm := CapsuleMesh.new()
	cm.radius = 0.36
	cm.height = 1.76
	cm.radial_segments = 16
	cm.rings = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.86, 0.08, 0.06, 0.48)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.65
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	cm.material = mat
	proxy_capsule_mesh.mesh = cm
	proxy_capsule_mesh.position = Vector3(0.0, 0.90, 0.0)
	stage_root.add_child(proxy_capsule_mesh)


func _build_hero_environment() -> void:
	# Official Resources/Behavior/GameAssets/Hero/Terrain/Environment.hkt -> res://hero/assets/hero_environment.glb
	level_pivot = Node3D.new()
	level_pivot.name = "HeroEnvironmentPivot"
	# Rotate by PI around Y to align raw Hero +Z world to Godot Standard -Z (matches HeroStandardAlign)
	level_pivot.rotation.y = PI
	stage_root.add_child(level_pivot)
	var hen := HeroEnvNode.new()
	hen.name = "OfficialHeroEnvironment"
	hen.show_docking_lines = false
	level_pivot.add_child(hen)


func _build_hk_anim_level(anchor_godot: Vector3, with_proxy_capsule: bool) -> void:
	# Official Resources/Animation/ShowCase/Level/hkAnimLevel_VertexColors.hkt -> env_hk_anim_level.glb
	level_pivot = Node3D.new()
	level_pivot.name = "HkAnimLevelPivot"
	# Align raw Havok Z-up->Y-up (+Z Hero forward) to Godot Standard (-Z Hero forward)
	level_pivot.rotation.y = PI
	stage_root.add_child(level_pivot)

	var inner := Node3D.new()
	inner.name = "HkAnimLevelOffset"
	inner.position = -anchor_godot
	level_pivot.add_child(inner)

	var entries := _load_glb_meshes(HK_ANIM_LEVEL_GLB)
	for ent in entries:
		var m: Mesh = ent["mesh"] as Mesh
		var mi := MeshInstance3D.new()
		mi.name = str(ent["name"])
		mi.mesh = m
		# Ensure vertex colors + embedded diffuse textures match Havok DX11 vertex-colored rendering
		for si in m.get_surface_count():
			var mat := m.surface_get_material(si)
			if mat is BaseMaterial3D:
				var dup := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
				dup.vertex_color_use_as_albedo = true
				dup.vertex_color_is_srgb = true
				dup.cull_mode = BaseMaterial3D.CULL_DISABLED
				dup.roughness = 0.88
				mi.set_surface_override_material(si, dup)
		inner.add_child(mi)
		# Attach real ConcavePolygonShape3D trimesh collider so HkbFootIkDriver raycasts hit exact stairs!
		var tri_shape := m.create_trimesh_shape()
		if tri_shape != null:
			var tsb := StaticBody3D.new()
			tsb.name = str(ent["name"]) + "_Col"
			tsb.collision_layer = 1
			tsb.collision_mask = 0
			var tcs := CollisionShape3D.new()
			tcs.shape = tri_shape
			tsb.add_child(tcs)
			inner.add_child(tsb)

	# Solid invisible safety floor right at Y = 0 so physics actors never fall through stairs
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(80.0, 0.4, 80.0)
	cs.shape = bs
	cs.position = Vector3(0.0, -0.2, 0.0)
	sb.add_child(cs)
	stage_root.add_child(sb)

	if with_proxy_capsule:
		_add_red_proxy_capsule()


func _make_havok_checker_material() -> StandardMaterial3D:
	# Exact grey/light-grey checkerboard tile matching Havok AttachmentScene DX11 floor
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var c_dark := Color(0.46, 0.46, 0.48, 1.0)
	var c_light := Color(0.74, 0.74, 0.76, 1.0)
	for y in 64:
		for x in 64:
			var is_light := ((x < 32) == (y < 32))
			img.set_pixel(x, y, c_light if is_light else c_dark)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 0.92
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _build_attachment_scene(primary_char: String) -> void:
	# Official Resources/Behavior/GameAssets/Terrain/AttachmentScene.hkt -> env_attachment_scene.glb
	level_pivot = Node3D.new()
	level_pivot.name = "AttachmentScenePivot"
	level_pivot.rotation.y = PI * 0.5 if primary_char == "soldier" else PI
	stage_root.add_child(level_pivot)

	var checker_mat := _make_havok_checker_material()
	var entries := _load_glb_meshes(ATTACHMENT_SCENE_GLB)
	for ent in entries:
		var m: Mesh = ent["mesh"] as Mesh
		var nm := str(ent["name"])
		var mi := MeshInstance3D.new()
		mi.name = nm
		mi.mesh = m
		var is_floor := ("rectangle" in nm.to_lower() or "floor" in nm.to_lower() or "ground" in nm.to_lower())
		for si in m.get_surface_count():
			if is_floor:
				mi.set_surface_override_material(si, checker_mat)
			else:
				var mat := m.surface_get_material(si)
				if mat is BaseMaterial3D:
					var dup := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
					dup.albedo_color = Color(0.76, 0.76, 0.78, 1.0)
					dup.cull_mode = BaseMaterial3D.CULL_DISABLED
					dup.roughness = 0.85
					mi.set_surface_override_material(si, dup)
		level_pivot.add_child(mi)

	# Solid floor collider matching Rectangle01 top surface at Y = 0.0
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(60.0, 0.5, 60.0)
	cs.shape = bs
	cs.position = Vector3(0.0, -0.25, 0.0)
	sb.add_child(cs)
	stage_root.add_child(sb)

	# Spawn REAL dynamic RigidBody3D skull props + HkbAttachmentManager from env_attachment_props.json!
	attachment_manager = HkbMods.HkbAttachmentManager.new()
	var props_meta := get_attachment_props()
	for p_raw in props_meta.get("dynamic_props", []) as Array:
		var pd: Dictionary = p_raw as Dictionary
		var pos_a: Array = pd.get("position", [0.0, 0.3, 0.0]) as Array
		var p_raw_v := Vector3(float(pos_a[0]), float(pos_a[1]), float(pos_a[2]))
		var rb := RigidBody3D.new()
		rb.name = str(pd.get("name", "SkullProp"))
		rb.mass = maxf(0.5, float(pd.get("mass", 2.0)))
		rb.collision_layer = 4
		rb.collision_mask = 1
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.freeze = true
		var col := CollisionShape3D.new()
		var sp := SphereShape3D.new()
		sp.radius = 0.16
		col.shape = sp
		rb.add_child(col)
		level_pivot.add_child(rb)
		rb.position = p_raw_v
		dynamic_props.append(rb)
		attachment_manager.register_prop(rb)


func _build_extra_sdk_env(kind: String, primary_char: String) -> void:
	var glb_path := str(EXTRA_ENV_GLBS.get(kind, ""))
	if glb_path.is_empty() or not FileAccess.file_exists(glb_path):
		_build_studio_floor(primary_char)
		return
	level_pivot = Node3D.new()
	level_pivot.name = "ExtraSdkEnv_" + kind
	level_pivot.rotation.y = PI
	stage_root.add_child(level_pivot)
	var inner_parent: Node3D = level_pivot
	if kind == "hk_gdc_level":
		var off := Node3D.new()
		off.name = "HkGdcLevelOffset"
		off.position = -Vector3(11.5, 4.76, 6.0)
		level_pivot.add_child(off)
		inner_parent = off
	var entries := _load_glb_meshes(glb_path)
	for ent in entries:
		var m: Mesh = ent["mesh"] as Mesh
		var mi := MeshInstance3D.new()
		mi.name = str(ent["name"])
		mi.mesh = m
		for si in m.get_surface_count():
			var mat := m.surface_get_material(si)
			if mat is BaseMaterial3D:
				var dup := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
				dup.cull_mode = BaseMaterial3D.CULL_DISABLED
				if kind == "hk_gdc_level":
					dup.vertex_color_use_as_albedo = true
					dup.vertex_color_is_srgb = true
				mi.set_surface_override_material(si, dup)
		inner_parent.add_child(mi)
	# Safety floor at Y = 0
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(100.0, 0.4, 100.0)
	cs.shape = bs
	cs.position = Vector3(0.0, -0.2, 0.0)
	sb.add_child(cs)
	stage_root.add_child(sb)


func _build_docking_blend() -> void:
	# DockingBlendDemo.cpp: ground (100,100,20)@(0,0,-10), 2 walls (1.5,1,2)@(±2,-2.5,1) Z-up
	var ground_col := Color(0.47, 0.47, 0.49)
	var wall_col := Color(0.56, 0.56, 0.58)
	_add_static_box(stage_root, Vector3(120.0, 0.4, 120.0), Vector3(0.0, -0.2, 0.0), ground_col)
	# Relative to docked Hero (rotated PI into -Z forward): cover wall behind/ahead at z = -2.5
	_add_static_box(stage_root, Vector3(1.5, 2.0, 1.0), Vector3(0.0, 1.0, -2.5), wall_col)
	_add_static_box(stage_root, Vector3(1.5, 2.0, 1.0), Vector3(4.0, 1.0, -2.5), wall_col)


func _build_docking_constrained() -> void:
	# DockingConstrainedMotionDemo.cpp: ground + wall (6.6,1,2)@(0,-2.5,1) + cylinder capsule r=1.0@(0,2.5,0)
	var ground_col := Color(0.47, 0.47, 0.49)
	var wall_col := Color(0.56, 0.56, 0.58)
	_add_static_box(stage_root, Vector3(120.0, 0.4, 120.0), Vector3(0.0, -0.2, 0.0), ground_col)
	_add_static_box(stage_root, Vector3(6.6, 2.0, 1.0), Vector3(0.0, 1.0, -1.5), wall_col)
	_add_static_capsule(stage_root, 1.0, 3.2, Vector3(0.0, 1.2, 3.5), wall_col)


func _build_docking_moving() -> void:
	# DockingMovingTargetDemo.cpp: ground + PURPLE keyframed platform (4.6,4.6,1.0) + PURPLE docking capsule r=0.75
	var ground_col := Color(0.45, 0.45, 0.47)
	var purple := Color(0.44, 0.02, 0.46)
	_add_static_box(stage_root, Vector3(160.0, 0.4, 160.0), Vector3(0.0, -0.75, 0.0), ground_col)
	moving_platform = Node3D.new()
	moving_platform.name = "DockingMovingPlatform"
	moving_platform.position = Vector3(0.0, -0.5, 0.0)
	stage_root.add_child(moving_platform)
	_add_static_box(moving_platform, Vector3(4.6, 1.0, 4.6), Vector3.ZERO, purple, true, 0.78)
	moving_capsule = _add_static_capsule(moving_platform, 0.75, 2.8, Vector3(0.95, 1.35, -0.25), purple, false)
	_moving_platform_mode = "docking_moving"


func _build_docking_multiple() -> void:
	# DockingMultipleTargetsDemo.cpp: ground + 2 cover boxes (1,1,2)@(0,0,1) & (-3,-3,1)
	var ground_col := Color(0.47, 0.47, 0.49)
	var wall_col := Color(0.56, 0.56, 0.58)
	_add_static_box(stage_root, Vector3(120.0, 0.4, 120.0), Vector3(0.0, -0.2, 0.0), ground_col)
	_add_static_box(stage_root, Vector3(1.0, 2.0, 1.0), Vector3(-2.0, 1.0, 0.0), wall_col)
	_add_static_box(stage_root, Vector3(1.0, 2.0, 1.0), Vector3(1.0, 1.0, -3.0), wall_col)


func _build_moving_platforms() -> void:
	# MovingPlatforms.cpp: PURPLE rotating platform (12,12,0.25) floating in defaultskybox + red proxy capsule
	var purple := Color(0.44, 0.03, 0.46)
	moving_platform = Node3D.new()
	moving_platform.name = "HavokRotatingPlatform"
	stage_root.add_child(moving_platform)
	_add_static_box(moving_platform, Vector3(12.0, 0.25, 12.0), Vector3(0.0, -0.125, 0.0), purple, true, 0.78)
	_moving_platform_mode = "moving_platforms"
	_add_red_proxy_capsule()


func _build_studio_floor(primary_char: String) -> void:
	# Exact Havok BehaviorUtils::createDemoBox flat grey ground calibrated to match Havok DX11 #A8A8A8
	var floor_col := Color(0.55, 0.55, 0.57) if primary_char == "soldier" else Color(0.50, 0.50, 0.52)
	_add_static_box(stage_root, Vector3(200.0, 0.4, 200.0), Vector3(0.0, -0.2, 0.0), floor_col, true, 0.95)
