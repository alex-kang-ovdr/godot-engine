extends Node3D
## 봉인 설계 밖 우회 경로 관찰 (판정 없음: GAP 또는 INFO 로만 기록).
## 패치가 명시적으로 막는 조작은 avatar_seal / corehud_seal 이 검사한다. 여기서는 패치가 다루지 않는 경로가
## 실제로 숨김·축소·제거와 같은 효과를 내는지 관찰해, 패치 유지·보강 판단 자료로 남긴다.

const PFTest = preload("res://lib/pf_test.gd")
const C := "a18fb005"

var t: PFTest
var captured := {}


func _init() -> void:
	t = PFTest.new("seal_gaps")
	(Engine.get_main_loop() as SceneTree).node_added.connect(func(n: Node): if not captured.has(n.name): captured[n.name] = n)


func _ready() -> void:
	await PFTest.frames(get_tree(), 2)
	var pf := PFTest.pf()
	var avatar := (pf.get_local_avatar() if pf else null) as Node3D
	var bar := captured.get("TopLeftPlatformBar") as Control
	if not t.check("setup_targets_sealed", C, avatar != null and bar != null and PFTest.sealed(avatar) and PFTest.sealed(bar)):
		t.finish(get_tree())
		return

	# 1) 숨김 처리된 CoreHUD 참조가 SceneTree.node_added 로 사용자 스크립트에 노출됨
	if captured.has("PlayForgeCoreHUD"):
		t.gap("corehud_reference_via_node_added", C, "SceneTree.node_added 신호로 숨겨진 PlayForgeCoreHUD 와 내부 Control 참조를 얻을 수 있음(조회 래퍼 우회). 변조는 개별 setter 봉인에 의존.")

	# 2) Node3D.transform/basis 로 스케일 변경 (set_scale만 봉인됨)
	var v0 := PFTest.violations()
	avatar.transform = Transform3D(Basis.from_scale(Vector3(0.01, 0.01, 0.01)), avatar.position)
	await PFTest.frames(get_tree(), 1)
	var sc := avatar.transform.basis.get_scale()
	if sc.x < 0.5:
		t.gap("avatar_scale_via_transform", C, "avatar.transform 에 축소 basis 대입 시 scale=%s, violations+%d (Node3D.set_scale 만 차단)" % [sc, PFTest.violations() - v0])
		avatar.transform = Transform3D(Basis(), avatar.position)
	else:
		t.info("avatar_scale_via_transform", "blocked, scale=%s" % sc)

	# 3) 아바타 위치를 멀리 이동 (위치는 봉인 대상 아님 — 게임플레이상 의도일 수 있음)
	var p0 := avatar.global_position
	avatar.global_position = Vector3(0, -100000, 0)
	if avatar.global_position.y < -1000:
		t.gap("avatar_teleport_out_of_view", C, "global_position 변경 허용 — 화면 밖으로 이동해 사실상 숨김 가능")
	avatar.global_position = p0

	# 4) CoreHUD 바를 화면 밖으로 이동 (Control.position 은 봉인 대상 아님)
	var bp := bar.position
	bar.position = Vector2(-100000, -100000)
	await PFTest.frames(get_tree(), 1)
	if bar.position.x < -1000:
		t.gap("corehud_bar_moved_offscreen", C, "TopLeftPlatformBar.position 변경 허용 — 화면 밖 이동으로 사실상 숨김 가능 (is_platform_hud_active=%s)" % pf.is_platform_hud_active())
	bar.position = bp

	# 5) 부모(사용자 씬)를 트리에서 떼면 봉인 아바타도 트리 밖으로 나감
	var root := get_tree().root
	root.remove_child(self)
	var out_of_tree := not avatar.is_inside_tree()
	root.add_child(self)
	if out_of_tree:
		t.gap("parent_scene_remove_child_cascade", C, "root.remove_child(current_scene) 로 봉인 아바타가 트리에서 빠짐(부모 노드는 봉인 대상 아님)")
	await PFTest.frames(get_tree(), 1)

	# 부모 씬 해제(current_scene.queue_free)는 엔진을 중단시키므로 sealed_parent_free 스위트로 분리했다.
	t.finish(get_tree())
