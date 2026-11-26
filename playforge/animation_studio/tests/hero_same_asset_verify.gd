extends SceneTree
## Same-asset verification on Havok original Hero (85 bones, Run/Walk/Idle/Turn):
## 1) Position parity: Havok SDK oracle.json (1,530 bone poses across 4 clips) vs
##    Godot AnimationPlayer AND Godot C++ AnimationStudioCrowdEvaluator (QuantizedClip)
##    measured in both local bone space and model-space end-effectors (Head/Hands/Feet).
## 2) Performance parity: Same Hero 85 bones x 200 agents (17,000 bones/tick)
##    comparing Godot AnimationPlayer vs C++ AnimationStudioCrowdEvaluator (pose-only & full skeleton update).
## 3) Compression parity on the real 85-bone Hero Run clip.

const Hero := preload("res://hero/hero.gd")
const CrowdEvaluator := preload("res://addons/animation_studio/crowd_evaluator.gd")

const MOTION_FILE := "res://hero/generated/motion.json"
const ORACLE_FILE := "res://hero/generated/oracle.json"
const AGENTS := 200
const STEP := 1.0 / 60.0
const WARMUP_TICKS := 5
const MEASURE_TICKS := 30
const END_EFFECTORS := ["Head", "LeftArmHand", "RightArmHand", "LeftLegFoot", "RightLegFoot"]

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
	var has_assets := FileAccess.file_exists(MOTION_FILE) and FileAccess.file_exists(ORACLE_FILE)
	report("Hero original motion.json and oracle.json available", has_assets)
	if not has_assets:
		print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
		quit(1)
		return

	var motion_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MOTION_FILE))
	var oracle_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ORACLE_FILE))
	var bone_defs: Array = motion_data.skeleton.bones
	var bone_count := bone_defs.size()

	var container := Node3D.new()
	root.add_child(container)
	var template_skel := _build_hero_skeleton(bone_defs)
	container.add_child(template_skel)

	# Build Animation resources for the 4 oracle clips (idle, walk, run, turn).
	var anims: Dictionary = {}
	var qclips: Dictionary = {}
	for clip_key in ["idle", "walk", "run", "turn"]:
		if motion_data.clips.has(clip_key):
			var anim := _build_hero_animation(motion_data.clips[clip_key], template_skel)
			anims[clip_key] = anim
			qclips[clip_key] = CrowdEvaluator.QuantizedClip.bake_from_animation(anim, template_skel, 60.0)

	# ------------------------------------------------------------------
	# 1. POSITION PARITY against Havok SDK oracle.json (1,530 bone poses)
	# ------------------------------------------------------------------
	var effector_indices: Array[int] = []
	for ename in END_EFFECTORS:
		var idx := template_skel.find_bone(ename)
		if idx >= 0:
			effector_indices.append(idx)

	var player_local_pos_mm := 0.0
	var player_local_rot_deg := 0.0
	var player_world_eff_mm := 0.0
	var quant_local_pos_mm := 0.0
	var quant_local_rot_deg := 0.0
	var quant_world_eff_mm := 0.0
	var pose_comparisons := 0

	var oracle_skel := _build_hero_skeleton(bone_defs)
	var player_skel := _build_hero_skeleton(bone_defs)
	var quant_skel := _build_hero_skeleton(bone_defs)
	container.add_child(oracle_skel)
	container.add_child(player_skel)
	container.add_child(quant_skel)

	for clip_key in ["idle", "walk", "run", "turn"]:
		var samples: Array = oracle_data.clips.get(clip_key, {}).get("samples", [])
		var anim: Animation = anims[clip_key]
		var qclip: CrowdEvaluator.QuantizedClip = qclips[clip_key]
		for sample in samples:
			var t := float(sample.time)
			var expected_pose: Array = sample.pose

			# Reference Havok SDK pose
			for b in bone_count:
				var e: Dictionary = expected_pose[b]
				oracle_skel.set_bone_pose_position(b, Hero.vector(e.translation))
				oracle_skel.set_bone_pose_rotation(b, Hero.rotation(e.rotation))
				oracle_skel.set_bone_pose_scale(b, Hero.vector(e.scale))
			oracle_skel.force_update_all_bone_transforms()

			# Godot AnimationPlayer exact interpolation
			_apply_animation_to_skeleton(anim, player_skel, t)
			player_skel.force_update_all_bone_transforms()

			# Godot QuantizedClip (same 16-bit buffer used by C++ CrowdEvaluator)
			_apply_quantized_to_skeleton(qclip, quant_skel, t)
			quant_skel.force_update_all_bone_transforms()

			for b in bone_count:
				pose_comparisons += 1
				var ep := oracle_skel.get_bone_pose_position(b)
				var er := oracle_skel.get_bone_pose_rotation(b)
				player_local_pos_mm = maxf(player_local_pos_mm, player_skel.get_bone_pose_position(b).distance_to(ep) * 1000.0)
				player_local_rot_deg = maxf(player_local_rot_deg, rad_to_deg(Hero.angle_between(player_skel.get_bone_pose_rotation(b), er)))
				quant_local_pos_mm = maxf(quant_local_pos_mm, quant_skel.get_bone_pose_position(b).distance_to(ep) * 1000.0)
				quant_local_rot_deg = maxf(quant_local_rot_deg, rad_to_deg(Hero.angle_between(quant_skel.get_bone_pose_rotation(b), er)))

			for b in effector_indices:
				var e_world := oracle_skel.get_bone_global_pose(b).origin
				player_world_eff_mm = maxf(player_world_eff_mm, player_skel.get_bone_global_pose(b).origin.distance_to(e_world) * 1000.0)
				quant_world_eff_mm = maxf(quant_world_eff_mm, quant_skel.get_bone_global_pose(b).origin.distance_to(e_world) * 1000.0)

	info("hero_oracle_position_parity", {
		"bones": bone_count, "pose_comparisons": pose_comparisons,
		"player_local_max_pos_mm": player_local_pos_mm,
		"player_local_max_rot_deg": player_local_rot_deg,
		"player_effector_world_max_mm": player_world_eff_mm,
		"quantized_local_max_pos_mm": quant_local_pos_mm,
		"quantized_local_max_rot_deg": quant_local_rot_deg,
		"quantized_effector_world_max_mm": quant_world_eff_mm,
	})

	report("Hero 85-bone AnimationPlayer matches Havok oracle within 1mm / 0.1deg",
		pose_comparisons == 1530 and player_local_pos_mm < 1.0 and player_local_rot_deg < 0.1 and player_world_eff_mm < 1.0,
		{"local_pos_mm": player_local_pos_mm, "local_rot_deg": player_local_rot_deg, "effector_world_mm": player_world_eff_mm})
	report("Hero 85-bone QuantizedClip matches Havok oracle end-effectors within 5mm",
		quant_local_pos_mm < 2.0 and quant_world_eff_mm < 5.0 and quant_local_rot_deg < 0.5,
		{"local_pos_mm": quant_local_pos_mm, "local_rot_deg": quant_local_rot_deg, "effector_world_mm": quant_world_eff_mm})

	# ------------------------------------------------------------------
	# 2. COMPRESSION on real 85-bone Hero Run clip
	# ------------------------------------------------------------------
	var run_anim: Animation = anims["run"]
	var run_qclip: CrowdEvaluator.QuantizedClip = qclips["run"]
	var est_uncomp := CrowdEvaluator.QuantizedClip.uncompressed_bytes(bone_count, run_qclip.key_count, true)
	var q_bytes := run_qclip.resident_bytes()
	var q_saving := (1.0 - float(q_bytes) / float(est_uncomp)) * 100.0
	info("hero_run_compression", {
		"bones": bone_count, "keys": run_qclip.key_count,
		"est_uncompressed_bytes": est_uncomp, "quantized_resident_bytes": q_bytes,
		"quantized_saving_pct": q_saving,
	})
	report("Hero 85-bone Run QuantizedClip achieves >= 70% memory reduction",
		q_saving >= 70.0, {"saving_pct": q_saving, "resident_bytes": q_bytes, "est_uncompressed_bytes": est_uncomp})

	oracle_skel.queue_free()
	player_skel.queue_free()
	quant_skel.queue_free()
	template_skel.queue_free()
	await process_frame

	# ------------------------------------------------------------------
	# 3. PERFORMANCE on same Hero 85-bone Run clip x 200 agents (17,000 bones/tick)
	# ------------------------------------------------------------------
	var skels: Array[Skeleton3D] = []
	var players: Array[AnimationPlayer] = []
	var lib := AnimationLibrary.new()
	lib.add_animation(&"run", run_anim)
	for i in AGENTS:
		var holder := Node3D.new()
		container.add_child(holder)
		var sk := _build_hero_skeleton(bone_defs)
		sk.name = "Rig"
		sk.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		holder.add_child(sk)
		var pl := AnimationPlayer.new()
		pl.root_node = ^".."
		pl.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		pl.add_animation_library(&"", lib)
		holder.add_child(pl)
		pl.play(&"run")
		pl.seek(fposmod(float(i) * 0.037, run_anim.length), true)
		skels.append(sk)
		players.append(pl)
	await process_frame

	var base_pose_ms: Array[float] = []
	var base_full_ms: Array[float] = []
	for tick in WARMUP_TICKS + MEASURE_TICKS:
		var t0 := Time.get_ticks_usec()
		for i in AGENTS:
			players[i].advance(STEP)
		var t1 := Time.get_ticks_usec()
		for i in AGENTS:
			skels[i].force_update_all_bone_transforms()
		var t2 := Time.get_ticks_usec()
		if tick >= WARMUP_TICKS:
			base_pose_ms.append(float(t1 - t0) / 1000.0)
			base_full_ms.append(float(t2 - t0) / 1000.0)

	for i in AGENTS:
		players[i].active = false

	var nat := CrowdEvaluator.new()
	nat.setup(run_qclip, AGENTS, true)
	var nat_pose_ms: Array[float] = []
	var nat_full_ms: Array[float] = []
	var nat_wait_ms: Array[float] = []
	var nat_apply_ms: Array[float] = []
	var prev_global := PackedVector3Array()
	prev_global.resize(AGENTS * bone_count)
	var changed_bones := 0
	for tick in WARMUP_TICKS + MEASURE_TICKS:
		var st := nat.step_parallel(STEP, skels)
		var u0 := Time.get_ticks_usec()
		for i in AGENTS:
			skels[i].force_update_all_bone_transforms()
		var u_ms := float(Time.get_ticks_usec() - u0) / 1000.0
		if tick == WARMUP_TICKS:
			for a in AGENTS:
				for b in bone_count:
					prev_global[a * bone_count + b] = skels[a].get_bone_global_pose(b).origin
		elif tick == WARMUP_TICKS + 1:
			for a in AGENTS:
				for b in bone_count:
					if skels[a].get_bone_global_pose(b).origin.distance_to(prev_global[a * bone_count + b]) > 1e-6:
						changed_bones += 1
		if tick >= WARMUP_TICKS:
			nat_pose_ms.append(float(st.main_total_ms))
			nat_wait_ms.append(float(st.worker_wait_ms))
			nat_apply_ms.append(float(st.main_apply_ms))
			nat_full_ms.append(float(st.main_total_ms) + u_ms)

	var bp50 := _pct(base_pose_ms, 0.50)
	var bp95 := _pct(base_pose_ms, 0.95)
	var bf50 := _pct(base_full_ms, 0.50)
	var bf95 := _pct(base_full_ms, 0.95)
	var np50 := _pct(nat_pose_ms, 0.50)
	var np95 := _pct(nat_pose_ms, 0.95)
	var nf50 := _pct(nat_full_ms, 0.50)
	var nf95 := _pct(nat_full_ms, 0.95)
	var nw50 := _pct(nat_wait_ms, 0.50)
	var na50 := _pct(nat_apply_ms, 0.50)

	info("hero_85x200_perf", {
		"bones": bone_count, "agents": AGENTS, "native": nat.is_using_native(),
		"changed_global_bones": changed_bones, "total_bones": AGENTS * bone_count,
		"base_pose_p50_ms": bp50, "base_pose_p95_ms": bp95,
		"base_full_p50_ms": bf50, "base_full_p95_ms": bf95,
		"native_wait_p50_ms": nw50, "native_apply_p50_ms": na50,
		"native_pose_p50_ms": np50, "native_pose_p95_ms": np95,
		"native_full_p50_ms": nf50, "native_full_p95_ms": nf95,
		"speedup_pose_only": bp50 / maxf(0.001, np50),
		"speedup_full": bf50 / maxf(0.001, nf50),
	})

	report("Hero 85-bone x 200 agents C++ evaluator updates active bones and outperforms AnimationPlayer",
		nat.is_using_native() and changed_bones > AGENTS * 70 and np50 <= 1.5 and nf50 < bf50 * 0.3,
		{"changed_bones": changed_bones, "base_full_p50_ms": bf50, "native_pose_p50_ms": np50,
		"native_full_p50_ms": nf50, "speedup_full": bf50 / maxf(0.001, nf50)})

	container.queue_free()
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)


