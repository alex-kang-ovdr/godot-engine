@tool
class_name MotionCommands
extends RefCounted
## PlayForge Motion Studio v3 — Unified Authoring Command & MCP Tool Contract Engine.
## Mirrors dist/agent-commands.js & dist/assets/agent-mcp-tool-contract.json natively
## inside Godot 4.7.2 so visible UI controls, Agent Replay workflows, and MCP tool
## schemas all execute through the exact same validated transaction & journal path.

const JournalScript := preload("res://addons/animation_studio/authoring/motion_journal.gd")

const AGENT_SCENARIO_STEPS := [
	{
		"step": 1,
		"id": "step_params",
		"label": "01 · 모션 기본값 조절",
		"summary": "Speed 3.4 / Blend 0.72",
		"commands": [
			{"op": "set_parameters", "values": {"speed": 3.4, "blend": 0.72}},
		],
	},
	{
		"step": 2,
		"id": "step_push_event",
		"label": "02 · 충격 이벤트 편집",
		"summary": "Push 48–84f / Strength 0.65",
		"commands": [
			{"op": "set_event_range", "event_id": "push", "start": 48, "end": 84},
			{"op": "set_event_strength", "event_id": "push", "value": 0.65},
		],
	},
	{
		"step": 3,
		"id": "step_physics",
		"label": "03 · 물리 회복 강도 조절",
		"summary": "Drive 0.82 / Limit 40°",
		"commands": [
			{"op": "set_physics", "values": {"strength": 0.82, "limit": 40}},
		],
	},
	{
		"step": 4,
		"id": "step_transitions",
		"label": "04 · 회복 전이 정리",
		"summary": "Air → Recover 0.28s / Recover → Idle 0.25s",
		"commands": [
			{"op": "set_transition", "transition_id": "air-recover", "values": {"duration": 0.28}},
			{"op": "set_transition", "transition_id": "recover-idle", "values": {"duration": 0.25}},
		],
	},
]

var journal: RefCounted = null
var write_access: bool = true
var active_gesture: bool = false
var frame_trace: Array[Dictionary] = []
var completed_agent_steps: Dictionary = {} # step_id -> commit_id
var _seq_counter: int = 0
var _status_message: String = "시안 문서 준비됨"


func _init(instance_name: String = "Hero_Arena", role: String = "hero_arena") -> void:
	var doc := build_default_document(instance_name, role)
	journal = JournalScript.create(doc)


static func build_default_document(instance_name: String, role: String) -> Dictionary:
	return {
		"instance": instance_name,
		"role": role,
		"defaultParameters": {
			"speed": 2.2,
			"turn": 0.1,
			"blend": 0.65,
		},
		"physics": {
			"strength": 0.65,
			"limit": 45,
			"balance": true,
			"impulse": 0.40,
			"joint": "Pelvis",
		},
		"events": [
			{
				"id": "stabilise",
				"label": "Stabilise",
				"track": "Behaviour / Balance",
				"kind": "behaviour",
				"start": 0,
				"end": 180,
				"strength": 0.65,
				"enabled": true,
			},
			{
				"id": "push",
				"label": "Push",
				"track": "External Force",
				"kind": "force",
				"start": 48,
				"end": 60,
				"strength": 0.55,
				"enabled": true,
			},
			{
				"id": "reach",
				"label": "Reach",
				"track": "Behaviour / Action",
				"kind": "behaviour",
				"start": 59,
				"end": 98,
				"strength": 0.72,
				"enabled": true,
			},
			{
				"id": "recover",
				"label": "Recover",
				"track": "Behaviour / Action",
				"kind": "behaviour",
				"start": 102,
				"end": 172,
				"strength": 0.80,
				"enabled": true,
			},
		],
		"transitions": [
			{"id": "idle-move", "from": "Idle", "to": "Run", "parameter": "speed", "threshold": 0.15, "duration": 0.20},
			{"id": "move-idle", "from": "Run", "to": "Idle", "parameter": "speed", "threshold": 0.15, "duration": 0.25},
			{"id": "move-air", "from": "Run", "to": "Jump", "parameter": "", "threshold": 0.0, "duration": 0.12},
			{"id": "air-recover", "from": "Jump", "to": "ClimbUp", "parameter": "", "threshold": 0.0, "duration": 0.20},
			{"id": "recover-idle", "from": "ClimbUp", "to": "Idle", "parameter": "", "threshold": 0.0, "duration": 0.30},
		],
		"nodes": [
			{"id": "idle", "label": "Idle", "type": "clip", "x": 40, "y": 40},
			{"id": "walk", "label": "Walk Forward", "type": "clip", "x": 40, "y": 150},
			{"id": "run", "label": "Run Forward", "type": "clip", "x": 40, "y": 260},
			{"id": "locomotion", "label": "Locomotion", "type": "blend", "x": 250, "y": 130},
			{"id": "foot_ik", "label": "Foot IK", "type": "ik", "x": 470, "y": 210},
			{"id": "output", "label": "Final Pose", "type": "output", "x": 650, "y": 150},
		],
	}


