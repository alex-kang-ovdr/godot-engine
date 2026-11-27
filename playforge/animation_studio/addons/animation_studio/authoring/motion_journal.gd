@tool
class_name MotionJournal
extends RefCounted
## PlayForge Motion Studio v3 — Immutable Operation Journal with branching,
## read-only snapshot review, transaction Undo/Redo, idempotency receipts,
## FNV-1a canonical fingerprints, and validated JSON session export/restore.
##
## Design invariant (matching dist/agent-journal.js):
##   - get_state() ALWAYS returns a copy of the live cursor document.
##   - inspect(commit_id) ONLY changes review_id; it NEVER alters cursor_id,
##     live state, or revision. Mutations (record/undo/redo) are blocked while
##     reviewing until exit_review() or fork() is called.
##   - Editing after Undo automatically creates a new branch and preserves
##     the original branch's future history.

const SCHEMA_ID := "playforge.motion-journal/v1"
const ENTITY_TYPES := {
	"nodes": "node",
	"edges": "edge",
	"events": "event",
	"transitions": "transition",
}

var session_id: String = ""
var created_at: String = ""
var revision: int = 0
var branch_id: String = "b000"
var cursor_id: String = "c000"
var review_id: String = ""

var _commit_order: Array[String] = []
var _commits: Dictionary = {} # id -> Dictionary
var _branch_order: Array[String] = []
var _branches: Dictionary = {} # id -> Dictionary
var _navigation: Array[Dictionary] = []
var _requests: Dictionary = {} # request_id -> {payload_text, payload, result}
var _commit_count: int = 0
var _branch_count: int = 0
var _listeners: Array[Callable] = []


static func create(initial_doc: Dictionary) -> RefCounted:
	var j := new()
	j._init_fresh(initial_doc)
	return j


static func restore(session: Dictionary) -> Dictionary:
	var validated := _validate_session(session)
	if not bool(validated.get("ok", false)):
		return validated
	var j := new()
	j._init_persisted(validated["data"] as Dictionary)
	return {"ok": true, "journal": j}


static func deep_clone(val: Variant) -> Variant:
	if val is Dictionary:
		var out: Dictionary = {}
		for k in (val as Dictionary).keys():
			out[str(k)] = deep_clone((val as Dictionary)[k])
		return out
	elif val is Array:
		var out_arr: Array = []
		for item in (val as Array):
			out_arr.append(deep_clone(item))
		return out_arr
	return val


static func canonical_json(val: Variant) -> String:
	if val == null:
		return "null"
	if val is bool:
		return "true" if bool(val) else "false"
	if val is int:
		return str(int(val))
	if val is float:
		var f: float = float(val)
		if is_nan(f) or is_inf(f):
			return "null"
		if absf(f - round(f)) < 1e-9 and absf(f) < 1e15:
			return str(int(round(f)))
		return JSON.stringify(snappedf(f, 0.000001))
	if val is String:
		return JSON.stringify(str(val))
	if val is Array:
		var parts := PackedStringArray()
		for item in (val as Array):
			parts.append(canonical_json(item))
		return "[" + ",".join(parts) + "]"
	if val is Dictionary:
		var d: Dictionary = val as Dictionary
		var keys: Array[String] = []
		for k in d.keys():
			keys.append(str(k))
		keys.sort()
		var parts := PackedStringArray()
		for k in keys:
			parts.append(JSON.stringify(k) + ":" + canonical_json(d[k]))
		return "{" + ",".join(parts) + "}"
	return JSON.stringify(str(val))


static func fingerprint(text: String) -> String:
	var h: int = 2166136261
	var bytes: PackedByteArray = text.to_utf8_buffer()
	for i in bytes.size():
		h = (h ^ int(bytes[i])) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return "fnv1a32:%08x" % h


static func _now_iso() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"


static func _fail(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}


static func _equal(a: Variant, b: Variant) -> bool:
	return canonical_json(a) == canonical_json(b)


