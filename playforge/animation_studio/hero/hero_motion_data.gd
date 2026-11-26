@tool
class_name HeroMotionData
extends Resource
## Native Godot binary Resource storing the internalized 85-bone Hero skeleton
## rest hierarchy and 5 locomotion animation clips (idle, idle_to_walk, walk, run, turn).
## Uses compact PackedFloat32Array streams for fast loading and small repository footprint,
## with zero external .hkt or Havok SDK dependency at runtime or in the Godot Editor.

const NATIVE_MOTION_RES := "res://hero/assets/hero_motion.res"
const NATIVE_SKIN_GLB := "res://hero/assets/hero_skin.glb"
const FALLBACK_GENERATED_MOTION := "res://hero/generated/motion.json"
const FALLBACK_GENERATED_SKIN := "res://hero/generated/hero_skin.gltf"

@export var schema_version: int = 1
@export var bone_names: PackedStringArray = PackedStringArray()
@export var bone_parents: PackedInt32Array = PackedInt32Array()
# 10 floats per bone: tx, ty, tz, rx, ry, rz, rw, sx, sy, sz
@export var bone_binds: PackedFloat32Array = PackedFloat32Array()
# Dictionary[String -> Dictionary] with compact PackedArrays:
#   duration: float, frame_count: int, track_bones: PackedInt32Array,
#   track_key_counts: PackedInt32Array, track_data: PackedFloat32Array (11 floats/key),
#   root_data: PackedFloat32Array (8 floats/key)
@export var packed_clips: Dictionary = {}


func pack_from_dict(raw: Dictionary) -> void:
	schema_version = 1
	var raw_bones: Array = raw.get("skeleton", {}).get("bones", [])
	var n_bones := raw_bones.size()
	bone_names = PackedStringArray()
	bone_names.resize(n_bones)
	bone_parents = PackedInt32Array()
	bone_parents.resize(n_bones)
	bone_binds = PackedFloat32Array()
	bone_binds.resize(n_bones * 10)
	for i in n_bones:
		var b: Dictionary = raw_bones[i]
		bone_names[i] = str(b.name)
		bone_parents[i] = int(b.parent)
		var bind: Dictionary = b.bind
		var t: Array = bind.translation
		var r: Array = bind.rotation
		var s: Array = bind.scale
		var o := i * 10
		bone_binds[o + 0] = float(t[0])
		bone_binds[o + 1] = float(t[1])
		bone_binds[o + 2] = float(t[2])
		bone_binds[o + 3] = float(r[0])
		bone_binds[o + 4] = float(r[1])
		bone_binds[o + 5] = float(r[2])
		bone_binds[o + 6] = float(r[3])
		bone_binds[o + 7] = float(s[0])
		bone_binds[o + 8] = float(s[1])
		bone_binds[o + 9] = float(s[2])

	packed_clips = {}
	var raw_clips: Dictionary = raw.get("clips", {})
	for clip_key in raw_clips:
		var c: Dictionary = raw_clips[clip_key]
		var tracks: Array = c.get("tracks", [])
		var t_bones := PackedInt32Array()
		var t_counts := PackedInt32Array()
		var total_keys := 0
		for tr in tracks:
			var keys: Array = tr.get("keys", [])
			t_bones.append(int(tr.bone))
			t_counts.append(keys.size())
			total_keys += keys.size()
		var t_data := PackedFloat32Array()
		t_data.resize(total_keys * 11)
		var cursor := 0
		for tr in tracks:
			for k in tr.get("keys", []):
				var trn: Array = k.translation
				var rot: Array = k.rotation
				var scl: Array = k.scale
				t_data[cursor + 0] = float(k.time)
				t_data[cursor + 1] = float(trn[0])
				t_data[cursor + 2] = float(trn[1])
				t_data[cursor + 3] = float(trn[2])
				t_data[cursor + 4] = float(rot[0])
				t_data[cursor + 5] = float(rot[1])
				t_data[cursor + 6] = float(rot[2])
				t_data[cursor + 7] = float(rot[3])
				t_data[cursor + 8] = float(scl[0])
				t_data[cursor + 9] = float(scl[1])
				t_data[cursor + 10] = float(scl[2])
				cursor += 11

		var rm = c.get("root_motion")
		var r_keys: Array = rm.get("keys", []) if rm is Dictionary else []
		var r_data := PackedFloat32Array()
		r_data.resize(r_keys.size() * 8)
		var rc := 0
		for k in r_keys:
			var trn: Array = k.translation
			var rot: Array = k.rotation
			r_data[rc + 0] = float(k.time)
			r_data[rc + 1] = float(trn[0])
			r_data[rc + 2] = float(trn[1])
			r_data[rc + 3] = float(trn[2])
			r_data[rc + 4] = float(rot[0])
			r_data[rc + 5] = float(rot[1])
			r_data[rc + 6] = float(rot[2])
			r_data[rc + 7] = float(rot[3])
			rc += 8

		var frame_count := 0
		if c.has("source") and c.source is Dictionary:
			frame_count = int(c.source.get("originalFrames", 0))
		elif c.has("frame_count"):
			frame_count = int(c.frame_count)
		packed_clips[str(clip_key)] = {
			"duration": float(c.duration),
			"frame_count": frame_count,
			"track_bones": t_bones,
			"track_key_counts": t_counts,
			"track_data": t_data,
			"root_data": r_data,
		}


