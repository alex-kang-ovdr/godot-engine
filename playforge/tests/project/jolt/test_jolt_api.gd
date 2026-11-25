extends Node
## Jolt 패치 API 존재·동작 시험.
## 83f5f345: PlayForgePhysicsBatch.sync_multimesh_from_bodies (PhysicsServer3D::batch_fill_multimesh_buffer 무박싱 경로)
## e7a83dd7: GSK 모드·협역 A/B 계측 API
## 패치가 빠진 엔진에서도 파싱 오류 대신 FAIL 이 나오도록 정적 메서드는 ClassDB.class_call_static 으로 부른다.

const PFTest = preload("res://lib/pf_test.gd")
const C_BATCH := "83f5f345"
const C_GSK := "e7a83dd7"
const CLS := "PlayForgePhysicsBatch"

var t: PFTest


func _init() -> void:
	t = PFTest.new("jolt_api")


func _call(method: String, args: Array = []) -> Variant:
	return ClassDB.class_call_static.callv([CLS, method] + args)


func _ready() -> void:
	await PFTest.frames(get_tree(), 1)
	var engine_name: String = ProjectSettings.get_setting("physics/3d/physics_engine")
	t.check("project_uses_jolt", C_BATCH, engine_name == "Jolt Physics", engine_name)
	# 스크립트에서 PhysicsServer3D 싱글톤의 get_class() 는 "PhysicsServer3D" 를 돌려줘 엔진 구분에 못 쓴다.
	# Jolt 가 실제로 돌고 있다는 증거는 아래 협역 계측 카운터(Jolt 내부에서만 증가)로 대신한다.

	var has_cls := ClassDB.class_exists(CLS)
	t.check("class_exists", C_BATCH, has_cls)
	if not has_cls:
		t.finish(get_tree())
		return
	for m in ["sync_multimesh_from_bodies", "clear_cache"]:
		t.check("method:" + m, C_BATCH, ClassDB.class_has_method(CLS, m, true))
	for m in ["set_jolt_gsk_mode", "get_jolt_gsk_mode", "set_jolt_narrow_stats_enabled", "reset_jolt_narrow_stats", "get_jolt_narrow_stats"]:
		t.check("method:" + m, C_GSK, ClassDB.class_has_method(CLS, m, true))

	# --- GSK 모드 ---
	var default_mode: int = _call("get_jolt_gsk_mode")
	t.check("gsk_default_mode_hybrid_2", C_GSK, default_mode == 2, "mode=%d" % default_mode)
	var roundtrip := true
	for m in [0, 1, 2]:
		_call("set_jolt_gsk_mode", [m])
		roundtrip = roundtrip and int(_call("get_jolt_gsk_mode")) == m
	t.check("gsk_mode_roundtrip", C_GSK, roundtrip)
	_call("set_jolt_gsk_mode", [2])

	# --- 협역 계측 ---
	var keys := ["pair_total", "pair_cache_hits", "pair_cache_misses", "gsk_warm_hits", "gsk_early_sep", "gjk_calls", "gjk_iters", "epa_calls", "narrow_phase_ms"]
	_call("reset_jolt_narrow_stats")
	var st0: Dictionary = _call("get_jolt_narrow_stats")
	var has_keys := true
	for k in keys:
		has_keys = has_keys and st0.has(k)
	t.check("narrow_stats_keys", C_GSK, has_keys, str(st0.keys()))
	t.check("narrow_stats_reset_zero", C_GSK, int(st0.get("pair_total", -1)) == 0 and int(st0.get("gjk_calls", -1)) == 0)

	var world := _make_world()
	_spawn_pile(world.get_child(0), 60)
	# 계측 꺼진 동안은 증가하지 않아야 한다
	_call("set_jolt_narrow_stats_enabled", [false])
	await _physics_ticks(30)
	var st_off: Dictionary = _call("get_jolt_narrow_stats")
	t.check("narrow_stats_disabled_no_counting", C_GSK, int(st_off["pair_total"]) == 0, str(st_off))
	_call("set_jolt_narrow_stats_enabled", [true])
	await _physics_ticks(60)
	var st: Dictionary = _call("get_jolt_narrow_stats")
	_call("set_jolt_narrow_stats_enabled", [false])
	t.info("narrow_stats_60_ticks_60_bodies", st)
	t.check("narrow_stats_count_pairs", C_GSK, int(st["pair_total"]) > 0 and int(st["pair_total"]) == int(st["pair_cache_hits"]) + int(st["pair_cache_misses"]), str(st))
	t.check("narrow_stats_gjk_runs", C_GSK, int(st["gjk_calls"]) > 0 or int(st["epa_calls"]) > 0, "gjk=%s epa=%s" % [st["gjk_calls"], st["epa_calls"]])
	t.check("narrow_stats_hybrid_warm_hits", C_GSK, int(st["gsk_warm_hits"]) > 0, "gsk_warm_hits=%s (mode 2 hybrid)" % st["gsk_warm_hits"])
	_call("reset_jolt_narrow_stats")
	t.check("narrow_stats_reset", C_GSK, int((_call("get_jolt_narrow_stats") as Dictionary)["pair_total"]) == 0)
	world.queue_free()
	await PFTest.frames(get_tree(), 1)

	# --- sync_multimesh_from_bodies ---
	await _check_batch_sync(16, "serial")
	await _check_batch_sync(3000, "parallel_ge_2048")
	var empty: int = _call("sync_multimesh_from_bodies", [RID(), PackedInt64Array(), PackedFloat32Array()])
	t.check("batch_sync_invalid_multimesh_returns_0", C_BATCH, empty == 0)
	_call("clear_cache")
	t.finish(get_tree())