static func _valid_entities(val: Variant) -> bool:
	if not (val is Array):
		return false
	var arr: Array = val as Array
	var seen: Dictionary = {}
	for item in arr:
		if not (item is Dictionary):
			return false
		var d: Dictionary = item as Dictionary
		if not d.has("id") or not (d["id"] is String):
			return false
		var id_str: String = str(d["id"])
		if seen.has(id_str):
			return false
		seen[id_str] = true
	return true


static func changes_between(before: Dictionary, after: Dictionary) -> Array[Dictionary]:
	var changes: Array[Dictionary] = []
	var key_set: Dictionary = {}
	for k in before.keys():
		key_set[str(k)] = true
	for k in after.keys():
		key_set[str(k)] = true
	var keys: Array[String] = []
	for k in key_set.keys():
		keys.append(str(k))
	keys.sort()

	for key in keys:
		var has_a := before.has(key)
		var has_b := after.has(key)
		var a: Variant = before.get(key, null)
		var b: Variant = after.get(key, null)
		if ENTITY_TYPES.has(key) and _valid_entities(a) and _valid_entities(b):
			var arr_a: Array = a as Array
			var arr_b: Array = b as Array
			var old_by_id: Dictionary = {}
			var new_by_id: Dictionary = {}
			var all_ids: Array[String] = []
			for item in arr_a:
				var eid: String = str((item as Dictionary)["id"])
				old_by_id[eid] = item
				if not all_ids.has(eid):
					all_ids.append(eid)
			for item in arr_b:
				var eid: String = str((item as Dictionary)["id"])
				new_by_id[eid] = item
				if not all_ids.has(eid):
					all_ids.append(eid)
			for eid in all_ids:
				_walk_diff(
					changes,
					str(ENTITY_TYPES[key]) + ":" + eid,
					"",
					old_by_id.get(eid, null),
					new_by_id.get(eid, null),
					old_by_id.has(eid),
					new_by_id.has(eid)
				)
		elif key == "defaultParameters" and a is Dictionary and b is Dictionary:
			var da: Dictionary = a as Dictionary
			var db: Dictionary = b as Dictionary
			var pset: Dictionary = {}
			for pk in da.keys():
				pset[str(pk)] = true
			for pk in db.keys():
				pset[str(pk)] = true
			var pkeys: Array[String] = []
			for pk in pset.keys():
				pkeys.append(str(pk))
			pkeys.sort()
			for pname in pkeys:
				_walk_diff(changes, "parameter:" + pname, "value", da.get(pname, null), db.get(pname, null), da.has(pname), db.has(pname))
		elif key == "physics":
			_walk_diff(changes, "rig:preview", "", a, b, has_a, has_b)
		else:
			_walk_diff(changes, "document", key, a, b, has_a, has_b)
	return changes


static func _walk_diff(changes: Array[Dictionary], target: String, path: String, a: Variant, b: Variant, has_a: bool, has_b: bool) -> void:
	if has_a and has_b and _equal(a, b):
		return
	if has_a and has_b and a is Dictionary and b is Dictionary:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		var kset: Dictionary = {}
		for k in da.keys():
			kset[str(k)] = true
		for k in db.keys():
			kset[str(k)] = true
		var keys: Array[String] = []
		for k in kset.keys():
			keys.append(str(k))
		keys.sort()
		for k in keys:
			var next_path := k if path.is_empty() else (path + "." + k)
			_walk_diff(changes, target, next_path, da.get(k, null), db.get(k, null), da.has(k), db.has(k))
	else:
		var op := "add" if not has_a else ("remove" if not has_b else "set")
		changes.append({
			"target": target,
			"path": path,
			"op": op,
			"before": deep_clone(a) if has_a else null,
			"after": deep_clone(b) if has_b else null,
		})


static func _invert_changes(changes: Array[Dictionary]) -> Array[Dictionary]:
	var inv: Array[Dictionary] = []
	for i in range(changes.size() - 1, -1, -1):
		var c: Dictionary = changes[i]
		var op: String = str(c.get("op", "set"))
		var inv_op := "remove" if op == "add" else ("add" if op == "remove" else "set")
		inv.append({
			"target": str(c.get("target", "")),
			"path": str(c.get("path", "")),
			"op": inv_op,
			"before": deep_clone(c.get("after", null)),
			"after": deep_clone(c.get("before", null)),
		})
	return inv


