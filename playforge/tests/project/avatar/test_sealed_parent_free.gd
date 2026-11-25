extends Node3D
## 봉인 아바타의 부모(사용자 현재 씬)를 사용자 스크립트가 queue_free 할 때 엔진이 살아남는지 시험 (a18fb005).
## 부모 해제는 봉인 대상이 아니지만, 해제 과정의 NOTIFICATION_PREDELETE 에서 봉인 자식의 remove_child 가
## 봉인 검사에 막히면 해제된 자식 포인터가 부모 children 에 남아 엔진이 중단될 수 있다.
## 결과 출력은 씬이 해제된 뒤에도 남도록 SceneTree 메타에 붙인 Probe 가 맡는다.

const PFTest = preload("res://lib/pf_test.gd")
const C := "a18fb005"

var t: PFTest


class Probe:
	extends RefCounted
	var t: PFTest
	var avatar_ref: WeakRef
	var tree: SceneTree
	var frames_left := 3

	func tick() -> void:
		frames_left -= 1
		if frames_left > 0:
			return
		tree.process_frame.disconnect(tick)
		t.check("engine_survives_freeing_parent_of_sealed_avatar", C, true, "엔진이 해제 후 %d 프레임 동안 살아 있음" % 3)
		if avatar_ref.get_ref() == null:
			t.gap("parent_free_cascades_to_sealed_avatar", C, "current_scene.queue_free() 로 봉인 아바타도 함께 해제되고 재스폰되지 않음")
		t.finish(tree)


func _init() -> void:
	t = PFTest.new("sealed_parent_free")


func _ready() -> void:
	await PFTest.frames(get_tree(), 2)
	var pf := PFTest.pf()
	var avatar: Node = pf.get_local_avatar() if pf else null
	if not t.check("setup_avatar_child_of_current_scene", C, avatar != null and avatar.get_parent() == self and PFTest.sealed(avatar)):
		t.finish(get_tree())
		return
	var probe := Probe.new()
	probe.t = t
	probe.avatar_ref = weakref(avatar)
	probe.tree = get_tree()
	get_tree().set_meta("pf_probe", probe)
	get_tree().process_frame.connect(probe.tick)
	t.info("about_to_free_parent", "current_scene.queue_free()")
	queue_free()