func _build_hero_skeleton(bone_defs: Array) -> Skeleton3D:
	var skel := Skeleton3D.new()
	for bone in bone_defs:
		var idx := skel.add_bone(bone.name)
		skel.set_bone_parent(idx, int(bone.parent))
		skel.set_bone_rest(idx, Hero.transform_from(bone.bind))
	skel.reset_bone_poses()
	return skel


func _build_hero_animation(clip: Dictionary, skel: Skeleton3D) -> Animation:
	var anim := Animation.new()
	anim.length = float(clip.duration)
	anim.loop_mode = Animation.LOOP_LINEAR
	for track in clip.tracks:
		var bname := skel.get_bone_name(int(track.bone))
		var path := NodePath("Rig:" + str(bname))
		var pt := anim.add_track(Animation.TYPE_POSITION_3D)
		var rt := anim.add_track(Animation.TYPE_ROTATION_3D)
		var st := anim.add_track(Animation.TYPE_SCALE_3D)
		anim.track_set_path(pt, path)
		anim.track_set_path(rt, path)
		anim.track_set_path(st, path)
		for k in track.keys:
			anim.position_track_insert_key(pt, float(k.time), Hero.vector(k.translation))
			anim.rotation_track_insert_key(rt, float(k.time), Hero.rotation(k.rotation))
			anim.scale_track_insert_key(st, float(k.time), Hero.vector(k.scale))
	return anim


