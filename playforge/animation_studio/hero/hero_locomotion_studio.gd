@tool
extends Control
## Hero Locomotion State-Machine Authoring Walkthrough & 255-Tick Rewind Studio.
## Runs identically inside the Godot Editor bottom panel and as a standalone scene.

const Hero := preload("res://hero/hero.gd")
const Locomotion := preload("res://hero/locomotion.gd")
const PoseBuffer := preload("res://addons/animation_studio/pose_buffer.gd")
const HeroSMCanvas := preload("res://hero/hero_sm_canvas.gd")

const MOTION_FILE := "res://hero/generated/motion.json"
const SKIN_FILE := "res://hero/generated/hero_skin.gltf"
const STEP := 1.0 / 60.0
const TOTAL_TICKS := 255

const STAGE_TITLES := [
	"1단계 · 원본 리그·스킨 & Idle 상태",
	"2단계 · 걷기 진입 전이 (Idle → Walk_Face_180 → Walk)",
	"3단계 · 달리기 전이 · Smoothstep · 카메라 리드 회전",
	"4단계 · 지형 레이캐스트 & 스윙 페이즈 발 IK",
	"5단계 · 완성 로코모션 & 255틱 전 구간 다시보기",
]

const STAGE_DESCRIPTIONS := [
	"Havok 원본 85본 Rig.hkt와 18,050정점 스킨 메시를 로드하고 기본 Idle_0 상태만 구동합니다.",
	"스틱 입력 시 Walk_Face_180으로 방향을 전환한 뒤 26틱 후 Walking 상태로 전이합니다. 달리기·회전·발 IK는 아직 비활성입니다.",
	"Running 상태, Smoothstep 전환 블렌딩(4틱/10틱), Walk→Run 회전 속도 유지, hero_camera.lua 3인칭 카메라 리드 각도를 추가합니다.",
	"평지·계단·경사면 지형 위에서 2본 발 IK와 스윙 페이즈 페이드아웃을 적용해 공중 보폭을 보존하면서 접지 발목을 보정합니다.",
	"전체 상태머신·카메라 리드·발 IK를 255틱 녹화했습니다. 타임라인과 전이 바로가기로 임의 틱을 되감아 포즈·상태를 다시봅니다.",
]

const KEY_JUMPS := [
	{"label": "t=0 Idle", "tick": 0},
	{"label": "t=31 걷기진입", "tick": 31},
	{"label": "t=57 걷기", "tick": 57},
	{"label": "t=90 달리기", "tick": 90},
	{"label": "t=150 우회전", "tick": 150},
	{"label": "t=202 정지", "tick": 202},
]

var data: Dictionary = {}
var build_stage: int = 5
var recorded_frames: Array[Dictionary] = []
var current_tick: int = 0
var playing: bool = true
var playback_speed: float = 1.0
var _accum: float = 0.0
var assets_ready: bool = false

# 3D preview nodes inside isolated SubViewport
var preview_viewport: SubViewport
var preview_stage: Node3D
var motion_node: Node3D
var rig: Skeleton3D
var camera: Camera3D
var trail_mesh: ImmediateMesh