static func _normalise_meta(meta: Dictionary) -> Dictionary:
	var source: String = str(meta.get("source", "user"))
	if not (source in ["user", "agent", "mcp"]):
		return _fail("INVALID_SOURCE", "source는 user, agent, mcp 중 하나여야 합니다.")
	var label: String = str(meta.get("label", "문서 변경")).strip_edges()
	if label.is_empty() or label.length() > 180:
		return _fail("INVALID_METADATA", "작업 이름은 1–180자의 문자열이어야 합니다.")
	var out: Dictionary = {
		"source": source,
		"label": label,
		"tool": str(meta.get("tool", "document.edit")),
	}
	if meta.has("transactionId") and meta["transactionId"] != null:
		var tid := str(meta["transactionId"]).strip_edges()
		if tid.is_empty() or tid.length() > 180:
			return _fail("INVALID_METADATA", "transactionId가 올바르지 않습니다.")
		out["transactionId"] = tid
	if meta.has("requestId") and meta["requestId"] != null:
		var rid := str(meta["requestId"]).strip_edges()
		if rid.is_empty() or rid.length() > 180:
			return _fail("INVALID_METADATA", "requestId가 올바르지 않습니다.")
		out["requestId"] = rid
	if meta.has("arguments") and meta["arguments"] != null:
		out["arguments"] = deep_clone(meta["arguments"])
	if meta.has("expectedRevision") and meta["expectedRevision"] != null:
		var er := int(meta["expectedRevision"])
		if er < 0:
			return _fail("INVALID_REVISION", "expectedRevision은 0 이상의 정수여야 합니다.")
		out["expectedRevision"] = er
	return {"ok": true, "value": out}


static func _semantic_payload(meta: Dictionary, after_doc: Dictionary) -> Dictionary:
	var tool_name: String = str(meta.get("tool", "document.edit"))
	if meta.has("arguments"):
		return {"tool": tool_name, "arguments": deep_clone(meta["arguments"])}
	return {"tool": tool_name, "after": deep_clone(after_doc)}


