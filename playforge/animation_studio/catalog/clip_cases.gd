extends Node3D
## Executable Animation catalog probes using internalized original Havok SDK
## characters (HavokGirl 50-bone SDK rig & clips) aligned to Godot Standard
## coordinates (-Z forward, +Y up, SI meters, Havok LOOP_LINEAR default).

const Standards := preload("res://catalog/havok_demo_standards.gd")

class StepEmitter extends Node:
	signal stepped(side: String)
	func emit_step(side: String) -> void:
		stepped.emit(side)

var _case_id := ""
var _spec: Dictionary = {}
var _status := "Choose an animation case."
var _elapsed := 0.0
var _actors: Array[Dictionary] = []
var _players: Array[AnimationPlayer] = []
var _trees: Array[AnimationTree] = []
var _blend_node: AnimationNode = null
var _blend_parameter := ""
var _step_count := 0
var _compression_error := -1.0
var _runtime_binding_target: Node3D
var _float_track_target: Node3D


func start_case(path: String, case_name: String) -> void:
	_clear_case()
	_case_id = path.to_lower()
	_spec = Standards.resolve_demo_spec(path, case_name)
	_elapsed = 0.0
	_step_count = 0
	_compression_error = -1.0

	if _case_id.contains("compression"):
		_start_compression_case()
	elif _case_id.contains("additive"):
		_start_tree_case("additive")
	elif _case_id.contains("mask") or _case_id.contains("/partition") or _case_id.contains("individualbone"):
		_start_tree_case("mask")
	elif _case_id.contains("mirror"):
		_start_mirror_case()
	elif _case_id.contains("multithread"):
		_start_pair_case("multithread")
	elif _case_id.contains("retarget"):
		_start_pair_case("retarget")
	elif _case_id.contains("annotation"):
		_start_playback_case("annotation")
	elif _case_id.contains("easecurve"):
		_start_tree_case("ease")
	elif _case_id.contains("control") or _case_id.contains("cycle"):
		_start_playback_case("control")
	elif _case_id.contains("floattrack"):
		_start_playback_case("float")
	elif _case_id.contains("runtimebinding"):
		_start_playback_case("runtime_binding")
	elif _case_id.contains("binding"):
		_start_playback_case("binding")
	elif _case_id.contains("animatedskeleton") or _case_id.contains("/skeleton/"):
		_start_playback_case("skeleton")
	else:
		_start_tree_case("blend")


func status_text() -> String:
	if _case_id.contains("annotation"):
		return "%s | footstep annotations received: %d" % [_status, _step_count]
	if _compression_error >= 0.0:
		return "%s | max sampled rotation error: %.6f rad" % [_status, _compression_error]
	return _status


func _process(delta: float) -> void:
	_elapsed += delta
	if _blend_node != null and not _trees.is_empty():
		var amount := 0.5 + 0.5 * sin(_elapsed * 1.35)
		if _case_id.contains("easecurve"):
			amount = 0.5 - 0.5 * cos(TAU * fposmod(_elapsed * 0.22, 1.0))
		_trees[0].set("parameters/Probe/%s" % _blend_parameter, amount)
		var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
		if _case_id.contains("additive"):
			_status = "AnimationNodeAdd2 [%s]: base walk + additive wave (weight %.2f)" % [cid, amount]
		elif _case_id.contains("mask") or _case_id.contains("/partition") or _case_id.contains("individualbone"):
			_status = "AnimationNodeBlend2 [%s]: upper-body bone track mask over lower-body locomotion (weight %.2f)" % [cid, amount]
		elif _case_id.contains("easecurve"):
			_status = "AnimationNodeBlend2 [%s]: cosine-eased blend transition (weight %.2f)" % [cid, amount]
		else:
			_status = "AnimationNodeBlend2 [%s]: walk <-> run normal blend (weight %.2f)" % [cid, amount]

	if (_case_id.contains("control") or _case_id.contains("cycle")) and not _players.is_empty():
		var cycle := fposmod(_elapsed, 6.0)
		var spd := 0.55 + cycle * 0.45 if cycle < 2.5 else (1.6 if cycle < 4.0 else -0.75)
		for player in _players:
			if is_instance_valid(player):
				player.speed_scale = spd
		_status = "AnimationPlayer playback control [%s]: speed ramp/hold/reverse %.2fx (LOOP_LINEAR)" % [
			str(_spec.get("primary_char", "havok_girl_sdk")), spd]
	if _runtime_binding_target and is_instance_valid(_runtime_binding_target):
		_status = "Runtime binding [%s]: live-attached hand marker scale %.2f" % [
			str(_spec.get("primary_char", "havok_girl_sdk")), _runtime_binding_target.scale.x]
	if _float_track_target and is_instance_valid(_float_track_target):
		_status = "Float scalar value track [%s]: emitter rotation %.2f rad" % [
			str(_spec.get("primary_char", "havok_girl_sdk")), _float_track_target.rotation.x]


