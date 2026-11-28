@tool
class_name HkbContext
extends RefCounted
## Pure-GDScript Havok Behavior Runtime Context (hkbContext + hkbVariableValueSet + hkbEventQueue + hkbSymbolLinker).
## Zero engine modifications ([엔진 수정] 0건) and zero runtime `.hkt` dependency.

var skeleton: Skeleton3D = null
var actor: Node3D = null
var world_3d: World3D = null
var rig_id: String = "hero"
var dt: float = 1.0 / 60.0
var tick: int = 0
var elapsed: float = 0.0

# Variable Value Set (hkbVariableValueSet)
var var_names: PackedStringArray = PackedStringArray()
var var_types: PackedStringArray = PackedStringArray()
var var_values: Array = []
var var_name_to_idx: Dictionary = {}

# Character Properties (BINDING_TYPE_CHARACTER_PROPERTY)
var prop_names: PackedStringArray = PackedStringArray()
var prop_types: PackedStringArray = PackedStringArray()
var prop_values: Array = []
var prop_name_to_idx: Dictionary = {}

# Attributes
var attr_names: PackedStringArray = PackedStringArray()
var attr_values: PackedFloat32Array = PackedFloat32Array()
var attr_name_to_idx: Dictionary = {}

# Event Registry & Queue (hkbEventQueue)
var event_names: PackedStringArray = PackedStringArray()
var event_name_to_idx: Dictionary = {}
var _pending_events: Array[Dictionary] = []
var _frame_events: Array[Dictionary] = []
var event_history: Array[Dictionary] = []

# Symbol Linker Maps for nested sub-behaviors (hkbSymbolLinker)
var symbol_links: Dictionary = {} # sub_key -> {var_map: Dictionary, ev_map: Dictionary, prop_map: Dictionary}

# Shared clip pack & cached mirror map
var clip_pack: Dictionary = {}
var mirror_map: Dictionary = {}

# Attached external drivers (optional)
var ragdoll_runtime: Node = null
var attachment_manager: RefCounted = null
var foot_ik_driver: RefCounted = null
var docking_driver: RefCounted = null

# Handle registry & GDScript script-generator inputs (replaces Lua globals)
var handles: Array[Dictionary] = [] # [{name, local_frame, pos, rot, valid, node, bone_idx}]
var script_inputs: Dictionary = {} # e.g. {"move_stick": Vector2, "camera_yaw": float, "aim_target_ws": Vector3}
var axis_standard: String = "godot_y_up_neg_z_forward"

# Per-tick telemetry outputs
var active_state_paths: PackedStringArray = PackedStringArray()
var active_modifier_names: PackedStringArray = PackedStringArray()
var root_motion_delta_pos: Vector3 = Vector3.ZERO
var root_motion_delta_yaw: float = 0.0
var ragdoll_control_commands: Array[Dictionary] = []
var foot_ik_control_command: Dictionary = {}
var attachment_commands: Array[Dictionary] = []


func configure_from_graph_def(graph_def: Dictionary) -> void:
	var_names.clear()
	var_types.clear()
	var_values.clear()
	var_name_to_idx.clear()
	for v_raw in graph_def.get("variables", []) as Array:
		var v: Dictionary = v_raw as Dictionary
		var idx := var_values.size()
		var nm := str(v.get("name", "var_%d" % idx))
		var tp := str(v.get("type", "real"))
		var def_val: Variant = _coerce_default(tp, v.get("default", 0.0))
		var_names.append(nm)
		var_types.append(tp)
		var_values.append(def_val)
		var_name_to_idx[nm] = idx

	prop_names.clear()
	prop_types.clear()
	prop_values.clear()
	prop_name_to_idx.clear()
	for p_raw in graph_def.get("character_properties", []) as Array:
		var p: Dictionary = p_raw as Dictionary
		var idx := prop_values.size()
		var nm := str(p.get("name", "prop_%d" % idx))
		var tp := str(p.get("type", "real"))
		prop_names.append(nm)
		prop_types.append(tp)
		prop_values.append(_coerce_default(tp, p.get("default", 0.0)))
		prop_name_to_idx[nm] = idx

	attr_names.clear()
	attr_values.clear()
	attr_name_to_idx.clear()
	for a_raw in graph_def.get("attributes", []) as Array:
		var a: Dictionary = a_raw as Dictionary
		var idx := attr_values.size()
		var nm := str(a.get("name", "attr_%d" % idx))
		attr_names.append(nm)
		attr_values.append(float(a.get("default", 0.0)))
		attr_name_to_idx[nm] = idx

	event_names.clear()
	event_name_to_idx.clear()
	for e_raw in graph_def.get("events", []) as Array:
		var nm := str(e_raw)
		var idx := event_names.size()
		event_names.append(nm)
		event_name_to_idx[nm] = idx

	_pending_events.clear()
	_frame_events.clear()
	event_history.clear()


