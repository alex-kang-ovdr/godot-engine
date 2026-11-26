@tool
extends Control
## Soldier 114-Bone Tactical Demo & Side-by-Side Engine Comparison Studio.
## Compares Godot AnimationPlayer (left) vs Godot 16-bit QuantizedClip / C++
## CrowdEvaluator pose buffer (right) in real time on the internalized 114-bone
## Soldier + M4 rifle asset (soldier_motion.res + soldier_skin.glb), plus optional
## SDK oracle error telemetry when soldier/generated/oracle.json is present.

const Hero := preload("res://hero/hero.gd")
const SoldierStore := preload("res://soldier/soldier_motion_store.gd")
const CrowdEvaluator := preload("res://addons/animation_studio/crowd_evaluator.gd")

const CLIP_LABELS := {
	"idle": "idle · 전투 대기 (M4 조준)",
	"walk": "walk · 전술 보행",
	"jog": "jog · 전술 조깅",
	"run": "run · 전력 질주",
	"vault": "vault · 낮은 엄폐물 뛰어넘기",
}

var data: Dictionary = {}
var oracle: Dictionary = {}
var assets_ready: bool = false
var compare_mode: bool = true
var selected_clip: String = "walk"
var elapsed: float = 0.0
var playing: bool = true
var playback_speed: float = 1.0
var animations: Dictionary = {} # clip_key -> Animation
var qclips: Dictionary = {}     # clip_key -> CrowdEvaluator.QuantizedClip
var skin_stats: Dictionary = {}

# 3D scene nodes
var preview_viewport: SubViewport
var preview_stage: Node3D
var camera: Camera3D
var left_motion: Node3D
var left_rig: Skeleton3D
var right_motion: Node3D
var right_rig: Skeleton3D
var left_tag_mesh: MeshInstance3D
var right_tag_mesh: MeshInstance3D

# UI controls
var back_button: Button
var mode_single_btn: Button
var mode_compare_btn: Button
var clip_option: OptionButton
var play_btn: Button
var speed_option: OptionButton
var timeline: HSlider
var time_label: Label
var metrics_label: Label
var detail_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip_contents = true
	custom_minimum_size = Vector2(480, 280)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()
	_load_soldier()
	if assets_ready:
		select_clip("walk")
		set_compare_mode(true)


