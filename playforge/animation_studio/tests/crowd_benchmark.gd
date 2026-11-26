extends SceneTree
## Stage 3 benchmark: 65 bones x 200 characters (baseline AnimationPlayer vs
## WorkerThreadPool parallel quantized evaluator) + Animation.compress() &
## QuantizedClip memory / reconstruction error comparison.

const CrowdEvaluator = preload("res://addons/animation_studio/crowd_evaluator.gd")
const BONES := 65
const AGENTS := 200
const DURATION := 1.0
const STEP := 1.0 / 60.0
const WARMUP_TICKS := 5
const MEASURE_TICKS := 30

var failures := 0


func _initialize() -> void:
	run.call_deferred()


func report(label: String, valid: bool, details: Dictionary = {}) -> void:
	if not valid:
		failures += 1
	print("PFTEST ", JSON.stringify({"test": label, "status": "PASS" if valid else "FAIL", "detail": JSON.stringify(details)}))


func info(label: String, details: Dictionary) -> void:
	print("PFTEST ", JSON.stringify({"status": "INFO", "test": label, "data": details}))


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))

	var container := Node3D.new()
	root.add_child(container)

	var template_skel := _make_skeleton(BONES)
	container.add_child(template_skel)
	var raw_anim := _make_clip(BONES, DURATION)

	# 1. Compression memory & reconstruction error comparison.
	var compressed_anim := raw_anim.duplicate(true) as Animation
	compressed_anim.compress(8192, 60, 4.0)
	var qclip := CrowdEvaluator.QuantizedClip.bake_from_animation(raw_anim, template_skel, 60.0)

	var raw_file := "user://bench_raw.res"
	var cmp_file := "user://bench_cmp.res"
	ResourceSaver.save(raw_anim, raw_file)
	ResourceSaver.save(compressed_anim, cmp_file)
	var raw_disk_bytes := FileAccess.get_file_as_bytes(raw_file).size()
	var cmp_disk_bytes := FileAccess.get_file_as_bytes(cmp_file).size()
	var q_resident_bytes := qclip.resident_bytes()
	var est_uncompressed_bytes := CrowdEvaluator.QuantizedClip.uncompressed_bytes(BONES, qclip.key_count, true)

	var builtin_err := _measure_animation_error(raw_anim, compressed_anim, template_skel)
	var quant_err := _measure_quantized_error(raw_anim, qclip, template_skel)

	var builtin_saving_pct := (1.0 - float(cmp_disk_bytes) / maxf(1.0, float(raw_disk_bytes))) * 100.0
	var quant_saving_pct := (1.0 - float(q_resident_bytes) / maxf(1.0, float(est_uncompressed_bytes))) * 100.0

	info("clip_compression", {
		"bones": BONES, "keys": qclip.key_count,
		"raw_res_bytes": raw_disk_bytes,
		"builtin_compress_res_bytes": cmp_disk_bytes,
		"builtin_saving_pct": builtin_saving_pct,
		"builtin_max_pos_mm": builtin_err.max_pos_m * 1000.0,
		"builtin_max_rot_deg": rad_to_deg(builtin_err.max_rot_rad),
		"est_uncompressed_bytes": est_uncompressed_bytes,
		"quantized_resident_bytes": q_resident_bytes,
		"quantized_saving_pct": quant_saving_pct,
		"quantized_max_pos_mm": quant_err.max_pos_m * 1000.0,
		"quantized_max_rot_deg": rad_to_deg(quant_err.max_rot_rad),
	})

	report("Animation.compress reduces serialized size with bounded error",
		cmp_disk_bytes < raw_disk_bytes and builtin_err.max_pos_m < 0.005 and builtin_err.max_rot_rad < 0.02,
		{"saving_pct": builtin_saving_pct, "max_pos_mm": builtin_err.max_pos_m * 1000.0, "max_rot_deg": rad_to_deg(builtin_err.max_rot_rad)})
	report("QuantizedClip achieves >= 70% resident memory reduction with < 1mm / 0.1deg error",
		quant_saving_pct >= 70.0 and quant_err.max_pos_m < 0.001 and rad_to_deg(quant_err.max_rot_rad) < 0.1,
		{"saving_pct": quant_saving_pct, "max_pos_mm": quant_err.max_pos_m * 1000.0, "max_rot_deg": rad_to_deg(quant_err.max_rot_rad)})

	template_skel.queue_free()
	await process_frame

	# 2. Build 200 identical 65-bone characters for baseline vs parallel comparison.
	var skeletons: Array[Skeleton3D] = []
	var players: Array[AnimationPlayer] = []
	var lib := AnimationLibrary.new()
	lib.add_animation(&"move", raw_anim)
	for i in AGENTS:
		var rig := Node3D.new()
		container.add_child(rig)
		var skel := _make_skeleton(BONES)
		skel.name = "Rig"
		skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		rig.add_child(skel)
		var player := AnimationPlayer.new()
		player.root_node = ^".."
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		player.add_animation_library(&"", lib)
		rig.add_child(player)
		player.play(&"move")
		player.seek(fposmod(float(i) * 0.037, DURATION), true)
		skeletons.append(skel)
		players.append(player)

	await process_frame

	# Baseline: 200 AnimationPlayers advancing 65 bones each on main thread (pose-only and full skeleton update).
	var base_ms: Array[float] = []
	var base_full_ms: Array[float] = []
	for tick in WARMUP_TICKS + MEASURE_TICKS:
		var t0 := Time.get_ticks_usec()
		for i in AGENTS:
			players[i].advance(STEP)
		var t1 := Time.get_ticks_usec()
		for i in AGENTS:
			skeletons[i].force_update_all_bone_transforms()
		var t2 := Time.get_ticks_usec()
		if tick >= WARMUP_TICKS:
			base_ms.append(float(t1 - t0) / 1000.0)
			base_full_ms.append(float(t2 - t0) / 1000.0)

	# Disable AnimationPlayers so the extended path runs cleanly on the exact same 200 skeletons.
	for i in AGENTS:
		players[i].active = false

	# GDScript WorkerThreadPool path
	var gd_eval := CrowdEvaluator.new()
	gd_eval.setup(qclip, AGENTS, false)
	var gd_worker_cpu_ms: Array[float] = []
	var gd_worker_wait_ms: Array[float] = []
	var gd_main_apply_ms: Array[float] = []
	var gd_main_total_ms: Array[float] = []
	for tick in WARMUP_TICKS + MEASURE_TICKS:
		var stats := gd_eval.step_parallel(STEP, skeletons)
		if tick >= WARMUP_TICKS:
			gd_worker_cpu_ms.append(stats.worker_cpu_ms)
			gd_worker_wait_ms.append(stats.worker_wait_ms)
			gd_main_apply_ms.append(stats.main_apply_ms)
			gd_main_total_ms.append(stats.main_total_ms)

	# Snapshot GDScript final poses of sample agents for parity check against native C++.
	var gd_sample_pos: Array[Vector3] = []
	var gd_sample_rot: Array[Quaternion] = []
	for a in [0, 37, 199]:
		for b in BONES:
			gd_sample_pos.append(skeletons[a].get_bone_pose_position(b))
			gd_sample_rot.append(skeletons[a].get_bone_pose_rotation(b))

	var base_p50 := _percentile(base_ms, 0.50)
	var base_p95 := _percentile(base_ms, 0.95)
	var base_full_p50 := _percentile(base_full_ms, 0.50)
	var base_full_p95 := _percentile(base_full_ms, 0.95)
	var gd_w_cpu_p50 := _percentile(gd_worker_cpu_ms, 0.50)
	var gd_w_cpu_p95 := _percentile(gd_worker_cpu_ms, 0.95)
	var gd_w_wait_p50 := _percentile(gd_worker_wait_ms, 0.50)
	var gd_w_wait_p95 := _percentile(gd_worker_wait_ms, 0.95)
	var gd_m_apply_p50 := _percentile(gd_main_apply_ms, 0.50)
	var gd_m_apply_p95 := _percentile(gd_main_apply_ms, 0.95)
	var gd_m_total_p50 := _percentile(gd_main_total_ms, 0.50)
	var gd_m_total_p95 := _percentile(gd_main_total_ms, 0.95)

	var perf_info := {
		"bones": BONES, "agents": AGENTS, "measure_ticks": MEASURE_TICKS,
		"baseline_main_p50_ms": base_p50, "baseline_main_p95_ms": base_p95,
		"baseline_full_p50_ms": base_full_p50, "baseline_full_p95_ms": base_full_p95,
		"gd_worker_cpu_p50_ms": gd_w_cpu_p50, "gd_worker_cpu_p95_ms": gd_w_cpu_p95,
		"gd_worker_wait_p50_ms": gd_w_wait_p50, "gd_worker_wait_p95_ms": gd_w_wait_p95,
		"gd_main_apply_p50_ms": gd_m_apply_p50, "gd_main_apply_p95_ms": gd_m_apply_p95,
		"gd_main_total_p50_ms": gd_m_total_p50, "gd_main_total_p95_ms": gd_m_total_p95,
		"native_available": false,
	}

	# C++ GDExtension native worker pool path (when debug DLL is present).
	var native_eval := CrowdEvaluator.new()
	native_eval.setup(qclip, AGENTS, true)
	if native_eval.is_using_native():
		var nat_worker_cpu_ms: Array[float] = []
		var nat_worker_wait_ms: Array[float] = []
		var nat_main_apply_ms: Array[float] = []
		var nat_main_total_ms: Array[float] = []
		var nat_full_ms: Array[float] = []
		var nat_threads := 0
		var prev_global := PackedVector3Array()
		prev_global.resize(AGENTS * BONES)
		var changed_global_bones := 0
		for tick in WARMUP_TICKS + MEASURE_TICKS:
			var stats := native_eval.step_parallel(STEP, skeletons)
			var t_upd0 := Time.get_ticks_usec()
			for i in AGENTS:
				skeletons[i].force_update_all_bone_transforms()
			var upd_ms := float(Time.get_ticks_usec() - t_upd0) / 1000.0
			if tick == WARMUP_TICKS:
				for a in AGENTS:
					for b in BONES:
						prev_global[a * BONES + b] = skeletons[a].get_bone_global_pose(b).origin
			elif tick == WARMUP_TICKS + 1:
				for a in AGENTS:
					for b in BONES:
						if skeletons[a].get_bone_global_pose(b).origin.distance_to(prev_global[a * BONES + b]) > 1e-6:
							changed_global_bones += 1
			nat_threads = int(stats.get("threads", 0))
			if tick >= WARMUP_TICKS:
				nat_worker_cpu_ms.append(stats.worker_cpu_ms)
				nat_worker_wait_ms.append(stats.worker_wait_ms)
				nat_main_apply_ms.append(stats.main_apply_ms)
				nat_main_total_ms.append(stats.main_total_ms)
				nat_full_ms.append(float(stats.main_total_ms) + upd_ms)

		var max_pos_parity := 0.0
		var max_rot_parity := 0.0
		var sidx := 0
		for a in [0, 37, 199]:
			for b in BONES:
				max_pos_parity = maxf(max_pos_parity, skeletons[a].get_bone_pose_position(b).distance_to(gd_sample_pos[sidx]))
				var d := skeletons[a].get_bone_pose_rotation(b).normalized().inverse() * gd_sample_rot[sidx].normalized()
				max_rot_parity = maxf(max_rot_parity, 2.0 * atan2(Vector3(d.x, d.y, d.z).length(), absf(d.w)))
				sidx += 1

		var nat_w_cpu_p50 := _percentile(nat_worker_cpu_ms, 0.50)
		var nat_w_cpu_p95 := _percentile(nat_worker_cpu_ms, 0.95)
		var nat_w_wait_p50 := _percentile(nat_worker_wait_ms, 0.50)
		var nat_w_wait_p95 := _percentile(nat_worker_wait_ms, 0.95)
		var nat_m_apply_p50 := _percentile(nat_main_apply_ms, 0.50)
		var nat_m_apply_p95 := _percentile(nat_main_apply_ms, 0.95)
		var nat_m_total_p50 := _percentile(nat_main_total_ms, 0.50)
		var nat_m_total_p95 := _percentile(nat_main_total_ms, 0.95)
		var nat_full_p50 := _percentile(nat_full_ms, 0.50)
		var nat_full_p95 := _percentile(nat_full_ms, 0.95)

		perf_info["native_available"] = true
		perf_info["native_threads"] = nat_threads
		perf_info["native_changed_global_bones"] = changed_global_bones
		perf_info["native_worker_cpu_p50_ms"] = nat_w_cpu_p50
		perf_info["native_worker_cpu_p95_ms"] = nat_w_cpu_p95
		perf_info["native_worker_wait_p50_ms"] = nat_w_wait_p50
		perf_info["native_worker_wait_p95_ms"] = nat_w_wait_p95
		perf_info["native_main_apply_p50_ms"] = nat_m_apply_p50
		perf_info["native_main_apply_p95_ms"] = nat_m_apply_p95
		perf_info["native_main_total_p50_ms"] = nat_m_total_p50
		perf_info["native_main_total_p95_ms"] = nat_m_total_p95
		perf_info["native_full_p50_ms"] = nat_full_p50
		perf_info["native_full_p95_ms"] = nat_full_p95
		perf_info["speedup_pose_only"] = base_p50 / maxf(0.001, nat_m_total_p50)
		perf_info["speedup_full_with_skeleton_update"] = base_full_p50 / maxf(0.001, nat_full_p50)
		perf_info["meets_1_5ms_target"] = nat_m_total_p50 <= 1.5
		perf_info["native_vs_gd_max_pos_mm"] = max_pos_parity * 1000.0
		perf_info["native_vs_gd_max_rot_deg"] = rad_to_deg(max_rot_parity)

		report("native C++ crowd evaluator updates all 13,000 bones and matches GDScript within 0.01mm / 0.01deg",
			changed_global_bones == AGENTS * BONES and max_pos_parity < 0.00001 and rad_to_deg(max_rot_parity) < 0.01,
			{"changed_bones": changed_global_bones, "max_pos_mm": max_pos_parity * 1000.0, "max_rot_deg": rad_to_deg(max_rot_parity)})
		report("native C++ 65x200 crowd meets <= 1.5 ms pose-eval/apply p50 and speeds up full skeleton update",
			nat_m_total_p50 <= 1.5 and nat_full_p50 < base_full_p50 * 0.25,
			{"native_main_p50_ms": nat_m_total_p50, "native_full_p50_ms": nat_full_p50,
			"base_full_p50_ms": base_full_p50, "speedup_full": perf_info["speedup_full_with_skeleton_update"], "threads": nat_threads})

	info("crowd_65x200_perf", perf_info)

	report("65 bones x 200 agents baseline and parallel paths both measured cleanly",
		base_p50 > 0.0 and gd_m_total_p50 > 0.0 and gd_m_apply_p50 > 0.0,
		{"baseline_p50_ms": base_p50, "gd_main_p50_ms": gd_m_total_p50, "gd_main_apply_p50_ms": gd_m_apply_p50})

	container.queue_free()
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)