static func _fail(code: String, message: String, extra: Dictionary = {}) -> Dictionary:
	var err := {"code": code, "message": message}
	var out := {"ok": false, "error": err}
	for k in extra.keys():
		out[k] = extra[k]
	return out


func validate_document(doc: Dictionary) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var params: Dictionary = doc.get("defaultParameters", {}) as Dictionary
	var spd := float(params.get("speed", 0.0))
	if spd < 0.0 or spd > 6.0:
		issues.append({"level": "error", "message": "speed는 0–6 범위여야 합니다."})
	var phys: Dictionary = doc.get("physics", {}) as Dictionary
	var lim := int(phys.get("limit", 45))
	if lim < 0 or lim > 120:
		issues.append({"level": "error", "message": "Joint Limit은 0–120° 범위여야 합니다."})
	var evs: Array = doc.get("events", []) as Array
	for item in evs:
		var ev: Dictionary = item as Dictionary
		if int(ev.get("end", 0)) <= int(ev.get("start", 0)):
			issues.append({"level": "error", "message": "이벤트 %s의 종료 프레임은 시작보다 커야 합니다." % str(ev.get("id", ""))})
	return issues


func _find_by_id(arr: Array, id_str: String) -> Dictionary:
	for item in arr:
		if item is Dictionary and str((item as Dictionary).get("id", "")) == id_str:
			return item as Dictionary
	return {}


