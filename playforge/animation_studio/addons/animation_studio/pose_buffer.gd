extends RefCounted
## Lightweight local bone pose buffer for Animation Studio graph evaluation,
## inertial blending, masked slot layering, and rewind capture.

var bone_count: int = 0
var positions: PackedVector3Array = PackedVector3Array()
var rotations: Array[Quaternion] = []
var scales: PackedVector3Array = PackedVector3Array()


static func create_rest(skeleton: Skeleton3D) -> RefCounted:
	var buf := new()
	buf.resize_from_skeleton(skeleton)
	for i in buf.bone_count:
		var rest := skeleton.get_bone_rest(i)
		buf.positions[i] = rest.origin
		buf.rotations[i] = rest.basis.get_rotation_quaternion().normalized()
		buf.scales[i] = rest.basis.get_scale()
	return buf


static func capture_from_skeleton(skeleton: Skeleton3D) -> RefCounted:
	var buf := new()
	buf.resize_from_skeleton(skeleton)
	for i in buf.bone_count:
		buf.positions[i] = skeleton.get_bone_pose_position(i)
		buf.rotations[i] = skeleton.get_bone_pose_rotation(i).normalized()
		buf.scales[i] = skeleton.get_bone_pose_scale(i)
	return buf


static func build_branch_mask(skeleton: Skeleton3D, root_bone_name: StringName) -> PackedFloat32Array:
	var count := skeleton.get_bone_count()
	var mask := PackedFloat32Array()
	mask.resize(count)
	mask.fill(0.0)
	var root_idx := skeleton.find_bone(root_bone_name)
	if root_idx < 0:
		return mask
	mask[root_idx] = 1.0
	for i in count:
		var p := skeleton.get_bone_parent(i)
		while p >= 0:
			if p == root_idx:
				mask[i] = 1.0
				break
			p = skeleton.get_bone_parent(p)
	return mask


func resize_from_skeleton(skeleton: Skeleton3D) -> void:
	bone_count = skeleton.get_bone_count()
	positions.resize(bone_count)
	rotations.resize(bone_count)
	scales.resize(bone_count)
	for i in bone_count:
		positions[i] = Vector3.ZERO
		rotations[i] = Quaternion.IDENTITY
		scales[i] = Vector3.ONE


func duplicate_buffer() -> RefCounted:
	var copy: RefCounted = get_script().new()
	copy.bone_count = bone_count
	copy.positions = positions.duplicate()
	copy.rotations = rotations.duplicate()
	copy.scales = scales.duplicate()
	return copy


func sample_animation(animation: Animation, skeleton: Skeleton3D, time: float, backwards: bool = false, root_motion_bone: StringName = &"") -> void:
	resize_from_skeleton(skeleton)
	for i in bone_count:
		var rest := skeleton.get_bone_rest(i)
		positions[i] = rest.origin
		rotations[i] = rest.basis.get_rotation_quaternion().normalized()
		scales[i] = rest.basis.get_scale()
	if animation == null:
		return
	var motion_scale := skeleton.motion_scale
	for track_idx in animation.get_track_count():
		if not animation.track_is_enabled(track_idx):
			continue
		if animation.track_get_key_count(track_idx) == 0:
			continue
		var path := animation.track_get_path(track_idx)
		if path.get_subname_count() != 1:
			continue
		var bone_name := StringName(path.get_subname(0))
		if not root_motion_bone.is_empty() and bone_name == root_motion_bone:
			continue
		var bone_idx := skeleton.find_bone(bone_name)
		if bone_idx < 0:
			continue
		match animation.track_get_type(track_idx):
			Animation.TYPE_POSITION_3D:
				positions[bone_idx] = animation.position_track_interpolate(track_idx, time, backwards) * motion_scale
			Animation.TYPE_ROTATION_3D:
				rotations[bone_idx] = animation.rotation_track_interpolate(track_idx, time, backwards).normalized()
			Animation.TYPE_SCALE_3D:
				scales[bone_idx] = animation.scale_track_interpolate(track_idx, time, backwards)


func blend_masked(overlay: RefCounted, mask: PackedFloat32Array, weight: float) -> void:
	var w := clampf(weight, 0.0, 1.0)
	if w <= 0.0 or overlay == null or overlay.bone_count != bone_count:
		return
	for i in bone_count:
		var bw := w * (mask[i] if i < mask.size() else 0.0)
		if bw <= 0.0:
			continue
		positions[i] = positions[i].lerp(overlay.positions[i], bw)
		var q_from := rotations[i]
		var q_to: Quaternion = overlay.rotations[i]
		if q_from.dot(q_to) < 0.0:
			q_to = -q_to
		rotations[i] = q_from.slerp(q_to, bw).normalized()
		scales[i] = scales[i].lerp(overlay.scales[i], bw)


func apply_to_skeleton(skeleton: Skeleton3D) -> void:
	if not is_instance_valid(skeleton) or skeleton.get_bone_count() != bone_count:
		return
	for i in bone_count:
		skeleton.set_bone_pose_position(i, positions[i])
		skeleton.set_bone_pose_rotation(i, rotations[i])
		skeleton.set_bone_pose_scale(i, scales[i])


func max_diff(other: RefCounted, mask: PackedFloat32Array = PackedFloat32Array(), invert_mask: bool = false) -> Dictionary:
	var max_pos := 0.0
	var max_rot := 0.0
	var max_scale := 0.0
	if other == null or other.bone_count != bone_count:
		return {"max_pos_m": INF, "max_rot_rad": INF, "max_scale": INF}
	for i in bone_count:
		if not mask.is_empty():
			var included := mask[i] > 0.5
			if invert_mask:
				included = not included
			if not included:
				continue
		max_pos = maxf(max_pos, positions[i].distance_to(other.positions[i]))
		var d: Quaternion = rotations[i].normalized().inverse() * other.rotations[i].normalized()
		var angle := 2.0 * atan2(Vector3(d.x, d.y, d.z).length(), absf(d.w))
		max_rot = maxf(max_rot, angle)
		max_scale = maxf(max_scale, scales[i].distance_to(other.scales[i]))
	return {"max_pos_m": max_pos, "max_rot_rad": max_rot, "max_scale": max_scale}