static func _validate_session(val: Dictionary) -> Dictionary:
	if str(val.get("schema", "")) != SCHEMA_ID:
		return _fail("INVALID_SESSION", "지원되지 않는 저널 스키마입니다.")
	var commits_raw: Variant = val.get("commits", null)
	var branches_raw: Variant = val.get("branches", null)
	var nav_raw: Variant = val.get("navigation", null)
	var receipts_raw: Variant = val.get("requestReceipts", null)
	if not (commits_raw is Array) or (commits_raw as Array).is_empty():
		return _fail("INVALID_SESSION", "커밋 목록이 올바르지 않습니다.")
	if not (branches_raw is Array) or (branches_raw as Array).is_empty():
		return _fail("INVALID_SESSION", "분기 목록이 올바르지 않습니다.")
	if not (nav_raw is Array) or not (receipts_raw is Array):
		return _fail("INVALID_SESSION", "탐색 기록 또는 requestReceipts가 없습니다.")

	var rev: int = int(val.get("revision", -1))
	if rev < 0 or rev != (nav_raw as Array).size():
		return _fail("INVALID_SESSION", "revision과 탐색 기록 수가 일치하지 않습니다.")

	var commit_map: Dictionary = {}
	var commits_arr: Array = commits_raw as Array
	for idx in commits_arr.size():
		var raw: Variant = commits_arr[idx]
		if not (raw is Dictionary):
			return _fail("INVALID_SESSION", "커밋 항목이 객체가 아닙니다.")
		var c: Dictionary = raw as Dictionary
		var cid: String = str(c.get("id", ""))
		if cid.is_empty() or commit_map.has(cid):
			return _fail("INVALID_SESSION", "커밋 ID가 중복되거나 비어 있습니다.")
		if idx == 0 and (cid != "c000" or str(c.get("branchId", "")) != "b000" or int(c.get("revision", -1)) != 0):
			return _fail("INVALID_SESSION", "c000 기준 문서가 올바르지 않습니다.")
		if idx > 0 and not commit_map.has(str(c.get("parentId", ""))):
			return _fail("INVALID_SESSION", "커밋 부모(%s)를 찾을 수 없습니다." % str(c.get("parentId", "")))
		var snap: Variant = c.get("snapshot", null)
		if not (snap is Dictionary):
			return _fail("INVALID_SESSION", "커밋 스냅샷이 JSON 객체가 아닙니다.")
		var parent_snap: Dictionary = (snap as Dictionary) if idx == 0 else ((commit_map[str(c["parentId"])] as Dictionary)["snapshot"] as Dictionary)
		var b_hash := fingerprint(canonical_json(parent_snap))
		var a_hash := fingerprint(canonical_json(snap))
		if str(c.get("beforeHash", "")) != b_hash or str(c.get("afterHash", "")) != a_hash:
			return _fail("INVALID_SESSION", "커밋 %s의 체크섬이 스냅샷과 일치하지 않습니다." % cid)
		commit_map[cid] = c

	var branch_map: Dictionary = {}
	for raw_b in (branches_raw as Array):
		if not (raw_b is Dictionary):
			return _fail("INVALID_SESSION", "분기 항목이 객체가 아닙니다.")
		var b: Dictionary = raw_b as Dictionary
		var bid: String = str(b.get("id", ""))
		if bid.is_empty() or branch_map.has(bid) or not commit_map.has(str(b.get("headId", ""))):
			return _fail("INVALID_SESSION", "분기(%s) 또는 headId가 올바르지 않습니다." % bid)
		branch_map[bid] = b

	if not branch_map.has("b000"):
		return _fail("INVALID_SESSION", "Main(b000) 분기가 없습니다.")
	var active_bid: String = str(val.get("branchId", ""))
	var active_cid: String = str(val.get("cursorId", ""))
	if not branch_map.has(active_bid) or not commit_map.has(active_cid):
		return _fail("INVALID_SESSION", "활성 분기 또는 커서가 올바르지 않습니다.")
	var r_id_val: Variant = val.get("reviewId", null)
	if r_id_val != null and not str(r_id_val).is_empty() and not commit_map.has(str(r_id_val)):
		return _fail("INVALID_SESSION", "검토 커밋을 찾을 수 없습니다.")

	return {"ok": true, "data": deep_clone(val)}


func _init_fresh(initial_doc: Dictionary) -> void:
	created_at = _now_iso()
	session_id = "motion-%d-%d" % [Time.get_ticks_msec(), randi() % 99999]
	revision = 0
	branch_id = "b000"
	cursor_id = "c000"
	review_id = ""
	_commit_count = 0
	_branch_count = 0
	_commits.clear()
	_commit_order.clear()
	_branches.clear()
	_branch_order.clear()
	_navigation.clear()
	_requests.clear()

	var snap: Dictionary = deep_clone(initial_doc)
	var h := fingerprint(canonical_json(snap))
	var c0 := {
		"id": "c000",
		"parentId": null,
		"branchId": "b000",
		"source": "user",
		"label": "초기 문서",
		"tool": "baseline",
		"arguments": {},
		"transactionId": null,
		"requestId": null,
		"revision": 0,
		"createdAt": created_at,
		"changes": [],
		"inverseChanges": [],
		"beforeHash": h,
		"afterHash": h,
		"snapshot": snap,
	}
	_commits["c000"] = c0
	_commit_order.append("c000")
	_branches["b000"] = {
		"id": "b000",
		"label": "Main",
		"headId": "c000",
		"forkedFromId": null,
		"parentBranchId": null,
		"createdAt": created_at,
	}
	_branch_order.append("b000")


