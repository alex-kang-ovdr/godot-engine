extends Node3D
## 표현 모드 1(초상) → 0(3D 월드) 전환 시 초상 UI 제거 시험 (fe0b4fe1).
## PlayForgePlatform::_remove_portrait_ui()는 봉인 레이어를 권한 범위 안에서 queue_free 하지만,
## 실제 해제는 다음 프레임 SceneTree::_flush_delete_queue()에서 권한 범위 밖으로 일어난다.
## 이때 봉인 자식의 NOTIFICATION_PREDELETE → parent->remove_child() 가 봉인 검사에 막히면 엔진이 중단될 수 있다.
## 엔진이 살아남아 SUMMARY 를 출력해야 PASS 다.

const PFTest = preload("res://lib/pf_test.gd")
const C := "fe0b4fe1"

var t: PFTest


func _init() -> void:
	t = PFTest.new("portrait_mode_switch")


func _ready() -> void:
	await PFTest.frames(get_tree(), 2)
	var pf := PFTest.pf()
	if not t.check("setup_singleton_and_avatar", C, pf != null and pf.get_local_avatar() != null):
		t.finish(get_tree())
		return
	pf.set_avatar_presentation_mode(1)
	await PFTest.frames(get_tree(), 2)
	var p := pf.get_avatar_portrait_ui() as Control
	t.check("setup_mode1_portrait_sealed", C, p != null and PFTest.sealed(p) and PFTest.sealed(p.get_parent()))
	t.info("about_to_switch", "set_avatar_presentation_mode(0): 봉인 초상 레이어 해제가 다음 프레임에 일어남")
	pf.set_avatar_presentation_mode(0)
	await PFTest.frames(get_tree(), 3)
	t.check("mode0_removes_portrait_without_crash", C, pf.get_avatar_portrait_ui() == null and not is_instance_valid(p))
	t.check("mode0_world_avatar_present", C, pf.get_local_avatar() != null and PFTest.sealed(pf.get_local_avatar()))
	t.finish(get_tree())
