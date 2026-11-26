extends Node3D
## Small, executable probes for the animation catalog. All examples use Godot
## Animation/AnimationTree on the courier rig; approximations are called out in
## status_text() instead of implying engine features that are not exercised.

const CHARACTER_SCENE: PackedScene = preload("res://demo/character/character.tscn")
const LOOP_SECONDS := 1.0

var _case_id := ""
var _status := "Choose an animation case."
var _elapsed := 0.0
var _characters: Array[Node3D] = []
var _players: Array[AnimationPlayer] = []
var _trees: Array[AnimationTree] = []
var _blend_node: AnimationNode = null
var _blend_parameter := ""
var _step_count := 0
var _compression_error := -1.0
var _runtime_binding_target: Node3D
var _float_track_target: Node3D


func start_case(path: String, name: String) -> void:
	_clear_case()
	# The catalog source path selects the behavior. The variant name is only a
	# display label and must not silently redirect a source to another probe.
	_case_id = path.to_lower()
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
		return "%s | measured maximum sampled rotation error: %.6f rad" % [_status, _compression_error]
	return _status


func _process(delta: float) -> void:
	_elapsed += delta
	if _blend_node != null and not _trees.is_empty():
		var amount := 0.5 + 0.5 * sin(_elapsed * 1.35)
		if _case_id.contains("easecurve"):
			var eased := 0.5 - 0.5 * cos(TAU * fposmod(_elapsed * 0.22, 1.0))
			amount = eased
		_trees[0].set("parameters/Probe/%s" % _blend_parameter, amount)
		if _case_id.contains("additive"):
			_status = "AnimationNodeAdd2: stride base plus sampled reach delta; additive weight %.2f" % amount
		elif _case_id.contains("mask") or _case_id.contains("/partition") or _case_id.contains("individualbone"):
			_status = "AnimationNodeBlend2 passes only the filtered upper-body bone tracks; lower body remains stride (weight %.2f)" % amount
		elif _case_id.contains("easecurve"):
			_status = "AnimationNodeBlend2 with a cosine-eased blend parameter (weight %.2f); easing curve is a probe approximation" % amount
		else:
			_status = "AnimationNodeBlend2 samples stride and reach simultaneously (weight %.2f)" % amount

	if _case_id.contains("control") or _case_id.contains("cycle"):
		for player in _players:
			if not is_instance_valid(player):
				continue
			var cycle := fposmod(_elapsed, 6.0)
			if cycle < 2.5:
				player.speed_scale = 0.55 + cycle * 0.45
			elif cycle < 4.0:
				player.speed_scale = 1.6
			else:
				player.speed_scale = -0.75
		_status = "Native AnimationPlayer playback control: speed ramps, holds fast, then reverses at %.2fx" % _players[0].speed_scale
	if _runtime_binding_target and is_instance_valid(_runtime_binding_target):
		_status = "Runtime binding resolved on the live-added node; animated marker scale is %.2f" % _runtime_binding_target.scale.x
	if _float_track_target and is_instance_valid(_float_track_target):
		_status = "Native scalar value track drives scanner emitter rotation: %.2f rad" % _float_track_target.rotation.x


func _clear_case() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_characters.clear()
	_players.clear()
	_trees.clear()
	_blend_node = null
	_blend_parameter = ""
	_runtime_binding_target = null
	_float_track_target = null


func _new_character(x: float = 0.0) -> Node3D:
	var character := CHARACTER_SCENE.instantiate() as Node3D
	character.position.x = x
	add_child(character)
	var rig := character.get_node("Rig") as Skeleton3D
	rig.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	var player := character.get_node("Player") as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	_characters.append(character)
	_players.append(player)
	_add_probe_animations(player)
	return character


func _add_probe_animations(player: AnimationPlayer) -> void:
	var library := AnimationLibrary.new()
	var reach := _make_gesture(0.95, 0.5)
	reach.resource_name = "Reach gesture"
	library.add_animation(&"reach", reach)
	var mirror := _make_gesture(-0.85, -0.35)
	mirror.resource_name = "Mirrored gesture"
	library.add_animation(&"mirror", mirror)
	var float_motion := Animation.new()
	float_motion.length = LOOP_SECONDS
	float_motion.loop_mode = Animation.LOOP_LINEAR
	var scale_track := float_motion.add_track(Animation.TYPE_VALUE)
	float_motion.track_set_path(scale_track, ^"Rig/ToolSocket/Tool/ScannerEmitter:rotation:x")
	float_motion.value_track_set_update_mode(scale_track, Animation.UPDATE_CONTINUOUS)
	float_motion.track_insert_key(scale_track, 0.0, 0.0)
	float_motion.track_insert_key(scale_track, 0.5, 1.35)
	float_motion.track_insert_key(scale_track, 1.0, 0.0)
	library.add_animation(&"float_probe", float_motion)
	player.add_animation_library(&"Probe", library)


