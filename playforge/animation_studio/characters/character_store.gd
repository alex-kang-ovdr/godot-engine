@tool
class_name CharacterRosterStore
extends RefCounted

const CATALOG_PATH := "res://characters/catalog.json"
const Hero := preload("res://hero/hero.gd")

static var _catalog_cache: Array[Dictionary] = []
static var _motion_cache: Dictionary = {}


static func load_catalog(force_reload: bool = false) -> Array[Dictionary]:
	if not force_reload and not _catalog_cache.is_empty():
		return _catalog_cache
	_catalog_cache.clear()
	if not FileAccess.file_exists(CATALOG_PATH):
		return _catalog_cache
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if parsed is Dictionary and parsed.has("characters") and parsed["characters"] is Array:
		for item in parsed["characters"]:
			if item is Dictionary:
				_catalog_cache.append(item)
	return _catalog_cache


static func get_entry(char_id: String) -> Dictionary:
	for entry in load_catalog():
		if str(entry.get("id", "")) == char_id:
			return entry
	return {}


static func load_motion_dict(char_id: String) -> Dictionary:
	if _motion_cache.has(char_id):
		return _motion_cache[char_id]
	var entry := get_entry(char_id)
	if entry.is_empty():
		return {}
	var mpath := str(entry.get("motion_path", ""))
	if mpath.is_empty() or not FileAccess.file_exists(mpath):
		return {}
	var res = ResourceLoader.load(mpath)
	if res != null and res.has_method("to_motion_dict"):
		var d: Dictionary = res.call("to_motion_dict")
		_motion_cache[char_id] = d
		return d
	return {}


static func populate_skeleton(skeleton: Skeleton3D, motion_dict: Dictionary) -> void:
	skeleton.clear_bones()
	var bones: Array = motion_dict.get("skeleton", {}).get("bones", [])
	for bone in bones:
		var idx := skeleton.add_bone(str(bone.name))
		skeleton.set_bone_parent(idx, int(bone.parent))
		skeleton.set_bone_rest(idx, Hero.transform_from(bone.bind))
	skeleton.reset_bone_poses()


static func build_animation_from_clip(motion_dict: Dictionary, clip_key: String, rig_name: String = "Skeleton3D") -> Animation:
	var clip: Dictionary = motion_dict.clips[clip_key]
	var bones: Array = motion_dict.skeleton.bones
	var anim := Animation.new()
	anim.length = float(clip.duration)
	anim.loop_mode = Animation.LOOP_LINEAR if bool(clip.get("loop", false)) else Animation.LOOP_NONE
	for track_def in clip.tracks:
		var bidx := int(track_def.bone)
		if bidx < 0 or bidx >= bones.size():
			continue
		var bname := str(bones[bidx].name)
		var path := NodePath("%s:%s" % [rig_name, bname])
		var pos_t := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(pos_t, path)
		var rot_t := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(rot_t, path)
		var scl_t := anim.add_track(Animation.TYPE_SCALE_3D)
		anim.track_set_path(scl_t, path)
		for key in track_def.keys:
			var t := float(key.time)
			var tr: Array = key.translation
			var rq: Array = key.rotation
			var sc: Array = key.scale
			anim.position_track_insert_key(pos_t, t, Vector3(float(tr[0]), float(tr[1]), float(tr[2])))
			anim.rotation_track_insert_key(rot_t, t, Quaternion(float(rq[0]), float(rq[1]), float(rq[2]), float(rq[3])).normalized())
			anim.scale_track_insert_key(scl_t, t, Vector3(float(sc[0]), float(sc[1]), float(sc[2])))
	return anim