func _physics_ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _make_world() -> SubViewport:
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.world_3d = World3D.new()
	var root3d := Node3D.new()
	sv.add_child(root3d)
	add_child(sv)
	var floor_body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	col.shape = box
	floor_body.add_child(col)
	floor_body.position = Vector3(0, -0.5, 0)
	root3d.add_child(floor_body)
	return sv


func _spawn_pile(parent: Node3D, n: int) -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.5, 0.5, 0.5)
	for i in n:
		var rb := RigidBody3D.new()
		var c := CollisionShape3D.new()
		c.shape = shape
		rb.add_child(c)
		rb.position = Vector3((i % 4) * 0.55 - 0.8, 0.3 + (i / 4) * 0.55, ((i / 2) % 2) * 0.55)
		parent.add_child(rb)


func _check_batch_sync(n: int, label: String) -> void:
	var space := get_viewport().find_world_3d().space
	var shape := PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(shape, Vector3(0.25, 0.25, 0.25))
	var rids := PackedInt64Array()
	var custom := PackedFloat32Array()
	var bodies: Array[RID] = []
	var expected: Array[Transform3D] = []
	for i in n:
		var b := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(b, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_add_shape(b, shape)
		# 공간 안(i 짝수)과 공간 밖(i 홀수) 경로를 모두 지난다
		if i % 2 == 0:
			PhysicsServer3D.body_set_space(b, space)
		var xf := Transform3D(Basis(Vector3.UP, 0.01 * i), Vector3(i * 0.5, 1000.0 + (i % 7), -i * 0.25))
		PhysicsServer3D.body_set_state(b, PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		bodies.append(b)
		expected.append(xf)
		rids.append(b.get_id())
		custom.append(float(i) * 0.5)
	var mm := RenderingServer.multimesh_create()
	RenderingServer.multimesh_allocate_data(mm, n, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true)
	var t0 := Time.get_ticks_usec()
	var written: int = _call("sync_multimesh_from_bodies", [mm, rids, custom])
	var us := Time.get_ticks_usec() - t0
	var buf := RenderingServer.multimesh_get_buffer(mm)
	var bad := 0
	var first_bad := ""
	if buf.size() == n * 16:
		for i in n:
			var o := i * 16
			var x: Transform3D = expected[i]
			var got_origin := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
			var got_x := Vector3(buf[o + 0], buf[o + 4], buf[o + 8])
			if not got_origin.is_equal_approx(x.origin) or not got_x.is_equal_approx(x.basis.x) or not is_equal_approx(buf[o + 12], custom[i]):
				bad += 1
				if first_bad.is_empty():
					first_bad = "i=%d got %s/%s want %s/%s custom %s" % [i, got_origin, got_x, x.origin, x.basis.x, buf[o + 12]]
	t.check("batch_sync_%s_n%d" % [label, n], C_BATCH, written == n and buf.size() == n * 16 and bad == 0,
			"written=%d buf=%d mismatches=%d %s" % [written, buf.size(), bad, first_bad])
	t.info("batch_sync_%s_n%d_usec" % [label, n], us)
	RenderingServer.free_rid(mm)
	for b in bodies:
		PhysicsServer3D.free_rid(b)
	PhysicsServer3D.free_rid(shape)
	await PFTest.frames(get_tree(), 1)
