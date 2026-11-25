extends Node

const PoseModifierScript = preload("res://addons/animation_studio/pose_modifier.gd")
const DownstreamProbeScript = preload("res://tests/downstream_probe.gd")
const TargetProbeScript = preload("res://tests/target_probe.gd")

const EPSILON := 0.0001
const DURATION := 1.0
const PLAYBACK := &"AnimationStudioRuntime/pose"

var _failures := 0
var _native_events := 0
var _cutscene_events := 0
var property_value := -1.0


func record_native_event(tag: String) -> void:
	if tag == "native":
		_native_events += 1
	elif tag == "cutscene":
		_cutscene_events += 1


func _check(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_failures += 1
		push_error("ANIMTEST FAIL %s %s" % [label, detail])
	print("PFTEST " + JSON.stringify({"status": "PASS" if condition else "FAIL", "suite": "animation_studio_coexistence", "test": label, "detail": detail}))


func _near_vec3(actual: Vector3, expected: Vector3, epsilon := EPSILON) -> bool:
	return actual.distance_to(expected) <= epsilon


func _ready() -> void:
	# This catches runtime hangs. The CLI command also uses --quit-after so a
	# parse/load error cannot leave a headless process alive indefinitely.
	get_tree().create_timer(15.0).timeout.connect(func():
		push_error("ANIMTEST TIMEOUT waiting for the coexistence fixture")
		get_tree().quit(2)
	)
	await get_tree().process_frame
	print("PFTEST " + JSON.stringify({"status": "START", "suite": "animation_studio_coexistence", "engine": Engine.get_version_info().get("hash", ""), "version": Engine.get_version_info().get("string", "")}))
	await _run_coexistence()
	await _run_retarget_ik()
	print("PFTEST " + JSON.stringify({"status": "SUMMARY", "suite": "animation_studio_coexistence", "fail": _failures}))
	get_tree().quit(1 if _failures else 0)


func _run_coexistence() -> void:
	var rig := Node3D.new()
	rig.name = "Rig"
	add_child(rig)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	rig.add_child(skeleton)
	skeleton.add_bone("Root")
	skeleton.add_bone("Hand")
	skeleton.set_bone_parent(1, 0)
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	player.root_node = NodePath("..")
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	rig.add_child(player)
	var source := _make_animation()
	var library := AnimationLibrary.new()
	library.add_animation(&"native", source)
	library.add_animation(&"cutscene", _make_cutscene())
	player.add_animation_library(&"", library)
	player.root_motion_track = NodePath("Skeleton:Root")

	var modifier = PoseModifierScript.new()
	modifier.name = "PoseModifier"
	skeleton.add_child(modifier)
	var probe := DownstreamProbeScript.new()
	probe.name = "DownstreamProbe"
	skeleton.add_child(probe)

	# Enter the tree before resolving the player and skeleton.
	_check("modifier entered tree", modifier.is_inside_tree())
	player.play(&"native")
	player.advance(0.5)
	await get_tree().process_frame
	_check("native clip can already be in progress", is_equal_approx(player.current_animation_position, 0.5))
	var events_before_takeover := _native_events
	_check("native method event runs before takeover", events_before_takeover == 1)
	_check("play_clip selects source", bool(modifier.play_clip(player, &"native")))
	_check("play_clip hard cuts generated alias to time zero", player.is_playing() and player.current_animation == PLAYBACK and is_zero_approx(player.current_animation_position))
	_check("source library and clip remain intact", player.has_animation(&"native") and player.get_animation(&"native") == source and source.get_track_count() == 4)
	var alias := player.get_animation(PLAYBACK)
	_check("generated alias excludes native hand track", alias != null and not _has_track_path(alias, NodePath("Skeleton:Hand")))

	var total_root_motion := Vector3.ZERO
	for step in 7:
		# Advance the primary mixer once, then let Skeleton3D run modifiers once.
		await _advance_pair(player, skeleton, probe, 0.25)
		var time := player.current_animation_position
		var expected := source.position_track_interpolate(0, time)
		_check("same-frame downstream pose matches native sample at step %d" % step, _near_vec3(probe.captured_position, expected), "time=%s expected=%s observed=%s" % [time, expected, probe.captured_position])
		var expected_time := fmod(float(step + 1) * 0.25, DURATION)
		_check("native time advances once at step %d" % step, is_equal_approx(time, expected_time), "time=%s expected=%s" % [time, expected_time])
		total_root_motion += player.get_root_motion_position()
		if step == 0:
			_check("native property track remains active", is_equal_approx(property_value, 0.25), "value=%s" % property_value)
		var expected_events := events_before_takeover + int(step >= 1) + int(step >= 5)
		_check("native method events run once per crossing at step %d" % step, _native_events == expected_events, "native_events=%d expected=%d" % [_native_events, expected_events])

	_check("root motion accumulates once across loop", _near_vec3(total_root_motion, Vector3(3.5, 0, 0)), "accumulated=%s" % total_root_motion)
	_check("native loop event fires once per loop", _native_events == events_before_takeover + 2, "native_events=%d" % _native_events)

	# Release the derived alias, let a cutscene own the same player, then start
	# a fresh pose playback. The API's takeover is a hard cut from time zero.
	modifier.stop_clip()
	_check("stop removes alias and preserves source", not player.has_animation(PLAYBACK) and player.get_animation(&"native") == source)
	player.play(&"cutscene")
	await _advance_pair(player, skeleton, probe, 0.25)
	_check("cutscene property and method tracks execute", is_equal_approx(property_value, 7.0) and _cutscene_events == 1)
	_check("cutscene leaves native source clip intact", player.has_animation(&"native") and player.get_animation(&"native") == source)
	player.play(&"native")
	player.seek(0.5, false)
	await get_tree().process_frame
	_check("rebind succeeds after cutscene", bool(modifier.play_clip(player, &"native")))
	_check("rebind hard cuts native playback to zero", is_zero_approx(player.current_animation_position))
	await _advance_pair(player, skeleton, probe, 0.25)
	_check("fresh pose playback samples from zero", _near_vec3(probe.captured_position, Vector3(0.25, 0, 0)))
	_check("native event does not replay from seek", _native_events == events_before_takeover + 2)
	modifier.stop_clip()
	_check("final stop leaves source and removes alias", player.has_animation(&"native") and player.get_animation(&"native") == source and not player.has_animation(PLAYBACK))

	modifier.queue_free()
	probe.queue_free()
	rig.queue_free()
	await get_tree().process_frame



func _advance_pair(player: AnimationPlayer, skeleton: Skeleton3D, probe, delta: float) -> void:
	var previous_samples: int = probe.sample_count
	player.advance(delta)
	skeleton.advance(0.0)
	# Skeleton3D defers modifier execution and emits this after the pass, before
	# restoring the original pose. The downstream probe records inside the pass.
	while probe.sample_count == previous_samples:
		await get_tree().process_frame
	await get_tree().process_frame


func _run_retarget_ik() -> void:
	var rig := Node3D.new()
	rig.name = "RetargetRig"
	add_child(rig)
	var source_skeleton := Skeleton3D.new()
	source_skeleton.name = "Source"
	source_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	rig.add_child(source_skeleton)
	_add_arm_chain(source_skeleton)
	var pose_modifier = PoseModifierScript.new()
	source_skeleton.add_child(pose_modifier)
	var retarget := RetargetModifier3D.new()
	retarget.profile = SkeletonProfileHumanoid.new()
	retarget.use_global_pose = false
	source_skeleton.add_child(retarget)
	var source_probe := DownstreamProbeScript.new()
	source_skeleton.add_child(source_probe)
	var target_skeleton := Skeleton3D.new()
	target_skeleton.name = "Target"
	target_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	_add_arm_chain(target_skeleton)
	retarget.add_child(target_skeleton)
	var retarget_probe := TargetProbeScript.new()
	retarget_probe.name = "RetargetProbe"
	target_skeleton.add_child(retarget_probe)
	var ik_target := Node3D.new()
	ik_target.name = "IKTarget"
	target_skeleton.add_child(ik_target)
	ik_target.global_position = Vector3(2.0, 1.0, 0.0)
	var ik_pole := Node3D.new()
	ik_pole.name = "IKPole"
	target_skeleton.add_child(ik_pole)
	ik_pole.global_position = Vector3(1.0, 2.0, 1.0)
	var ik := TwoBoneIK3D.new()
	ik.setting_count = 1
	target_skeleton.add_child(ik)
	ik.set_root_bone_name(0, "LeftUpperArm")
	ik.set_middle_bone_name(0, "LeftLowerArm")
	ik.set_end_bone_name(0, "LeftHand")
	ik.set_target_node(0, NodePath("../IKTarget"))
	ik.set_pole_node(0, NodePath("../IKPole"))
	var target_probe := TargetProbeScript.new()
	target_probe.name = "IKProbe"
	target_skeleton.add_child(target_probe)

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	player.root_node = NodePath("..")
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	rig.add_child(player)
	var animation := Animation.new()
	animation.length = DURATION
	var rotation_track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(rotation_track, NodePath("Source:LeftUpperArm"))
	animation.track_insert_key(rotation_track, 0.0, Quaternion.IDENTITY)
	animation.track_insert_key(rotation_track, DURATION, Quaternion(Vector3.FORWARD, PI * 0.5))
	var library := AnimationLibrary.new()
	library.add_animation(&"pose", animation)
	player.add_animation_library(&"", library)

	await get_tree().process_frame
	_check("retarget and IK fixture configured", pose_modifier.is_inside_tree() and retarget.is_inside_tree() and target_skeleton.is_inside_tree() and ik.get_root_bone(0) == 1 and ik.get_middle_bone(0) == 2 and ik.get_end_bone(0) == 3)
	_check("IK target and pole paths resolve", ik.get_node_or_null(ik.get_target_node(0)) == ik_target and ik.get_node_or_null(ik.get_pole_node(0)) == ik_pole, "target=%s pole=%s" % [ik.get_target_node(0), ik.get_pole_node(0)])
	await get_tree().physics_frame
	await get_tree().physics_frame
	player.play(&"pose")
	_check("pose clip binds ahead of RetargetModifier3D", bool(pose_modifier.play_clip(player, &"pose")))
	ik.active = true
	ik.reset()
	await _advance_retarget_target(player, source_skeleton, target_skeleton, source_probe, retarget_probe, target_probe, 0.25)
	var first_source_rotation := source_probe.captured_rotation
	_check("RetargetModifier3D transfers the sampled rotation in the same tick", retarget_probe.captured_upper_rotation.is_equal_approx(first_source_rotation), "source=%s target=%s" % [first_source_rotation, retarget_probe.captured_upper_rotation])
	var goal_in_skeleton: Vector3 = target_skeleton.global_transform.affine_inverse() * ik_target.global_position
	var pre_ik_error := retarget_probe.captured_hand_global.origin.distance_to(goal_in_skeleton)
	var post_ik_error := target_probe.captured_hand_global.origin.distance_to(goal_in_skeleton)
	_check("TwoBoneIK3D moves the mapped hand closer to its target", post_ik_error + 0.001 < pre_ik_error, "goal=%s before=%s (%s) after=%s (%s)" % [goal_in_skeleton, retarget_probe.captured_hand_global.origin, pre_ik_error, target_probe.captured_hand_global.origin, post_ik_error])
	await _advance_retarget_target(player, source_skeleton, target_skeleton, source_probe, retarget_probe, target_probe, 0.25)
	_check("second tick transfers the changed source pose", not first_source_rotation.is_equal_approx(source_probe.captured_rotation) and retarget_probe.captured_upper_rotation.is_equal_approx(source_probe.captured_rotation), "first=%s source=%s target=%s" % [first_source_rotation, source_probe.captured_rotation, retarget_probe.captured_upper_rotation])
	var second_pre_error := retarget_probe.captured_hand_global.origin.distance_to(goal_in_skeleton)
	var second_post_error := target_probe.captured_hand_global.origin.distance_to(goal_in_skeleton)
	_check("IK follows the updated retargeted pose", second_post_error + 0.001 < second_pre_error, "before=%s (%s) after=%s (%s)" % [retarget_probe.captured_hand_global.origin, second_pre_error, target_probe.captured_hand_global.origin, second_post_error])
	pose_modifier.stop_clip()
	rig.queue_free()
	await get_tree().process_frame


func _advance_retarget_target(player: AnimationPlayer, source: Skeleton3D, target: Skeleton3D, source_probe, retarget_probe, ik_probe, delta: float) -> void:
	var source_samples: int = source_probe.sample_count
	var target_samples: int = ik_probe.sample_count
	player.advance(delta)
	source.advance(0.0)
	target.advance(0.0)
	# Queue both manual updates before yielding. The source pass retargets first;
	# the target pass then runs TwoBoneIK3D over that new pose in the same tick.
	while source_probe.sample_count == source_samples or retarget_probe.sample_count == target_samples or ik_probe.sample_count == target_samples:
		await get_tree().process_frame
	await get_tree().process_frame


func _add_arm_chain(skeleton: Skeleton3D) -> void:
	skeleton.add_bone("Hips")
	skeleton.add_bone("LeftUpperArm")
	skeleton.set_bone_parent(1, 0)
	skeleton.add_bone("LeftLowerArm")
	skeleton.set_bone_parent(2, 1)
	skeleton.add_bone("LeftHand")
	skeleton.set_bone_parent(3, 2)
	skeleton.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	skeleton.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	skeleton.set_bone_rest(3, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	skeleton.reset_bone_poses()


func _make_animation() -> Animation:
	var animation := Animation.new()
	animation.length = DURATION
	animation.loop_mode = Animation.LOOP_LINEAR
	var hand_track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(hand_track, NodePath("Skeleton:Hand"))
	animation.track_insert_key(hand_track, 0.0, Vector3.ZERO)
	animation.track_insert_key(hand_track, DURATION, Vector3(1, 0, 0))

	var root_track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(root_track, NodePath("Skeleton:Root"))
	animation.track_insert_key(root_track, 0.0, Vector3.ZERO)
	animation.track_insert_key(root_track, DURATION, Vector3(2, 0, 0))

	var property_track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(property_track, NodePath("..:property_value"))
	animation.track_insert_key(property_track, 0.0, 0.0)
	animation.track_insert_key(property_track, DURATION, 1.0)

	var method_track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(method_track, NodePath(".."))
	animation.track_insert_key(method_track, 0.5, {"method": "record_native_event", "args": ["native"]})
	return animation


func _make_cutscene() -> Animation:
	var animation := Animation.new()
	animation.length = DURATION
	var property_track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(property_track, NodePath("..:property_value"))
	animation.track_insert_key(property_track, 0.0, 7.0)
	animation.track_insert_key(property_track, DURATION, 7.0)
	var method_track := animation.add_track(Animation.TYPE_METHOD)
	animation.track_set_path(method_track, NodePath(".."))
	animation.track_insert_key(method_track, 0.1, {"method": "record_native_event", "args": ["cutscene"]})
	return animation


func _has_track_path(animation: Animation, path: NodePath) -> bool:
	for track_index in animation.get_track_count():
		if animation.track_get_path(track_index) == path:
			return true
	return false