func to_motion_dict() -> Dictionary:
	var bones_out: Array = []
	var n_bones := bone_names.size()
	bones_out.resize(n_bones)
	for i in n_bones:
		var o := i * 10
		bones_out[i] = {
			"name": bone_names[i],
			"parent": bone_parents[i],
			"bind": {
				"translation": [bone_binds[o + 0], bone_binds[o + 1], bone_binds[o + 2]],
				"rotation": [bone_binds[o + 3], bone_binds[o + 4], bone_binds[o + 5], bone_binds[o + 6]],
				"scale": [bone_binds[o + 7], bone_binds[o + 8], bone_binds[o + 9]],
			},
		}

	var clips_out: Dictionary = {}
	for clip_key in packed_clips:
		var pc: Dictionary = packed_clips[clip_key]
		var t_bones: PackedInt32Array = pc.track_bones
		var t_counts: PackedInt32Array = pc.track_key_counts
		var t_data: PackedFloat32Array = pc.track_data
		var tracks_out: Array = []
		tracks_out.resize(t_bones.size())
		var cursor := 0
		for ti in t_bones.size():
			var cnt := t_counts[ti]
			var keys_out: Array = []
			keys_out.resize(cnt)
			for ki in cnt:
				keys_out[ki] = {
					"time": t_data[cursor + 0],
					"translation": [t_data[cursor + 1], t_data[cursor + 2], t_data[cursor + 3]],
					"rotation": [t_data[cursor + 4], t_data[cursor + 5], t_data[cursor + 6], t_data[cursor + 7]],
					"scale": [t_data[cursor + 8], t_data[cursor + 9], t_data[cursor + 10]],
				}
				cursor += 11
			tracks_out[ti] = {"bone": t_bones[ti], "keys": keys_out}

		var r_data: PackedFloat32Array = pc.root_data
		var r_cnt := int(r_data.size() / 8)
		var root_motion_out = null
		if r_cnt > 0:
			var r_keys: Array = []
			r_keys.resize(r_cnt)
			for ki in r_cnt:
				var rc := ki * 8
				r_keys[ki] = {
					"time": r_data[rc + 0],
					"translation": [r_data[rc + 1], r_data[rc + 2], r_data[rc + 3]],
					"rotation": [r_data[rc + 4], r_data[rc + 5], r_data[rc + 6], r_data[rc + 7]],
					"scale": [1.0, 1.0, 1.0],
				}
			root_motion_out = {"keys": r_keys}

		clips_out[clip_key] = {
			"duration": float(pc.duration),
			"frame_count": int(pc.get("frame_count", 0)),
			"tracks": tracks_out,
			"root_motion": root_motion_out,
		}

	return {
		"schema_version": schema_version,
		"skeleton": {"bones": bones_out},
		"clips": clips_out,
	}


static func has_motion_data() -> bool:
	return FileAccess.file_exists(NATIVE_MOTION_RES) or FileAccess.file_exists(FALLBACK_GENERATED_MOTION)


static func load_motion_dict() -> Dictionary:
	if FileAccess.file_exists(NATIVE_MOTION_RES):
		var res = ResourceLoader.load(NATIVE_MOTION_RES)
		if res != null and res.has_method("to_motion_dict"):
			return res.call("to_motion_dict")
	if FileAccess.file_exists(FALLBACK_GENERATED_MOTION):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(FALLBACK_GENERATED_MOTION))
		if parsed is Dictionary:
			return parsed
	return {}


static func resolve_skin_path() -> String:
	if FileAccess.file_exists(NATIVE_SKIN_GLB):
		return NATIVE_SKIN_GLB
	if FileAccess.file_exists(FALLBACK_GENERATED_SKIN):
		return FALLBACK_GENERATED_SKIN
	return ""
