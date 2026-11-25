extends SkeletonModifier3D
## Install as the skeleton's first modifier. The AnimationPlayer owns playback
## time, root motion and non-pose tracks. Later modifiers see the sampled pose.

const PoseClip = preload("pose_clip.gd")
const LIBRARY := &"AnimationStudioRuntime"
const PLAYBACK := &"AnimationStudioRuntime/pose"

var _player: AnimationPlayer
var _library: AnimationLibrary
var _source_name: StringName
var _clip: PoseClip


## Start the named source from its beginning, with a hard cut. Validate the
## entire split before disturbing either the current clip or its player.
func play_clip(player: AnimationPlayer, animation_name: StringName) -> bool:
	var skeleton := get_skeleton()
	if not is_instance_valid(player) or not player.is_inside_tree() or not skeleton:
		return false
	if not active or not player.active or not player.has_animation(animation_name) or animation_name == PLAYBACK:
		return false
	for child in skeleton.get_children():
		if child is SkeletonModifier3D:
			if child != self:
				return false
			break
	if player.has_animation_library(LIBRARY) and player.get_animation_library(LIBRARY) != _library:
		return false
	# An active tree can evaluate the original bone tracks independently of the
	# player. Check at handoff rather than traversing the scene for every pose.
	for node in player.get_tree().root.find_children("*", "AnimationTree", true, false):
		var tree := node as AnimationTree
		if tree.active and not tree.anim_player.is_empty() and tree.get_node_or_null(tree.anim_player) == player:
			return false
	var clip := PoseClip.new()
	if not clip.configure(player.get_animation(animation_name), player.get_node_or_null(player.root_node), skeleton, player.root_motion_track):
		return false
	var library := AnimationLibrary.new()
	if library.add_animation(&"pose", clip.playback) != OK:
		return false

	stop_clip()
	if player.add_animation_library(LIBRARY, library) != OK:
		return false
	_player = player
	_library = library
	_source_name = animation_name
	_clip = clip
	player.play(PLAYBACK, 0.0)
	return true


func stop_clip() -> void:
	if is_instance_valid(_player) and _player.has_animation_library(LIBRARY) and _player.get_animation_library(LIBRARY) == _library:
		if _player.assigned_animation == PLAYBACK:
			_player.stop(true)
			if _player.has_animation(_source_name):
				_player.assigned_animation = _source_name
		_player.remove_animation_library(LIBRARY)
	_player = null
	_library = null
	_clip = null
	_source_name = &""


func _process_modification_with_delta(_delta: float) -> void:
	if _clip and is_instance_valid(_player) and _player.assigned_animation == PLAYBACK and _player.is_animation_active():
		_clip.apply_pose(get_skeleton(), _player.current_animation_position, _player.get_playing_speed() < 0.0)


func _exit_tree() -> void:
	stop_clip()