func _make_skeleton(bone_count: int) -> Skeleton3D:
	var skel := Skeleton3D.new()
	for i in bone_count:
		skel.add_bone("Bone_%02d" % i)
		if i > 0:
			skel.set_bone_parent(i, (i - 1) / 3)
		skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.08, 0.0)))
	skel.reset_bone_poses()
	return skel


func _make_clip(bone_count: int, duration: float) -> Animation:
	var anim := Animation.new()
	anim.length = duration
	anim.step = STEP
	anim.loop_mode = Animation.LOOP_LINEAR
	var key_count := 31
	for b in bone_count:
		var path := NodePath("Rig:Bone_%02d" % b)
		var pt := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(pt, path)
		var rt := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(rt, path)
		var phase := float(b) * 0.17
		for k in key_count:
			var t := duration * float(k) / float(key_count - 1)
			var s := sin(t * TAU + phase)
			anim.position_track_insert_key(pt, t, Vector3(0.02 * s, 0.08 + 0.01 * cos(t * TAU + phase), 0.0))
			anim.rotation_track_insert_key(rt, t, Quaternion(Vector3.FORWARD, 0.35 * s))
	return anim


func _measure_animation_error(raw: Animation, cmp: Animation, skel: Skeleton3D) -> Dictionary:
	var max_pos := 0.0
	var max_rot := 0.0
	for s in 11:
		var t := raw.length * float(s) / 10.0
		for ti in raw.get_track_count():
			match raw.track_get_type(ti):
				Animation.TYPE_POSITION_3D:
					max_pos = maxf(max_pos, raw.position_track_interpolate(ti, t).distance_to(cmp.position_track_interpolate(ti, t)))
				Animation.TYPE_ROTATION_3D:
					var qa := raw.rotation_track_interpolate(ti, t).normalized()
					var qb := cmp.rotation_track_interpolate(ti, t).normalized()
					var d := qa.inverse() * qb
					max_rot = maxf(max_rot, 2.0 * atan2(Vector3(d.x, d.y, d.z).length(), absf(d.w)))
	return {"max_pos_m": max_pos, "max_rot_rad": max_rot}


func _measure_quantized_error(raw: Animation, qclip: CrowdEvaluator.QuantizedClip, skel: Skeleton3D) -> Dictionary:
	var max_pos := 0.0
	var max_rot := 0.0
	for k in [0, 7, 15, 29, 45, 60]:
		var idx := mini(k, qclip.key_count - 1)
		var t := minf(raw.length, float(idx) / qclip.sample_rate)
		for b in qclip.bone_count:
			var pt := b * 2
			var rt := b * 2 + 1
			var rp := raw.position_track_interpolate(pt, t) * skel.motion_scale
			var rr := raw.rotation_track_interpolate(rt, t).normalized()
			var qp := qclip.sample_bone_pos(idx, b)
			var qr := qclip.sample_bone_rot(idx, b)
			max_pos = maxf(max_pos, rp.distance_to(qp))
			var d := rr.inverse() * qr
			max_rot = maxf(max_rot, 2.0 * atan2(Vector3(d.x, d.y, d.z).length(), absf(d.w)))
	return {"max_pos_m": max_pos, "max_rot_rad": max_rot}


static func _percentile(values: Array[float], p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var idx := clampi(int(round(p * float(sorted.size() - 1))), 0, sorted.size() - 1)
	return sorted[idx]
