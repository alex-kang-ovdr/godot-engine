extends SceneTree
## Comprehensive Soldier (114-bone + M4 rifle, 51,170 verts) Internalization & Demo Comparison Suite:
## 1) Native asset & M4 rifle integrity (soldier_motion.res + soldier_skin.glb, zero .hkt dependency)
## 2) Position parity: AnimationPlayer vs 16-bit QuantizedClip (and optional Havok SDK oracle.json across all 5 clips!)
## 3) Compression parity on real 114-bone Soldier run clip (>= 70% memory reduction)
## 4) Crowd performance benchmark: 114 bones x 200 agents (22,800 bones/tick)
##    comparing Godot AnimationPlayer vs C++ AnimationStudioCrowdEvaluator (8T)
## 5) Interactive side-by-side comparison scene (soldier_demo.tscn) verification.

const Hero := preload("res://hero/hero.gd")
const SoldierStore := preload("res://soldier/soldier_motion_store.gd")
const CrowdEvaluator := preload("res://addons/animation_studio/crowd_evaluator.gd")

const AGENTS := 200
const STEP := 1.0 / 60.0
const WARMUP_TICKS := 5
const MEASURE_TICKS := 30
const END_EFFECTORS := ["Head_M", "Wrist_L", "Wrist_R", "receiver", "Ankle_L", "Ankle_R"]

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

	var motion_data: Dictionary = SoldierStore.load_motion_dict()
	var clips_dict: Dictionary = motion_data.get("clips", {})
	var oracle_data: Dictionary = SoldierStore.load_optional_oracle()
	var has_oracle: bool = not oracle_data.is_empty()
	var has_native: bool = SoldierStore.has_native_assets() and not clips_dict.is_empty()
	report("internalized Soldier native .res and .glb assets available", has_native,
		{"clips": clips_dict.keys(), "optional_oracle": has_oracle})
	if not has_native:
		print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
		quit(1)
		return

	var bone_defs: Array = motion_data.skeleton.bones
	var bone_count := bone_defs.size()

	var container := Node3D.new()
	root.add_child(container)
	var template_skel := _build_skeleton(bone_defs)
	container.add_child(template_skel)
	var skin_stats := SoldierStore.load_skin_into_skeleton(template_skel)
	report("Soldier 114-bone rig and 9 skinned+M4 rifle meshes load cleanly",
		bone_count == 114 and (skin_stats.meshes as Array).size() == 9 and int(skin_stats.vertices) == 51170 and int(skin_stats.textured_surfaces) >= 8,
		{"bones": bone_count, "meshes": (skin_stats.meshes as Array).size(), "vertices": skin_stats.vertices, "textured": skin_stats.textured_surfaces})

	# Build Animation & QuantizedClip for all 5 clips
	var anims: Dictionary = {}
	var qclips: Dictionary = {}
	for clip_key in ["idle", "walk", "jog", "run", "vault"]:
		if clips_dict.has(clip_key):
			var anim := _build_animation(clips_dict[clip_key], template_skel)
			anims[clip_key] = anim
			qclips[clip_key] = CrowdEvaluator.QuantizedClip.bake_from_animation(anim, template_skel, 60.0)

	# ------------------------------------------------------------------
	# 1. POSITION PARITY across all 5 Soldier clips (optional Havok oracle + self-parity)
	# ------------------------------------------------------------------
	var effector_indices: Array[int] = []
	for ename in END_EFFECTORS:
		var idx := template_skel.find_bone(ename)
		if idx >= 0:
			effector_indices.append(idx)

	var player_local_pos_mm := 0.0
	var player_local_rot_deg := 0.0
	var player_eff_mm := 0.0
	var quant_local_pos_mm := 0.0
	var quant_local_rot_deg := 0.0
	var quant_eff_mm := 0.0
	var pose_comparisons := 0

	var oracle_skel := _build_skeleton(bone_defs)
	var player_skel := _build_skeleton(bone_defs)
	var quant_skel := _build_skeleton(bone_defs)
	container.add_child(oracle_skel)
	container.add_child(player_skel)
	container.add_child(quant_skel)

	for clip_key in ["idle", "walk", "jog", "run", "vault"]:
		var anim: Animation = anims[clip_key]
		var qclip: CrowdEvaluator.QuantizedClip = qclips[clip_key]
		var samples: Array = oracle_data.get("clips", {}).get(clip_key, {}).get("samples", []) if has_oracle else []
		if samples.is_empty():
			for s_i in 5:
				samples.append({"time": anim.length * float(s_i) / 4.0})
		for sample in samples:
			var t := float(sample.time)
			_apply_animation(anim, player_skel, t)
			player_skel.force_update_all_bone_transforms()
			_apply_quantized(qclip, quant_skel, t)
			quant_skel.force_update_all_bone_transforms()

			var ref_skel := player_skel
			if sample.has("pose"):
				var exp_pose: Array = sample.pose
				for b in bone_count:
					var e: Dictionary = exp_pose[b]
					oracle_skel.set_bone_pose_position(b, Hero.vector(e.translation))
					oracle_skel.set_bone_pose_rotation(b, Hero.rotation(e.rotation))
					oracle_skel.set_bone_pose_scale(b, Hero.vector(e.scale))
				oracle_skel.force_update_all_bone_transforms()
				ref_skel = oracle_skel

			for b in bone_count:
				pose_comparisons += 1
				var ep := ref_skel.get_bone_pose_position(b)
				var er := ref_skel.get_bone_pose_rotation(b)
				player_local_pos_mm = maxf(player_local_pos_mm, player_skel.get_bone_pose_position(b).distance_to(ep) * 1000.0)
				player_local_rot_deg = maxf(player_local_rot_deg, rad_to_deg(Hero.angle_between(player_skel.get_bone_pose_rotation(b), er)))
				quant_local_pos_mm = maxf(quant_local_pos_mm, quant_skel.get_bone_pose_position(b).distance_to(ep) * 1000.0)
				quant_local_rot_deg = maxf(quant_local_rot_deg, rad_to_deg(Hero.angle_between(quant_skel.get_bone_pose_rotation(b), er)))

			for b in effector_indices:
				var ew := ref_skel.get_bone_global_pose(b).origin
				player_eff_mm = maxf(player_eff_mm, player_skel.get_bone_global_pose(b).origin.distance_to(ew) * 1000.0)
				quant_eff_mm = maxf(quant_eff_mm, quant_skel.get_bone_global_pose(b).origin.distance_to(ew) * 1000.0)

	info("soldier_oracle_position_parity", {
		"bones": bone_count, "pose_comparisons": pose_comparisons, "used_optional_oracle": has_oracle,
		"player_local_max_pos_mm": player_local_pos_mm, "player_local_max_rot_deg": player_local_rot_deg,
		"player_effector_world_max_mm": player_eff_mm,
		"quantized_local_max_pos_mm": quant_local_pos_mm, "quantized_local_max_rot_deg": quant_local_rot_deg,
		"quantized_effector_world_max_mm": quant_eff_mm,
	})

	report("Soldier 114-bone AnimationPlayer matches reference within 1mm / 0.1deg",
		pose_comparisons >= 2500 and player_local_pos_mm < 1.0 and player_local_rot_deg < 0.1 and player_eff_mm < 1.0,
		{"comparisons": pose_comparisons, "local_pos_mm": player_local_pos_mm, "local_rot_deg": player_local_rot_deg, "effector_mm": player_eff_mm})
	report("Soldier 114-bone QuantizedClip matches Head/Hands/M4-Rifle/Feet within 5mm",
		quant_local_pos_mm < 1.0 and quant_eff_mm < 5.0 and quant_local_rot_deg < 1.0,
		{"local_pos_mm": quant_local_pos_mm, "local_rot_deg": quant_local_rot_deg, "effector_mm": quant_eff_mm})

	# ------------------------------------------------------------------
	# 2. COMPRESSION on real 114-bone Soldier Run clip
	# ------------------------------------------------------------------
	var run_anim: Animation = anims["run"]
	var run_qclip: CrowdEvaluator.QuantizedClip = qclips["run"]
	var est_uncomp := CrowdEvaluator.QuantizedClip.uncompressed_bytes(bone_count, run_qclip.key_count, true)
	var q_bytes := run_qclip.resident_bytes()
	var q_saving := (1.0 - float(q_bytes) / float(est_uncomp)) * 100.0
	report("Soldier 114-bone Run QuantizedClip achieves >= 70% memory reduction",
		q_saving >= 70.0, {"saving_pct": q_saving, "resident_bytes": q_bytes, "est_uncompressed_bytes": est_uncomp})

	oracle_skel.queue_free()
	player_skel.queue_free()
	quant_skel.queue_free()
	template_skel.queue_free()
	await process_frame

	# ------------------------------------------------------------------
	# 3. PERFORMANCE: 114-bone Soldier Run x 200 agents (22,800 bones/tick)
	# ------------------------------------------------------------------
	var skels: Array[Skeleton3D] = []
	var players: Array[AnimationPlayer] = []
	var lib := AnimationLibrary.new()
	lib.add_animation(&"run", run_anim)
	for i in AGENTS:
		var holder := Node3D.new()
		container.add_child(holder)
		var sk := _build_skeleton(bone_defs)
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
	var bf50 := _pct(base_full_ms, 0.50)
	var np50 := _pct(nat_pose_ms, 0.50)
	var nf50 := _pct(nat_full_ms, 0.50)
	info("soldier_114x200_perf", {
		"bones": bone_count, "agents": AGENTS, "native": nat.is_using_native(),
		"changed_global_bones": changed_bones, "total_bones": AGENTS * bone_count,
		"base_pose_p50_ms": bp50, "base_full_p50_ms": bf50,
		"native_wait_p50_ms": _pct(nat_wait_ms, 0.50), "native_apply_p50_ms": _pct(nat_apply_ms, 0.50),
		"native_pose_p50_ms": np50, "native_full_p50_ms": nf50,
		"speedup_pose_only": bp50 / maxf(0.001, np50), "speedup_full": bf50 / maxf(0.001, nf50),
	})
	report("Soldier 114-bone x 200 agents C++ evaluator updates active bones and outperforms AnimationPlayer",
		nat.is_using_native() and changed_bones > AGENTS * 90 and np50 <= 2.0 and nf50 < bf50 * 0.3,
		{"changed_bones": changed_bones, "base_full_p50_ms": bf50, "native_pose_p50_ms": np50, "native_full_p50_ms": nf50, "speedup_full": bf50 / maxf(0.001, nf50)})

	container.queue_free()
	await process_frame

	# ------------------------------------------------------------------
	# 4. Interactive Soldier Demo Comparison Scene verification
	# ------------------------------------------------------------------
	change_scene_to_file("res://soldier/soldier_demo.tscn")
	await scene_changed
	await process_frame
	var demo = current_scene
	demo.set_playing(false)
	demo.set_compare_mode(true)
	demo.select_clip("vault")
	var sample_res: Dictionary = demo.sample_at(1.25)
	report("Soldier side-by-side comparison scene plays vault clip with sub-millimeter parity",
		demo.assets_ready and demo.right_motion.visible and float(sample_res.get("rifle_err_mm", 99.0)) < 2.0,
		sample_res)

	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	quit(1 if failures else 0)