func _init_persisted(data: Dictionary) -> void:
	session_id = str(data.get("sessionId", ""))
	created_at = str(data.get("createdAt", _now_iso()))
	revision = int(data.get("revision", 0))
	branch_id = str(data.get("branchId", "b000"))
	cursor_id = str(data.get("cursorId", "c000"))
	var rv: Variant = data.get("reviewId", null)
	review_id = "" if rv == null else str(rv)

	_commits.clear()
	_commit_order.clear()
	_commit_count = 0
	for raw_c in (data["commits"] as Array):
		var c: Dictionary = deep_clone(raw_c)
		var cid: String = str(c["id"])
		_commits[cid] = c
		_commit_order.append(cid)
		_commit_count = maxi(_commit_count, int(cid.substr(1)))

	_branches.clear()
	_branch_order.clear()
	_branch_count = 0
	for raw_b in (data["branches"] as Array):
		var b: Dictionary = deep_clone(raw_b)
		var bid: String = str(b["id"])
		_branches[bid] = b
		_branch_order.append(bid)
		_branch_count = maxi(_branch_count, int(bid.substr(1)))

	_navigation.clear()
	for raw_n in (data["navigation"] as Array):
		_navigation.append(deep_clone(raw_n) as Dictionary)

	_requests.clear()
	for raw_r in (data["requestReceipts"] as Array):
		var rd: Dictionary = deep_clone(raw_r) as Dictionary
		var rid: String = str(rd["requestId"])
		_requests[rid] = {
			"payload_text": canonical_json(rd["payload"]),
			"payload": rd["payload"],
			"result": rd["result"],
		}


func head_id() -> String:
	return str((_branches[branch_id] as Dictionary)["headId"])


func _live_snapshot() -> Dictionary:
	return (_commits[cursor_id] as Dictionary)["snapshot"] as Dictionary


func get_state() -> Dictionary:
	return deep_clone(_live_snapshot()) as Dictionary


func get_snapshot(commit_id: String) -> Dictionary:
	if not _commits.has(commit_id):
		return {}
	return deep_clone((_commits[commit_id] as Dictionary)["snapshot"]) as Dictionary


func active_path(for_branch_id: String = "") -> Array[String]:
	var bid := branch_id if for_branch_id.is_empty() else for_branch_id
	if not _branches.has(bid):
		return []
	var path: Array[String] = []
	var cur: Variant = (_branches[bid] as Dictionary)["headId"]
	while cur != null and not str(cur).is_empty() and _commits.has(str(cur)):
		var cs: String = str(cur)
		path.append(cs)
		cur = (_commits[cs] as Dictionary).get("parentId", null)
	path.reverse()
	return path


func _entry_summary(entry: Dictionary) -> Dictionary:
	var out: Dictionary = deep_clone(entry) as Dictionary
	out.erase("snapshot")
	return out


func get_view() -> Dictionary:
	var path := active_path()
	var c_idx := path.find(cursor_id)
	var sel_id := review_id if not review_id.is_empty() else cursor_id
	var entries: Array[Dictionary] = []
	for cid in _commit_order:
		entries.append(_entry_summary(_commits[cid] as Dictionary))
	var branches_arr: Array[Dictionary] = []
	for bid in _branch_order:
		branches_arr.append(deep_clone(_branches[bid]) as Dictionary)
	return {
		"entries": entries,
		"branches": branches_arr,
		"activePath": path,
		"branchId": branch_id,
		"cursorId": cursor_id,
		"headId": head_id(),
		"reviewId": null if review_id.is_empty() else review_id,
		"selectedId": sel_id,
		"selectedSnapshot": get_snapshot(sel_id),
		"revision": revision,
		"reviewing": not review_id.is_empty(),
		"canUndo": review_id.is_empty() and c_idx > 0,
		"canRedo": review_id.is_empty() and c_idx >= 0 and c_idx < path.size() - 1,
		"canRecord": review_id.is_empty(),
	}


func subscribe(listener: Callable) -> void:
	if not _listeners.has(listener):
		_listeners.append(listener)


func _notify() -> void:
	var v := get_view()
	for cb in _listeners:
		if cb.is_valid():
			cb.call(v)


func _ok(cid: String = "") -> Dictionary:
	return {
		"ok": true,
		"commitId": cursor_id if cid.is_empty() else cid,
		"revision": revision,
		"branchId": branch_id,
	}


func _add_navigation(kind: String, from_id: String, to_id: String, extra: Dictionary = {}) -> void:
	var item: Dictionary = {
		"kind": kind,
		"fromId": from_id,
		"toId": to_id,
		"branchId": branch_id,
		"revision": revision,
		"createdAt": _now_iso(),
	}
	for k in extra.keys():
		item[k] = extra[k]
	_navigation.append(item)


