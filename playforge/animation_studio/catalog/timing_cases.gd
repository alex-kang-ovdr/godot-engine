extends Node3D
## Local benchmark for the sample-only and sample-and-blend timing suites.
## Keep a separate, read-only clip per lane during threaded evaluation.

const LANES := 12
var clips: Array[Animation] = []
var poses: Array[Quaternion] = []
var display := MultiMesh.new()
var clock := 0.0
var threaded := false
var blend := false
var compressed := false
var elapsed_us := 0
var evaluations := 0


func start_case(path: String, case_name: String) -> void:
	threaded = "multi-thread" in case_name.to_lower()
	blend = "sampleandblend" in path.to_lower()
	compressed = not "uncompressed" in case_name.to_lower()
	var reference := Animation.new()
	reference.length = 1.0
	var track := reference.add_track(Animation.TYPE_ROTATION_3D)
	reference.track_set_path(track, ^"Rig:Arm")
	for i in 33:
		var t := i / 32.0
		reference.rotation_track_insert_key(track, t, Quaternion(Vector3.FORWARD, sin(t * TAU) * 1.15))
	if compressed:
		reference.compress()
		compressed = reference.track_is_compressed(track)
	poses.resize(LANES)
	for i in LANES:
		clips.append(reference.duplicate() as Animation)
	var bar := BoxMesh.new()
	bar.size = Vector3(0.14, 0.75, 0.14)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#f6ae54") if blend else Color("#4ecbb8")
	bar.material = mat
	display.transform_format = MultiMesh.TRANSFORM_3D
	display.mesh = bar
	display.instance_count = LANES
	var view := MultiMeshInstance3D.new()
	view.multimesh = display
	add_child(view)


func _physics_process(delta: float) -> void:
	clock += delta
	var start := Time.get_ticks_usec()
	if threaded:
		var task := WorkerThreadPool.add_group_task(_sample, LANES)
		WorkerThreadPool.wait_for_group_task_completion(task)
	else:
		for i in LANES:
			_sample(i)
	elapsed_us = Time.get_ticks_usec() - start
	evaluations += LANES * (2 if blend else 1)
	for i in LANES:
		var pivot := Vector3((i % 4 - 1.5) * 0.85, 0.65, (floori(i / 4.0) - 1.0) * 0.65)
		var basis := Basis(poses[i])
		display.set_instance_transform(i, Transform3D(basis, pivot + basis.y * 0.375))


func _sample(i: int) -> void:
	var t := fposmod(clock + i / float(LANES), 1.0)
	var rotation := clips[i].rotation_track_interpolate(0, t)
	if blend:
		var offset := clips[i].rotation_track_interpolate(0, fposmod(t + 0.25, 1.0))
		rotation = rotation.slerp(offset, 0.5)
	poses[i] = rotation


func status_text() -> String:
	return "%s · %s · %s · 최근 평가 %d µs · 누적 %d 샘플" % [
		"워커" if threaded else "단일 스레드", "샘플 + 블렌드" if blend else "단일 샘플",
		"Godot 내장 압축" if compressed else "비압축", elapsed_us, evaluations]