func _make_box(bg_hex: String, border_hex: String, pad := 5) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg_hex)
	sb.border_color = Color(border_hex)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	return sb


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#12151b")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var skin := Theme.new()
	if not Engine.is_editor_hint() and not OS.has_feature("web"):
		var font := SystemFont.new()
		font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans"])
		skin.default_font = font
	skin.default_font_size = 12
	theme = skin

	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_vbox.add_theme_constant_override("separation", 4)
	add_child(root_vbox)

	# Top Ribbon
	var top_panel := PanelContainer.new()
	top_panel.add_theme_stylebox_override("panel", _make_box("#1a1f28", "#2d3545", 5))
	root_vbox.add_child(top_panel)
	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 8)
	top_panel.add_child(top_bar)

	if not Engine.is_editor_hint():
		back_button = Button.new()
		back_button.text = "← 모션 실험실"
		back_button.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/animation_lab.tscn"))
		top_bar.add_child(back_button)

	var brand := Label.new()
	brand.text = "◆ SOLDIER 114-BONE · M4 DEMO COMPARE"
	brand.modulate = Color("#f39c2b")
	top_bar.add_child(brand)

	mode_compare_btn = Button.new()
	mode_compare_btn.text = "나란히 비교 (AnimationPlayer vs 16-bit C++)"
	mode_compare_btn.toggle_mode = true
	mode_compare_btn.pressed.connect(func(): set_compare_mode(true))
	top_bar.add_child(mode_compare_btn)

	mode_single_btn = Button.new()
	mode_single_btn.text = "단독 보기"
	mode_single_btn.toggle_mode = true
	mode_single_btn.pressed.connect(func(): set_compare_mode(false))
	top_bar.add_child(mode_single_btn)

	var badge := Label.new()
	badge.text = "● 114 Bones · 9 Meshes (M4 Rifle) · Native GLB/RES"
	badge.modulate = Color("#4ad689")
	top_bar.add_child(badge)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	clip_option = OptionButton.new()
	clip_option.item_selected.connect(func(i: int):
		var key := str(clip_option.get_item_metadata(i))
		select_clip(key)
	)
	top_bar.add_child(clip_option)

	# Main split: Left Telemetry & Comparison Card | Right 3D Viewport
	var main_hsplit := HSplitContainer.new()
	main_hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(main_hsplit)

	var left_panel := PanelContainer.new()
	left_panel.custom_minimum_size.x = 290
	left_panel.add_theme_stylebox_override("panel", _make_box("#171b22", "#2a3240", 8))
	main_hsplit.add_child(left_panel)

	var left_vbox := VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", 6)
	left_panel.add_child(left_vbox)

	var h1 := Label.new()
	h1.text = "Soldier 내재화 에셋 & 데모 비교"
	h1.modulate = Color("#2cc7b8")
	left_vbox.add_child(h1)

	metrics_label = Label.new()
	metrics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	metrics_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	metrics_label.modulate = Color("#dce6f4")
	left_vbox.add_child(metrics_label)

	var vp_panel := PanelContainer.new()
	vp_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_panel.add_theme_stylebox_override("panel", _make_box("#14181f", "#2a3240", 3))
	main_hsplit.add_child(vp_panel)

	var vp_vbox := VBoxContainer.new()
	vp_vbox.add_theme_constant_override("separation", 3)
	vp_panel.add_child(vp_vbox)

	var view_container := SubViewportContainer.new()
	view_container.stretch = true
	view_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_vbox.add_child(view_container)

	preview_viewport = SubViewport.new()
	preview_viewport.own_world_3d = true
	preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view_container.add_child(preview_viewport)

	preview_stage = Node3D.new()
	preview_viewport.add_child(preview_stage)
	_build_3d_stage()

	detail_label = Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.modulate = Color("#b8cbe0")
	vp_vbox.add_child(detail_label)

	# Bottom Transport Bar
	var bot_panel := PanelContainer.new()
	bot_panel.add_theme_stylebox_override("panel", _make_box("#171b22", "#2a3240", 5))
	root_vbox.add_child(bot_panel)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bot_panel.add_child(bar)

	play_btn = Button.new()
	play_btn.text = "일시정지"
	play_btn.pressed.connect(func(): set_playing(not playing))
	bar.add_child(play_btn)

	var step_btn := Button.new()
	step_btn.text = "+1/60s"
	step_btn.pressed.connect(func():
		set_playing(false)
		sample_at(elapsed + 1.0 / 60.0)
	)
	bar.add_child(step_btn)

	speed_option = OptionButton.new()
	for lbl in ["0.25×", "0.5×", "1.0×", "2.0×"]:
		speed_option.add_item(lbl)
	speed_option.select(2)
	speed_option.item_selected.connect(func(i: int): playback_speed = [0.25, 0.5, 1.0, 2.0][i])
	bar.add_child(speed_option)

	time_label = Label.new()
	time_label.custom_minimum_size.x = 120
	bar.add_child(time_label)

	timeline = HSlider.new()
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.step = 0.005
	timeline.value_changed.connect(func(v: float):
		set_playing(false)
		sample_at(v)
	)
	bar.add_child(timeline)


func _build_3d_stage() -> void:
	camera = Camera3D.new()
	camera.fov = 38.0
	camera.current = true
	preview_stage.add_child(camera)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.78, -0.52, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	preview_stage.add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#182029")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.45
	env_node.environment = env
	preview_stage.add_child(env_node)

	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(36, 36)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color("#2b3540")
	pmat.roughness = 0.95
	pm.material = pmat
	floor_mi.mesh = pm
	preview_stage.add_child(floor_mi)

	# Left Soldier (Godot AnimationPlayer reference)
	left_motion = Node3D.new()
	left_motion.name = "LeftSoldier"
	preview_stage.add_child(left_motion)
	left_rig = Skeleton3D.new()
	left_rig.name = "Rig"
	left_motion.add_child(left_rig)
	left_tag_mesh = _make_pedestal(left_motion, Color("#2cc7b8"))

	# Right Soldier (16-bit QuantizedClip / C++ CrowdEvaluator path)
	right_motion = Node3D.new()
	right_motion.name = "RightSoldier"
	preview_stage.add_child(right_motion)
	right_rig = Skeleton3D.new()
	right_rig.name = "Rig"
	right_motion.add_child(right_rig)
	right_tag_mesh = _make_pedestal(right_motion, Color("#f39c2b"))


