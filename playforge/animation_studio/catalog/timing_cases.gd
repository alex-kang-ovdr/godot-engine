extends Node3D
## Compression timing benchmark using the original Havok SDK 38-bone Firefighter
## asset (walk/run clips, LOOP_LINEAR) across 12 independent WorkerThreadPool lanes.

const Standards := preload("res://catalog/havok_demo_standards.gd")

const LANES := 12
var clips: Array[Animation] = []
var secondary_clips: Array[Animation] = []
var poses: Array[Quaternion] = []
var display := MultiMesh.new()
var _hero_pack: Dictionary = {}
var _sample_track := 0
var _clip_len := 1.0
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
	var spec := Standards.resolve_demo_spec(path, case_name)
	var cid := str(spec.get("primary_char", "firefighter"))

	# Live internalized Firefighter rig standing on Y=0 facing Godot Standard -Z
	_hero_pack = Standards.spawn_aligned_character(cid, "TimingsFirefighter", Animation.LOOP_LINEAR)
	var outer: Node3D = _hero_pack["outer"] as Node3D
	outer.position = Vector3(0.0, 0.0, -1.35)
	add_child(outer)
	var player: AnimationPlayer = _hero_pack["player"] as AnimationPlayer
	var primary_key := Standards.pick_clip(_hero_pack, str(spec.get("primary_clip", "walk")))
	var secondary_key := Standards.pick_clip(_hero_pack, str(spec.get("secondary_clip", "run")))
	player.play(StringName(primary_key))

	var ref_a := player.get_animation(StringName(primary_key)).duplicate(true) as Animation
	var ref_b := player.get_animation(StringName(secondary_key)).duplicate(true) as Animation
	_clip_len = maxf(0.1, ref_a.length)
	_sample_track = _find_rotation_track(ref_a)
	if compressed:
		ref_a.compress(16384, 60, 0.5)
		ref_b.compress(16384, 60, 0.5)
		compressed = ref_a.track_is_compressed(_sample_track)

	poses.resize(LANES)
	clips.clear()
	secondary_clips.clear()
	for i in LANES:
		clips.append(ref_a.duplicate() as Animation)
		secondary_clips.append(ref_b.duplicate() as Animation)

	var bar := BoxMesh.new()
	bar.size = Vector3(0.14, 0.72, 0.14)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#f6ae54") if blend else Color("#4ecbb8")
	bar.material = mat
	display.transform_format = MultiMesh.TRANSFORM_3D
	display.mesh = bar
	display.instance_count = LANES
	var view := MultiMeshInstance3D.new()
	view.multimesh = display
	add_child(view)


func _find_rotation_track(anim: Animation) -> int:
	for idx in anim.get_track_count():
		if anim.track_get_type(idx) == Animation.TYPE_ROTATION_3D:
			var p := str(anim.track_get_path(idx)).to_lower()
			if "spine" in p or "shoulder" in p:
				return idx
	for idx in anim.get_track_count():
		if anim.track_get_type(idx) == Animation.TYPE_ROTATION_3D:
			return idx
	return 0


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
		var pivot := Vector3((i % 4 - 1.5) * 0.85, 0.45, (floori(i / 4.0) - 1.0) * 0.65 + 0.9)
		var basis := Basis(poses[i])
		display.set_instance_transform(i, Transform3D(basis, pivot + basis.y * 0.36))


func _sample(i: int) -> void:
	var t := fposmod(clock + i * (_clip_len / float(LANES)), _clip_len)
	var rot := clips[i].rotation_track_interpolate(_sample_track, t).normalized()
	if blend:
		var len_b := maxf(0.1, secondary_clips[i].length)
		var tb := fposmod(t + 0.25, len_b)
		var track_b := mini(_sample_track, secondary_clips[i].get_track_count() - 1)
		if secondary_clips[i].track_get_type(track_b) == Animation.TYPE_ROTATION_3D:
			var rot_b := secondary_clips[i].rotation_track_interpolate(track_b, tb).normalized()
			rot = rot.slerp(rot_b, 0.5).normalized()
	poses[i] = rot


func status_text() -> String:
	return "%s [firefighter 38b] · %s · %s · 최근 평가 %d µs · 누적 %d 샘플" % [
		"워커" if threaded else "단일 스레드", "샘플 + 블렌드" if blend else "단일 샘플",
		"Godot 내장 압축" if compressed else "비압축", elapsed_us, evaluations]