func _make_gesture(swing: float, wrist: float) -> Animation:
	var animation := Animation.new()
	animation.length = LOOP_SECONDS
	animation.loop_mode = Animation.LOOP_LINEAR
	_add_rotation_track(animation, ^"Rig:ShoulderRight", Vector3.BACK, [0.0, swing, 0.0, swing, 0.0])
	_add_rotation_track(animation, ^"Rig:Hand.R", Vector3.RIGHT, [0.0, wrist, 0.0, -wrist, 0.0])
	_add_rotation_track(animation, ^"Rig:Spine", Vector3.BACK, [0.0, 0.08, 0.0, -0.08, 0.0])
	return animation


func _add_rotation_track(animation: Animation, path: NodePath, axis: Vector3, angles: Array[float]) -> void:
	var track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(track, path)
	for key_index in 5:
		animation.rotation_track_insert_key(track, float(key_index) * 0.25, Quaternion(axis, angles[key_index]))


func _start_tree_case(style: String) -> void:
	var character := _new_character()
	var tree := AnimationTree.new()
	tree.name = "ProbeTree"
	tree.anim_player = ^"../Player"
	tree.root_node = ^".."
	var tree_root := AnimationNodeBlendTree.new()
	var stride_node := AnimationNodeAnimation.new()
	stride_node.animation = &"stride"
	var reach_node := AnimationNodeAnimation.new()
	reach_node.animation = &"Probe/reach"
	tree_root.add_node(&"stride", stride_node, Vector2(-260, -70))
	tree_root.add_node(&"reach", reach_node, Vector2(-260, 90))
	var blend: AnimationNode
	if style == "additive":
		blend = AnimationNodeAdd2.new()
		_blend_parameter = "add_amount"
	else:
		blend = AnimationNodeBlend2.new()
		_blend_parameter = "blend_amount"
	if style == "mask":
		blend.filter_enabled = true
		blend.set_filter_path(^"Rig:ShoulderRight", true)
		blend.set_filter_path(^"Rig:Hand.R", true)
		blend.set_filter_path(^"Rig:Spine", true)
	tree_root.add_node(&"Probe", blend, Vector2(0, 0))
	tree_root.connect_node(&"Probe", 0, &"stride")
	tree_root.connect_node(&"Probe", 1, &"reach")
	tree_root.connect_node(&"output", 0, &"Probe")
	tree.tree_root = tree_root
	character.add_child(tree)
	tree.active = true
	_trees.append(tree)
	_blend_node = blend
	if style == "additive":
		_status = "Additive probe: an AnimationNodeAdd2 adds the reach delta to stride."
	elif style == "mask":
		_status = "Mask/partition probe: a filtered AnimationNodeBlend2 overlays upper-body tracks on stride."
	elif style == "ease":
		_status = "Ease-curve probe: a cosine-eased AnimationNodeBlend2 weight drives a real blend."
	else:
		_status = "Normal blending probe: AnimationNodeBlend2 mixes stride and reach."


func _start_mirror_case() -> void:
	var left := _new_character(-0.68)
	var right := _new_character(0.68)
	var mirror := _make_gesture(-0.95, -0.5)
	mirror.resource_name = "Mirrored stride overlay"
	var mirror_library := AnimationLibrary.new()
	mirror_library.add_animation(&"mirror_overlay", mirror)
	(_players[1] as AnimationPlayer).add_animation_library(&"Mirror", mirror_library)
	(_players[0] as AnimationPlayer).play(&"stride")
	(_players[1] as AnimationPlayer).play(&"Mirror/mirror_overlay")
	_status = "Mirroring comparison: left courier plays stride; right plays a separately authored opposite-sign upper-body pose. This is a pose-level mirror approximation, not full skeleton mirroring."


func _start_pair_case(kind: String) -> void:
	if kind == "multithread":
		_new_character(-0.92)
		_new_character(0.0)
		_new_character(0.92)
	else:
		_new_character(-0.68)
		_new_character(0.68)
	for player in _players:
		player.play(&"stride")
	if kind == "retarget":
		_status = "Retargeting preview: both identical rigs consume the same clip. This demonstrates shared binding only; no humanoid profile or bone-map retarget is applied."
	else:
		_status = "Partition worker preview: three copies sample the same stride sequentially. Godot worker-thread execution is not implemented by this probe."


