extends SceneTree

const PoseModifier = preload("../addons/animation_studio/pose_modifier.gd")
const STEP := 1.0 / 60.0
const EPSILON := 0.0001

var failures := 0
var captured := Transform3D.IDENTITY
var samples := 0


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		print("PFTEST ", JSON.stringify({"status": "FAIL", "test": message}))
		push_error(message)


func make_rig(library: AnimationLibrary) -> Node3D:
	var rig := Node3D.new()
	root.add_child(rig)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Rig"
	rig.add_child(skeleton)
	skeleton.add_bone("Hand")
	skeleton.motion_scale = 1.5
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var player := AnimationPlayer.new()
	player.name = "Player"
	rig.add_child(player)
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.add_animation_library(&"", library)
	return rig


func make_clip() -> Animation:
	var clip := Animation.new()
	clip.length = 1.0
	clip.loop_mode = Animation.LOOP_LINEAR
	var keys := [
		[Animation.TYPE_POSITION_3D, Vector3.ZERO, Vector3(1.0, 0.5, -2.0)],
		[Animation.TYPE_ROTATION_3D, Quaternion.IDENTITY, Quaternion(Vector3.UP, 1.2)],
		[Animation.TYPE_SCALE_3D, Vector3.ONE, Vector3(1.5, 2.0, 0.5)],
	]
	for channel: Array in keys:
		var track := clip.add_track(channel[0])
		clip.track_set_path(track, ^"Rig:Hand")
		clip.track_insert_key(track, 0.0, channel[1])
		clip.track_insert_key(track, 1.0, channel[2])
	return clip


func run() -> void:
	print("PFTEST ", JSON.stringify({"status": "START", "engine": Engine.get_version_info().hash}))
	var library := AnimationLibrary.new()
	var source := make_clip()
	var compressed := "--compressed" in OS.get_cmdline_user_args()
	if compressed:
		source.compress()
		check(source.track_is_compressed(0), "Compression fixture did not produce a packed channel")
	library.add_animation(&"move", source)
	var reference := make_rig(library)
	var pilot := make_rig(library)
	var skeleton: Skeleton3D = pilot.get_node("Rig")
	var player: AnimationPlayer = pilot.get_node("Player")
	var reference_skeleton: Skeleton3D = reference.get_node("Rig")
	var tree := AnimationTree.new()
	tree.active = false
	reference.add_child(tree)
	tree.anim_player = ^"../Player"
	var clip_node := AnimationNodeAnimation.new()
	clip_node.animation = &"move"
	tree.tree_root = clip_node
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	tree.active = true
	var modifier := PoseModifier.new()
	reference_skeleton.add_child(modifier)
	check(not modifier.play_clip(reference.get_node("Player"), &"move"), "Accepted a player owned by an active AnimationTree")
	modifier.reparent(skeleton)
	if not modifier.play_clip(player, &"move"):
		push_error("Unable to bind the pilot rig")
		quit(1)
		return
	var native := ClassDB.class_exists(&"AnimationStudioPoseSampler")
	if "--expect-native" in OS.get_cmdline_user_args():
		check(native, "Native extension did not load")
	var alias_before := player.assigned_animation
	check(not modifier.play_clip(player, &"unknown") and player.assigned_animation == alias_before, "Failed bind interrupted playback")
	var duplicate := make_clip()
	duplicate.copy_track(0, duplicate)
	library.add_animation(&"duplicate", duplicate)
	check(not modifier.play_clip(player, &"duplicate") and player.assigned_animation == alias_before, "Accepted two position writers for the same bone")
	skeleton.skeleton_updated.connect(func():
		captured = skeleton.get_bone_pose(0)
		samples += 1
	)
	# Initialize both clocks at zero before measuring the first full tick.
	tree.advance(0.0)
	player.advance(0.0)
	var max_position := 0.0
	var max_rotation := 0.0
	var max_scale := 0.0
	for tick in 90:
		await process_frame
		tree.advance(STEP)
		player.advance(STEP)
		var before := samples
		skeleton.advance(STEP)
		await skeleton.skeleton_updated
		check(samples > before, "Missing final pose for tick %d" % tick)
		var expected := reference_skeleton.get_bone_pose(0)
		max_position = maxf(max_position, captured.origin.distance_to(expected.origin))
		var lhs := captured.basis.get_rotation_quaternion()
		var rhs := expected.basis.get_rotation_quaternion()
		max_rotation = maxf(max_rotation, 1.0 - absf(lhs.dot(rhs)))
		max_scale = maxf(max_scale, captured.basis.get_scale().distance_to(expected.basis.get_scale()))
	check(max_position <= EPSILON and max_rotation <= EPSILON and max_scale <= EPSILON, "Pose diverged from AnimationTree")
	await process_frame
	modifier.stop_clip()
	check(player.get_animation_library_list().size() == 1, "Playback library survived stop")
	print("PARITY native=%s compressed=%s ticks=90 position_error=%f rotation_dot_error=%f scale_error=%f failures=%d" % [native, compressed, max_position, max_rotation, max_scale, failures])
	print("PFTEST ", JSON.stringify({"status": "INFO", "test": "pose_error", "data": {
		"native": native, "compressed": compressed, "ticks": 90, "max_position": max_position,
		"max_rotation_dot_error": max_rotation, "max_scale": max_scale
	}}))
	if failures == 0:
		print("PFTEST ", JSON.stringify({"status": "PASS", "test": "animation_tree_parity_and_ownership"}))
	print("PFTEST ", JSON.stringify({"status": "SUMMARY", "fail": failures}))
	reference.free()
	pilot.free()
	quit(1 if failures else 0)