func _apply_one(doc: Dictionary, c: Dictionary) -> Dictionary:
	var op: String = str(c.get("op", ""))
	if op.is_empty():
		return _fail("INVALID_COMMAND", "명령에는 op가 필요합니다.")

	match op:
		"set_parameters":
			var vals_v: Variant = c.get("values", null)
			if not (vals_v is Dictionary) or (vals_v as Dictionary).is_empty():
				return _fail("EMPTY_COMMAND", "하나 이상의 파라미터 값을 지정하세요.")
			var vals: Dictionary = vals_v as Dictionary
			var params: Dictionary = doc["defaultParameters"] as Dictionary
			for k in vals.keys():
				var ks := str(k)
				if not (ks in ["speed", "turn", "blend"]):
					return _fail("INVALID_INPUT", "알 수 없는 파라미터 필드: " + ks)
				var v := float(vals[k])
				var lo := -1.0 if ks == "turn" else 0.0
				var hi := 6.0 if ks == "speed" else 1.0
				if v < lo or v > hi:
					return _fail("OUT_OF_RANGE", "%s 값은 %.1f–%.1f 범위여야 합니다." % [ks, lo, hi])
				params[ks] = snappedf(v, 0.001)
		"set_event_range":
			var eid := str(c.get("event_id", ""))
			var ev := _find_by_id(doc["events"] as Array, eid)
			if ev.is_empty():
				return _fail("TARGET_NOT_FOUND", "이벤트 %s을 찾을 수 없습니다." % eid)
			var st := int(c.get("start", -1))
			var en := int(c.get("end", -1))
			if st < 0 or st > 179 or en < 1 or en > 180:
				return _fail("OUT_OF_RANGE", "프레임 범위(0–180)를 확인하세요.")
			if en <= st:
				return _fail("INVALID_RANGE", "종료 프레임은 시작 프레임보다 커야 합니다.")
			ev["start"] = st
			ev["end"] = en
		"set_event_strength":
			var eid := str(c.get("event_id", ""))
			var ev := _find_by_id(doc["events"] as Array, eid)
			if ev.is_empty():
				return _fail("TARGET_NOT_FOUND", "이벤트 %s을 찾을 수 없습니다." % eid)
			var v := float(c.get("value", -1.0))
			if v < 0.0 or v > 1.0:
				return _fail("OUT_OF_RANGE", "강도는 0–1 범위여야 합니다.")
			ev["strength"] = snappedf(v, 0.001)
		"set_event_enabled":
			var eid := str(c.get("event_id", ""))
			var ev := _find_by_id(doc["events"] as Array, eid)
			if ev.is_empty():
				return _fail("TARGET_NOT_FOUND", "이벤트 %s을 찾을 수 없습니다." % eid)
			if not (c.get("enabled", null) is bool):
				return _fail("INVALID_INPUT", "enabled는 boolean이어야 합니다.")
			ev["enabled"] = bool(c["enabled"])
		"set_physics":
			var vals_v: Variant = c.get("values", null)
			if not (vals_v is Dictionary) or (vals_v as Dictionary).is_empty():
				return _fail("EMPTY_COMMAND", "하나 이상의 물리 값을 지정하세요.")
			var vals: Dictionary = vals_v as Dictionary
			var phys: Dictionary = doc["physics"] as Dictionary
			for k in vals.keys():
				var ks := str(k)
				if not (ks in ["strength", "limit", "balance", "impulse", "joint"]):
					return _fail("INVALID_INPUT", "알 수 없는 물리 필드: " + ks)
				if ks == "balance":
					if not (vals[k] is bool):
						return _fail("INVALID_INPUT", "balance는 boolean이어야 합니다.")
					phys["balance"] = bool(vals[k])
				elif ks == "joint":
					phys["joint"] = str(vals[k])
				elif ks == "limit":
					var lim := int(vals[k])
					if lim < 0 or lim > 120:
						return _fail("OUT_OF_RANGE", "limit은 0–120 정수여야 합니다.")
					phys["limit"] = lim
				else:
					var fv := float(vals[k])
					if fv < 0.0 or fv > 1.0:
						return _fail("OUT_OF_RANGE", "%s는 0–1 범위여야 합니다." % ks)
					phys[ks] = snappedf(fv, 0.001)
		"set_transition":
			var tid := str(c.get("transition_id", ""))
			var tr := _find_by_id(doc["transitions"] as Array, tid)
			if tr.is_empty():
				return _fail("TARGET_NOT_FOUND", "전이 %s을 찾을 수 없습니다." % tid)
			var vals_v: Variant = c.get("values", null)
			if not (vals_v is Dictionary) or (vals_v as Dictionary).is_empty():
				return _fail("EMPTY_COMMAND", "하나 이상의 전이 값을 지정하세요.")
			var vals: Dictionary = vals_v as Dictionary
			for k in vals.keys():
				var ks := str(k)
				if not (ks in ["threshold", "duration"]):
					return _fail("INVALID_INPUT", "알 수 없는 전이 필드: " + ks)
				if ks == "threshold" and str(tr.get("parameter", "")).is_empty():
					return _fail("INVALID_COMMAND", "요청 전이에는 threshold가 없습니다.")
				var fv := float(vals[k])
				var lo := -10.0 if ks == "threshold" else 0.0
				var hi := 10.0 if ks == "threshold" else 5.0
				if fv < lo or fv > hi:
					return _fail("OUT_OF_RANGE", "%s는 %.1f–%.1f 범위여야 합니다." % [ks, lo, hi])
				tr[ks] = snappedf(fv, 0.001)
		"rename_node":
			var nid := str(c.get("node_id", ""))
			var node := _find_by_id(doc["nodes"] as Array, nid)
			if node.is_empty():
				return _fail("TARGET_NOT_FOUND", "노드 %s을 찾을 수 없습니다." % nid)
			var lbl := str(c.get("label", "")).strip_edges()
			if lbl.is_empty() or lbl.length() > 96:
				return _fail("INVALID_INPUT", "이름은 1–96자 문자열이어야 합니다.")
			node["label"] = lbl
		"move_node":
			var nid := str(c.get("node_id", ""))
			var node := _find_by_id(doc["nodes"] as Array, nid)
			if node.is_empty():
				return _fail("TARGET_NOT_FOUND", "노드 %s을 찾을 수 없습니다." % nid)
			var nx := int(c.get("x", -1))
			var ny := int(c.get("y", -1))
			if nx < 8 or nx > 740 or ny < 8 or ny > 465:
				return _fail("OUT_OF_RANGE", "노드 좌표가 캔버스 범위 밖입니다.")
			node["x"] = nx
			node["y"] = ny
		_:
			return _fail("UNKNOWN_COMMAND", "지원하지 않는 명령: " + op)
	return {"ok": true}


