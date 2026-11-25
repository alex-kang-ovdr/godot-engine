extends Node3D
## 봉인 아바타 변조 차단 시험 (a18fb005).
## 각 시도는 PFTest.attempt: 봉인 확인 → 시도 → 위반 카운터 증가·상태 유지 확인 → 봉인 안 된 대조 노드에서는 효과 있음 확인.

const PFTest = preload("res://lib/pf_test.gd")
const EvilScript = preload("res://lib/evil_script.gd")
const C_SEAL := "a18fb005"

var t: PFTest
var avatar: CharacterBody3D
var holder: Node3D


func _init() -> void:
	t = PFTest.new("avatar_seal")


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	await _frames(2)
	var pf := PFTest.pf()
	if not t.check("setup_singleton", C_SEAL, pf != null):
		t.finish(get_tree())
		return
	avatar = pf.get_local_avatar() as CharacterBody3D
	if not t.check("setup_avatar_sealed_in_tree", C_SEAL, avatar != null and avatar.is_inside_tree() and PFTest.sealed(avatar), "avatar=%s" % avatar):
		t.finish(get_tree())
		return
	holder = Node3D.new()
	holder.name = "UserHolder"
	add_child(holder)

	await _attempt("queue_free_blocked",
			func(n: Node3D): n.queue_free(),
			func(n: Node3D): return is_instance_valid(n) and n.is_inside_tree())
	await _attempt("free_blocked",
			func(n: Node3D): n.free(),
			func(n: Node3D): return is_instance_valid(n) and n.is_inside_tree())
	await _attempt("remove_child_blocked",
			func(n: Node3D): n.get_parent().remove_child(n),
			func(n: Node3D): return is_instance_valid(n) and n.get_parent() == self)
	await _attempt("reparent_blocked",
			func(n: Node3D): n.reparent(holder),
			func(n: Node3D): return is_instance_valid(n) and n.get_parent() == self)
	var orig_script: Variant = avatar.get_script()
	await _attempt("set_script_blocked",
			func(n: Node3D): n.set_script(EvilScript),
			func(n: Node3D): return is_instance_valid(n) and n.get_script() == (orig_script if n == avatar else null) and not ("pwned" in n))
	await _attempt("visible_false_blocked",
			func(n: Node3D): n.visible = false,
			func(n: Node3D): return n.visible)
	await _attempt("hide_blocked",
			func(n: Node3D): n.hide(),
			func(n: Node3D): return n.visible)
	await _attempt("scale_down_blocked",
			func(n: Node3D): n.scale = Vector3(0.01, 0.01, 0.01),
			func(n: Node3D): return n.scale.is_equal_approx(Vector3.ONE))
	await _attempt("process_mode_disable_blocked",
			func(n: Node3D): n.process_mode = Node.PROCESS_MODE_DISABLED,
			func(n: Node3D): return n.process_mode != Node.PROCESS_MODE_DISABLED)
	await _attempt("queue_delete_via_tree_blocked",
			func(n: Node3D): n.get_tree().queue_delete(n),
			func(n: Node3D): return is_instance_valid(n) and n.is_inside_tree())

	t.check("avatar_still_registered", C_SEAL, pf.get_local_avatar() == avatar and is_instance_valid(avatar))
	t.finish(get_tree())


func _attempt(name: String, op: Callable, intact: Callable) -> void:
	await t.attempt(get_tree(), name, C_SEAL, avatar, op, intact, func(): return CharacterBody3D.new(), self)
