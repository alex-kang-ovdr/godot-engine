extends SkeletonModifier3D

var captured_position := Vector3.ZERO
var captured_rotation := Quaternion.IDENTITY
var sample_count := 0


func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton and skeleton.get_bone_count() > 1:
		captured_position = skeleton.get_bone_pose_position(1)
		captured_rotation = skeleton.get_bone_pose_rotation(1)
		sample_count += 1
