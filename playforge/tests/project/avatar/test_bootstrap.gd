extends Node3D
## 빈 3D 씬 자동 부트스트랩 시험.
## 이 씬은 루트 Node3D(이 스크립트)만 있고 충돌체·조명·메시·아바타가 없다.
## 엔진은 메인 씬 로드 훅(SceneTree::add_current_scene)에서 CoreHUD(layer 128)·바닥·조명·봉인 아바타를 넣어야 한다.
##
## `-- --avatar-presentation-mode=upper_body` 사용자 인자로 실행하면 CLI 표현 모드 덮어쓰기(fe0b4fe1)를 검사한다.

const PFTest = preload("res://lib/pf_test.gd")
const C_SEAL := "a18fb005"
const C_PORTRAIT := "fe0b4fe1"
const C_BUDGET := "ed003ce5"

var t: PFTest
var captured := {}
var cli_portrait := false


func _init() -> void:
	cli_portrait = OS.get_cmdline_user_args().has("--avatar-presentation-mode=upper_body")
	t = PFTest.new("avatar_bootstrap_cli_portrait" if cli_portrait else "avatar_bootstrap")
	# CoreHUD는 사용자 트리 조회에서 숨겨지므로, 트리 진입 신호로 참조를 잡아 실제로 생성됐는지 확인한다.
	(Engine.get_main_loop() as SceneTree).node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if not captured.has(n.name):
		captured[n.name] = n


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var pf := PFTest.pf()
	if not t.check("singleton_present", C_SEAL, pf != null, "Engine singleton PlayForgePlatform"):
		t.finish(get_tree())
		return
	t.check("is_engine_sealed", C_SEAL, pf.is_engine_sealed())
	if cli_portrait:
		_run_cli_portrait(pf)
	else:
		_run_default(pf)
	t.finish(get_tree())


