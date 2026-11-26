extends RefCounted
## Fixed-capacity ring buffer that captures final Skeleton3D poses inside
## the skeleton_updated signal for deterministic Rewind scrubbing.

const PoseBuffer = preload("pose_buffer.gd")

var capacity: int = 300
var _frames: Array[Dictionary] = []
var _write_index: int = 0
var _count: int = 0
var _total_recorded: int = 0
var _skeleton: Skeleton3D
var _root_node: Node3D
var _pending_meta: Dictionary = {}
var _has_pending := false
var _scrubbing := false


func _init(p_capacity: int = 300) -> void:
	capacity = maxi(1, p_capacity)
	_frames.resize(capacity)


func attach(skeleton: Skeleton3D, root_node: Node3D = null) -> void:
	detach()
	_skeleton = skeleton
	_root_node = root_node
	if is_instance_valid(_skeleton) and not _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.connect(_on_skeleton_updated)


func detach() -> void:
	if is_instance_valid(_skeleton) and _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.disconnect(_on_skeleton_updated)
	_skeleton = null
	_root_node = null


func clear() -> void:
	_write_index = 0
	_count = 0
	_total_recorded = 0
	_has_pending = false
	_pending_meta = {}


func queue_metadata(meta: Dictionary) -> void:
	_pending_meta = meta.duplicate(true)
	_has_pending = true


func get_frame_count() -> int:
	return _count


func get_total_recorded() -> int:
	return _total_recorded


func get_frame(logical_index: int) -> Dictionary:
	if logical_index < 0 or logical_index >= _count:
		return {}
	var start := (_write_index - _count + capacity) % capacity
	return _frames[(start + logical_index) % capacity]


func apply_frame(logical_index: int, skeleton: Skeleton3D = null, root_node: Node3D = null) -> Dictionary:
	var frame := get_frame(logical_index)
	if frame.is_empty():
		return {}
	var target_skel := skeleton if is_instance_valid(skeleton) else _skeleton
	var target_root := root_node if is_instance_valid(root_node) else _root_node
	_scrubbing = true
	if is_instance_valid(target_root) and frame.has("root_transform"):
		target_root.transform = frame.root_transform
	if is_instance_valid(target_skel) and frame.has("pose"):
		var pose: PoseBuffer = frame.pose
		pose.apply_to_skeleton(target_skel)
		target_skel.force_update_all_bone_transforms()
	_scrubbing = false
	return frame


func _on_skeleton_updated() -> void:
	if _scrubbing or not is_instance_valid(_skeleton):
		return
	var entry := {
		"index": _total_recorded,
		"pose": PoseBuffer.capture_from_skeleton(_skeleton),
		"root_transform": _root_node.transform if is_instance_valid(_root_node) else Transform3D.IDENTITY,
		"meta": _pending_meta.duplicate(true) if _has_pending else {},
	}
	_frames[_write_index] = entry
	_write_index = (_write_index + 1) % capacity
	_count = mini(_count + 1, capacity)
	_total_recorded += 1
	_has_pending = false
