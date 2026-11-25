extends RefCounted
## PlayForge 엔진 패치 회귀 시험 공용 헬퍼.
## 모든 결과는 한 줄짜리 `PFTEST {json}` 으로 stdout에 찍고, run.py가 이를 모은다.
## status: PASS / FAIL / INFO(측정값, 판정 없음) / GAP(패치 설계 밖 우회 관찰, 판정 없음) / NOT_COVERED

const PREFIX := "PFTEST "


class ErrLogger extends Logger:
	var mutex := Mutex.new()
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		mutex.lock()
		var kind := "WARNING" if error_type == Logger.ERROR_TYPE_WARNING else "ERROR"
		errors.append("%s: %s %s (%s:%d)" % [kind, code, rationale, file, line])
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func snapshot() -> Array[String]:
		mutex.lock()
		var copy := errors.duplicate()
		mutex.unlock()
		return copy


var suite: String
var pass_count := 0
var fail_count := 0
var logger := ErrLogger.new()
var _started_usec := Time.get_ticks_usec()


func _init(p_suite: String) -> void:
	suite = p_suite
	OS.add_logger(logger)
	_emit({"status": "START", "suite": suite, "engine": Engine.get_version_info().get("hash", ""), "version": Engine.get_version_info().get("string", "")})


func _emit(d: Dictionary) -> void:
	print(PREFIX + JSON.stringify(d))


func check(name: String, commit: String, cond: bool, detail: Variant = "") -> bool:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
	_emit({"status": "PASS" if cond else "FAIL", "suite": suite, "test": name, "commit": commit, "detail": str(detail)})
	return cond


func info(name: String, data: Variant) -> void:
	_emit({"status": "INFO", "suite": suite, "test": name, "data": data})


func gap(name: String, commit: String, detail: String) -> void:
	_emit({"status": "GAP", "suite": suite, "test": name, "commit": commit, "detail": detail})


func not_covered(name: String, commit: String, reason: String) -> void:
	_emit({"status": "NOT_COVERED", "suite": suite, "test": name, "commit": commit, "detail": reason})


## 표시 시점 이후 기록된 오류 중 기대한 봉인 차단 메시지를 뺀 것.
func error_mark() -> int:
	return logger.snapshot().size()


func errors_since(mark: int, include_seal := false) -> Array[String]:
	var all := logger.snapshot()
	var out: Array[String] = []
	for i in range(mark, all.size()):
		if include_seal or not all[i].contains("PlayForge Engine Seal"):
			out.append(all[i])
	return out


func seal_errors_since(mark: int) -> Array[String]:
	var all := logger.snapshot()
	var out: Array[String] = []
	for i in range(mark, all.size()):
		if all[i].contains("PlayForge Engine Seal"):
			out.append(all[i])
	return out


## 패치가 빠진 엔진에서도 파싱 오류 대신 FAIL로 끝나도록 싱글톤은 이름으로 찾는다.
static func pf() -> Object:
	return Engine.get_singleton("PlayForgePlatform") if Engine.has_singleton("PlayForgePlatform") else null


static func violations() -> int:
	var p := pf()
	return int(p.call("get_violation_count")) if p else -1


func finish(tree: SceneTree) -> void:
	var elapsed := float(Time.get_ticks_usec() - _started_usec) / 1000000.0
	_emit({"status": "SUMMARY", "suite": suite, "pass": pass_count, "fail": fail_count, "seconds": snappedf(elapsed, 0.001)})
	OS.remove_logger(logger)
	tree.quit(1 if fail_count > 0 else 0)


## 봉인 플래그 조회. 패치가 빠진 엔진에서도 파싱 오류 없이 false가 되도록 이름으로 호출한다.
static func sealed(o: Object) -> bool:
	return o != null and o.has_method("is_platform_sealed") and bool(o.call("is_platform_sealed"))


static func platform_min_size(c: Control) -> Vector2:
	return c.call("get_platform_min_size") if c.has_method("get_platform_min_size") else Vector2(-1, -1)


static func frames(tree: SceneTree, n: int) -> void:
	for i in n:
		await tree.process_frame


## 봉인 대상 변조 시도 한 건.
## (1) 대상이 실제로 봉인돼 있는지 먼저 확인하고, (2) 시도 후 위반 카운터가 늘고 상태가 유지되는지 확인하고,
## (3) decoy_factory가 있으면 같은 조작을 봉인되지 않은 대조 노드에 해서 조작 자체는 효과가 있음(시험이 공허하지 않음)을 확인한다.
## op(n): 노드에 가하는 조작. intact(n): 조작이 막혔으면 true.
func attempt(tree: SceneTree, name: String, commit: String, target: Node, op: Callable, intact: Callable, decoy_factory: Callable = Callable(), decoy_parent: Node = null) -> void:
	var setup_ok := is_instance_valid(target) and target.is_inside_tree() and sealed(target)
	var v0 := violations()
	var mark := error_mark()
	if setup_ok:
		op.call(target)
	await frames(tree, 2)
	var dv := violations() - v0
	var still: bool = is_instance_valid(target) and bool(intact.call(target))
	check(name, commit, setup_ok and dv >= 1 and still,
			"setup_sealed=%s violations+%d intact=%s seal_log_lines=%d" % [setup_ok, dv, still, seal_errors_since(mark).size()])
	if not decoy_factory.is_valid():
		return
	var decoy: Node = decoy_factory.call()
	decoy.name = "Decoy_" + name
	decoy_parent.add_child(decoy)
	await frames(tree, 1)
	var dv0 := violations()
	op.call(decoy)
	await frames(tree, 2)
	var decoy_unchanged: bool = is_instance_valid(decoy) and bool(intact.call(decoy))
	check(name + "__control_unsealed_takes_effect", commit, not decoy_unchanged and violations() == dv0,
			"decoy unchanged=%s violations+%d" % [decoy_unchanged, violations() - dv0])
	if is_instance_valid(decoy):
		if decoy.get_parent():
			decoy.get_parent().remove_child(decoy)
		decoy.free()
