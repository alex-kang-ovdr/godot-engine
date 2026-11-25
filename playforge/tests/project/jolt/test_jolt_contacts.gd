extends Node
## JoltContactListener3D fast path 스모크 시험 (c9050da1).
## 패치는 OnContactAdded/Persisted 에서 접촉 보고·충돌 응답 재정의·표면 속도 처리를 조건부로 건너뛰고,
## OnContactRemoved 를 플래그로 락 없이 빠져나가게 했다. 건너뛰면 안 되는 경우가 여전히 동작하는지 본다.
## - contact_monitor 켠 강체: body_entered / get_colliding_bodies 보고 (_try_add_contacts)
## - Area3D: body_entered / body_exited (센서 경로, 영역 겹침 제거)
## - 서로 다른 layer/mask 쌍(한쪽만 감지): _try_override_collision_response 경로
## - 상자 해제 후 접촉 제거(OnContactRemoved) 경로
## 엔진 오류 로그 0건, 모든 강체 위치 유한·바닥 위를 확인한다. 시간은 INFO.

const PFTest = preload("res://lib/pf_test.gd")
const C := "c9050da1"
const N_BODIES := 800

var t: PFTest
var body_entered := 0
var body_exited := 0
var area_entered := 0
var area_exited := 0


func _init() -> void:
	t = PFTest.new("jolt_contacts")


