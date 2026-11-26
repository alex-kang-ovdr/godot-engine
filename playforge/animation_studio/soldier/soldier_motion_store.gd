@tool
extends RefCounted
## Native Godot asset loader for the internalized 114-bone Soldier + M4 Rifle
## (soldier_motion.res + soldier_skin.glb). Zero .hkt or external SDK dependency.

const NATIVE_MOTION_RES := "res://soldier/assets/soldier_motion.res"
const NATIVE_SKIN_GLB := "res://soldier/assets/soldier_skin.glb"
const OPTIONAL_ORACLE_JSON := "res://soldier/generated/oracle.json"


static func has_native_assets() -> bool:
	return FileAccess.file_exists(NATIVE_MOTION_RES) and FileAccess.file_exists(NATIVE_SKIN_GLB)


static func load_motion_dict() -> Dictionary:
	if FileAccess.file_exists(NATIVE_MOTION_RES):
		var res = ResourceLoader.load(NATIVE_MOTION_RES)
		if res != null and res.has_method("to_motion_dict"):
			return res.call("to_motion_dict")
	return {}


static func load_optional_oracle() -> Dictionary:
	if FileAccess.file_exists(OPTIONAL_ORACLE_JSON):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(OPTIONAL_ORACLE_JSON))
		if parsed is Dictionary:
			return parsed
	return {}


static func load_skin_into_skeleton(rig: Skeleton3D) -> Dictionary:
	var out := {"meshes": [], "surfaces": 0, "vertices": 0, "textured_surfaces": 0}
	if not FileAccess.file_exists(NATIVE_SKIN_GLB):
		return out
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.use_named_skin_binds = true
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var bytes := FileAccess.get_file_as_bytes(NATIVE_SKIN_GLB)
	if doc.append_from_buffer(bytes, "", st) != OK:
		return out
	var scene := doc.generate_scene(st)
	if scene == null:
		return out

	var mesh_nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	mesh_nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))
	var fallback_skels := scene.find_children("*", "Skeleton3D", true, false)
	var fallback_rig: Skeleton3D = fallback_skels[0] as Skeleton3D if not fallback_skels.is_empty() else null

	for src in mesh_nodes:
		var src_mesh: Mesh = null
		var src_skin: Skin = null
		var src_skel_path := NodePath()
		if src is MeshInstance3D:
			src_mesh = src.mesh
			src_skin = src.skin
			src_skel_path = src.skeleton
		elif src.is_class("ImporterMeshInstance3D"):
			var imp = src.get("mesh")
			if imp != null and imp.has_method("get_mesh"):
				src_mesh = imp.call("get_mesh")
			src_skin = src.get("skin") as Skin
			src_skel_path = src.get("skeleton_path") as NodePath
		if src_mesh == null or src_skin == null:
			continue
		var src_rig := src.get_node_or_null(src_skel_path) as Skeleton3D
		if src_rig == null:
			src_rig = fallback_rig
		var skin := src_skin.duplicate() as Skin
		var valid := true
		for i in skin.get_bind_count():
			var bname := skin.get_bind_name(i)
			if bname.is_empty() and src_rig:
				bname = src_rig.get_bone_name(skin.get_bind_bone(i))
			var bidx := rig.find_bone(bname)
			if bidx < 0:
				valid = false
				break
			skin.set_bind_name(i, bname)
			skin.set_bind_bone(i, bidx)
		if not valid:
			continue
		var vis := MeshInstance3D.new()
		vis.name = src.name
		vis.mesh = src_mesh
		vis.skin = skin
		vis.skeleton = ^".."
		rig.add_child(vis)
		out.meshes.append(vis)
		out.surfaces += src_mesh.get_surface_count()
		for j in src_mesh.get_surface_count():
			out.vertices += src_mesh.surface_get_array_len(j)
			var mat := vis.get_active_material(j) as BaseMaterial3D
			if mat and mat.albedo_texture:
				out.textured_surfaces += 1

	scene.free()
	return out