func _make_pedestal(parent: Node3D, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.42
	cyl.bottom_radius = 0.44
	cyl.height = 0.02
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col.darkened(0.45)
	mat.roughness = 0.85
	cyl.material = mat
	mi.mesh = cyl
	mi.position.y = 0.01
	parent.add_child(mi)
	return mi


func _load_soldier() -> void:
	assets_ready = false
	data = SoldierStore.load_motion_dict()
	if data.is_empty() or (data.get("clips", {}) as Dictionary).is_empty():
		metrics_label.text = "내재화된 Soldier 리소스(soldier/assets/soldier_motion.res)를 찾을 수 없습니다."
		return
	oracle = SoldierStore.load_optional_oracle()

	for target_rig: Skeleton3D in [left_rig, right_rig]:
		target_rig.clear_bones()
		for bone in data.skeleton.bones:
			var idx := target_rig.add_bone(bone.name)
			target_rig.set_bone_parent(idx, int(bone.parent))
			target_rig.set_bone_rest(idx, Hero.transform_from(bone.bind))
		target_rig.reset_bone_poses()

	skin_stats = SoldierStore.load_skin_into_skeleton(left_rig)
	SoldierStore.load_skin_into_skeleton(right_rig)

	animations.clear()
	qclips.clear()
	clip_option.clear()
	var idx := 0
	for clip_key in ["idle", "walk", "jog", "run", "vault"]:
		if not data.clips.has(clip_key):
			continue
		var anim := _build_animation(data.clips[clip_key], left_rig)
		animations[clip_key] = anim
		qclips[clip_key] = CrowdEvaluator.QuantizedClip.bake_from_animation(anim, left_rig, 60.0)
		clip_option.add_item(CLIP_LABELS.get(clip_key, clip_key))
		clip_option.set_item_metadata(idx, clip_key)
		idx += 1

	assets_ready = animations.size() > 0


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


func set_compare_mode(enabled: bool) -> void:
	compare_mode = enabled
	if mode_compare_btn:
		mode_compare_btn.set_pressed_no_signal(compare_mode)
	if mode_single_btn:
		mode_single_btn.set_pressed_no_signal(not compare_mode)
	if right_motion:
		right_motion.visible = compare_mode
	sample_at(elapsed)


func set_playing(value: bool) -> void:
	playing = value
	if play_btn:
		play_btn.text = "일시정지" if playing else "재생"


func select_clip(clip_key: String) -> void:
	if not animations.has(clip_key):
		return
	selected_clip = clip_key
	for i in clip_option.item_count:
		if str(clip_option.get_item_metadata(i)) == clip_key:
			clip_option.select(i)
			break
	var anim: Animation = animations[clip_key]
	timeline.min_value = 0.0
	timeline.max_value = anim.length
	sample_at(0.0)


func sample_at(t: float) -> Dictionary:
	if not assets_ready or not animations.has(selected_clip):
		return {}
	var anim: Animation = animations[selected_clip]
	var qclip: CrowdEvaluator.QuantizedClip = qclips[selected_clip]
	elapsed = clampf(t, 0.0, anim.length)
	if timeline:
		timeline.set_value_no_signal(elapsed)
	if time_label:
		time_label.text = "%.2f / %.2f s" % [elapsed, anim.length]

	# Left: exact Animation interpolation (Godot AnimationPlayer path)
	left_rig.reset_bone_poses()
	for ti in anim.get_track_count():
		var bname := StringName(anim.track_get_path(ti).get_subname(0))
		var bi := left_rig.find_bone(bname)
		if bi < 0:
			continue
		match anim.track_get_type(ti):
			Animation.TYPE_POSITION_3D:
				left_rig.set_bone_pose_position(bi, anim.position_track_interpolate(ti, elapsed))
			Animation.TYPE_ROTATION_3D:
				left_rig.set_bone_pose_rotation(bi, anim.rotation_track_interpolate(ti, elapsed).normalized())
			Animation.TYPE_SCALE_3D:
				left_rig.set_bone_pose_scale(bi, anim.scale_track_interpolate(ti, elapsed))
	left_rig.force_update_all_bone_transforms()

	# Right: 16-bit QuantizedClip (C++ AnimationStudioCrowdEvaluator buffer)
	var fkey := clampf(elapsed * qclip.sample_rate, 0.0, float(qclip.key_count - 1))
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
		right_rig.set_bone_pose_position(b, p0.lerp(p1, frac))
		right_rig.set_bone_pose_rotation(b, r0.slerp(r1, frac).normalized())
		right_rig.set_bone_pose_scale(b, Vector3.ONE)
	right_rig.force_update_all_bone_transforms()

	var offset_x := -0.78 if compare_mode else 0.0
	left_motion.position = Vector3(offset_x, 0.0, 0.0)
	right_motion.position = Vector3(0.78, 0.0, 0.0)

	var look_at_pt := Vector3(0.0, 0.96, 0.0)
	camera.position = Vector3(0.0, 1.38, 3.35 if compare_mode else 2.55)
	camera.look_at(look_at_pt)

	# Compute live pose delta between AnimationPlayer and 16-bit QuantizedClip
	var max_pos_mm := 0.0
	var max_rot_deg := 0.0
	for b in left_rig.get_bone_count():
		max_pos_mm = maxf(max_pos_mm, left_rig.get_bone_pose_position(b).distance_to(right_rig.get_bone_pose_position(b)) * 1000.0)
		max_rot_deg = maxf(max_rot_deg, rad_to_deg(Hero.angle_between(left_rig.get_bone_pose_rotation(b), right_rig.get_bone_pose_rotation(b))))

	var rifle_idx := left_rig.find_bone("receiver")
	var rifle_err_mm := 0.0
	if rifle_idx >= 0:
		rifle_err_mm = left_rig.get_bone_global_pose(rifle_idx).origin.distance_to(right_rig.get_bone_global_pose(rifle_idx).origin) * 1000.0

	var est_uncomp := CrowdEvaluator.QuantizedClip.uncompressed_bytes(qclip.bone_count, qclip.key_count, true)
	var q_bytes := qclip.resident_bytes()
	var saving_pct := (1.0 - float(q_bytes) / float(maxi(1, est_uncomp))) * 100.0

	if metrics_label:
		metrics_label.text = (
			"리소스: soldier_motion.res + soldier_skin.glb\n"
			+ "스켈레톤: %d본 (M4 소총 3파츠 포함)\n"
			+ "메시: %d개 · %d정점 · 텍스처 표면 %d\n\n"
			+ "[실시간 엔진 경로 비교]\n"
			+ "좌(청록): Godot AnimationPlayer (float32)\n"
			+ "우(주황): C++ CrowdEvaluator (16-bit)\n\n"
			+ "현재 클립: %s (%.2f / %.2fs)\n"
			+ "전신 최대 로컬 위치 차: %.4f mm\n"
			+ "전신 최대 로컬 회전 차: %.4f°\n"
			+ "M4 소총(receiver) 말단 차: %.4f mm\n"
			+ "양자화 메모리 절감: %.1f%% (%d KB)\n"
			+ "선택 SDK 오라클: %s"
		) % [
			left_rig.get_bone_count(),
			(skin_stats.get("meshes", []) as Array).size(),
			int(skin_stats.get("vertices", 0)),
			int(skin_stats.get("textured_surfaces", 0)),
			selected_clip, elapsed, anim.length,
			max_pos_mm, max_rot_deg, rifle_err_mm,
			saving_pct, int(q_bytes / 1024),
			"사용 가능 (oracle.json)" if not oracle.is_empty() else "미설치 (네이티브 단독 실행)",
		]
	if detail_label:
		detail_label.text = "Clip: %s · %.3fs · Left=AnimationPlayer vs Right=16-bit C++ · Local Δ=%.4fmm / %.4f° · M4 Δ=%.4fmm" % [
			selected_clip, elapsed, max_pos_mm, max_rot_deg, rifle_err_mm
		]
	return {
		"max_pos_mm": max_pos_mm,
		"max_rot_deg": max_rot_deg,
		"rifle_err_mm": rifle_err_mm,
		"saving_pct": saving_pct,
	}


func _process(delta: float) -> void:
	if not assets_ready or not playing or not animations.has(selected_clip):
		return
	var dur: float = (animations[selected_clip] as Animation).length
	if dur > 0.0:
		sample_at(fposmod(elapsed + delta * playback_speed, dur))