func plan(commands: Array, base_doc: Dictionary) -> Dictionary:
	if commands.is_empty() or commands.size() > 24:
		return _fail("INVALID_BATCH", "1–24개의 명령을 지정하세요.")
	var draft: Dictionary = JournalScript.deep_clone(base_doc) as Dictionary
	for raw_c in commands:
		if not (raw_c is Dictionary):
			return _fail("INVALID_COMMAND", "명령은 객체여야 합니다.")
		var step_res := _apply_one(draft, raw_c as Dictionary)
		if not bool(step_res.get("ok", false)):
			return step_res
	var validation := validate_document(draft)
	for issue in validation:
		if str(issue.get("level", "")) == "error":
			return _fail("VALIDATION_FAILED", "문서 검증 실패: " + str(issue.get("message", "")))
	var ch: Array[Dictionary] = JournalScript.changes_between(base_doc, draft)
	return {
		"ok": true,
		"draft": draft,
		"changes": ch,
		"validation": validation,
		"command_count": commands.size(),
	}


# --- 8 Semantic MCP Contract Methods ---

func motion_read_state() -> Dictionary:
	var view: Dictionary = journal.call("get_view")
	return {
		"ok": true,
		"document": journal.call("get_state"),
		"selected_document": view["selectedSnapshot"],
		"revision": int(view["revision"]),
		"branch_id": str(view["branchId"]),
		"cursor_id": str(view["cursorId"]),
		"review_id": view["reviewId"],
		"reviewing": bool(view["reviewing"]),
		"editable": not bool(view["reviewing"]),
		"active_gesture": active_gesture,
		"agent_write_allowed": write_access,
		"status_message": _status_message,
	}


func motion_preview_commands(input: Dictionary) -> Dictionary:
	var cmds_v: Variant = input.get("commands", null)
	if not (cmds_v is Array):
		return _fail("INVALID_INPUT", "commands 배열이 필요합니다.")
	var state := motion_read_state()
	var base_cid: String = str(input.get("base_commit_id", ""))
	var doc: Dictionary = state["document"] as Dictionary
	if not base_cid.is_empty():
		doc = journal.call("get_snapshot", base_cid)
		if doc.is_empty():
			return _fail("UNKNOWN_COMMIT", "기준 스냅샷(%s)이 없습니다." % base_cid)
	var planned := plan(cmds_v as Array, doc)
	if not bool(planned.get("ok", false)):
		return planned
	return {
		"ok": true,
		"changes": planned["changes"],
		"validation": planned["validation"],
		"command_count": int(planned["command_count"]),
		"base_revision": int(state["revision"]),
		"base_commit_id": base_cid if not base_cid.is_empty() else str(state["cursor_id"]),
	}


