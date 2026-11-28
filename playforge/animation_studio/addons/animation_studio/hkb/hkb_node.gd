@tool
class_name HkbNode
extends RefCounted
## Pure-GDScript base class mirroring `hkbBindable` + `hkbNode` + `hkbVariableBindingSet`.
##
## Implements REAL Havok variable-to-member binding (`copy_variables_to_members`),
## supporting:
##   - Input bindings (variable / character_property -> node property or nested path e.g. `children:1/weight`)
##   - Output reverse bindings (node output property -> behavior variable e.g. `dampedValue`, `currentStateId`)
##   - Bit-index bindings (`bit >= 0`) and `enable` binding

const HkbCtx := preload("res://addons/animation_studio/hkb/hkb_context.gd")
const HkbPoseCls := preload("res://addons/animation_studio/hkb/hkb_pose.gd")

# Known Havok output member names copied in reverse (member -> variable) after update/modify
const OUTPUT_MEMBERS := {
	"dampedValue": true,
	"dampedVector": true,
	"currentStateId": true,
	"isActive": true,
	"isTargetInsideLimitCone": true,
	"angleOut": true,
	"groundPositionOut": true,
	"verticalErrorOut": true,
	"hitSomething": true,
	"directionOut": true,
	"rotationOut": true,
	"translationOut": true,
	"vectorOut": true,
	"worldFromModelTranslationOut": true,
	"worldFromModelRotationOut": true,
	"handleOut": true,
	"distanceOut": true,
	"foundHandleOut": true,
	"handlePositionOut": true,
	"handleRotationOut": true,
	"isValidOut": true,
}

# Mapping from Havok camelCase member names to Godot snake_case properties
const HAVOK_MEMBER_ALIAS := {
	"enable": "enable",
	"playbackSpeed": "playback_speed",
	"enforcedDuration": "enforced_duration",
	"userControlledTimeFraction": "user_controlled_time_fraction",
	"selectedGeneratorIndex": "selected_index",
	"blendParameter": "blend_parameter",
	"referencePoseWeightThreshold": "ref_threshold",
	"weight": "weight",
	"worldFromModelWeight": "wfm_weight",
	"rawValue": "raw_value",
	"dampedValue": "damped_value",
	"rawVector": "raw_vector",
	"dampedVector": "damped_vector",
	"kP": "kp",
	"kI": "ki",
	"kD": "kd",
	"inputValue": "input_value",
	"lowerBound": "lower_bound",
	"alarmTimeSeconds": "alarm_time",
	"delaySeconds": "delay_seconds",
	"durationSeconds": "duration_seconds",
	"targetWS": "target_ws",
	"isOn": "is_on",
	"limitAngleDegrees": "limit_angle_deg",
	"onGain": "on_gain",
	"offGain": "off_gain",
	"newTargetGain": "new_target_gain",
	"isTargetInsideLimitCone": "is_target_inside_limit_cone",
	"twistAngle": "twist_angle_deg",
	"axisOfRotation": "axis_of_rotation",
	"isAdditive": "is_additive",
	"currentStateId": "current_state_id",
	"isActive": "is_active",
	"maxForce": "max_force",
	"tau": "tau",
	"damping": "damping",
	"hierarchyGain": "hierarchy_gain",
	"animationBlendFraction": "anim_blend",
	"duration": "duration",
	"directionOut": "direction_out",
	"rotationOut": "rotation_out",
	"translationOut": "translation_out",
	"vectorOut": "vector_out",
	"degreesPerSecond": "degrees_per_second",
	"speedMultiplier": "speed_multiplier",
	"offsetPerSecondMS": "offset_per_second_ms",
	"handle": "handle",
	"handleIn": "handle_in",
	"handleOut": "handle_out",
	"distanceOut": "distance_out",
	"foundHandleOut": "found_handle_out",
	"handlePositionOut": "handle_position_out",
	"handleRotationOut": "handle_rotation_out",
	"isValidOut": "is_valid_out",
	"xAxisParameterValue": "x_axis_param",
	"yAxisParameterValue": "y_axis_param",
	"fraction": "fraction",
	"boneIndices": "bone_indices",
	"controlDatas": "control_datas",
	"targetHandle": "target_handle",
	"targetPosition": "target_pos",
	"targetRotation": "target_rot",
	"animationInfluence": "anim_influence",
}

var id: int = -1
var node_name: String = ""
var node_type: String = "hkbNode"
var enable: bool = true
var is_active: bool = false
var bindings: Array[Dictionary] = [] # [{member, var_idx, var_name, type, bit, is_output}]
var symbol_link: Dictionary = {} # optional HkbSymbolLinker remap {var_map, ev_map, prop_map}


func init_common(def: Dictionary, p_link: Dictionary = {}) -> void:
	id = int(def.get("id", -1))
	node_name = str(def.get("name", ""))
	node_type = str(def.get("type", "hkbNode"))
	enable = bool(def.get("enable", true))
	symbol_link = p_link
	bindings.clear()
	for b_raw in def.get("bindings", []) as Array:
		add_binding_dict(b_raw as Dictionary)


