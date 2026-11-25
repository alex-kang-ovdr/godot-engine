extends Node3D
## 봉인 아바타의 부모(사용자 현재 씬)를 사용자 스크립트가 queue_free 할 때 (a18fb005, 보존 수정).
## 기대 동작: 엔진이 중단되지 않고, 봉인 아바타는 삭제되지 않은 채 트리 루트로 옮겨져 마지막 월드 위치에
## 정지 상태로 남는다. 다음 씬이 로드되면 같은 인스턴스가 그 씬으로 입양되어 위치를 유지하고 처리가 복원되며,
## 아바타가 새로 하나 더 생기지 않는다.
## 결과 출력은 씬이 해제된 뒤에도 남도록 SceneTree 메타에 붙인 Probe 가 맡는다.

const PFTest = preload("res://lib/pf_test.gd")
const C := "a18fb005"
const MOVED_TO := Vector3(7.0, 1.25, -4.0)

var t: PFTest


class Probe:
	extends RefCounted
	var t: PFTest
	var avatar_ref: WeakRef
	var avatar_id: int
	var original_process_mode: int
	var tree: SceneTree
	var frames_left := 3
	var phase := 0

	func _avatar_count() -> int:
		var n := 0
		var stack: Array[Node] = [tree.root]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node.name == "PlayForgePlayerAvatar":
				n += 1
			for c in node.get_children(true):
				stack.push_back(c)
		return n

	func tick() -> void:
		frames_left -= 1
		if frames_left > 0:
			return
		if phase == 0:
			_check_preserved()
			# 다음 씬: 바닥·조명·아바타가 없는 빈 3D 씬으로 전환한다.
			var blank := Node3D.new()
			blank.name = "NextScene"
			var packed := PackedScene.new()
			packed.pack(blank)
			blank.free()
			tree.change_scene_to_packed(packed)
			phase = 1
			frames_left = 3
			return
		tree.process_frame.disconnect(tick)
		_check_adopted()
		t.finish(tree)

	func _check_preserved() -> void:
		t.check("engine_survives_freeing_parent_of_sealed_avatar", C, true, "부모 해제 후 3 프레임 생존")
		var avatar: Node3D = avatar_ref.get_ref()
		if not t.check("sealed_avatar_not_deleted", C, avatar != null, "부모 해제 후에도 아바타 인스턴스가 남음"):
			return
		t.check("preserved_at_tree_root", C, avatar.get_parent() == tree.root, "parent=%s" % [avatar.get_parent()])
		t.check("preserved_keeps_last_world_position", C, avatar.global_position.is_equal_approx(MOVED_TO), "global_position=%s 기대=%s" % [avatar.global_position, MOVED_TO])
		t.check("preserved_is_held_still", C, avatar.process_mode == Node.PROCESS_MODE_DISABLED, "process_mode=%d" % avatar.process_mode)
		t.check("preserved_still_sealed", C, PFTest.sealed(avatar))
		t.check("preserved_is_local_avatar", C, PFTest.pf().get_local_avatar() == avatar)

	func _check_adopted() -> void:
		var pf := PFTest.pf()
		var scene := tree.current_scene
		var avatar: Node3D = pf.get_local_avatar() if pf else null
		t.check("next_scene_loaded", C, scene != null and scene.name == "NextScene", "current_scene=%s" % [scene])
		if not t.check("next_scene_adopts_same_instance", C, avatar != null and avatar.get_instance_id() == avatar_id, "local_avatar=%s" % [avatar]):
			return
		t.check("adopted_into_current_scene", C, avatar.get_parent() == scene, "parent=%s" % [avatar.get_parent()])
		t.check("adopted_keeps_last_world_position", C, avatar.global_position.is_equal_approx(MOVED_TO), "global_position=%s" % [avatar.global_position])
		t.check("adopted_process_mode_restored", C, avatar.process_mode == original_process_mode, "process_mode=%d 기대=%d" % [avatar.process_mode, original_process_mode])
		t.check("adopted_has_no_preserve_marker", C, not avatar.has_meta("_playforge_preserved_process_mode"))
		t.check("no_duplicate_avatar", C, _avatar_count() == 1, "PlayForgePlayerAvatar 개수=%d" % _avatar_count())
		t.check("blank_next_scene_still_gets_floor", C, scene.find_child("PlayForgeBaseplateFloor", true, false) != null or _has_floor(scene))

	func _has_floor(scene: Node) -> bool:
		for c in scene.get_children(true):
			if c.name == "PlayForgeBaseplateFloor":
				return true
		return false


func _init() -> void:
	t = PFTest.new("sealed_parent_free")


func _ready() -> void:
	await PFTest.frames(get_tree(), 2)
	var pf := PFTest.pf()
	var avatar: Node3D = pf.get_local_avatar() if pf else null
	if not t.check("setup_avatar_child_of_current_scene", C, avatar != null and avatar.get_parent() == self and PFTest.sealed(avatar)):
		t.finish(get_tree())
		return
	# 봉인은 위치 변경을 막지 않는다(seal_gaps 관찰). 마지막 위치 유지 여부를 구분하려고 스폰 위치에서 옮긴다.
	avatar.global_position = MOVED_TO
	var probe := Probe.new()
	probe.t = t
	probe.avatar_ref = weakref(avatar)
	probe.avatar_id = avatar.get_instance_id()
	probe.original_process_mode = avatar.process_mode
	probe.tree = get_tree()
	get_tree().set_meta("pf_probe", probe)
	get_tree().process_frame.connect(probe.tick)
	t.info("about_to_free_parent", "current_scene.queue_free() at %s" % [MOVED_TO])
	queue_free()