func motion_apply_commands(input: Dictionary, context: Dictionary = {"source": "mcp"}) -> Dictionary:
	var cmds_v: Variant = input.get("commands", null)
	if not (cmds_v is Array):
		return _fail("INVALID_INPUT", "commands 배열이 필요합니다.")
	if not input.has("base_revision") or not input.has("request_id"):
		return _fail("INVALID_INPUT", "base_revision과 request_id가 필요합니다.")
	var base_rev := int(input["base_revision"])
	var req_id := str(input["request_id"]).strip_edges()
	if base_rev < 0 or req_id.is_empty() or req_id.length() > 120:
		return _fail("INVALID_REQUEST_ID", "base_revision 또는 request_id가 올바르지 않습니다.")

	var meta_lookup := {"tool": "motion_apply_commands", "arguments": {"commands": JournalScript.deep_clone(cmds_v)}}
	var prev_receipt: Variant = journal.call("lookup_receipt", req_id, meta_lookup)
	if prev_receipt != null:
		return _command_receipt(prev_receipt as Dictionary, cmds_v as Array)

	var source := str(context.get("source", "mcp"))
	if source != "user" and not write_access:
		return _fail("CAPABILITY_DENIED", "Agent 쓰기 권한이 꺼져 있습니다. 읽기·미리보기는 계속 사용할 수 있습니다.")

	var state := motion_read_state()
	if active_gesture:
		return _fail("EDITOR_BUSY", "사용자 편집 동작이 진행 중입니다.")
	if not bool(state["editable"]):
		return _fail("READ_ONLY", "검토 모드에서는 적용할 수 없습니다. 현재 작업으로 복귀하거나 분기하세요.")
	if base_rev != int(state["revision"]):
		return _fail("STALE_REVISION", "현재 revision을 다시 읽고 요청하세요.", {"current_revision": int(state["revision"]), "retry": "read_state_then_replan"})

	var planned := plan(cmds_v as Array, state["document"] as Dictionary)
	if not bool(planned.get("ok", false)):
		return planned

	var label_txt := str(input.get("label", "Agent 명령 적용")).strip_edges()
	var commit_meta := {
		"source": source,
		"label": label_txt if not label_txt.is_empty() else "Agent 명령 적용",
		"tool": "motion_apply_commands",
		"arguments": {"commands": JournalScript.deep_clone(cmds_v)},
		"requestId": req_id,
		"transactionId": req_id,
		"expectedRevision": base_rev,
	}
	var res: Dictionary = journal.call("record", state["document"], planned["draft"], commit_meta)
	if not bool(res.get("ok", false)):
		res["current_revision"] = int(motion_read_state()["revision"])
		return res
	_status_message = "%s 적용됨 (%s · r%d)" % [label_txt, str(res["commitId"]), int(res["revision"])]
	return _command_receipt(res, cmds_v as Array)


func _command_receipt(res: Dictionary, commands: Array) -> Dictionary:
	if not bool(res.get("ok", false)):
		return res
	var out: Dictionary = JournalScript.deep_clone(res) as Dictionary
	var cid := str(out.get("commitId", ""))
	var snap: Dictionary = journal.call("get_snapshot", cid)
	var changed_ids: Array[String] = []
	if not bool(out.get("unchanged", false)):
		var view: Dictionary = journal.call("get_view")
		for e in (view["entries"] as Array):
			var ed: Dictionary = e as Dictionary
			if str(ed.get("id", "")) == cid:
				for ch in (ed.get("changes", []) as Array):
					var tid := str((ch as Dictionary).get("target", ""))
					if not changed_ids.has(tid):
						changed_ids.append(tid)
				break
	out["changed_ids"] = changed_ids
	out["command_count"] = commands.size()
	out["validation"] = validate_document(snap)
	return out


func motion_history() -> Dictionary:
	return journal.call("get_view")


func motion_review_snapshot(input: Dictionary) -> Dictionary:
	var cid_v: Variant = input.get("commit_id", null)
	if cid_v == null or str(cid_v).is_empty():
		var res: Dictionary = journal.call("exit_review")
		_status_message = "현재 라이브 작업으로 복귀했습니다."
		return res
	var res: Dictionary = journal.call("inspect", str(cid_v))
	if bool(res.get("ok", false)):
		_status_message = "읽기 전용 검토: %s (라이브 작업 보존)" % str(cid_v)
	return res