func _make_branch(from_id: String, label: String = "") -> String:
	var prev_branch := branch_id
	var path := active_path()
	var parent_b: String = prev_branch if path.has(from_id) else str((_commits[from_id] as Dictionary)["branchId"])
	_branch_count += 1
	var bid := "b%03d" % _branch_count
	var clean_label := label.strip_edges()
	if clean_label.is_empty():
		clean_label = "Review branch %d" % _branch_count
	elif clean_label.length() > 120:
		clean_label = clean_label.substr(0, 120)
	_branches[bid] = {
		"id": bid,
		"label": clean_label,
		"headId": from_id,
		"forkedFromId": from_id,
		"parentBranchId": parent_b,
		"createdAt": _now_iso(),
	}
	_branch_order.append(bid)
	branch_id = bid
	return prev_branch


func _cached_receipt(request_id: String, payload_text: String) -> Variant:
	if not _requests.has(request_id):
		return null
	var prior: Dictionary = _requests[request_id] as Dictionary
	if str(prior["payload_text"]) == payload_text:
		return deep_clone(prior["result"])
	return _fail("IDEMPOTENCY_CONFLICT", "같은 requestId에 다른 명령 내용이 전달되었습니다.")


func lookup_receipt(request_id: String, semantic: Dictionary) -> Variant:
	if request_id.strip_edges().is_empty():
		return _fail("INVALID_METADATA", "조회할 requestId가 필요합니다.")
	var payload := _semantic_payload(semantic, semantic.get("after", {}) as Dictionary)
	return _cached_receipt(request_id, canonical_json(payload))


func record(before: Dictionary, after: Dictionary, meta: Dictionary = {}) -> Dictionary:
	var checked := _normalise_meta(meta)
	if not bool(checked.get("ok", false)):
		return checked
	var m: Dictionary = checked["value"] as Dictionary
	var before_text := canonical_json(before)
	var after_text := canonical_json(after)
	var payload := _semantic_payload(m, after)
	var payload_text := canonical_json(payload)

	if m.has("requestId"):
		var cached: Variant = _cached_receipt(str(m["requestId"]), payload_text)
		if cached != null:
			return cached as Dictionary

	if not review_id.is_empty():
		return _fail("REVIEW_READ_ONLY", "검토 중에는 문서를 변경할 수 없습니다. 현재 작업으로 돌아가거나 이 지점에서 분기하세요.")
	if m.has("expectedRevision") and int(m["expectedRevision"]) != revision:
		return _fail("STALE_REVISION", "문서 revision이 변경되었습니다. 현재 상태를 다시 읽고 명령을 준비하세요.")
	if before_text != canonical_json(_live_snapshot()):
		return _fail("BASE_STATE_MISMATCH", "변경 전 문서가 현재 저널 상태와 다릅니다. 최신 문서를 기준으로 편집하세요.")

	if before_text == after_text:
		var noop_res := _ok()
		noop_res["unchanged"] = true
		if m.has("requestId"):
			_requests[str(m["requestId"])] = {"payload_text": payload_text, "payload": payload, "result": deep_clone(noop_res)}
		return noop_res

	var forked := false
	var prev_branch: Variant = null
	if cursor_id != head_id():
		prev_branch = _make_branch(cursor_id)
		forked = true

	var parent_id := cursor_id
	_commit_count += 1
	var cid := "c%03d" % _commit_count
	var snap: Dictionary = deep_clone(after) as Dictionary
	var ch := changes_between(before, after)
	var inv_ch := _invert_changes(ch)
	revision += 1

	var entry := {
		"id": cid,
		"parentId": parent_id,
		"branchId": branch_id,
		"source": str(m["source"]),
		"label": str(m["label"]),
		"tool": str(m["tool"]),
		"arguments": deep_clone(m.get("arguments", {})),
		"transactionId": m.get("transactionId", null),
		"requestId": m.get("requestId", null),
		"revision": revision,
		"createdAt": _now_iso(),
		"changes": ch,
		"inverseChanges": inv_ch,
		"beforeHash": fingerprint(before_text),
		"afterHash": fingerprint(after_text),
		"snapshot": snap,
	}
	_commits[cid] = entry
	_commit_order.append(cid)
	(_branches[branch_id] as Dictionary)["headId"] = cid
	cursor_id = cid
	_add_navigation("commit", parent_id, cid, {"forked": forked, "previousBranchId": prev_branch})

	var res := _ok()
	res["forked"] = forked
	if m.has("requestId"):
		_requests[str(m["requestId"])] = {"payload_text": payload_text, "payload": payload, "result": deep_clone(res)}
	_notify()
	return res