func _run_default(pf: Object) -> void:
	# --- CoreHUD ---
	var hud: CanvasLayer = captured.get("PlayForgeCoreHUD") as CanvasLayer
	t.check("corehud_spawned", C_SEAL, hud != null and is_instance_valid(hud) and hud.is_inside_tree(), "captured via SceneTree.node_added")
	if hud:
		t.check("corehud_layer_128", C_SEAL, hud.layer == 128, "layer=%d" % hud.layer)
		t.check("corehud_sealed", C_SEAL, PFTest.sealed(hud))
		t.check("corehud_parent_is_root", C_SEAL, hud.get_parent() == get_tree().root)
		t.check("corehud_visible", C_SEAL, hud.visible)
	t.check("is_platform_hud_active", C_SEAL, pf.is_platform_hud_active())
	var topbar := captured.get("TopLeftPlatformBar") as Control
	t.check("corehud_topleft_bar_sealed", C_SEAL, topbar != null and PFTest.sealed(topbar))
	t.check("topbar_safe_inset", C_SEAL, pf.get_topbar_safe_inset() == Rect2(12, 12, 224, 44), str(pf.get_topbar_safe_inset()))

	# CoreHUD는 사용자 스크립트의 트리 조회에서 보이지 않아야 한다 (Node::_get_*_script 래퍼).
	var root := get_tree().root
	var listed := false
	for c in root.get_children(true):
		if c.name == "PlayForgeCoreHUD":
			listed = true
	t.check("corehud_hidden_from_get_children", C_SEAL, not listed, "root.get_children(true) n=%d" % root.get_child_count(true))
	t.check("corehud_hidden_from_get_node", C_SEAL, root.get_node_or_null("PlayForgeCoreHUD") == null and not root.has_node("PlayForgeCoreHUD"))
	t.check("corehud_hidden_from_find_child", C_SEAL, root.find_child("PlayForgeCoreHUD", true, false) == null and root.find_child("TopLeftPlatformBar", true, false) == null)

	# --- 아바타 ---
	var avatar: Node = pf.get_local_avatar()
	t.check("avatar_spawned", C_SEAL, avatar != null and avatar.is_inside_tree())
	if avatar:
		t.check("avatar_is_characterbody3d", C_SEAL, avatar is CharacterBody3D, avatar.get_class())
		t.check("avatar_name", C_SEAL, avatar.name == "PlayForgePlayerAvatar", str(avatar.name))
		t.check("avatar_parent_is_current_scene", C_SEAL, avatar.get_parent() == self and get_tree().current_scene == self)
		t.check("avatar_sealed", C_SEAL, PFTest.sealed(avatar))
		t.check("avatar_visible", C_SEAL, (avatar as Node3D).visible)
		# 코어 팩 없이 실행하므로 엔진 내장 TPS 대체 아바타(SealedCapsule/SealedFallbackBody/SealedCameraPivot)가 나와야 한다.
		var internal := 0
		for n in ["SealedCapsule", "SealedFallbackBody", "SealedCameraPivot", "SealedSpringArm", "SealedCamera"]:
			if captured.has(n) and is_instance_valid(captured[n]) and captured[n].is_inside_tree():
				internal += 1
		t.check("avatar_fallback_rig_present", C_SEAL, internal == 5, "internal sealed nodes found=%d/5" % internal)
		t.check("avatar_internal_hidden_from_tree", C_SEAL, avatar.get_child_count() == 0 and avatar.get_node_or_null("SealedCameraPivot") == null, "script-visible child_count=%d" % avatar.get_child_count())
		var cam := captured.get("SealedCamera") as Camera3D
		t.check("avatar_camera_current", C_SEAL, cam != null and get_viewport().get_camera_3d() == cam)
		# ed003ce5: 템플릿별 스폰 위치(project.godot [playforge] avatar/spawn_position)
		var want: Vector3 = ProjectSettings.get_setting("playforge/avatar/spawn_position", Vector3.INF)
		t.check("avatar_spawn_position_from_project_setting", C_BUDGET, (avatar as Node3D).position.is_equal_approx(want), "pos=%s want=%s" % [(avatar as Node3D).position, want])
	t.check("presentation_mode_world_3d", C_PORTRAIT, pf.get_avatar_presentation_mode() == 0, "mode=%d" % pf.get_avatar_presentation_mode())
	t.check("no_portrait_in_world_mode", C_PORTRAIT, pf.get_avatar_portrait_ui() == null)

	# --- 빈 씬 보정: 바닥·조명 ---
	var floor_body := get_node_or_null("PlayForgeBaseplateFloor")
	t.check("baseplate_floor_injected", C_SEAL, floor_body is StaticBody3D)
	t.check("default_light_injected", C_SEAL, get_node_or_null("PlayForgeDefaultLight") is DirectionalLight3D)

	# --- VFS 봉인 프리픽스 (main.cpp: 에디터가 아닌 실행에서 addons/playforge_avatar/ 봉인) ---
	var prefixes: PackedStringArray = pf.get_sealed_prefixes()
	t.check("vfs_prefix_sealed", C_SEAL, prefixes.has("addons/playforge_avatar/"), str(prefixes))
	t.check("no_violation_during_bootstrap", C_SEAL, PFTest.violations() == 0, "violations=%d" % PFTest.violations())


func _run_cli_portrait(pf: Object) -> void:
	# fe0b4fe1: CLI --avatar-presentation-mode=upper_body 가 프로젝트 기본(3D 월드)을 덮어써 상반신 초상 UI만 띄워야 한다.
	t.check("cli_mode_upper_body", C_PORTRAIT, pf.get_avatar_presentation_mode() == 1, "mode=%d" % pf.get_avatar_presentation_mode())
	var portrait: Control = pf.get_avatar_portrait_ui()
	t.check("cli_portrait_spawned", C_PORTRAIT, portrait != null and portrait.is_inside_tree())
	if portrait:
		t.check("cli_portrait_sealed", C_PORTRAIT, PFTest.sealed(portrait))
		t.check("cli_portrait_min_size_floor", C_PORTRAIT, PFTest.platform_min_size(portrait) == Vector2(128, 128), str(PFTest.platform_min_size(portrait)))
		t.check("cli_portrait_size_ge_min", C_PORTRAIT, portrait.size.x >= 128 and portrait.size.y >= 128, str(portrait.size))
		var layer := portrait.get_parent() as CanvasLayer
		t.check("cli_portrait_layer_115", C_PORTRAIT, layer != null and layer.layer == 115 and PFTest.sealed(layer), "layer=%s" % (layer.layer if layer else -1))
	t.check("cli_no_world_avatar", C_PORTRAIT, pf.get_local_avatar() == null)
	t.check("cli_corehud_still_active", C_SEAL, pf.is_platform_hud_active())