func _start_playback_case(style: String) -> void:
	var character := _new_character()
	var player := character.get_node("Player") as AnimationPlayer
	if style == "annotation":
		character.step_event.connect(_on_step_event)
		player.play(&"stride")
		_status = "Annotation probe: native stride method keys at 0.25 s and 0.75 s emit L/R step signals."
	elif style == "control":
		player.play(&"stride")
		_status = "Playback control probe: native AnimationPlayer speed is ramped, held, and reversed."
	elif style == "float":
		player.play(&"Probe/float_probe")
		_float_track_target = character.get_node("Rig/ToolSocket/Tool/ScannerEmitter") as Node3D
		_status = "Float-track probe: a native scalar value track rotates the scanner's emitter."
	elif style == "binding":
		player.play(&"Probe/float_probe")
		_status = "Binding probe: a pre-authored value-track path binds directly to the live scanner emitter node."
	elif style == "runtime_binding":
		var runtime_animation := Animation.new()
		runtime_animation.length = LOOP_SECONDS
		runtime_animation.loop_mode = Animation.LOOP_LINEAR
		var runtime_track := runtime_animation.add_track(Animation.TYPE_VALUE)
		runtime_animation.track_set_path(runtime_track, ^"Rig/ToolSocket/LiveBindingTarget:scale")
		runtime_animation.value_track_set_update_mode(runtime_track, Animation.UPDATE_CONTINUOUS)
		runtime_animation.track_insert_key(runtime_track, 0.0, Vector3.ONE)
		runtime_animation.track_insert_key(runtime_track, 0.5, Vector3(1.6, 1.6, 1.6))
		runtime_animation.track_insert_key(runtime_track, 1.0, Vector3.ONE)
		var runtime_library := AnimationLibrary.new()
		runtime_library.add_animation(&"runtime_target", runtime_animation)
		player.add_animation_library(&"RuntimeBinding", runtime_library)
		var live_target := Node3D.new()
		live_target.name = "LiveBindingTarget"
		(character.get_node("Rig/ToolSocket") as Node3D).add_child(live_target)
		_runtime_binding_target = live_target
		var marker := MeshInstance3D.new()
		marker.name = "BindingMarker"
		var marker_mesh := SphereMesh.new()
		marker_mesh.radius = 0.045
		marker_mesh.height = 0.09
		marker.mesh = marker_mesh
		var marker_material := StandardMaterial3D.new()
		marker_material.albedo_color = Color("#ffe168")
		marker_material.emission_enabled = true
		marker_material.emission = Color("#ffe168")
		marker.material_override = marker_material
		marker.position = Vector3(0.0, 0.22, 0.12)
		live_target.add_child(marker)
		player.clear_caches()
		player.play(&"RuntimeBinding/runtime_target")
		_status = "Runtime binding probe: clip is created, then resolves a node added at runtime; its visible marker scales through the new track binding."
	else:
		player.play(&"stride")
		_status = "Skeleton playback probe: native transform tracks animate an actual 16-bone Skeleton3D with attached geometry."


func _on_step_event(_side: String) -> void:
	_step_count += 1


func _start_compression_case() -> void:
	_new_character(-0.68)
	var compressed_character := _new_character(0.68)
	var source := _players[0].get_animation(&"stride")
	var compressed := source.duplicate(true) as Animation
	compressed.compress(2048, 60, 0.01)
	var compressed_library := AnimationLibrary.new()
	compressed_library.add_animation(&"stride_compressed", compressed)
	(_players[1] as AnimationPlayer).add_animation_library(&"Compare", compressed_library)
	_players[0].play(&"stride")
	_players[1].play(&"Compare/stride_compressed")
	_compression_error = _measure_rotation_error(source, compressed)
	var compressed_track_count := 0
	for index in compressed.get_track_count():
		if compressed.track_is_compressed(index):
			compressed_track_count += 1
	_status = "Compression comparison: original stride at left; Godot-compressed duplicate at right (%d/%d tracks compressed, 2048-byte pages, 60 Hz, 0.01 split tolerance)." % [compressed_track_count, compressed.get_track_count()]


func _measure_rotation_error(source: Animation, compressed: Animation) -> float:
	var largest := 0.0
	for track in source.get_track_count():
		if source.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var compressed_track := compressed.find_track(source.track_get_path(track), Animation.TYPE_ROTATION_3D)
		if compressed_track < 0:
			continue
		for sample_index in 101:
			var time := LOOP_SECONDS * float(sample_index) / 100.0
			var a := source.rotation_track_interpolate(track, time)
			var b := compressed.rotation_track_interpolate(compressed_track, time)
			var dot := clampf(absf(a.dot(b)), 0.0, 1.0)
			largest = maxf(largest, 2.0 * acos(dot))
	return largest
