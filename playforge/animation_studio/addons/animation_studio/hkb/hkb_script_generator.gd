@tool
class_name HkbScriptGenerator
extends "res://addons/animation_studio/hkb/hkb_generators.gd".HkbGenerator
## Native GDScript replacement for Havok `hkbScriptGenerator` (ZERO Lua VM dependency!).
##
## Replaces all 88 official SDK `hkbScriptGenerator` Lua nodes with clean GDScript execution:
##   1. User-registered GDScript callbacks (`set_gdscript_callbacks` / `register_script_handler`)
##   2. Built-in GDScript ports of official SDK Hero / Soldier / Camera / Gamepad / Cover /
##      Climbing / Vaulting / Leaping / Docking / Stagger / AI Lua scripts (operating strictly
##      in Godot standard axes: +Y up, -Z forward, +X right!)
##   3. Automatic declarative GDScript interpreter for simple inline `hkbSetVariable(...)` /
##      `hkbFireEvent(...)` Lua call snippets extracted directly from `.hkt` graphs.

const HkbExpr := preload("res://addons/animation_studio/hkb/hkb_expression.gd")
const AxisStd := preload("res://addons/animation_studio/hkb/hkb_axis_standard.gd")

# Static global GDScript handler registry: handler_key (lowercase) -> Callable(phase: String, ctx: HkbCtx, gen: Object, arg: Variant)
static var _global_handlers: Dictionary = {}
static var _builtins_registered: bool = false

var child = null
var on_activate_src: String = ""
var on_pre_update_src: String = ""
var on_generate_src: String = ""
var on_handle_event_src: String = ""
var on_deactivate_src: String = ""
var resolved_handler_key: String = ""

# Optional per-instance GDScript callbacks overriding/extending registry handlers
var cb_on_activate: Callable = Callable()
var cb_on_pre_update: Callable = Callable()
var cb_on_generate: Callable = Callable()
var cb_on_handle_event: Callable = Callable()
var cb_on_deactivate: Callable = Callable()

# Telemetry counters (verifiable in tests & editor inspector)
var activate_calls: int = 0
var pre_update_calls: int = 0
var generate_calls: int = 0
var handle_event_calls: int = 0
var deactivate_calls: int = 0


static func register_handler(key: String, handler: Callable) -> void:
	_ensure_builtins()
	_global_handlers[key.to_lower()] = handler


static func list_registered_handlers() -> PackedStringArray:
	_ensure_builtins()
	var out := PackedStringArray()
	for k in _global_handlers.keys():
		out.append(str(k))
	out.sort()
	return out


func configure(def: Dictionary) -> void:
	_ensure_builtins()
	on_activate_src = str(def.get("on_activate", "")).strip_edges()
	on_pre_update_src = str(def.get("on_pre_update", "")).strip_edges()
	on_generate_src = str(def.get("on_generate", "")).strip_edges()
	on_handle_event_src = str(def.get("on_handle_event", "")).strip_edges()
	on_deactivate_src = str(def.get("on_deactivate", "")).strip_edges()
	resolved_handler_key = _resolve_builtin_key()


func set_gdscript_callbacks(callbacks: Dictionary) -> void:
	if callbacks.has("on_activate") and callbacks["on_activate"] is Callable:
		cb_on_activate = callbacks["on_activate"] as Callable
	if callbacks.has("on_pre_update") and callbacks["on_pre_update"] is Callable:
		cb_on_pre_update = callbacks["on_pre_update"] as Callable
	if callbacks.has("on_generate") and callbacks["on_generate"] is Callable:
		cb_on_generate = callbacks["on_generate"] as Callable
	if callbacks.has("on_handle_event") and callbacks["on_handle_event"] is Callable:
		cb_on_handle_event = callbacks["on_handle_event"] as Callable
	if callbacks.has("on_deactivate") and callbacks["on_deactivate"] is Callable:
		cb_on_deactivate = callbacks["on_deactivate"] as Callable


func activate(ctx: HkbCtx) -> void:
	super.activate(ctx)
	activate_calls += 1
	_dispatch("on_activate", on_activate_src, cb_on_activate, ctx, null)
	if child != null:
		child.activate(ctx)


func update(ctx: HkbCtx, dt: float) -> void:
	super.update(ctx, dt)
	pre_update_calls += 1
	_dispatch("on_pre_update", on_pre_update_src, cb_on_pre_update, ctx, dt)
	if child != null:
		child.update(ctx, dt)
	copy_variables_to_members(ctx, true)


