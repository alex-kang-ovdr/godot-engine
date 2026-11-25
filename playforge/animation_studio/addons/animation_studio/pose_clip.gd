extends RefCounted

const NATIVE_CLASS := &"AnimationStudioPoseSampler"
const NATIVE_DESCRIPTOR := "res://addons/animation_studio/bin/animation_studio_pose_sampler.gdextension"

class TrackBinding extends RefCounted:
	var track_index: int
	var track_type: Animation.TrackType
	var bone_name: StringName
	var bone_index: int

	func _init(p_track_index: int, p_track_type: Animation.TrackType, p_bone_name: StringName, p_bone_index: int) -> void:
		track_index = p_track_index
		track_type = p_track_type
		bone_name = p_bone_name
		bone_index = p_bone_index


## A shallow sample snapshot plus a shallow playback duplicate with owned bone
## PRS tracks removed. Neither resource aliases the caller's editable source.
var playback: Animation

var _pose_snapshot: Animation
var _native_sampler: RefCounted
var _bindings: Array[TrackBinding] = []
var _skeleton_id: int = 0
var _skeleton_version: int = -1


func configure(source: Animation, mixer_root: Node, skeleton: Skeleton3D, root_motion_track: NodePath) -> bool:
	stop()
	if source == null or not is_instance_valid(mixer_root) or not is_instance_valid(skeleton):
		return false

	var remove_indices: Array[int] = []
	var extracted_bindings: Array[TrackBinding] = []
	var writers: Dictionary = {}
	for track_index in source.get_track_count():
		if not source.track_is_enabled(track_index):
			continue
		var path := source.track_get_path(track_index)
		if not root_motion_track.is_empty() and path == root_motion_track:
			continue
		var target := _resolve_node(mixer_root, path)
		if target != skeleton:
			continue
		var track_type := source.track_get_type(track_index)
		if not _is_prs_type(track_type):
			continue
		var subname_count := path.get_subname_count()
		if subname_count == 0:
			# This animates the Skeleton3D node itself, not one of its bones.
			continue
		if subname_count != 1:
			return false
		var bone_name := StringName(path.get_subname(0))
		var bone_index := skeleton.find_bone(bone_name)
		if bone_index < 0:
			return false
		if source.track_get_key_count(track_index) == 0:
			continue
		var writer_key := str(bone_index) + ":" + str(track_type)
		if writers.has(writer_key):
			return false
		writers[writer_key] = true
		extracted_bindings.append(TrackBinding.new(track_index, track_type, bone_name, bone_index))
		remove_indices.append(track_index)

	if extracted_bindings.is_empty():
		return false

	_pose_snapshot = source.duplicate(false) as Animation
	if _pose_snapshot == null:
		return false
	playback = _pose_snapshot.duplicate(false) as Animation
	if playback == null:
		_pose_snapshot = null
		return false
	_bindings = extracted_bindings
	if _native_available():
		var names := PackedStringArray()
		for binding in _bindings:
			names.append(binding.bone_name)
		_native_sampler = ClassDB.instantiate(NATIVE_CLASS)
		_native_sampler.call(&"configure", _pose_snapshot, PackedInt32Array(remove_indices), names)
	remove_indices.reverse()
	for track_index in remove_indices:
		# Godot cannot remove individual channels from a compressed page.
		if playback.track_is_compressed(track_index):
			playback.track_set_enabled(track_index, false)
		else:
			playback.remove_track(track_index)
	_skeleton_id = skeleton.get_instance_id()
	_skeleton_version = skeleton.get_version()
	return true


func apply_pose(skeleton: Skeleton3D, time: float, backwards: bool = false) -> void:
	if playback == null or _pose_snapshot == null:
		return
	if not is_instance_valid(skeleton) or skeleton.get_instance_id() != _skeleton_id:
		return
	if _native_sampler:
		_native_sampler.call(&"apply_pose", skeleton, time, backwards)
		return
	if skeleton.get_version() != _skeleton_version:
		_rebuild_bone_indices(skeleton)
	for binding in _bindings:
		var index := binding.track_index
		if binding.bone_index < 0 or not _pose_snapshot.track_is_enabled(index):
			continue
		if _pose_snapshot.track_get_key_count(index) == 0:
			continue
		match binding.track_type:
			Animation.TYPE_POSITION_3D:
				skeleton.set_bone_pose_position(binding.bone_index, _pose_snapshot.position_track_interpolate(index, time, backwards) * skeleton.motion_scale)
			Animation.TYPE_ROTATION_3D:
				skeleton.set_bone_pose_rotation(binding.bone_index, _pose_snapshot.rotation_track_interpolate(index, time, backwards))
			Animation.TYPE_SCALE_3D:
				skeleton.set_bone_pose_scale(binding.bone_index, _pose_snapshot.scale_track_interpolate(index, time, backwards))


## Releases both animation resources and their track bindings when playback stops.
func stop() -> void:
	playback = null
	_pose_snapshot = null
	_native_sampler = null
	_bindings.clear()
	_skeleton_id = 0
	_skeleton_version = -1


func _rebuild_bone_indices(skeleton: Skeleton3D) -> void:
	for binding in _bindings:
		binding.bone_index = skeleton.find_bone(binding.bone_name)
	_skeleton_version = skeleton.get_version()


func _resolve_node(root: Node, path: NodePath) -> Node:
	var node_path := NodePath(path.get_concatenated_names())
	return root if node_path.is_empty() else root.get_node_or_null(node_path)


func _is_prs_type(track_type: Animation.TrackType) -> bool:
	return track_type == Animation.TYPE_POSITION_3D \
			or track_type == Animation.TYPE_ROTATION_3D \
			or track_type == Animation.TYPE_SCALE_3D


static func _native_available() -> bool:
	if not ClassDB.class_exists(NATIVE_CLASS):
		if not (OS.has_feature("windows") and OS.has_feature("x86_64") and OS.has_feature("debug")):
			return false
		if not FileAccess.file_exists(NATIVE_DESCRIPTOR):
			return false
		# Generated debug binaries are outside editor import. Loading by path
		# also works on a clean headless checkout with no extension-list cache.
		GDExtensionManager.load_extension(NATIVE_DESCRIPTOR)
	return ClassDB.class_exists(NATIVE_CLASS)
