extends SkeletonModifier3D

var captured_hand_global := Transform3D.IDENTITY
var captured_upper_rotation := Quaternion.IDENTITY
var captured_lower_rotation := Quaternion.IDENTITY
var sample_count := 0


func _process_modification_with_delta(_delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton and skeleton.get_bone_count() > 3:
		captured_hand_global = skeleton.get_bone_global_pose(3)
		captured_upper_rotation = skeleton.get_bone_pose_rotation(1)
		captured_lower_rotation = skeleton.get_bone_pose_rotation(2)
		sample_count += 1