func add_binding(member_path: String, var_name_or_idx: Variant, binding_type: String = "variable", bit_index: int = -1, is_output: bool = false) -> void:
	var leaf := member_path.split("/")[-1]
	var out_flag := is_output or OUTPUT_MEMBERS.has(leaf)
	var b := {
		"member": member_path,
		"var_idx": int(var_name_or_idx) if var_name_or_idx is int else -1,
		"var_name": str(var_name_or_idx) if not (var_name_or_idx is int) else "",
		"type": binding_type,
		"bit": bit_index,
		"is_output": out_flag,
	}
	bindings.append(b)


func add_binding_dict(b_raw: Dictionary) -> void:
	var member := str(b_raw.get("member", ""))
	if member.is_empty():
		return
	var leaf := member.split("/")[-1]
	var btype := str(b_raw.get("type", "variable"))
	var vidx := int(b_raw.get("var_idx", -1))
	var vname := str(b_raw.get("var_name", ""))
	# Apply symbol linker remap if inside nested BehaviorReferenceGenerator
	if not symbol_link.is_empty() and vidx >= 0:
		if btype == "character_property":
			var pmap: Dictionary = symbol_link.get("prop_map", {}) as Dictionary
			if pmap.has(vidx):
				vidx = int(pmap[vidx])
		else:
			var vmap: Dictionary = symbol_link.get("var_map", {}) as Dictionary
			if vmap.has(vidx):
				vidx = int(vmap[vidx])
	bindings.append({
		"member": member,
		"var_idx": vidx,
		"var_name": vname,
		"type": btype,
		"bit": int(b_raw.get("bit", -1)),
		"is_output": bool(b_raw.get("is_output", OUTPUT_MEMBERS.has(leaf))),
	})


func copy_variables_to_members(ctx: HkbCtx, reverse: bool = false) -> int:
	## Executes Havok `hkbVariableBindingSet::copyVariablesToMembers()` directly in GDScript.
	## Returns number of bindings applied.
	if ctx == null or bindings.is_empty():
		return 0
	var count := 0
	for b in bindings:
		var is_out := bool(b.get("is_output", false))
		if reverse != is_out:
			continue
		var member := str(b["member"])
		var btype := str(b["type"])
		var bit := int(b.get("bit", -1))
		var key: Variant = str(b["var_name"]) if not str(b["var_name"]).is_empty() else int(b["var_idx"])
		if not reverse:
			var val: Variant = ctx.get_char_prop(key) if btype == "character_property" else ctx.get_var(key)
			if _write_member_path(self, member, val, bit):
				count += 1
		else:
			var cur: Variant = _read_member_path(self, member, bit)
			if cur != null:
				if btype == "character_property":
					ctx.set_char_prop(key, cur)
				else:
					ctx.set_var(key, cur)
				count += 1
	return count


static func apply_binding_list(target_obj: Variant, binding_list: Array, ctx: HkbCtx, reverse: bool = false) -> int:
	if ctx == null or binding_list.is_empty():
		return 0
	var count := 0
	for b_raw in binding_list:
		var b: Dictionary = b_raw as Dictionary
		var member := str(b.get("member", ""))
		if member.is_empty():
			continue
		var leaf := member.split("/")[-1]
		var is_out := bool(b.get("is_output", OUTPUT_MEMBERS.has(leaf)))
		if reverse != is_out:
			continue
		var btype := str(b.get("type", "variable"))
		var bit := int(b.get("bit", -1))
		var key: Variant = str(b.get("var_name", "")) if not str(b.get("var_name", "")).is_empty() else int(b.get("var_idx", -1))
		if not reverse:
			var val: Variant = ctx.get_char_prop(key) if btype == "character_property" else ctx.get_var(key)
			if _write_member_path(target_obj, member, val, bit):
				count += 1
		else:
			var cur: Variant = _read_member_path(target_obj, member, bit)
			if cur != null:
				if btype == "character_property":
					ctx.set_char_prop(key, cur)
				else:
					ctx.set_var(key, cur)
				count += 1
	return count


static func _resolve_prop_name(raw_seg: String) -> String:
	if HAVOK_MEMBER_ALIAS.has(raw_seg):
		return str(HAVOK_MEMBER_ALIAS[raw_seg])
	return raw_seg