func _clear_case() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_actors.clear()
	_players.clear()
	_trees.clear()
	_blend_node = null
	_blend_parameter = ""
	_runtime_binding_target = null
	_float_track_target = null


func _new_havok_actor(char_id: String = "", x: float = 0.0, loop_override: int = -1) -> Dictionary:
	var cid := char_id if not char_id.is_empty() else str(_spec.get("primary_char", "havok_girl_sdk"))
	var eff_loop := loop_override if loop_override >= 0 else int(_spec.get("loop_mode", Animation.LOOP_LINEAR))
	var pack := Standards.spawn_aligned_character(cid, "HavokClip_%d" % _actors.size(), eff_loop)
	var outer: Node3D = pack["outer"] as Node3D
	outer.position.x = x
	add_child(outer)
	var skel: Skeleton3D = pack["skeleton"] as Skeleton3D
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	var player: AnimationPlayer = pack["player"] as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	player.speed_scale = float(_spec.get("playback_speed", 1.0))

	# Mount hand socket on semantic right hand for float/binding/runtime_binding probes
	var hand_idx := Standards.find_semantic_bone(skel, "r_hand")
	var hand_sock := BoneAttachment3D.new()
	hand_sock.name = "HandSocket"
	hand_sock.bone_name = skel.get_bone_name(hand_idx) if hand_idx >= 0 else skel.get_bone_name(0)
	skel.add_child(hand_sock)
	var emitter := Node3D.new()
	emitter.name = "ScannerEmitter"
	emitter.visible = false
	var prop_mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.025
	cyl.bottom_radius = 0.025
	cyl.height = 0.24
	prop_mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#58d6c1")
	mat.emission_enabled = true
	mat.emission = Color("#34a89a")
	prop_mesh.material_override = mat
	emitter.add_child(prop_mesh)
	hand_sock.add_child(emitter)
	pack["hand_socket"] = hand_sock
	pack["emitter"] = emitter

	_actors.append(pack)
	_players.append(player)
	return pack


func _start_tree_case(style: String) -> void:
	var pack := _new_havok_actor()
	var inner: Node3D = pack["root"] as Node3D
	var skel: Skeleton3D = pack["skeleton"] as Skeleton3D
	var clip_a := Standards.pick_clip(pack, str(_spec.get("primary_clip", "walk")))
	var clip_b := Standards.pick_clip(pack, str(_spec.get("secondary_clip", "wave" if style != "blend" else "run")))

	var tree := AnimationTree.new()
	tree.name = "ProbeTree"
	var tree_root := AnimationNodeBlendTree.new()
	var node_a := AnimationNodeAnimation.new()
	node_a.animation = StringName(clip_a)
	var node_b := AnimationNodeAnimation.new()
	node_b.animation = StringName(clip_b)
	tree_root.add_node(&"ClipA", node_a, Vector2(-260, -70))
	tree_root.add_node(&"ClipB", node_b, Vector2(-260, 90))

	var blend: AnimationNode
	if style == "additive":
		blend = AnimationNodeAdd2.new()
		_blend_parameter = "add_amount"
	else:
		blend = AnimationNodeBlend2.new()
		_blend_parameter = "blend_amount"
	if style == "mask":
		blend.filter_enabled = true
		for bpath in Standards.build_upper_body_bone_paths(skel, "Skeleton3D"):
			blend.set_filter_path(bpath, true)

	tree_root.add_node(&"Probe", blend, Vector2(0, 0))
	tree_root.connect_node(&"Probe", 0, &"ClipA")
	tree_root.connect_node(&"Probe", 1, &"ClipB")
	tree_root.connect_node(&"output", 0, &"Probe")
	tree.tree_root = tree_root
	inner.add_child(tree)
	tree.anim_player = ^"../AnimationPlayer"
	tree.root_node = ^".."
	tree.active = true
	_trees.append(tree)
	_blend_node = blend

	var cid := str(pack["char_id"])
	if style == "additive":
		_status = "Additive blending [%s %db]: AnimationNodeAdd2 (%s + %s)" % [cid, skel.get_bone_count(), clip_a, clip_b]
	elif style == "mask":
		_status = "Upper-body partition mask [%s %db]: filtered AnimationNodeBlend2 (%s + %s)" % [cid, skel.get_bone_count(), clip_a, clip_b]
	elif style == "ease":
		_status = "Ease-curve blend [%s %db]: cosine-eased AnimationNodeBlend2 (%s <-> %s)" % [cid, skel.get_bone_count(), clip_a, clip_b]
	else:
		_status = "Normal blending [%s %db]: AnimationNodeBlend2 (%s <-> %s)" % [cid, skel.get_bone_count(), clip_a, clip_b]