# UI controls
var stage_option: OptionButton
var stage_desc: Label
var sm_canvas: HeroSMCanvas
var detail_label: Label
var timeline: HSlider
var tick_label: Label
var play_button: Button
var speed_option: OptionButton
var back_button: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	custom_minimum_size = Vector2(720, 360)
	_build_ui()
	_load_hero_assets()
	if assets_ready:
		set_build_stage(5)


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#132021")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var skin := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans"])
	skin.default_font = font
	skin.default_font_size = 14
	theme = skin

	var margin := MarginContainer.new()
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 8)
	margin.add_child(root_vbox)

	# Top bar: Back (runtime only) + Stage selector + Re-bake
	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 8)
	root_vbox.add_child(top_bar)

	if not Engine.is_editor_hint():
		back_button = Button.new()
		back_button.text = "← 모션 실험실"
		back_button.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/animation_lab.tscn"))
		top_bar.add_child(back_button)

	var title := Label.new()
	title.text = "Hero 로코모션 상태머신 · 제작 과정 다시보기"
	title.add_theme_font_size_override("font_size", 17)
	top_bar.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	var stage_lbl := Label.new()
	stage_lbl.text = "제작 단계:"
	top_bar.add_child(stage_lbl)

	stage_option = OptionButton.new()
	for s_title in STAGE_TITLES:
		stage_option.add_item(s_title)
	stage_option.select(4)
	stage_option.item_selected.connect(func(idx: int): set_build_stage(idx + 1))
	top_bar.add_child(stage_option)

	# Center split: Left (State machine diagram + walkthrough notes) / Right (3D SubViewport)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(split)

	var left_col := VBoxContainer.new()
	left_col.custom_minimum_size.x = 420
	left_col.add_theme_constant_override("separation", 6)
	split.add_child(left_col)

	stage_desc = Label.new()
	stage_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stage_desc.modulate = Color("#b8d1c8")
	left_col.add_child(stage_desc)

	sm_canvas = HeroSMCanvas.new()
	sm_canvas.custom_minimum_size = Vector2(412, 212)
	left_col.add_child(sm_canvas)

	detail_label = Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left_col.add_child(detail_label)

	var view_container := SubViewportContainer.new()
	view_container.stretch = true
	view_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(view_container)

	preview_viewport = SubViewport.new()
	preview_viewport.own_world_3d = true
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view_container.add_child(preview_viewport)

	preview_stage = Node3D.new()
	preview_viewport.add_child(preview_stage)
	_build_3d_stage()

	# Bottom rewind & keyframe jump bar
	var jump_bar := HBoxContainer.new()
	jump_bar.add_theme_constant_override("separation", 6)
	root_vbox.add_child(jump_bar)

	play_button = Button.new()
	play_button.text = "일시정지"
	play_button.pressed.connect(func(): set_playing(not playing))
	jump_bar.add_child(play_button)

	var prev_btn := Button.new()
	prev_btn.text = "◀ -1틱"
	prev_btn.pressed.connect(func(): set_playing(false); scrub_to(maxi(0, current_tick - 1)))
	jump_bar.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "+1틱 ▶"
	next_btn.pressed.connect(func(): set_playing(false); scrub_to(mini(maxi(0, recorded_frames.size() - 1), current_tick + 1)))
	jump_bar.add_child(next_btn)

	speed_option = OptionButton.new()
	for label in ["0.25×", "0.5×", "1.0×"]:
		speed_option.add_item(label)
	speed_option.select(2)
	speed_option.item_selected.connect(func(i: int): playback_speed = [0.25, 0.5, 1.0][i])
	jump_bar.add_child(speed_option)

	var jump_sep := Label.new()
	jump_sep.text = "  전이 점프:"
	jump_sep.modulate = Color("#89a69d")
	jump_bar.add_child(jump_sep)

	for j in KEY_JUMPS:
		var jb := Button.new()
		jb.text = j.label
		var target_t: int = j.tick
		jb.pressed.connect(func(): set_playing(false); scrub_to(target_t))
		jump_bar.add_child(jb)

	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(slider_row)

	tick_label = Label.new()
	tick_label.custom_minimum_size.x = 130
	tick_label.text = "틱 0 / 254 (0.00s)"
	slider_row.add_child(tick_label)

	timeline = HSlider.new()
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.min_value = 0
	timeline.max_value = TOTAL_TICKS - 1
	timeline.step = 1
	timeline.value_changed.connect(func(v: float):
		set_playing(false)
		scrub_to(int(v))
	)
	slider_row.add_child(timeline)