static func _write_member_path(root_obj: Variant, path: String, value: Variant, bit: int = -1) -> bool:
	var segs := path.split("/", false)
	if segs.is_empty():
		return false
	var cur: Variant = root_obj
	var last_seg := segs[segs.size() - 1]
	# Handle Vector3 component writes such as `offsetPerSecondMS/x`
	if segs.size() >= 2 and last_seg in ["x", "y", "z"]:
		for si in segs.size() - 2:
			cur = _step_container(cur, segs[si])
			if cur == null:
				return false
		var vec_prop := _resolve_prop_name(segs[segs.size() - 2])
		var cur_v: Variant = _get_field(cur, vec_prop)
		if cur_v is Vector3:
			var v3: Vector3 = cur_v as Vector3
			if last_seg == "x":
				v3.x = float(value)
			elif last_seg == "y":
				v3.y = float(value)
			else:
				v3.z = float(value)
			return _set_field(cur, vec_prop, v3)
	for si in segs.size() - 1:
		cur = _step_container(cur, segs[si])
		if cur == null:
			return false
	if ":" in last_seg:
		var parts := last_seg.split(":", false, 1)
		var arr_prop := _resolve_prop_name(parts[0])
		var idx := int(parts[1])
		var arr: Variant = _get_field(cur, arr_prop)
		if arr is Array and idx >= 0 and idx < (arr as Array).size():
			(arr as Array)[idx] = value
			return true
		if arr is PackedFloat32Array and idx >= 0 and idx < (arr as PackedFloat32Array).size():
			var pfa: PackedFloat32Array = arr as PackedFloat32Array
			pfa[idx] = float(value)
			_set_field(cur, arr_prop, pfa)
			return true
		return false
	var prop := _resolve_prop_name(last_seg)
	if bit >= 0:
		var existing := int(_get_field(cur, prop))
		var mask := 1 << bit
		var next_bits := (existing | mask) if bool(value) else (existing & ~mask)
		return _set_field(cur, prop, next_bits)
	return _set_field(cur, prop, value)


static func _read_member_path(root_obj: Variant, path: String, bit: int = -1) -> Variant:
	var segs := path.split("/", false)
	if segs.is_empty():
		return null
	var cur: Variant = root_obj
	for si in segs.size() - 1:
		cur = _step_container(cur, segs[si])
		if cur == null:
			return null
	var last_seg := segs[segs.size() - 1]
	if ":" in last_seg:
		var parts := last_seg.split(":", false, 1)
		var arr: Variant = _get_field(cur, _resolve_prop_name(parts[0]))
		var idx := int(parts[1])
		if arr is Array and idx >= 0 and idx < (arr as Array).size():
			return (arr as Array)[idx]
		if arr is PackedFloat32Array and idx >= 0 and idx < (arr as PackedFloat32Array).size():
			return (arr as PackedFloat32Array)[idx]
		return null
	var v: Variant = _get_field(cur, _resolve_prop_name(last_seg))
	if bit >= 0 and v != null:
		return (int(v) & (1 << bit)) != 0
	return v


static func _step_container(cur: Variant, seg: String) -> Variant:
	if ":" in seg:
		var parts := seg.split(":", false, 1)
		var arr: Variant = _get_field(cur, _resolve_prop_name(parts[0]))
		var idx := int(parts[1])
		if arr is Array and idx >= 0 and idx < (arr as Array).size():
			return (arr as Array)[idx]
		return null
	var next: Variant = _get_field(cur, _resolve_prop_name(seg))
	# Transparently unwrap Havok nested controlData structs (stored flat on GDScript node)
	if next == null and seg in ["controlData", "keyFrameControlData", "blendingControlData", "gains"]:
		return cur
	return next


static func _get_field(obj: Variant, prop: String) -> Variant:
	if obj is Dictionary:
		var d: Dictionary = obj as Dictionary
		if d.has(prop):
			return d[prop]
		return null
	if obj is Object:
		var o: Object = obj as Object
		if prop in o:
			return o.get(prop)
	return null


static func _set_field(obj: Variant, prop: String, value: Variant) -> bool:
	if obj is Dictionary:
		(obj as Dictionary)[prop] = value
		return true
	if obj is Object:
		var o: Object = obj as Object
		if prop in o:
			var cur: Variant = o.get(prop)
			if cur is bool:
				o.set(prop, bool(value))
			elif cur is int:
				if value is int or value is float or value is bool or value is String:
					o.set(prop, int(value))
			elif cur is float:
				if value is float or value is int or value is bool or value is String:
					o.set(prop, float(value))
				elif value is Vector3:
					o.set(prop, (value as Vector3).x)
				elif value is Vector4:
					o.set(prop, (value as Vector4).x)
			elif cur is Vector3 and value is Vector4:
				var v4: Vector4 = value as Vector4
				o.set(prop, Vector3(v4.x, v4.y, v4.z))
			else:
				o.set(prop, value)
			return true
	return false


# --- Virtual Havok hkbNode lifecycle ---

func activate(ctx: HkbCtx) -> void:
	is_active = true
	copy_variables_to_members(ctx, false)


func update(ctx: HkbCtx, _dt: float) -> void:
	copy_variables_to_members(ctx, false)


func handle_event(_ctx: HkbCtx, _ev_id: int, _ev_name: String) -> bool:
	return false


func deactivate(_ctx: HkbCtx) -> void:
	is_active = false


func generate(_ctx: HkbCtx, _out_pose: HkbPoseCls) -> void:
	pass


func modify(_ctx: HkbCtx, _pose: HkbPoseCls) -> void:
	pass