func undo() -> Dictionary:
	if not review_id.is_empty():
		return _fail("REVIEW_READ_ONLY", "검토를 종료한 후 Undo를 실행하세요.")
	var parent_val: Variant = (_commits[cursor_id] as Dictionary).get("parentId", null)
	if parent_val == null or str(parent_val).is_empty():
		return _fail("NO_UNDO", "되돌릴 작업이 없습니다.")
	var prev := cursor_id
	cursor_id = str(parent_val)
	revision += 1
	_add_navigation("undo", prev, cursor_id)
	_notify()
	return _ok()


func redo() -> Dictionary:
	if not review_id.is_empty():
		return _fail("REVIEW_READ_ONLY", "검토를 종료한 후 Redo를 실행하세요.")
	var path := active_path()
	var idx := path.find(cursor_id)
	if idx < 0 or idx >= path.size() - 1:
		return _fail("NO_REDO", "다시 실행할 작업이 없습니다.")
	var prev := cursor_id
	cursor_id = path[idx + 1]
	revision += 1
	_add_navigation("redo", prev, cursor_id)
	_notify()
	return _ok()


func inspect(commit_id: String) -> Dictionary:
	if not _commits.has(commit_id):
		return _fail("UNKNOWN_COMMIT", "검토할 작업 기록을 찾을 수 없습니다.")
	review_id = commit_id
	_notify()
	var res := _ok(commit_id)
	res["snapshot"] = get_snapshot(commit_id)
	return res


func exit_review() -> Dictionary:
	if review_id.is_empty():
		var res := _ok()
		res["unchanged"] = true
		return res
	review_id = ""
	_notify()
	return _ok()


func fork(commit_id: String, label: String = "") -> Dictionary:
	if not _commits.has(commit_id):
		return _fail("UNKNOWN_COMMIT", "분기할 작업 기록을 찾을 수 없습니다.")
	var prev := cursor_id
	var prev_branch := _make_branch(commit_id, label)
	cursor_id = commit_id
	review_id = ""
	revision += 1
	_add_navigation("fork", prev, cursor_id, {"previousBranchId": prev_branch})
	_notify()
	return _ok()


func export_session() -> Dictionary:
	var commits_arr: Array[Dictionary] = []
	for cid in _commit_order:
		commits_arr.append(deep_clone(_commits[cid]) as Dictionary)
	var branches_arr: Array[Dictionary] = []
	for bid in _branch_order:
		branches_arr.append(deep_clone(_branches[bid]) as Dictionary)
	var receipts_arr: Array[Dictionary] = []
	for rid in _requests.keys():
		var r: Dictionary = _requests[rid] as Dictionary
		receipts_arr.append({
			"requestId": str(rid),
			"payload": deep_clone(r["payload"]),
			"result": deep_clone(r["result"]),
		})
	return {
		"schema": SCHEMA_ID,
		"scope": "godot-animation-studio-authoring",
		"sourceIdentity": "display metadata only; not authenticated",
		"fingerprintAlgorithm": "FNV-1a 32-bit; display checksum only",
		"sessionId": session_id,
		"createdAt": created_at,
		"revision": revision,
		"branchId": branch_id,
		"cursorId": cursor_id,
		"headId": head_id(),
		"reviewId": null if review_id.is_empty() else review_id,
		"branches": branches_arr,
		"commits": commits_arr,
		"navigation": deep_clone(_navigation),
		"requestReceipts": receipts_arr,
	}


func export_json() -> String:
	return JSON.stringify(export_session(), "  ")