func _start_mirror_case() -> void:
	var left := _new_havok_actor("", -0.75)
	var right := _new_havok_actor("", 0.75)
	var clip_a := Standards.pick_clip(left, str(_spec.get("primary_clip", "run")))
	var p_left: AnimationPlayer = left["player"] as AnimationPlayer
	var p_right: AnimationPlayer = right["player"] as AnimationPlayer
	var src_anim := p_left.get_animation(StringName(clip_a))
	var mirrored := Standards.build_mirrored_animation(src_anim)
	var lib := AnimationLibrary.new()
	lib.add_animation(&"mirrored", mirrored)
	p_right.add_animation_library(&"Mirror", lib)
	p_left.play(StringName(clip_a))
	p_right.play(&"Mirror/mirrored")
	_status = "Skeleton mirroring [%s 50b]: left plays original '%s', right plays L<->R X-plane mirrored '%s'" % [
		str(left["char_id"]), clip_a, clip_a]


func _start_pair_case(kind: String) -> void:
	var positions := [-0.95, 0.0, 0.95] if kind == "multithread" else [-0.75, 0.75]
	for x in positions:
		var pack := _new_havok_actor("", float(x))
		var cname := Standards.pick_clip(pack, str(_spec.get("primary_clip", "walk")))
		(pack["player"] as AnimationPlayer).play(StringName(cname))
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	if kind == "retarget":
		_status = "Shared rig preview [%s]: paired internalized Havok rigs synchronized on Godot -Z" % cid
	else:
		_status = "Partition preview [%s]: 3 internalized Havok rigs evaluating original clips" % cid