func _ready() -> void:
	await PFTest.frames(get_tree(), 1)
	var mark := t.error_mark()
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.world_3d = World3D.new()
	var root3d := Node3D.new()
	sv.add_child(root3d)
	add_child(sv)

	# 구덩이: 바닥 + 벽 4개
	for spec in [[Vector3(0, -0.5, 0), Vector3(12, 1, 12)], [Vector3(6.5, 4, 0), Vector3(1, 10, 14)], [Vector3(-6.5, 4, 0), Vector3(1, 10, 14)], [Vector3(0, 4, 6.5), Vector3(14, 10, 1)], [Vector3(0, 4, -6.5), Vector3(14, 10, 1)]]:
		var sb := StaticBody3D.new()
		var c := CollisionShape3D.new()
		var b := BoxShape3D.new()
		b.size = spec[1]
		c.shape = b
		sb.add_child(c)
		sb.position = spec[0]
		root3d.add_child(sb)

	# 구덩이 아래쪽 절반을 덮는 감지 영역
	var area := Area3D.new()
	var ac := CollisionShape3D.new()
	var ab := BoxShape3D.new()
	ab.size = Vector3(12, 3, 12)
	ac.shape = ab
	area.add_child(ac)
	area.position = Vector3(0, 1.5, 0)
	area.body_entered.connect(func(_b): area_entered += 1)
	area.body_exited.connect(func(_b): area_exited += 1)
	root3d.add_child(area)

	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 0.4, 0.4)
	var sphere := SphereShape3D.new()
	sphere.radius = 0.22
	var bodies: Array[RigidBody3D] = []
	var monitored: Array[RigidBody3D] = []
	var one_way_pairs := 0
	for i in N_BODIES:
		var rb := RigidBody3D.new()
		var c := CollisionShape3D.new()
		c.shape = box if i % 3 != 0 else sphere
		rb.add_child(c)
		rb.position = Vector3((i % 20) * 0.5 - 4.75, 1.0 + float(i / 400) * 0.8, ((i / 20) % 20) * 0.5 - 4.75)
		if i % 4 == 0:
			rb.contact_monitor = true
			rb.max_contacts_reported = 4
			rb.body_entered.connect(func(_b): body_entered += 1)
			rb.body_exited.connect(func(_b): body_exited += 1)
			monitored.append(rb)
		if i % 10 == 5:
			# 한쪽만 감지하는 쌍: layer 2, mask 0 (다른 상자는 layer 1, mask 1|2 로 이 상자를 감지)
			rb.collision_layer = 2
			rb.collision_mask = 0
			one_way_pairs += 1
		else:
			rb.collision_layer = 1
			rb.collision_mask = 1 | 2
		root3d.add_child(rb)
		bodies.append(rb)
	# 표면 속도(정적 컨베이어) 경로: constant_linear_velocity 를 가진 정적 판 위에 상자 몇 개
	var conveyor := StaticBody3D.new()
	var cc := CollisionShape3D.new()
	var cb := BoxShape3D.new()
	cb.size = Vector3(2, 0.2, 2)
	cc.shape = cb
	conveyor.add_child(cc)
	conveyor.position = Vector3(0, 9.0, 0)
	conveyor.constant_linear_velocity = Vector3(1, 0, 0)
	root3d.add_child(conveyor)
	for k in 4:
		var rb := RigidBody3D.new()
		var c := CollisionShape3D.new()
		c.shape = box
		rb.add_child(c)
		rb.position = Vector3(-0.6 + k * 0.45, 9.4, 0)
		root3d.add_child(rb)

	var t0 := Time.get_ticks_usec()
	for i in 180:
		await get_tree().physics_frame
	var ms_settle := float(Time.get_ticks_usec() - t0) / 1000.0
	var colliding := 0
	for m in monitored:
		if not m.get_colliding_bodies().is_empty():
			colliding += 1
	t.check("monitored_bodies_report_contacts", C, body_entered > 0 and colliding > 0, "body_entered=%d monitored_now_colliding=%d/%d" % [body_entered, colliding, monitored.size()])
	t.check("area_overlap_enter_reported", C, area_entered > 0, "area_entered=%d" % area_entered)

	# 접촉 제거 경로: 절반 해제
	var exited_before := area_exited
	var removed := 0
	for i in range(0, bodies.size(), 2):
		bodies[i].queue_free()
		removed += 1
	var survivors: Array[RigidBody3D] = []
	for i in range(1, bodies.size(), 2):
		survivors.append(bodies[i])
	t0 = Time.get_ticks_usec()
	for i in 90:
		await get_tree().physics_frame
	var ms_after := float(Time.get_ticks_usec() - t0) / 1000.0
	t.check("area_exit_on_body_removal", C, area_exited > exited_before, "area_exited %d -> %d after freeing %d bodies" % [exited_before, area_exited, removed])
	t.check("monitored_body_exit_reported", C, body_exited > 0, "body_exited=%d" % body_exited)

	# 일반 강체(layer 1)는 바닥 위에 있어야 하고, layer 2/mask 0 강체는 정적 바닥(mask 1)과 서로 감지하지 않으므로
	# 바닥을 통과해 떨어져야 한다(Godot layer/mask 의미 유지 확인).
	var bad := 0
	var below := 0
	var normal := 0
	var one_way_fell := 0
	var one_way_total := 0
	for b in survivors:
		var p := b.global_position
		if not p.is_finite():
			bad += 1
		elif b.collision_layer == 2:
			one_way_total += 1
			if p.y < -0.5:
				one_way_fell += 1
		else:
			normal += 1
			if p.y < -0.5:
				below += 1
	t.check("all_bodies_finite_and_normal_above_floor", C, bad == 0 and below == 0 and normal > 0, "nonfinite=%d below_floor=%d of %d normal" % [bad, below, normal])
	t.check("one_way_layer_bodies_skip_static_floor", C, one_way_pairs > 0 and one_way_total > 0 and one_way_fell == one_way_total, "fell=%d/%d" % [one_way_fell, one_way_total])
	var errs := t.errors_since(mark)
	t.check("no_engine_errors", C, errs.is_empty(), "%d errors: %s" % [errs.size(), "; ".join(errs.slice(0, 3))])
	t.info("timing", {"bodies": N_BODIES, "settle_180_ticks_ms": snappedf(ms_settle, 0.1), "after_removal_90_ticks_ms": snappedf(ms_after, 0.1)})
	sv.queue_free()
	await PFTest.frames(get_tree(), 1)
	t.finish(get_tree())
