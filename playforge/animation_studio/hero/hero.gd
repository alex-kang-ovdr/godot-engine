extends Node3D

const MOTION_FILE := "res://hero/generated/motion.json"

@onready var rig: Skeleton3D = $Motion/Rig
@onready var player: AnimationPlayer = $Player
var data: Dictionary
var oracle: Dictionary
var reference_index := -1
var selected := ""
var elapsed := 0.0
var running := true
var library := AnimationLibrary.new()
var skin_surfaces := 0
var skin_vertices := 0
var skin_problem := ""


static func vector(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


static func rotation(a: Array) -> Quaternion:
	return Quaternion(a[0], a[1], a[2], a[3]).normalized()


static func transform_from(t: Dictionary) -> Transform3D:
	return Transform3D(Basis(rotation(t.rotation)).scaled_local(vector(t.scale)), vector(t.translation))


static func angle_between(a: Quaternion, b: Quaternion) -> float:
	var d := a.normalized().inverse() * b.normalized()
	return 2.0 * atan2(Vector3(d.x, d.y, d.z).length(), absf(d.w))


func _ready() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR"])
	var theme := Theme.new()
	theme.default_font = font
	$UI/Panel.theme = theme
	%Back.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/animation_lab.tscn"))
	%Clips.item_selected.connect(func(i: int): select_clip(%Clips.get_item_text(i)))
	%Play.pressed.connect(func(): set_running(not running))
	%Step.pressed.connect(func(): set_running(false); sample_at(elapsed + 1.0 / 60.0))
	%Progress.value_changed.connect(func(t: float): set_running(false); sample_at(t))
	%Reference.pressed.connect(show_next_reference)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#253638")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.9
	$Camera.environment = env
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(100, 100)
	var mat := StandardMaterial3D.new()
	var tile := Image.create_empty(64, 64, false, Image.FORMAT_RGB8)
	tile.fill(Color("#52645e"))
	tile.fill_rect(Rect2i(0, 0, 64, 1), Color("#86978e"))
	tile.fill_rect(Rect2i(0, 0, 1, 64), Color("#86978e"))
	tile.generate_mipmaps()
	mat.albedo_color = Color("#626d67")
	mat.albedo_texture = ImageTexture.create_from_image(tile)
	mat.uv1_scale = Vector3(100, 100, 1)
	mat.roughness = 1.0
	floor_mesh.material = mat
	var ground := MeshInstance3D.new()
	ground.mesh = floor_mesh
	add_child(ground)
	if not FileAccess.file_exists(MOTION_FILE):
		%Readout.text = "Hero 원본 데이터가 없습니다. hero/README.md의 SDK 변환 명령을 실행하세요."
		%Play.disabled = true
		%Step.disabled = true
		%Progress.editable = false
		return
	var obj = JSON.parse_string(FileAccess.get_file_as_string(MOTION_FILE))
	if not obj is Dictionary or obj.get("schema_version") != 1 or obj.get("clips", {}).is_empty():
		%Readout.text = "Hero 데이터 형식을 확인하세요. SDK 원본에서 다시 생성할 수 있습니다."
		return
	data = obj
	if FileAccess.file_exists("res://hero/generated/oracle.json"):
		var decoded = JSON.parse_string(FileAccess.get_file_as_string("res://hero/generated/oracle.json"))
		if decoded is Dictionary:
			oracle = decoded
	for bone in data.skeleton.bones:
		var index := rig.add_bone(bone.name)
		rig.set_bone_parent(index, int(bone.parent))
		rig.set_bone_rest(index, transform_from(bone.bind))
	rig.reset_bone_poses()
	load_skin()
	player.add_animation_library("", library)
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for key in data.clips:
		%Clips.add_item(key)
	select_clip(%Clips.get_item_text(0))


func load_skin() -> void:
	var file := "res://hero/generated/hero_skin.gltf"
	if not FileAccess.file_exists(file):
		skin_problem = "스킨 없음 · SDK 변환 필요"
		return
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	state.use_named_skin_binds = true
	if document.append_from_file(file, state) != OK:
		skin_problem = "스킨 읽기 실패"
		return
	var scene := document.generate_scene(state)
	if scene == null:
		skin_problem = "스킨 장면 생성 실패"
		return
	for source: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		if source.mesh == null or source.skin == null:
			continue
		var source_rig := source.get_node_or_null(source.skeleton) as Skeleton3D
		var skin := source.skin.duplicate() as Skin
		for i in skin.get_bind_count():
			var bone := skin.get_bind_name(i)
			if bone.is_empty() and source_rig:
				bone = source_rig.get_bone_name(skin.get_bind_bone(i))
			var index := rig.find_bone(bone)
			if index < 0:
				skin_problem = "스킨 본 누락 · %s" % bone
				scene.free()
				return
			skin.set_bind_name(i, bone)
			skin.set_bind_bone(i, index)
		var visual := MeshInstance3D.new()
		visual.name = source.name
		visual.mesh = source.mesh
		visual.skin = skin
		visual.skeleton = ^".."
		rig.add_child(visual)
		skin_surfaces += visual.mesh.get_surface_count()
		for j in visual.mesh.get_surface_count():
			skin_vertices += visual.mesh.surface_get_array_len(j)
	scene.free()
	if skin_surfaces == 0:
		skin_problem = "바인딩된 메시 없음"


func select_clip(key: String) -> void:
	if not data.get("clips", {}).has(key):
		return
	player.stop()
	rig.reset_bone_poses()
	$Motion.transform = Transform3D.IDENTITY
	selected = key
	for i in %Clips.item_count:
		if %Clips.get_item_text(i) == key:
			%Clips.select(i)
			break
	reference_index = -1
	%Reference.disabled = oracle.get("clips", {}).get(key, {}).get("samples", []).is_empty()
	var clip: Dictionary = data.clips[key]
	if not library.has_animation(key):
		var anim := Animation.new()
		anim.length = clip.duration
		for track in clip.tracks:
			var bone := rig.get_bone_name(int(track.bone))
			add_keys(anim, NodePath("Motion/Rig:" + str(bone)), track.keys, true)
		if clip.get("root_motion") is Dictionary and not clip.root_motion.keys.is_empty():
			add_keys(anim, ^"Motion", clip.root_motion.keys, false)
		library.add_animation(key, anim)
	player.play(key)
	%Progress.max_value = clip.duration
	sample_at(0.0)


func add_keys(anim: Animation, path: NodePath, keys: Array, include_scale: bool) -> void:
	if keys.is_empty():
		return
	var pos := anim.add_track(Animation.TYPE_POSITION_3D)
	var rot := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(pos, path)
	anim.track_set_path(rot, path)
	var scale_track := -1
	if include_scale:
		scale_track = anim.add_track(Animation.TYPE_SCALE_3D)
		anim.track_set_path(scale_track, path)
	for k in keys:
		anim.position_track_insert_key(pos, k.time, vector(k.translation))
		anim.rotation_track_insert_key(rot, k.time, rotation(k.rotation))
		if include_scale:
			anim.scale_track_insert_key(scale_track, k.time, vector(k.scale))


func set_running(value: bool) -> void:
	running = value
	%Play.text = "일시정지" if running else "재생"


func sample_at(t: float) -> void:
	if selected.is_empty():
		return
	elapsed = clampf(t, 0, player.current_animation_length)
	player.seek(elapsed, true)
	%Progress.set_value_no_signal(elapsed)
	var at: Vector3 = $Motion.position + Vector3.UP * 0.98
	$Camera.position = at + Vector3(2.5, 0.55, 3.8)
	$Camera.look_at(at)
	%Readout.text = "%s   %.3f / %.3f s   ·   본 %d   ·   루트 (%.3f, %.3f, %.3f) m" % [
		selected, elapsed, player.current_animation_length, rig.get_bone_count(),
		$Motion.position.x, $Motion.position.y, $Motion.position.z]
	if not skin_problem.is_empty():
		%Readout.text += "   ·   " + skin_problem


func _process(delta: float) -> void:
	if running and not selected.is_empty():
		var duration := player.current_animation_length
		sample_at(fposmod(elapsed + delta, duration))


func show_next_reference() -> void:
	var samples: Array = oracle.clips[selected].samples
	reference_index = (reference_index + 1) % samples.size()
	var reference: Dictionary = samples[reference_index]
	set_running(false)
	sample_at(reference.time)
	if reference.pose.size() != rig.get_bone_count():
		%Readout.text += "   ·   기준 리그 불일치"
		return
	var translation_error := 0.0
	var rotation_error := 0.0
	for i in reference.pose.size():
		var expected: Dictionary = reference.pose[i]
		translation_error = maxf(translation_error, rig.get_bone_pose_position(i).distance_to(vector(expected.translation)))
		rotation_error = maxf(rotation_error, angle_between(rig.get_bone_pose_rotation(i), rotation(expected.rotation)))
	%Readout.text += "   ·   SDK 최대 오차 %.3f mm / %.3f°" % [translation_error * 1000.0, rad_to_deg(rotation_error)]