func motion_fork_snapshot(input: Dictionary, source: String = "user") -> Dictionary:
	if source != "user" and not write_access:
		return _fail("CAPABILITY_DENIED", "Agent 쓰기 권한이 꺼져 있습니다.")
	var base_rev := int(input.get("base_revision", -1))
	var cur_rev := int(motion_read_state()["revision"])
	if base_rev != cur_rev:
		return _fail("STALE_REVISION", "현재 revision을 다시 읽고 요청하세요.", {"current_revision": cur_rev})
	var cid := str(input.get("commit_id", ""))
	var lbl := str(input.get("label", ""))
	var res: Dictionary = journal.call("fork", cid, lbl)
	if bool(res.get("ok", false)):
		_status_message = "%s에서 새 분기 %s 생성됨" % [cid, str(res["branchId"])]
	return res


func motion_undo_transaction(input: Dictionary, source: String = "user") -> Dictionary:
	if source != "user" and not write_access:
		return _fail("CAPABILITY_DENIED", "Agent 쓰기 권한이 꺼져 있습니다.")
	var base_rev := int(input.get("base_revision", -1))
	var cur_rev := int(motion_read_state()["revision"])
	if base_rev != cur_rev:
		return _fail("STALE_REVISION", "현재 revision을 다시 읽고 요청하세요.", {"current_revision": cur_rev})
	var res: Dictionary = journal.call("undo")
	if bool(res.get("ok", false)):
		_status_message = "Undo 완료 -> %s (r%d)" % [str(res["commitId"]), int(res["revision"])]
	return res


func motion_redo_transaction(input: Dictionary, source: String = "user") -> Dictionary:
	if source != "user" and not write_access:
		return _fail("CAPABILITY_DENIED", "Agent 쓰기 권한이 꺼져 있습니다.")
	var base_rev := int(input.get("base_revision", -1))
	var cur_rev := int(motion_read_state()["revision"])
	if base_rev != cur_rev:
		return _fail("STALE_REVISION", "현재 revision을 다시 읽고 요청하세요.", {"current_revision": cur_rev})
	var res: Dictionary = journal.call("redo")
	if bool(res.get("ok", false)):
		_status_message = "Redo 완료 -> %s (r%d)" % [str(res["commitId"]), int(res["revision"])]
	return res


func replace_step(commit_id: String, commands: Array, branch_label: String = "사용자 수정안") -> Dictionary:
	var view: Dictionary = journal.call("get_view")
	var target_entry: Dictionary = {}
	for e in (view["entries"] as Array):
		if str((e as Dictionary).get("id", "")) == commit_id:
			target_entry = e as Dictionary
			break
	if target_entry.is_empty() or target_entry.get("parentId", null) == null:
		return _fail("INVALID_STEP", "초기 문서는 교체할 수 없습니다.")
	var parent_id := str(target_entry["parentId"])
	var parent_doc: Dictionary = journal.call("get_snapshot", parent_id)
	var planned := plan(commands, parent_doc)
	if not bool(planned.get("ok", false)):
		return planned
	var forked: Dictionary = journal.call("fork", parent_id, branch_label)
	if not bool(forked.get("ok", false)):
		return forked
	_seq_counter += 1
	var req_id := "replace-%d-%d" % [Time.get_ticks_msec(), _seq_counter]
	var res: Dictionary = journal.call("record", parent_doc, planned["draft"], {
		"source": "user",
		"label": "사용자 수정 · " + str(target_entry.get("label", "")),
		"tool": "motion_apply_commands",
		"arguments": {"commands": JournalScript.deep_clone(commands)},
		"requestId": req_id,
		"transactionId": req_id,
		"expectedRevision": int(forked["revision"]),
	})
	if bool(res.get("ok", false)):
		_status_message = "새 분기 %s에 수정안 적용됨 (%s)" % [str(res["branchId"]), str(res["commitId"])]
	return res


# --- Convenience Helpers for UI & Built-in 4-Step Agent Scenario ---

func apply_user_commands(commands: Array, label: String) -> Dictionary:
	var st := motion_read_state()
	if bool(st["reviewing"]):
		journal.call("exit_review")
		st = motion_read_state()
	_seq_counter += 1
	return motion_apply_commands({
		"commands": commands,
		"base_revision": int(st["revision"]),
		"request_id": "ui-%d-%d" % [Time.get_ticks_msec(), _seq_counter],
		"label": label,
	}, {"source": "user"})