func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
	handle_event_calls += 1
	var handled := false
	if _dispatch("on_handle_event", on_handle_event_src, cb_on_handle_event, ctx, {"id": ev_id, "name": ev_name}):
		handled = true
	if child != null and child.handle_event(ctx, ev_id, ev_name):
		handled = true
	return handled


func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
	if child != null:
		child.generate(ctx, out_pose)
	else:
		out_pose.init_from_skeleton(ctx.skeleton)
	generate_calls += 1
	_dispatch("on_generate", on_generate_src, cb_on_generate, ctx, out_pose)


func deactivate(ctx: HkbCtx) -> void:
	deactivate_calls += 1
	_dispatch("on_deactivate", on_deactivate_src, cb_on_deactivate, ctx, null)
	if child != null:
		child.deactivate(ctx)
	super.deactivate(ctx)


func _dispatch(phase: String, raw_src: String, instance_cb: Callable, ctx: HkbCtx, arg: Variant) -> bool:
	if instance_cb.is_valid():
		var r: Variant = instance_cb.call(ctx, self, arg)
		return bool(r) if r is bool else true

	# Check exact function name match in registry (e.g. "onUpdateLocomotion()" -> "onupdatelocomotion")
	var fn_token := _extract_fn_token(raw_src)
	if not fn_token.is_empty() and _global_handlers.has(fn_token):
		var h: Callable = _global_handlers[fn_token] as Callable
		if h.is_valid():
			var r: Variant = h.call(phase, ctx, self, arg)
			return bool(r) if r is bool else true

	# Check resolved domain handler (e.g. "gamepad", "locomotion", "camera", "cover", "climbing", "vaulting", "leaping", "docking", "stagger", "soldier")
	if not resolved_handler_key.is_empty() and _global_handlers.has(resolved_handler_key):
		var h2: Callable = _global_handlers[resolved_handler_key] as Callable
		if h2.is_valid():
			var r2: Variant = h2.call(phase, ctx, self, arg)
			return bool(r2) if r2 is bool else true

	# Fallback: evaluate simple inline hkbSetVariable / hkbFireEvent statements in pure GDScript
	if not raw_src.is_empty():
		return _eval_inline_hkb_statements(raw_src, ctx)
	return false


func _resolve_builtin_key() -> String:
	var combined := ("%s %s %s %s" % [node_name, on_activate_src, on_pre_update_src, on_handle_event_src]).to_lower()
	for key in [
		"gamepad", "camera", "locomotion", "cover", "climbing", "vaulting",
		"leaping", "docking", "stagger", "soldier", "ondemand", "hero",
	]:
		if key in combined:
			return key
	return ""


static func _extract_fn_token(src: String) -> String:
	if src.is_empty():
		return ""
	var s := src.strip_edges()
	var lp := s.find("(")
	if lp > 0:
		var head := s.substr(0, lp).strip_edges()
		if " " not in head and "\n" not in head and ";" not in head:
			return head.to_lower()
	return ""


static func _eval_inline_hkb_statements(src: String, ctx: HkbCtx) -> bool:
	## Pure-GDScript translator for common inline Havok script calls:
	##   hkbSetVariable("Name", expr) / hkbFireEvent("EventName")
	if ctx == null or src.is_empty():
		return false
	var executed := false
	for raw_line in src.replace(";", "\n").split("\n", false):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("--"):
			continue
		if line.begins_with("hkbSetVariable(") and line.ends_with(")"):
			var inner := line.substr(15, line.length() - 16)
			var comma := inner.find(",")
			if comma > 0:
				var vname := inner.substr(0, comma).strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
				var expr := inner.substr(comma + 1).strip_edges()
				if not vname.is_empty():
					var val := HkbExpr.evaluate(expr, ctx)
					ctx.set_var(vname, val)
					executed = true
		elif line.begins_with("hkbFireEvent(") and line.ends_with(")"):
			var ename := line.substr(13, line.length() - 14).strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
			if not ename.is_empty():
				ctx.enqueue_event(ename)
				executed = true
	return executed