func _build_3d_stage() -> void:
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.current = true
	preview_stage.add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, -0.6, 0.0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	preview_stage.add_child(light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#213234")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.85
	env_node.environment = env
	preview_stage.add_child(env_node)

	# Shared Hero test terrain visuals (flat ground + 2 steps + slope)
	_add_terrain_box("LevelGround", Vector3(0.0, -0.12, 0.0), Vector3(30.0, 0.20, 30.0), Color("#4f615b"))
	_add_terrain_box("FirstStep", Vector3(-0.1, 0.08, 0.92), Vector3(0.8, 0.16, 0.55), Color("#738279"))
	_add_terrain_box("SecondStep", Vector3(0.15, 0.22, 1.47), Vector3(0.8, 0.12, 0.55), Color("#829087"))
	var slope := _add_terrain_box("Slope", Vector3(0.8, 0.13, 1.05), Vector3(1.0, 0.22, 1.8), Color("#687a70"))
	slope.rotation.z = deg_to_rad(-10.0)

	# Trail mesh showing root trajectory across the 255-tick replay
	trail_mesh = ImmediateMesh.new()
	var trail_inst := MeshInstance3D.new()
	trail_inst.mesh = trail_mesh
	var trail_mat := StandardMaterial3D.new()
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.albedo_color = Color("#f0a642")
	trail_inst.material_override = trail_mat
	preview_stage.add_child(trail_inst)

	motion_node = Node3D.new()
	motion_node.name = "Motion"
	preview_stage.add_child(motion_node)

	rig = Skeleton3D.new()
	rig.name = "Rig"
	motion_node.add_child(rig)


func _add_terrain_box(n: String, pos: Vector3, box_size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	var box := BoxMesh.new()
	box.size = box_size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	box.material = mat
	mi.mesh = box
	mi.position = pos
	preview_stage.add_child(mi)
	return mi


func _load_hero_assets() -> void:
	assets_ready = false
	if not FileAccess.file_exists(MOTION_FILE):
		detail_label.text = "Hero 원본 데이터(motion.json)가 없습니다. hero/README.md의 변환 명령을 먼저 실행하세요."
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MOTION_FILE))
	if not parsed is Dictionary or parsed.get("clips", {}).is_empty():
		detail_label.text = "motion.json 형식이 올바르지 않습니다."
		return
	data = parsed
	rig.clear_bones()
	for bone in data.skeleton.bones:
		var idx := rig.add_bone(bone.name)
		rig.set_bone_parent(idx, int(bone.parent))
		rig.set_bone_rest(idx, Hero.transform_from(bone.bind))
	rig.reset_bone_poses()
	_load_hero_skin()
	assets_ready = true


func _load_hero_skin() -> void:
	if not FileAccess.file_exists(SKIN_FILE):
		return
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	st.use_named_skin_binds = true
	if doc.append_from_file(SKIN_FILE, st) != OK:
		return
	var scene := doc.generate_scene(st)
	if scene == null:
		return
	for src: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		if src.mesh == null or src.skin == null:
			continue
		var src_rig := src.get_node_or_null(src.skeleton) as Skeleton3D
		var skin := src.skin.duplicate() as Skin
		var valid := true
		for i in skin.get_bind_count():
			var bname := skin.get_bind_name(i)
			if bname.is_empty() and src_rig:
				bname = src_rig.get_bone_name(skin.get_bind_bone(i))
			var bidx := rig.find_bone(bname)
			if bidx < 0:
				valid = false
				break
			skin.set_bind_name(i, bname)
			skin.set_bind_bone(i, bidx)
		if not valid:
			continue
		var vis := MeshInstance3D.new()
		vis.name = src.name
		vis.mesh = src.mesh
		vis.skin = skin
		vis.skeleton = ^".."
		rig.add_child(vis)
	scene.free()


func set_build_stage(stage: int) -> void:
	build_stage = clampi(stage, 1, 5)
	if stage_option and stage_option.selected != build_stage - 1:
		stage_option.select(build_stage - 1)
	stage_desc.text = STAGE_DESCRIPTIONS[build_stage - 1]
	if assets_ready:
		bake_replay()
		scrub_to(0)