func get_next_agent_step_index() -> int:
	var view: Dictionary = journal.call("get_view")
	var path: Array = view.get("activePath", []) as Array
	var cur_id := str(view.get("cursorId", "c000"))
	var cur_idx := path.find(cur_id)
	var active_labels: Array[String] = []
	for i in range(0, cur_idx + 1):
		var cid := str(path[i])
		for e in (view["entries"] as Array):
			var ed: Dictionary = e as Dictionary
			if str(ed.get("id", "")) == cid:
				active_labels.append(str(ed.get("label", "")))
				break
	for s_idx in AGENT_SCENARIO_STEPS.size():
		var step: Dictionary = AGENT_SCENARIO_STEPS[s_idx]
		var s_lbl := str(step["label"])
		var found := false
		for al in active_labels:
			if al == s_lbl or al.ends_with(s_lbl):
				found = true
				break
		if not found:
			return s_idx
	return AGENT_SCENARIO_STEPS.size()


func run_next_agent_step() -> Dictionary:
	var next_idx := get_next_agent_step_index()
	if next_idx >= AGENT_SCENARIO_STEPS.size():
		return {"ok": true, "done": true, "message": "모든 Agent 4단계가 완료되었습니다."}
	var step: Dictionary = AGENT_SCENARIO_STEPS[next_idx]
	var st := motion_read_state()
	if bool(st["reviewing"]):
		return _fail("REVIEW_READ_ONLY", "검토를 종료하거나 분기한 후 실행하세요.")
	_seq_counter += 1
	var res := motion_apply_commands({
		"commands": JournalScript.deep_clone(step["commands"]),
		"base_revision": int(st["revision"]),
		"request_id": "agent-%s-r%d-%d" % [str(step["id"]), int(st["revision"]), _seq_counter],
		"label": str(step["label"]),
	}, {"source": "agent"})
	if bool(res.get("ok", false)):
		completed_agent_steps[str(step["id"])] = str(res["commitId"])
	return res


func run_all_remaining_agent_steps() -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for _i in AGENT_SCENARIO_STEPS.size():
		var next_idx := get_next_agent_step_index()
		if next_idx >= AGENT_SCENARIO_STEPS.size():
			break
		var r := run_next_agent_step()
		results.append(r)
		if not bool(r.get("ok", false)):
			break
	return results


func record_frame_trace(frame_idx: int, time_sec: float, active_state: String, speed: float) -> void:
	var view: Dictionary = journal.call("get_view")
	var doc: Dictionary = view["selectedSnapshot"] as Dictionary
	var active_evs: Array[String] = []
	for item in (doc.get("events", []) as Array):
		var ev: Dictionary = item as Dictionary
		if bool(ev.get("enabled", true)) and frame_idx >= int(ev.get("start", 0)) and frame_idx <= int(ev.get("end", 0)):
			active_evs.append(str(ev.get("label", ev.get("id", ""))))
	frame_trace.append({
		"frame": frame_idx,
		"time": snappedf(time_sec, 0.01),
		"state": active_state,
		"speed": snappedf(speed, 0.02),
		"activeEvents": active_evs,
		"sourceCommitId": str(view.get("selectedId", "c000")),
		"sourceRevision": int(view.get("revision", 0)),
	})
	if frame_trace.size() > 60:
		frame_trace.remove_at(0)


func export_session_json() -> String:
	return str(journal.call("export_json"))


func restore_session_json(json_text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(json_text)
	if not (parsed is Dictionary):
		return _fail("INVALID_JSON", "올바른 JSON 세션 형식이 아닙니다.")
	var res: Dictionary = JournalScript.restore(parsed as Dictionary)
	if not bool(res.get("ok", false)):
		return res
	journal = res["journal"]
	_status_message = "저장된 작업 기록을 복원했습니다."
	return {"ok": true, "revision": int(motion_read_state()["revision"])}