func register_variable(var_name: String, var_type: String, default_val: Variant) -> int:
	if var_name_to_idx.has(var_name):
		return int(var_name_to_idx[var_name])
	var idx := var_values.size()
	var_names.append(var_name)
	var_types.append(var_type)
	var_values.append(_coerce_default(var_type, default_val))
	var_name_to_idx[var_name] = idx
	return idx


func register_character_property(prop_name: String, prop_type: String, default_val: Variant) -> int:
	if prop_name_to_idx.has(prop_name):
		return int(prop_name_to_idx[prop_name])
	var idx := prop_values.size()
	prop_names.append(prop_name)
	prop_types.append(prop_type)
	prop_values.append(_coerce_default(prop_type, default_val))
	prop_name_to_idx[prop_name] = idx
	return idx


func register_event(ev_name: String) -> int:
	if event_name_to_idx.has(ev_name):
		return int(event_name_to_idx[ev_name])
	var idx := event_names.size()
	event_names.append(ev_name)
	event_name_to_idx[ev_name] = idx
	return idx


func get_var_idx(var_name: String) -> int:
	return int(var_name_to_idx.get(var_name, -1))


func get_var(idx_or_name: Variant, fallback: Variant = 0.0) -> Variant:
	var idx := -1
	if idx_or_name is int:
		idx = int(idx_or_name)
	else:
		idx = int(var_name_to_idx.get(str(idx_or_name), -1))
	if idx >= 0 and idx < var_values.size():
		return var_values[idx]
	return fallback


func set_var(idx_or_name: Variant, value: Variant) -> bool:
	var idx := -1
	if idx_or_name is int:
		idx = int(idx_or_name)
	else:
		var nm := str(idx_or_name)
		idx = int(var_name_to_idx.get(nm, -1))
		if idx < 0:
			var tp := "bool" if value is bool else ("int32" if value is int else ("vector3" if value is Vector3 else ("quaternion" if value is Quaternion else ("pointer" if (value is Dictionary or value is Object) else "real"))))
			idx = register_variable(nm, tp, value)
	if idx < 0 or idx >= var_values.size():
		return false
	var_values[idx] = _coerce_default(var_types[idx], value)
	return true


func get_char_prop(idx_or_name: Variant, fallback: Variant = 0.0) -> Variant:
	var idx := -1
	if idx_or_name is int:
		idx = int(idx_or_name)
	else:
		idx = int(prop_name_to_idx.get(str(idx_or_name), -1))
	if idx >= 0 and idx < prop_values.size():
		return prop_values[idx]
	return fallback


func set_char_prop(idx_or_name: Variant, value: Variant) -> bool:
	var idx := -1
	if idx_or_name is int:
		idx = int(idx_or_name)
	else:
		var nm := str(idx_or_name)
		idx = int(prop_name_to_idx.get(nm, -1))
		if idx < 0:
			var tp := "bool" if value is bool else ("int32" if value is int else ("vector3" if value is Vector3 else "real"))
			idx = register_character_property(nm, tp, value)
	if idx < 0 or idx >= prop_values.size():
		return false
	prop_values[idx] = _coerce_default(prop_types[idx], value)
	return true


