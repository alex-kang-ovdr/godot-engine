extends SceneTree

const PoseClip = preload("res://addons/animation_studio/pose_clip.gd")
const SIDECAR_PATH := "res://fixture_anim.tres"
const SCENE_PATH := "res://fixture.gltf"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	assert(not args.is_empty(), "Expected prepare or verify phase argument.")
	match args[0]:
		"seed":
			_seed_sidecar_uid()
		"prepare":
			_prepare_override()
		"verify":
			_verify_reimport()
		_:
			assert(false, "Unknown phase: " + args[0])
	quit()


func _seed_sidecar_uid() -> void:
	var animation := Animation.new()
	assert(ResourceSaver.save(animation, SIDECAR_PATH) == OK)
	var uid := ResourceUID.create_id_for_path(SIDECAR_PATH)
	assert(ResourceSaver.set_uid(SIDECAR_PATH, uid) == OK)
	print("PASS_SEED: stable animation sidecar UID created")


func _prepare_override() -> void:
	var fixture := _instantiate_fixture()
	var player := _find_player(fixture)
	var skeleton := _find_skeleton(fixture)
	assert(player != null and skeleton != null, "Imported glTF must contain an AnimationPlayer and Skeleton3D.")
	var animation := ResourceLoader.load(SIDECAR_PATH, "Animation") as Animation
	assert(animation != null, "Importer did not create the animation sidecar.")
	assert(animation.get_track_count() == 1)
	assert(animation.track_get_type(0) == Animation.TYPE_POSITION_3D)
	var imported_path := animation.track_get_path(0)
	assert(imported_path.get_subname_count() == 1, "Imported skeletal tracks must use the canonical one-subname path.")
	var mixer_root: Node = player.get_node(player.root_node)
	assert(_resolve_target(mixer_root, imported_path) == skeleton, "Imported track must resolve to the scene skeleton.")

	# Bind first, then edit the original sidecar in memory. The active clip must
	# continue sampling its immutable snapshot.
	var clip = PoseClip.new()
	assert(clip.configure(animation, mixer_root, skeleton, NodePath()))
	assert(animation.get_track_count() == 1, "Binding must leave the imported sidecar resource intact.")
	assert(clip.playback.get_track_count() == 0)
	var start: Vector3 = animation.track_get_key_value(0, 0)
	var original_end: Vector3 = animation.track_get_key_value(0, 1)
	var expected_original_mid := (start + original_end) * 0.5
	animation.track_remove_key_at_time(0, animation.track_get_key_time(0, 1))
	animation.position_track_insert_key(0, 1.0, original_end + Vector3(6.0, 0.0, 0.0))
	clip.apply_pose(skeleton, 0.5)
	assert(skeleton.get_bone_pose_position(skeleton.find_bone("Hand")).is_equal_approx(expected_original_mid), "Active binding must retain the sample snapshot after source edits.")
	clip.stop()

	# Save a deliberate custom mapping. ResourceImporterScene preserves tracks
	# marked non-imported when keep_custom_tracks is enabled in the .import file.
	var sidecar_uid := ResourceLoader.get_resource_uid(SIDECAR_PATH)
	assert(sidecar_uid != ResourceUID.INVALID_ID, "The imported sidecar must have a UID before editing.")
	var override_path := NodePath(String(imported_path.get_concatenated_names()) + ":HandOverride")
	animation.track_remove_key_at_time(0, 1.0)
	animation.position_track_insert_key(0, 1.0, original_end)
	animation.track_set_path(0, override_path)
	animation.track_set_imported(0, false)
	assert(ResourceSaver.save(animation, SIDECAR_PATH) == OK)
	assert(ResourceSaver.set_uid(SIDECAR_PATH, sidecar_uid) == OK, "Saving the edited sidecar must preserve its UID.")
	assert(ResourceLoader.get_resource_uid(SIDECAR_PATH) == sidecar_uid)
	var uid_file := FileAccess.open(SIDECAR_PATH + ".uid", FileAccess.WRITE)
	assert(uid_file != null)
	uid_file.store_string(ResourceUID.id_to_text(sidecar_uid) + "\n")
	assert(animation.track_get_path(0) == override_path)
	fixture.free()
	print("PASS_PREPARE: immutable sample, source intact, custom HandOverride mapping saved")


func _verify_reimport() -> void:
	var fixture := _instantiate_fixture()
	var player := _find_player(fixture)
	var skeleton := _find_skeleton(fixture)
	assert(player != null and skeleton != null)
	var animation := ResourceLoader.load(SIDECAR_PATH, "Animation") as Animation
	assert(animation != null)
	assert(animation.get_track_count() == 2, "Reimport must preserve the custom track alongside the fresh imported track.")
	var hand_track := -1
	var override_track := -1
	for track_index in animation.get_track_count():
		var path := animation.track_get_path(track_index)
		if path.get_subname_count() != 1:
			continue
		match path.get_subname(0):
			"Hand":
				hand_track = track_index
			"HandOverride":
				override_track = track_index
	assert(hand_track >= 0 and override_track >= 0, "Both imported and custom-mapped tracks must survive reimport.")
	assert(animation.track_is_imported(hand_track), "Fresh source track should remain marked as imported.")
	assert(not animation.track_is_imported(override_track), "Custom mapping should remain marked as user-owned.")
	assert(animation.track_get_path(override_track).get_concatenated_names() == animation.track_get_path(hand_track).get_concatenated_names())
	assert(_resolve_target(player.get_node(player.root_node), animation.track_get_path(hand_track)) == skeleton)
	assert(_resolve_target(player.get_node(player.root_node), animation.track_get_path(override_track)) == skeleton)
	var fresh_end: Vector3 = animation.track_get_key_value(hand_track, 1)
	var old_end: Vector3 = animation.track_get_key_value(override_track, 1)
	assert(is_equal_approx(fresh_end.x, 4.0), "Fresh glTF accessor value was not imported.")
	assert(is_equal_approx(old_end.x, 2.25), "Custom override should retain the previous animation key data.")

	var clip = PoseClip.new()
	assert(clip.configure(animation, player.get_node(player.root_node), skeleton, NodePath()))
	assert(animation.get_track_count() == 2, "Binding must not mutate the reimported library resource.")
	clip.apply_pose(skeleton, 0.5)
	assert(skeleton.get_bone_pose_position(skeleton.find_bone("Hand")).is_equal_approx(Vector3(2.0, 0.0, 0.0)))
	assert(skeleton.get_bone_pose_position(skeleton.find_bone("HandOverride")).is_equal_approx(Vector3(1.125, 0.0, 0.0)))
	clip.stop()
	fixture.free()
	print("PASS_VERIFY: reimported keys sampled and custom mapping survived")


func _instantiate_fixture() -> Node:
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	assert(packed != null, "Unable to load imported glTF scene.")
	var instance := packed.instantiate()
	root.add_child(instance)
	return instance


func _find_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _resolve_target(root_node: Node, path: NodePath) -> Node:
	var names := NodePath(path.get_concatenated_names())
	return root_node if names.is_empty() else root_node.get_node_or_null(names)