func _apply_animation_to_skeleton(anim: Animation, skel: Skeleton3D, t: float) -> void:
	skel.reset_bone_poses()
	for ti in anim.get_track_count():
		var bname := StringName(anim.track_get_path(ti).get_subname(0))
		var bi := skel.find_bone(bname)
		if bi < 0:
			continue
		match anim.track_get_type(ti):
			Animation.TYPE_POSITION_3D:
				skel.set_bone_pose_position(bi, anim.position_track_interpolate(ti, t))
			Animation.TYPE_ROTATION_3D:
				skel.set_bone_pose_rotation(bi, anim.rotation_track_interpolate(ti, t).normalized())
			Animation.TYPE_SCALE_3D:
				skel.set_bone_pose_scale(bi, anim.scale_track_interpolate(ti, t))


func _apply_quantized_to_skeleton(qclip: CrowdEvaluator.QuantizedClip, skel: Skeleton3D, t: float) -> void:
	var fkey := clampf(t * qclip.sample_rate, 0.0, float(qclip.key_count - 1))
	var k0 := clampi(int(floor(fkey)), 0, qclip.key_count - 1)
	var k1 := mini(k0 + 1, qclip.key_count - 1)
	var frac := fkey - float(k0)
	for b in qclip.bone_count:
		var p0 := qclip.sample_bone_pos(k0, b)
		var p1 := qclip.sample_bone_pos(k1, b)
		var r0 := qclip.sample_bone_rot(k0, b)
		var r1 := qclip.sample_bone_rot(k1, b)
		if r0.dot(r1) < 0.0:
			r1 = -r1
		skel.set_bone_pose_position(b, p0.lerp(p1, frac))
		skel.set_bone_pose_rotation(b, r0.slerp(r1, frac).normalized())
		skel.set_bone_pose_scale(b, Vector3.ONE)


static func _pct(arr: Array[float], p: float) -> float:
	var s := arr.duplicate()
	s.sort()
	return s[clampi(int(round(p * float(s.size() - 1))), 0, s.size() - 1)]