func _start_playback_case(style: String) -> void:
	var pack := _new_havok_actor()
	var inner: Node3D = pack["root"] as Node3D
	var skel: Skeleton3D = pack["skeleton"] as Skeleton3D
	var player: AnimationPlayer = pack["player"] as AnimationPlayer
	var cname := Standards.pick_clip(pack, str(_spec.get("primary_clip", "walk")))

	if style == "annotation":
		var emitter := StepEmitter.new()
		emitter.name = "StepEmitter"
		inner.add_child(emitter)
		emitter.stepped.connect(_on_step_event)
		var src := player.get_animation(StringName(cname))
		var annotated := src.duplicate(true) as Animation
		annotated.loop_mode = Animation.LOOP_LINEAR
		var mt := annotated.add_track(Animation.TYPE_METHOD)
		annotated.track_set_path(mt, ^"StepEmitter")
		annotated.track_insert_key(mt, annotated.length * 0.25, {"method": &"emit_step", "args": ["L"]})
		annotated.track_insert_key(mt, annotated.length * 0.75, {"method": &"emit_step", "args": ["R"]})
		var lib := AnimationLibrary.new()
		lib.add_animation(&"annotated", annotated)
		player.add_animation_library(&"Annot", lib)
		player.play(&"Annot/annotated")
		_status = "Annotation playback [%s]: method keys at 25%%/75%% emit L/R footstep events" % str(pack["char_id"])
	elif style == "control":
		player.play(StringName(cname))
		_status = "Playback control [%s]: speed ramp, hold, and reverse (LOOP_LINEAR)" % str(pack["char_id"])
	elif style == "float" or style == "binding":
		player.play(StringName(cname))
		var float_player := AnimationPlayer.new()
		float_player.name = "FloatTrackPlayer"
		float_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
		inner.add_child(float_player)
		float_player.root_node = float_player.get_path_to(inner)
		var f_anim := Animation.new()
		f_anim.length = 1.0
		f_anim.loop_mode = Animation.LOOP_LINEAR
		var ft := f_anim.add_track(Animation.TYPE_VALUE)
		f_anim.track_set_path(ft, ^"Skeleton3D/HandSocket/ScannerEmitter:rotation:x")
		f_anim.value_track_set_update_mode(ft, Animation.UPDATE_CONTINUOUS)
		f_anim.track_insert_key(ft, 0.0, 0.0)
		f_anim.track_insert_key(ft, 0.5, 1.35)
		f_anim.track_insert_key(ft, 1.0, 0.0)
		var flib := AnimationLibrary.new()
		flib.add_animation(&"float_probe", f_anim)
		float_player.add_animation_library(&"Probe", flib)
		float_player.play(&"Probe/float_probe")
		_float_track_target = pack["emitter"] as Node3D
		_float_track_target.visible = true
		_status = "Float/Binding playback [%s]: scalar value track bound to %s" % [str(pack["char_id"]), str(pack["hand_socket"].bone_name)]
	elif style == "runtime_binding":
		player.play(StringName(cname))
		var float_player := AnimationPlayer.new()
		float_player.name = "RuntimeBindPlayer"
		float_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
		inner.add_child(float_player)
		float_player.root_node = float_player.get_path_to(inner)
		var r_anim := Animation.new()
		r_anim.length = 1.0
		r_anim.loop_mode = Animation.LOOP_LINEAR
		var rt := r_anim.add_track(Animation.TYPE_VALUE)
		r_anim.track_set_path(rt, ^"Skeleton3D/HandSocket/LiveBindingTarget:scale")
		r_anim.value_track_set_update_mode(rt, Animation.UPDATE_CONTINUOUS)
		r_anim.track_insert_key(rt, 0.0, Vector3.ONE)
		r_anim.track_insert_key(rt, 0.5, Vector3(1.6, 1.6, 1.6))
		r_anim.track_insert_key(rt, 1.0, Vector3.ONE)
		var rlib := AnimationLibrary.new()
		rlib.add_animation(&"runtime_target", r_anim)
		float_player.add_animation_library(&"RuntimeBinding", rlib)
		var live_target := Node3D.new()
		live_target.name = "LiveBindingTarget"
		(pack["hand_socket"] as Node3D).add_child(live_target)
		_runtime_binding_target = live_target
		var marker := MeshInstance3D.new()
		var sp := SphereMesh.new()
		sp.radius = 0.055
		sp.height = 0.11
		marker.mesh = sp
		var mmat := StandardMaterial3D.new()
		mmat.albedo_color = Color("#ffe168")
		mmat.emission_enabled = true
		mmat.emission = Color("#ffe168")
		marker.material_override = mmat
		marker.position = Vector3(0.0, 0.14, 0.0)
		live_target.add_child(marker)
		float_player.clear_caches()
		float_player.play(&"RuntimeBinding/runtime_target")
		_status = "Runtime binding [%s]: live hand node added & resolved via clear_caches()" % str(pack["char_id"])
	else:
		player.play(StringName(cname))
		_status = "Animated skeleton [%s]: %d-bone original Havok SDK rig playing '%s' (%s)" % [
			str(pack["char_id"]), skel.get_bone_count(), cname, Standards.loop_mode_name(int(_spec.get("loop_mode", Animation.LOOP_LINEAR)))]


func _on_step_event(_side: String) -> void:
	_step_count += 1


func _start_compression_case() -> void:
	var left := _new_havok_actor("", -0.75)
	var right := _new_havok_actor("", 0.75)
	var cname := Standards.pick_clip(left, str(_spec.get("primary_clip", "walk")))
	var p_left: AnimationPlayer = left["player"] as AnimationPlayer
	var p_right: AnimationPlayer = right["player"] as AnimationPlayer
	var source := p_left.get_animation(StringName(cname))
	var compressed := source.duplicate(true) as Animation
	compressed.compress(16384, 60, 0.5)
	var lib := AnimationLibrary.new()
	lib.add_animation(&"compressed", compressed)
	p_right.add_animation_library(&"Compare", lib)
	p_left.play(StringName(cname))
	p_right.play(&"Compare/compressed")
	_compression_error = _measure_rotation_error(source, compressed)
	var compressed_tracks := 0
	for idx in compressed.get_track_count():
		if compressed.track_is_compressed(idx):
			compressed_tracks += 1
	_status = "Compression [%s %db '%s']: left original vs right Godot compressed (%d/%d tracks)" % [
		str(left["char_id"]), (left["skeleton"] as Skeleton3D).get_bone_count(), cname,
		compressed_tracks, compressed.get_track_count()]


func _measure_rotation_error(source: Animation, compressed: Animation) -> float:
	var largest := 0.0
	var dur := maxf(0.05, source.length)
	for track in source.get_track_count():
		if source.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var c_track := compressed.find_track(source.track_get_path(track), Animation.TYPE_ROTATION_3D)
		if c_track < 0:
			continue
		for s in 51:
			var t := dur * float(s) / 50.0
			var a := source.rotation_track_interpolate(track, t)
			var b := compressed.rotation_track_interpolate(c_track, t)
			var dot := clampf(absf(a.dot(b)), 0.0, 1.0)
			largest = maxf(largest, 2.0 * acos(dot))
	return largest