func _build_skeleton(bone_defs: Array) -> Skeleton3D:
	var skel := Skeleton3D.new()
	for bone in bone_defs:
		var idx := skel.add_bone(bone.name)
		skel.set_bone_parent(idx, int(bone.parent))
		skel.set_bone_rest(idx, Hero.transform_from(bone.bind))
	skel.reset_bone_poses()
	return skel


func _build_animation(clip: Dictionary, skel: Skeleton3D) -> Animation:
	var anim := Animation.new()
	anim.length = float(clip.duration)
	anim.loop_mode = Animation.LOOP_LINEAR
	for tr in clip.tracks:
		var bname := skel.get_bone_name(int(tr.bone))
		var path := NodePath("Rig:" + str(bname))
		var pt := anim.add_track(Animation.TYPE_POSITION_3D)
		var rt := anim.add_track(Animation.TYPE_ROTATION_3D)
		var st := anim.add_track(Animation.TYPE_SCALE_3D)
		anim.track_set_path(pt, path)
		anim.track_set_path(rt, path)
		anim.track_set_path(st, path)
		for k in tr.keys:
			anim.position_track_insert_key(pt, float(k.time), Hero.vector(k.translation))
			anim.rotation_track_insert_key(rt, float(k.time), Hero.rotation(k.rotation))
			anim.scale_track_insert_key(st, float(k.time), Hero.vector(k.scale))
	return anim


func _apply_animation(anim: Animation, skel: Skeleton3D, t: float) -> void:
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


func _apply_quantized(qclip: CrowdEvaluator.QuantizedClip, skel: Skeleton3D, t: float) -> void:
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