func bake_replay() -> void:
	recorded_frames.clear()
	if not assets_ready:
		return

	motion_node.transform = Transform3D.IDENTITY
	rig.reset_bone_poses()

	var loco := Locomotion.new()
	loco.setup(rig, motion_node, data.clips)

	var left_foot := rig.find_bone("LeftLegFoot")
	var right_foot := rig.find_bone("RightLegFoot")
	var left_thigh := rig.find_bone("LeftLegThigh1")
	var left_calf := rig.find_bone("LeftLegCalf")
	var right_thigh := rig.find_bone("RightLegThigh1")
	var right_calf := rig.find_bone("RightLegCalf")
	var smoothed_y := [0.12, 0.12]

	for tick in TOTAL_TICKS:
		var stick := Hero.replay_input(tick)
		var walk_mod := Hero.replay_walk_modifier(tick)
		# Apply authoring-stage gating so users see each subsystem added step by step.
		var eff_stick := stick
		var eff_walk := walk_mod
		if build_stage == 1:
			eff_stick = Vector2.ZERO
			eff_walk = false
		elif build_stage == 2:
			# Only Idle -> IdleToWalk -> Walking (hold walk modifier, ignore right turn & run)
			eff_stick = Vector2(0.0, 0.45) if (tick >= 30 and tick < 195) else Vector2.ZERO
			eff_walk = tick >= 30 and tick < 195

		var step_res := loco.step(eff_stick, STEP, eff_walk)
		var ik_hits := 0
		var ik_offset_mm := 0.0
		if build_stage >= 4 and left_foot >= 0 and right_foot >= 0:
			var leg_bones := [[left_thigh, left_calf, left_foot], [right_thigh, right_calf, right_foot]]
			var root_y := motion_node.position.y
			for side in 2:
				var foot_idx: int = leg_bones[side][2]
				var ankle := rig.to_global(rig.get_bone_global_pose(foot_idx).origin)
				var ground_y := _analytic_terrain_height(ankle.x, ankle.z)
				ik_hits += 1
				var ankle_h := ankle.y - root_y
				var stance_w := clampf(1.0 - (ankle_h - 0.14) / 0.12, 0.0, 1.0)
				var desired_y := maxf(ankle.y + (ground_y - root_y) * stance_w, ground_y + 0.08)
				smoothed_y[side] = move_toward(smoothed_y[side], desired_y, STEP * 4.0)
				if stance_w > 0.001 or desired_y > ankle.y + 0.001:
					var target := Vector3(ankle.x, smoothed_y[side], ankle.z)
					ik_offset_mm = maxf(ik_offset_mm, absf(target.y - ankle.y) * 1000.0)
					_solve_two_bone_leg(leg_bones[side][0], leg_bones[side][1], foot_idx, rig.to_local(target))

		var outgoing_w := 0.0
		if not loco._outgoing_clip.is_empty() and loco._blend_duration > 0.0:
			var u := clampf(loco._state_elapsed / loco._blend_duration, 0.0, 1.0)
			outgoing_w = 1.0 - u * u * (3.0 - 2.0 * u)

		recorded_frames.append({
			"tick": tick,
			"state": str(step_res.state),
			"clip": str(step_res.clip),
			"clip_time": float(step_res.time),
			"stick": eff_stick,
			"walk_modifier": eff_walk,
			"root_transform": motion_node.transform,
			"yaw_deg": rad_to_deg(motion_node.rotation.y),
			"camera_lead_deg": rad_to_deg(loco._camera_angle),
			"outgoing_weight": outgoing_w,
			"outgoing_state": str(loco._outgoing_name),
			"ik_hits": ik_hits,
			"ik_offset_mm": ik_offset_mm,
			"pose": PoseBuffer.capture_from_skeleton(rig),
		})

	_rebuild_trail()
	timeline.max_value = maxi(0, recorded_frames.size() - 1)


func _analytic_terrain_height(x: float, z: float) -> float:
	# Mirrors terrain_ik.gd shared fixture so editor baking works synchronously without physics ticks.
	var y := -0.02
	if absf(x - (-0.1)) <= 0.4 and absf(z - 0.92) <= 0.275:
		y = maxf(y, 0.16)
	if absf(x - 0.15) <= 0.4 and absf(z - 1.47) <= 0.275:
		y = maxf(y, 0.28)
	if absf(x - 0.8) <= 0.5 and absf(z - 1.05) <= 0.9:
		y = maxf(y, 0.24 - (x - 0.8) * tan(deg_to_rad(10.0)))
	return y


