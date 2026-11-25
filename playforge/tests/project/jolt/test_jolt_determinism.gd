extends Node
## 같은 기기 결정성 시험 (83f5f345 락프리 JobSystem·병렬 pre_step, c9050da1 접촉 리스너, e7a83dd7 GSK 워밍업 캐시).
## 600개 상자 탑(>=512 이라 병렬 pre_step 경로) + 90틱째 폭발 임펄스, 300 물리 틱.
## 매 실행마다 새 World3D(새 Jolt 공간)를 만들어 같은 프로세스 안에서 두 번 돌려 상태 hash 를 비교한다.
## hash: 위치를 1cm 로 양자화(HavokProfile 벤치마크와 같은 기준). 비트 단위 hash 와 시간은 INFO 로만 남긴다.
## run.py 는 이 스위트를 두 프로세스로 돌려 xproc_hash 도 비교한다.
## 사용자 인자 `--modes=2` 처럼 GSK 모드 목록을 줄 수 있다(기본 2,0,1).

const PFTest = preload("res://lib/pf_test.gd")
const C_JOB := "83f5f345"
const C_GSK := "e7a83dd7"
const CLS := "PlayForgePhysicsBatch"
const TICKS := 300
const EXPLODE_AT := 90
const GRID := 10
const HEIGHT := 6

var t: PFTest


func _init() -> void:
	t = PFTest.new("jolt_determinism")


func _ready() -> void:
	await PFTest.frames(get_tree(), 1)
	if not t.check("setup_playforge_batch_class", C_GSK, ClassDB.class_exists(CLS)):
		t.finish(get_tree())
		return
	var modes := [2, 0, 1]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--modes="):
			modes = Array(a.substr(8).split(",")).map(func(x): return int(x))
	var mark := t.error_mark()
	for mode in modes:
		ClassDB.class_call_static(CLS, "set_jolt_gsk_mode", mode)
		var r1 := await _simulate()
		var r2 := await _simulate()
		t.check("same_process_hash_equal_gsk_mode_%d" % mode, C_JOB if mode == 0 else C_GSK,
				r1.q == r2.q and r1.bodies == GRID * GRID * HEIGHT and r1.moved > 0,
				"q1=%s q2=%s bodies=%d moved=%d" % [r1.q.left(16), r2.q.left(16), r1.bodies, r1.moved])
		t.info("xproc_hash_gsk_mode_%d" % mode, {"xproc_hash": r1.q, "bit_exact_equal_in_process": r1.exact == r2.exact, "exact": r1.exact.left(16)})
		t.info("timing_gsk_mode_%d" % mode, {"run1_ms": r1.ms, "run2_ms": r2.ms, "ticks": TICKS, "bodies": r1.bodies})
	ClassDB.class_call_static(CLS, "set_jolt_gsk_mode", 2)
	var errs := t.errors_since(mark)
	t.check("no_engine_errors_during_simulation", C_JOB, errs.is_empty(), "%d errors: %s" % [errs.size(), "; ".join(errs.slice(0, 3))])
	t.finish(get_tree())


func _simulate() -> Dictionary:
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.world_3d = World3D.new()
	var root3d := Node3D.new()
	sv.add_child(root3d)
	add_child(sv)

	var floor_body := StaticBody3D.new()
	var fcol := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(60, 1, 60)
	fcol.shape = fbox
	floor_body.add_child(fcol)
	floor_body.position = Vector3(0, -0.5, 0)
	root3d.add_child(floor_body)

	var shape := BoxShape3D.new()
	shape.size = Vector3(0.5, 0.5, 0.5)
	var bodies: Array[RigidBody3D] = []
	for gx in GRID:
		for gz in GRID:
			for h in HEIGHT:
				var rb := RigidBody3D.new()
				var c := CollisionShape3D.new()
				c.shape = shape
				rb.add_child(c)
				rb.mass = 1.0
				rb.position = Vector3((gx - GRID / 2.0) * 0.7, 0.25 + h * 0.5, (gz - GRID / 2.0) * 0.7)
				root3d.add_child(rb)
				bodies.append(rb)
	var start: Array[Vector3] = []
	for b in bodies:
		start.append(b.position)

	var t0 := Time.get_ticks_usec()
	for tick in TICKS:
		await get_tree().physics_frame
		if tick == EXPLODE_AT:
			var center := Vector3(0.0, 0.0, 0.0)
			for b in bodies:
				var d := b.global_position - center
				var dist := maxf(d.length(), 0.25)
				b.apply_central_impulse(d.normalized() * (40.0 / (1.0 + dist * dist)) + Vector3.UP * 3.0)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0

	var q := PackedInt32Array()
	var exact := PackedFloat32Array()
	var moved := 0
	for i in bodies.size():
		var p := bodies[i].global_position
		var r := bodies[i].global_basis.get_rotation_quaternion()
		q.append_array([roundi(p.x * 100.0), roundi(p.y * 100.0), roundi(p.z * 100.0)])
		exact.append_array([p.x, p.y, p.z, r.x, r.y, r.z, r.w])
		if p.distance_to(start[i]) > 0.5:
			moved += 1
	var res := {
		"q": _sha(q.to_byte_array()),
		"exact": _sha(exact.to_byte_array()),
		"bodies": bodies.size(),
		"moved": moved,
		"ms": snappedf(ms, 0.1),
	}
	sv.queue_free()
	await PFTest.frames(get_tree(), 2)
	return res


func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