func get_symbol_value(symbol_name: String) -> Variant:
	if var_name_to_idx.has(symbol_name):
		return var_values[int(var_name_to_idx[symbol_name])]
	if prop_name_to_idx.has(symbol_name):
		return prop_values[int(prop_name_to_idx[symbol_name])]
	if attr_name_to_idx.has(symbol_name):
		return attr_values[int(attr_name_to_idx[symbol_name])]
	# Case-insensitive fallback (Havok expressions sometimes vary case)
	var low := symbol_name.to_lower()
	for i in var_names.size():
		if var_names[i].to_lower() == low:
			return var_values[i]
	for i in prop_names.size():
		if prop_names[i].to_lower() == low:
			return prop_values[i]
	return 0.0


func enqueue_event(id_or_name: Variant, payload: Dictionary = {}) -> int:
	var eid := -1
	var enm := ""
	if id_or_name is int:
		eid = int(id_or_name)
		if eid >= 0 and eid < event_names.size():
			enm = event_names[eid]
		elif eid < 0:
			return -1
	else:
		enm = str(id_or_name)
		if enm.is_empty():
			return -1
		eid = int(event_name_to_idx.get(enm, -1))
		if eid < 0:
			eid = register_event(enm)
	var rec := {"id": eid, "name": enm, "tick": tick, "payload": payload}
	_pending_events.append(rec)
	return eid


func begin_frame_events() -> Array[Dictionary]:
	_frame_events = _pending_events.duplicate()
	_pending_events.clear()
	for ev in _frame_events:
		event_history.append(ev)
	if event_history.size() > 256:
		event_history = event_history.slice(event_history.size() - 256)
	return _frame_events


func get_frame_events() -> Array[Dictionary]:
	return _frame_events


func link_subgraph_symbols(sub_key: String, sub_graph_def: Dictionary) -> Dictionary:
	## Havok hkbSymbolLinker: maps subgraph local variable/event/property IDs to root external IDs by name.
	var var_map := {}
	for v_raw in sub_graph_def.get("variables", []) as Array:
		var v: Dictionary = v_raw as Dictionary
		var local_idx := int(v.get("idx", -1))
		var nm := str(v.get("name", ""))
		var tp := str(v.get("type", "real"))
		var root_idx := register_variable(nm, tp, v.get("default", 0.0))
		var_map[local_idx] = root_idx
	var ev_map := {}
	var evs: Array = sub_graph_def.get("events", []) as Array
	for li in evs.size():
		ev_map[li] = register_event(str(evs[li]))
	var prop_map := {}
	for p_raw in sub_graph_def.get("character_properties", []) as Array:
		var p: Dictionary = p_raw as Dictionary
		var local_idx := int(p.get("idx", -1))
		var nm := str(p.get("name", ""))
		var tp := str(p.get("type", "real"))
		prop_map[local_idx] = register_character_property(nm, tp, p.get("default", 0.0))
	var link := {"var_map": var_map, "ev_map": ev_map, "prop_map": prop_map}
	symbol_links[sub_key] = link
	return link


func dump_variables() -> Dictionary:
	var out := {}
	for i in var_names.size():
		out[var_names[i]] = var_values[i]
	return out


static func _coerce_default(tp: String, raw: Variant) -> Variant:
	match tp:
		"bool":
			if raw is bool:
				return raw
			return bool(raw)
		"int8", "int16", "int32":
			return int(raw) if (raw is int or raw is float or raw is bool or raw is String) else 0
		"real":
			return float(raw) if (raw is float or raw is int or raw is bool or raw is String) else 0.0
		"pointer":
			return raw
		"vector3":
			if raw is Vector3:
				return raw
			if raw is Array and (raw as Array).size() >= 3:
				return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
			return Vector3.ZERO
		"vector4":
			if raw is Vector4:
				return raw
			if raw is Vector3:
				return Vector4((raw as Vector3).x, (raw as Vector3).y, (raw as Vector3).z, 0.0)
			if raw is Array and (raw as Array).size() >= 4:
				return Vector4(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
			return Vector4.ZERO
		"quaternion":
			if raw is Quaternion:
				return (raw as Quaternion).normalized()
			if raw is Array and (raw as Array).size() >= 4:
				var q := Quaternion(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
				return q.normalized() if q.length_squared() > 1e-8 else Quaternion.IDENTITY
			return Quaternion.IDENTITY
		_:
			return raw
