extends SkeletonModifier3D
## Installs a PoseGraph as a SkeletonModifier3D so Skeleton3D executes it in
## modifier order and emits skeleton_updated immediately after pose evaluation.

const PoseGraph = preload("pose_graph.gd")

var graph: PoseGraph = null
var last_snapshot: Dictionary = {}


func _process_modification_with_delta(delta: float) -> void:
	if graph == null:
		return
	var skeleton := get_skeleton()
	if not is_instance_valid(skeleton):
		return
	last_snapshot = graph.evaluate(delta, skeleton)