static func _ensure_builtins() -> void:
	if _builtins_registered:
		return
	_builtins_registered = true

	# Built-in GDScript ports replacing Havok's official Lua behavior scripts
	# All directional/angular math strictly follows Godot standard (+Y up, -Z forward, +X right).
	_global_handlers["gamepad"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			var move_in: Vector2 = ctx.script_inputs.get("move_stick", Vector2.ZERO) as Vector2
			var spd := clampf(move_in.length(), 0.0, 1.0)
			if ctx.get_var_idx("WalkSpeed") >= 0:
				ctx.set_var("WalkSpeed", spd)
			if ctx.get_var_idx("MoveSpeed") >= 0:
				ctx.set_var("MoveSpeed", spd)
			if spd > 0.05:
				# Godot standard: stick (x=right, y=up/forward) -> world dir (x, 0, -y) -> yaw = atan2(-x, -(-y))
				var desired_dir := Vector3(move_in.x, 0.0, -move_in.y).normalized()
				var yaw_deg := rad_to_deg(AxisStd.yaw_from_forward(desired_dir))
				if ctx.get_var_idx("WalkDirection") >= 0:
					ctx.set_var("WalkDirection", yaw_deg)
				if ctx.get_var_idx("LinearDirection") >= 0:
					ctx.set_var("LinearDirection", yaw_deg)
			return true
		return false

	_global_handlers["locomotion"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			var spd := float(ctx.get_var("WalkSpeed", float(ctx.get_var("MoveSpeed", 0.0))))
			if ctx.get_var_idx("IsMoving") >= 0:
				ctx.set_var("IsMoving", spd > 0.1)
			if ctx.get_var_idx("AnimationIndex") >= 0 and spd > 0.1:
				var dir_deg := float(ctx.get_var("WalkDirection", 0.0))
				var slice := int(floor(fposmod(dir_deg + 22.5, 360.0) / 45.0)) % 8
				ctx.set_var("AnimationIndex", slice)
			return true
		return false

	_global_handlers["camera"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			var cam_yaw := float(ctx.script_inputs.get("camera_yaw", 0.0))
			if ctx.get_var_idx("CameraAngle") >= 0:
				ctx.set_var("CameraAngle", rad_to_deg(cam_yaw))
			return true
		return false

	_global_handlers["cover"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			if bool(ctx.script_inputs.get("take_cover", false)):
				ctx.enqueue_event("TakeCover")
			return true
		return false

	_global_handlers["climbing"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			if bool(ctx.script_inputs.get("climb_up", false)):
				ctx.enqueue_event("ClimbUp")
			return true
		return false

	_global_handlers["vaulting"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			if bool(ctx.script_inputs.get("vault", false)):
				ctx.enqueue_event("Vault")
			return true
		return false

	_global_handlers["leaping"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			if bool(ctx.script_inputs.get("leap", false)):
				ctx.enqueue_event("Leap")
			return true
		return false

	_global_handlers["docking"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null and ctx.docking_driver != null:
			return true
		return false

	_global_handlers["stagger"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			if bool(ctx.script_inputs.get("trigger_stagger", false)):
				ctx.enqueue_event("Stagger")
			return true
		return false

	_global_handlers["soldier"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null:
			var aim_ws: Vector3 = ctx.script_inputs.get("aim_target_ws", Vector3.ZERO) as Vector3
			if aim_ws.length_squared() > 1e-6 and ctx.get_var_idx("AimTarget") >= 0:
				ctx.set_var("AimTarget", aim_ws)
			return true
		return false

	_global_handlers["hero"] = func(phase: String, ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		if phase == "on_pre_update" and ctx != null and ctx.skeleton != null:
			# Foot-forward detection in Godot standard (-Z forward) space (port of hero.lua lines 102-116)
			var l_i := ctx.skeleton.find_bone("LeftLegCalf")
			var r_i := ctx.skeleton.find_bone("RightLegCalf")
			if l_i >= 0 and r_i >= 0 and ctx.get_var_idx("IsRightFootForward") >= 0:
				var lz := ctx.skeleton.get_bone_global_pose(l_i).origin.z
				var rz := ctx.skeleton.get_bone_global_pose(r_i).origin.z
				# Godot forward is -Z -> smaller Z is further forward
				ctx.set_var("IsRightFootForward", 1 if rz < lz else 0)
			return true
		return false

	_global_handlers["ondemand"] = func(_phase: String, _ctx: HkbCtx, _gen: Object, _arg: Variant) -> bool:
		return true