static func attach_skin_to_skeleton(char_id: String, rig: Skeleton3D) -> Dictionary:
	var summary := {
		"loaded": false,
		"meshes": 0,
		"surfaces": 0,
		"vertices": 0,
		"textured_surfaces": 0,
		"aabb": AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.8, 1.0)),
	}
	if rig == null:
		return summary
	var entry := get_entry(char_id)
	if entry.is_empty():
		return summary
	var glb_path := str(entry.get("glb_path", ""))
	if glb_path.is_empty() or not FileAccess.file_exists(glb_path):
		return summary
	var bytes := FileAccess.get_file_as_bytes(glb_path)
	if bytes.is_empty():
		return summary

	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.use_named_skin_binds = true
	st.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	if doc.append_from_buffer(bytes, "", st) != OK:
		return summary
	var scene := doc.generate_scene(st)
	if scene == null:
		return summary

	var mesh_nodes: Array[Node] = scene.find_children("*", "MeshInstance3D", true, false)
	mesh_nodes.append_array(scene.find_children("*", "ImporterMeshInstance3D", true, false))
	var fallback_skels := scene.find_children("*", "Skeleton3D", true, false)
	var fallback_rig: Skeleton3D = fallback_skels[0] as Skeleton3D if not fallback_skels.is_empty() else null

	var combined_aabb := AABB()
	var has_aabb := false
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
			if bname.is_empty() and src_rig != null:
				var sb := skin.get_bind_bone(i)
				if sb >= 0 and sb < src_rig.get_bone_count():
					bname = src_rig.get_bone_name(sb)
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
		vis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		rig.add_child(vis)

		var maabb := src_mesh.get_aabb()
		if maabb.size.length() > 0.0001:
			combined_aabb = maabb if not has_aabb else combined_aabb.merge(maabb)
			has_aabb = true

		summary["meshes"] = int(summary["meshes"]) + 1
		summary["surfaces"] = int(summary["surfaces"]) + src_mesh.get_surface_count()
		for j in src_mesh.get_surface_count():
			summary["vertices"] = int(summary["vertices"]) + src_mesh.surface_get_array_len(j)
			var mat := vis.get_active_material(j) as BaseMaterial3D
			if mat and mat.albedo_texture:
				summary["textured_surfaces"] = int(summary["textured_surfaces"]) + 1

	scene.free()
	if has_aabb:
		summary["aabb"] = combined_aabb
	summary["loaded"] = int(summary["meshes"]) > 0
	return summary


static func build_rig(char_id: String, name_prefix: String = "CharRig") -> Dictionary:
	var motion_dict := load_motion_dict(char_id)
	if motion_dict.is_empty():
		return {}
	var motion_root := Node3D.new()
	motion_root.name = name_prefix
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	motion_root.add_child(skeleton)
	populate_skeleton(skeleton, motion_dict)

	var skin_info := attach_skin_to_skeleton(char_id, skeleton)

	var library := AnimationLibrary.new()
	var clips_dict: Dictionary = motion_dict.get("clips", {})
	for clip_key in clips_dict.keys():
		var anim := build_animation_from_clip(motion_dict, str(clip_key), "Skeleton3D")
		library.add_animation(str(clip_key), anim)

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	motion_root.add_child(player)
	player.add_animation_library("", library)
	player.root_node = player.get_path_to(motion_root)

	return {
		"root": motion_root,
		"skeleton": skeleton,
		"player": player,
		"library": library,
		"clips": clips_dict.keys(),
		"data": motion_dict,
		"skin_info": skin_info,
	}


static func compute_pose_aabb(skeleton: Skeleton3D, skin_info: Dictionary) -> AABB:
	if skeleton == null or skeleton.get_bone_count() == 0:
		return skin_info.get("aabb", AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.8, 1.0)))
	var min_p := Vector3(INF, INF, INF)
	var max_p := Vector3(-INF, -INF, -INF)
	var any := false
	for i in skeleton.get_bone_count():
		var p := skeleton.get_bone_global_pose(i).origin
		if not p.is_finite():
			continue
		min_p = min_p.min(p)
		max_p = max_p.max(p)
		any = true
	if not any:
		return skin_info.get("aabb", AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.8, 1.0)))
	var size := (max_p - min_p).max(Vector3(0.35, 0.45, 0.35))
	var pad_y := maxf(0.06, size.y * 0.07)
	min_p.y -= pad_y
	size.y += pad_y * 2.0
	return AABB(min_p, size)


static func apply_quantized_to_skeleton(qclip, skel: Skeleton3D, t: float) -> void:
	if qclip == null or skel == null:
		return
	var fkey := clampf(t * qclip.sample_rate, 0.0, float(qclip.key_count - 1))
	var k0 := clampi(int(floor(fkey)), 0, qclip.key_count - 1)
	var k1 := mini(k0 + 1, qclip.key_count - 1)
	var frac := fkey - float(k0)
	for b in qclip.bone_count:
		var p0: Vector3 = qclip.sample_bone_pos(k0, b)
		var p1: Vector3 = qclip.sample_bone_pos(k1, b)
		var r0: Quaternion = qclip.sample_bone_rot(k0, b)
		var r1: Quaternion = qclip.sample_bone_rot(k1, b)
		if r0.dot(r1) < 0.0:
			r1 = -r1
		skel.set_bone_pose_position(b, p0.lerp(p1, frac))
		skel.set_bone_pose_rotation(b, r0.slerp(r1, frac).normalized())