func _solve_two_bone_leg(hip: int, knee: int, ankle: int, target: Vector3) -> void:
	if hip < 0 or knee < 0 or ankle < 0:
		return
	var h := rig.get_bone_global_pose(hip).origin
	var k := rig.get_bone_global_pose(knee).origin
	var a := rig.get_bone_global_pose(ankle).origin
	var upper := h.distance_to(k)
	var lower := k.distance_to(a)
	var dir := (target - h).normalized()
	var dist := clampf(h.distance_to(target), absf(upper - lower) + 0.001, upper + lower - 0.001)
	var bend := (k - h).slide(dir).normalized()
	if dir.is_zero_approx() or bend.is_zero_approx():
		return
	var along := (upper * upper - lower * lower + dist * dist) / (2.0 * dist)
	var desired_k := h + dir * along + bend * sqrt(maxf(0.0, upper * upper - along * along))
	_rotate_bone(hip, (k - h).normalized(), (desired_k - h).normalized())
	rig.force_update_all_bone_transforms()
	k = rig.get_bone_global_pose(knee).origin
	a = rig.get_bone_global_pose(ankle).origin
	_rotate_bone(knee, (a - k).normalized(), (h + dir * dist - k).normalized())
	rig.force_update_all_bone_transforms()


func _rotate_bone(index: int, from_v: Vector3, to_v: Vector3) -> void:
	var pose := rig.get_bone_global_pose(index)
	pose.basis = Basis(Quaternion(from_v, to_v)) * pose.basis
	rig.set_bone_global_pose(index, pose)


func _rebuild_trail() -> void:
	if trail_mesh == null:
		return
	trail_mesh.clear_surfaces()
	if recorded_frames.size() < 2:
		return
	trail_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for f in recorded_frames:
		var p: Vector3 = f.root_transform.origin
		trail_mesh.surface_add_vertex(Vector3(p.x, p.y + 0.04, p.z))
	trail_mesh.surface_end()


func set_playing(value: bool) -> void:
	playing = value
	if play_button:
		play_button.text = "일시정지" if playing else "재생"


func scrub_to(tick: int) -> Dictionary:
	if recorded_frames.is_empty():
		return {}
	current_tick = clampi(tick, 0, recorded_frames.size() - 1)
	var frame: Dictionary = recorded_frames[current_tick]
	motion_node.transform = frame.root_transform
	var pose: PoseBuffer = frame.pose
	pose.apply_to_skeleton(rig)
	rig.force_update_all_bone_transforms()

	var at: Vector3 = motion_node.position + Vector3(0.0, 0.98, 0.0)
	camera.position = at + Vector3(2.4, 0.72, 3.5)
	camera.look_at(at)

	if sm_canvas:
		sm_canvas.set_display(build_stage, frame)
	if timeline:
		timeline.set_value_no_signal(current_tick)
	if tick_label:
		tick_label.text = "틱 %d / %d (%.2fs)" % [current_tick, recorded_frames.size() - 1, float(current_tick) * STEP]
	if detail_label:
		var p: Vector3 = frame.root_transform.origin
		detail_label.text = "상태: %s  ·  클립: %s (%.2fs)\n루트: (%.2f, %.2f, %.2f) m  ·  Yaw: %.1f°\n카메라 리드: %+.1f°  ·  발 IK 보정: %.1f mm" % [
			frame.state, frame.clip, float(frame.clip_time),
			p.x, p.y, p.z, float(frame.yaw_deg),
			float(frame.camera_lead_deg), float(frame.ik_offset_mm),
		]
	return frame


func _process(delta: float) -> void:
	if not assets_ready or not playing or recorded_frames.is_empty():
		return
	_accum += delta * playback_speed
	if _accum >= STEP:
		var steps := int(_accum / STEP)
		_accum -= float(steps) * STEP
		scrub_to((current_tick + steps) % recorded_frames.size())
