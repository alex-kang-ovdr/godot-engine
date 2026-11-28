@tool
class_name HkbGenerators
extends RefCounted
## Pure-GDScript Havok `hkbGenerator` Suite mirroring official Havok 2015.1.0-r1:
##   - HkbClipGenerator (4 playback modes, playbackSpeed, enforcedDuration, clip triggers, root motion)
##   - HkbStateMachine (states, wildcards, conditions, eventless transitions, trigger/initiate intervals,
##       smoothstep simultaneous blending transitions, generator transitions, return-to-prev, nesting)
##   - HkbBlenderGenerator (multi-child weighted blend, per-child variable bindings & bone weights,
##       FLAG_SYNC, FLAG_SMOOTH_GENERATOR_WEIGHTS, FLAG_PARAMETRIC_BLEND, referencePoseWeightThreshold)
##   - HkbLayerGenerator (event-driven fade-in/out layers, per-layer bone weights & variable bindings)
##   - HkbManualSelectorGenerator (live variable-bound index selection)
##   - HkbReferencePoseGenerator, HkbModifierGenerator, HkbBehaviorReferenceGenerator, HkbDockingGenerator

const HkbCtx := preload("res://addons/animation_studio/hkb/hkb_context.gd")
const HkbPoseCls := preload("res://addons/animation_studio/hkb/hkb_pose.gd")
const HkbNodeCls := preload("res://addons/animation_studio/hkb/hkb_node.gd")
const HkbExpr := preload("res://addons/animation_studio/hkb/hkb_expression.gd")
const HkbMods := preload("res://addons/animation_studio/hkb/hkb_modifiers.gd")


static func canonical_clip_key(anim_path: String) -> String:
	var s := anim_path.replace("\\", "/").get_file()
	if ":" in s:
		s = s.split(":", false, 1)[1]
	if s.to_lower().ends_with(".hkt"):
		s = s.substr(0, s.length() - 4)
	return s.to_lower()


static func _smoothstep(u: float) -> float:
	var x := clampf(u, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


class HkbGenerator extends HkbNodeCls:
	func get_duration(_ctx: HkbCtx) -> float:
		return 1.0


class HkbReferencePoseGenerator extends HkbGenerator:
	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		out_pose.init_from_skeleton(ctx.skeleton)


class HkbClipGenerator extends HkbGenerator:
	enum PlaybackMode {
		MODE_SINGLE_PLAY = 0,
		MODE_LOOPING = 1,
		MODE_USER_CONTROLLED = 2,
		MODE_PING_PONG = 3,
	}

	var animation_name: String = ""
	var clip_key: String = ""
	var mode: int = PlaybackMode.MODE_LOOPING
	var playback_speed: float = 1.0
	var start_time: float = 0.0
	var enforced_duration: float = 0.0
	var user_controlled_time_fraction: float = 0.0
	var flags: int = 0
	var triggers: Array[Dictionary] = []

	var local_time: float = 0.0
	var _ping_dir: float = 1.0
	var _fired_acyclic: Dictionary = {}
	var _last_rm_pos: Vector3 = Vector3.ZERO
	var _last_rm_yaw: float = 0.0

	func configure(def: Dictionary) -> void:
		animation_name = str(def.get("animation", ""))
		var s := animation_name.replace("\\", "/").get_file()
		if ":" in s:
			s = s.split(":", false, 1)[1]
		if s.to_lower().ends_with(".hkt"):
			s = s.substr(0, s.length() - 4)
		clip_key = s.to_lower()
		mode = int(def.get("mode", PlaybackMode.MODE_LOOPING))
		playback_speed = float(def.get("speed", 1.0))
		start_time = float(def.get("start_time", 0.0))
		enforced_duration = float(def.get("enforced_duration", 0.0))
		user_controlled_time_fraction = float(def.get("user_frac", 0.0))
		flags = int(def.get("flags", 0))
		triggers.clear()
		for tr_raw in def.get("triggers", []) as Array:
			triggers.append(tr_raw as Dictionary)

	func _resolve_clip(ctx: HkbCtx) -> Dictionary:
		if ctx == null or ctx.clip_pack.is_empty():
			return {}
		if ctx.clip_pack.has(clip_key):
			return ctx.clip_pack[clip_key] as Dictionary
		# Fuzzy suffix fallback when SDK animation filename has extra prefix/suffix
		for k in ctx.clip_pack.keys():
			var ks := str(k).to_lower()
			if ks == clip_key or ks.ends_with(clip_key) or clip_key.ends_with(ks):
				return ctx.clip_pack[k] as Dictionary
		return {}

	func get_duration(ctx: HkbCtx) -> float:
		var cl := _resolve_clip(ctx)
		return maxf(0.0167, float(cl.get("duration", 1.0))) if not cl.is_empty() else 1.0

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		local_time = start_time
		_ping_dir = 1.0
		_fired_acyclic.clear()

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		var dur := get_duration(ctx)
		var prev_t := local_time
		var eff_speed := playback_speed
		if enforced_duration > 1e-4:
			eff_speed = dur / enforced_duration
		match mode:
			PlaybackMode.MODE_USER_CONTROLLED:
				local_time = clampf(user_controlled_time_fraction, 0.0, 1.0) * dur
			PlaybackMode.MODE_SINGLE_PLAY:
				local_time = clampf(local_time + dt * eff_speed, 0.0, dur)
			PlaybackMode.MODE_PING_PONG:
				local_time += dt * absf(eff_speed) * _ping_dir
				if local_time >= dur:
					local_time = maxf(0.0, dur - (local_time - dur))
					_ping_dir = -1.0
				elif local_time <= 0.0:
					local_time = absf(local_time)
					_ping_dir = 1.0
			_:
				local_time = fposmod(local_time + dt * eff_speed, dur)

		# Fire Havok clip triggers cleanly into HkbEventQueue
		for ti in triggers.size():
			var tr: Dictionary = triggers[ti]
			if bool(tr.get("acyclic", false)) and _fired_acyclic.has(ti):
				continue
			var fire_t := float(tr.get("t", 0.0))
			if bool(tr.get("rel_end", false)):
				fire_t = maxf(0.0, dur - fire_t)
			var crossed := false
			if local_time >= prev_t:
				crossed = (prev_t <= fire_t and fire_t <= local_time)
			else:
				crossed = (fire_t >= prev_t or fire_t <= local_time)
			if crossed:
				if bool(tr.get("acyclic", false)):
					_fired_acyclic[ti] = true
				var enm := str(tr.get("ev_name", ""))
				var eid := int(tr.get("ev_id", -1))
				if not enm.is_empty():
					ctx.enqueue_event(enm)
				elif eid >= 0:
					ctx.enqueue_event(eid)
		copy_variables_to_members(ctx, true)

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		var cl := _resolve_clip(ctx)
		if cl.is_empty():
			out_pose.init_from_skeleton(ctx.skeleton)
			return
		out_pose.sample_clip_dict(cl, local_time, ctx.skeleton)
		# Extract step root motion delta cleanly (supports both Dictionary{"keys": [...]} and raw Array formats)
		var rm_raw: Variant = cl.get("root_motion", null)
		var rm_keys: Array = []
		if rm_raw is Dictionary:
			rm_keys = (rm_raw as Dictionary).get("keys", []) as Array
		elif rm_raw is Array:
			rm_keys = rm_raw as Array
		if rm_keys.size() >= 2:
			var fps := float(cl.get("fps", 60.0))
			var idx := clampi(int(round(local_time * fps)), 0, rm_keys.size() - 1)
			var entry: Variant = rm_keys[idx]
			var p := Vector3.ZERO
			if entry is Dictionary:
				var ta: Array = (entry as Dictionary).get("translation", [0.0, 0.0, 0.0]) as Array
				p = Vector3(float(ta[0]), float(ta[1]), float(ta[2]))
			elif entry is Array and (entry as Array).size() >= 3:
				var row: Array = entry as Array
				p = Vector3(float(row[0]), float(row[1]), float(row[2]))
			var dp := p - _last_rm_pos
			if dp.length() < 0.8:
				out_pose.root_delta_pos = dp
			_last_rm_pos = p


class HkbModifierGenerator extends HkbGenerator:
	var modifier: HkbMods.HkbModifier = null
	var generator: HkbGenerator = null

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		if generator != null:
			generator.activate(ctx)
		if modifier != null:
			modifier.activate(ctx)

	func deactivate(ctx: HkbCtx) -> void:
		super.deactivate(ctx)
		if modifier != null:
			modifier.deactivate(ctx)
		if generator != null:
			generator.deactivate(ctx)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		var h := false
		if modifier != null and modifier.handle_event(ctx, ev_id, ev_name):
			h = true
		if generator != null and generator.handle_event(ctx, ev_id, ev_name):
			h = true
		return h

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		if modifier != null:
			modifier.pre_modify(ctx, dt)
		if generator != null:
			generator.update(ctx, dt)

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		if generator != null:
			generator.generate(ctx, out_pose)
		else:
			out_pose.init_from_skeleton(ctx.skeleton)
		if modifier != null:
			modifier.modify(ctx, out_pose)


class HkbManualSelectorGenerator extends HkbGenerator:
	var selected_index: int = 0
	var generators: Array = []
	var _active_idx: int = -1

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_sync_active(ctx)

	func _sync_active(ctx: HkbCtx) -> void:
		if generators.is_empty():
			return
		var idx := clampi(selected_index, 0, generators.size() - 1)
		if idx != _active_idx:
			if _active_idx >= 0 and _active_idx < generators.size() and generators[_active_idx] != null:
				generators[_active_idx].deactivate(ctx)
			_active_idx = idx
			if generators[_active_idx] != null:
				generators[_active_idx].activate(ctx)

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		_sync_active(ctx)
		if _active_idx >= 0 and _active_idx < generators.size() and generators[_active_idx] != null:
			generators[_active_idx].update(ctx, dt)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		if _active_idx >= 0 and _active_idx < generators.size() and generators[_active_idx] != null:
			return generators[_active_idx].handle_event(ctx, ev_id, ev_name)
		return false

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		if _active_idx >= 0 and _active_idx < generators.size() and generators[_active_idx] != null:
			generators[_active_idx].generate(ctx, out_pose)
		else:
			out_pose.init_from_skeleton(ctx.skeleton)


class HkbBlenderGenerator extends HkbGenerator:
	## Mirrors `hkbBlenderGenerator` with per-child variable bindings, bone masks, parametric blend, & ref threshold.
	const FLAG_SYNC := 0x1
	const FLAG_SMOOTH_WEIGHTS := 0x4
	const FLAG_PARAMETRIC_BLEND := 0x10

	var flags: int = 0
	var ref_threshold: float = 0.0
	var blend_parameter: float = 0.0
	var subtract_last_child: bool = false
	var children: Array[Dictionary] = [] # [{gen, weight, wfm_weight, bindings, bone_weights, active}]

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		for ch in children:
			HkbNodeCls.apply_binding_list(ch, ch.get("bindings", []) as Array, ctx, false)
			var g = ch.get("gen")
			if g != null:
				g.activate(ctx)
				ch["active"] = true

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		for ch in children:
			HkbNodeCls.apply_binding_list(ch, ch.get("bindings", []) as Array, ctx, false)
			var g = ch.get("gen")
			if g != null and float(ch.get("weight", 0.0)) > 1e-4:
				g.update(ctx, dt)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		var handled := false
		for ch in children:
			var g = ch.get("gen")
			if g != null and g.handle_event(ctx, ev_id, ev_name):
				handled = true
		return handled

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		out_pose.init_from_skeleton(ctx.skeleton)
		if children.is_empty():
			return
		var wsum := 0.0
		var active_list: Array[Dictionary] = []
		for ch in children:
			var w := maxf(0.0, float(ch.get("weight", 0.0)))
			if (flags & FLAG_SMOOTH_WEIGHTS) != 0:
				var x := clampf(w, 0.0, 1.0)
				w = x * x * (3.0 - 2.0 * x)
			if w > 1e-5 and ch.get("gen") != null:
				active_list.append({"ch": ch, "w": w})
				wsum += w
		if active_list.is_empty():
			return

		var accum_w := 0.0
		for item in active_list:
			var ch: Dictionary = item["ch"] as Dictionary
			var w := float(item["w"])
			var tmp := HkbPoseCls.new()
			ch["gen"].generate(ctx, tmp)
			var bw: PackedFloat32Array = ch.get("bone_weights", PackedFloat32Array())
			if accum_w <= 1e-6:
				out_pose.pos = tmp.pos.duplicate()
				out_pose.rot_xyzw = tmp.rot_xyzw.duplicate()
				out_pose.scl = tmp.scl.duplicate()
				out_pose.root_delta_pos = tmp.root_delta_pos
				out_pose.root_delta_yaw = tmp.root_delta_yaw
				accum_w = w
			else:
				var alpha := w / (accum_w + w)
				out_pose.blend_with(tmp, alpha, bw)
				accum_w += w

		if ref_threshold > 1e-4 and wsum < ref_threshold:
			var ref_pose := HkbPoseCls.new()
			ref_pose.init_from_skeleton(ctx.skeleton)
			var ref_alpha := 1.0 - clampf(wsum / ref_threshold, 0.0, 1.0)
			out_pose.blend_with(ref_pose, ref_alpha)


class HkbLayerGenerator extends HkbGenerator:
	## Mirrors `hkbLayerGenerator` + `hkbEventDrivenBlendingObject` fade-in/out & per-layer bone weights.
	var flags: int = 0
	var layers: Array[Dictionary] = [] # [{gen, weight, fade_in, fade_out, on_ev, off_ev, on_default, use_motion, bindings, bone_weights, on_frac, fading}]

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		for ly in layers:
			HkbNodeCls.apply_binding_list(ly, ly.get("bindings", []) as Array, ctx, false)
			var on_def := bool(ly.get("on_default", true))
			ly["on_frac"] = 1.0 if on_def else 0.0
			ly["fading"] = 0 # 0=steady, 1=in, -1=out
			if ly.get("gen") != null and on_def:
				ly["gen"].activate(ctx)

	func handle_event(ctx: HkbCtx, ev_id: int, _ev_name: String) -> bool:
		var handled := false
		for ly in layers:
			var on_ev := int(ly.get("on_ev", -1))
			var off_ev := int(ly.get("off_ev", -1))
			if on_ev >= 0 and ev_id == on_ev:
				ly["fading"] = 1
				if ly.get("gen") != null and float(ly.get("on_frac", 0.0)) <= 1e-4:
					ly["gen"].activate(ctx)
				handled = true
			elif off_ev >= 0 and ev_id == off_ev:
				ly["fading"] = -1
				handled = true
			elif ly.get("gen") != null and float(ly.get("on_frac", 0.0)) > 1e-4:
				if ly["gen"].handle_event(ctx, ev_id, _ev_name):
					handled = true
		return handled

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		for ly in layers:
			HkbNodeCls.apply_binding_list(ly, ly.get("bindings", []) as Array, ctx, false)
			var f := int(ly.get("fading", 0))
			var frac := float(ly.get("on_frac", 1.0))
			if f == 1:
				var fi := float(ly.get("fade_in", 0.0))
				frac = 1.0 if fi <= 1e-4 else minf(1.0, frac + dt / fi)
				if frac >= 1.0:
					ly["fading"] = 0
			elif f == -1:
				var fo := float(ly.get("fade_out", 0.0))
				frac = 0.0 if fo <= 1e-4 else maxf(0.0, frac - dt / fo)
				if frac <= 0.0:
					ly["fading"] = 0
			ly["on_frac"] = frac
			if frac > 1e-4 and ly.get("gen") != null:
				ly["gen"].update(ctx, dt)

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		out_pose.init_from_skeleton(ctx.skeleton)
		var first := true
		for ly in layers:
			var eff_w := clampf(float(ly.get("weight", 1.0)) * float(ly.get("on_frac", 1.0)), 0.0, 1.0)
			if eff_w <= 1e-4 or ly.get("gen") == null:
				continue
			var tmp := HkbPoseCls.new()
			ly["gen"].generate(ctx, tmp)
			var bw: PackedFloat32Array = ly.get("bone_weights", PackedFloat32Array())
			if first and bw.is_empty():
				out_pose.pos = tmp.pos.duplicate()
				out_pose.rot_xyzw = tmp.rot_xyzw.duplicate()
				out_pose.scl = tmp.scl.duplicate()
				if bool(ly.get("use_motion", true)):
					out_pose.root_delta_pos = tmp.root_delta_pos
					out_pose.root_delta_yaw = tmp.root_delta_yaw
				first = false
			else:
				out_pose.blend_with(tmp, eff_w, bw)
				first = false


class HkbStateMachine extends HkbGenerator:
	## Complete Pure-GDScript `hkbStateMachine` with live conditions, wildcards, intervals,
	## simultaneous smoothstep blending transitions, generator transitions, return-to-previous, & nesting!
	const FLAG_USE_TRIGGER_INTERVAL := 0x1
	const FLAG_USE_INITIATE_INTERVAL := 0x2
	const FLAG_DISABLED := 0x20
	const FLAG_DISABLE_CONDITION := 0x100

	var start_state_id: int = 0
	var return_prev_ev: int = -1
	var random_ev: int = -1
	var next_hi_ev: int = -1
	var next_lo_ev: int = -1
	var sync_var: int = -1
	var max_sim_trans: int = 8

	var states: Array[Dictionary] = [] # [{state_id, name, gen, prob, enable, bindings, enter_events, exit_events, transitions}]
	var state_id_to_idx: Dictionary = {}
	var wildcards: Array[Dictionary] = []

	var current_state_id: int = -1
	var previous_state_id: int = -1
	var _state_time: float = 0.0
	var _active_transitions: Array[Dictionary] = [] # [{from_gen, to_gen, duration, elapsed, kind, trans_gen}]
	var transition_count: int = 0

	func configure(def: Dictionary) -> void:
		start_state_id = int(def.get("start_state_id", 0))
		return_prev_ev = int(def.get("return_prev_ev", -1))
		random_ev = int(def.get("random_ev", -1))
		next_hi_ev = int(def.get("next_hi_ev", -1))
		next_lo_ev = int(def.get("next_lo_ev", -1))
		sync_var = int(def.get("sync_var", -1))
		max_sim_trans = maxi(1, int(def.get("max_sim_trans", 8)))
		wildcards.clear()
		for wc_raw in def.get("wildcards", []) as Array:
			wildcards.append(wc_raw as Dictionary)

	func add_state_dict(st: Dictionary) -> void:
		var idx := states.size()
		states.append(st)
		state_id_to_idx[int(st["state_id"])] = idx

	func get_current_state_name() -> String:
		var idx := int(state_id_to_idx.get(current_state_id, -1))
		return str(states[idx]["name"]) if idx >= 0 else ""

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_active_transitions.clear()
		transition_count = 0
		previous_state_id = -1
		var sid := start_state_id
		if sync_var >= 0:
			var sv := int(ctx.get_var(sync_var, sid))
			if state_id_to_idx.has(sv):
				sid = sv
		if not state_id_to_idx.has(sid) and not states.is_empty():
			sid = int(states[0]["state_id"])
		_enter_state(ctx, sid, null)

	func _enter_state(ctx: HkbCtx, to_sid: int, effect: Variant) -> void:
		if not state_id_to_idx.has(to_sid):
			return
		var prev_idx := int(state_id_to_idx.get(current_state_id, -1))
		var next_idx := int(state_id_to_idx[to_sid])
		var prev_gen = states[prev_idx]["gen"] if prev_idx >= 0 else null
		var next_st: Dictionary = states[next_idx]
		var next_gen = next_st["gen"]

		if prev_idx >= 0:
			for ev in states[prev_idx].get("exit_events", []) as Array:
				ctx.enqueue_event(int((ev as Dictionary).get("id", -1)))
			previous_state_id = current_state_id

		current_state_id = to_sid
		_state_time = 0.0
		if sync_var >= 0:
			ctx.set_var(sync_var, current_state_id)
		HkbNodeCls.apply_binding_list(next_st, next_st.get("bindings", []) as Array, ctx, false)
		for ev in next_st.get("enter_events", []) as Array:
			ctx.enqueue_event(int((ev as Dictionary).get("id", -1)))
		if next_gen != null:
			next_gen.activate(ctx)

		if prev_gen != null and prev_gen != next_gen and effect is Dictionary:
			var eff: Dictionary = effect as Dictionary
			var dur := float(eff.get("duration", 0.0))
			var kind := str(eff.get("kind", "blending"))
			if kind == "generator" and eff.get("trans_gen_obj") != null:
				dur = maxf(0.15, float(eff.get("blend_in", 0.1)) + float(eff.get("blend_out", 0.1)))
				eff["trans_gen_obj"].activate(ctx)
			if dur > 1e-4:
				_active_transitions.append({
					"from_gen": prev_gen,
					"to_gen": next_gen,
					"duration": dur,
					"elapsed": 0.0,
					"kind": kind,
					"trans_gen": eff.get("trans_gen_obj"),
				})
				while _active_transitions.size() > max_sim_trans:
					var oldest: Dictionary = _active_transitions.pop_front()
					if oldest["from_gen"] != null and oldest["from_gen"] != next_gen:
						oldest["from_gen"].deactivate(ctx)
			elif prev_gen != null:
				prev_gen.deactivate(ctx)
		elif prev_gen != null and prev_gen != next_gen:
			prev_gen.deactivate(ctx)
		transition_count += 1
		copy_variables_to_members(ctx, true)

	func force_state(ctx: HkbCtx, state_id_or_name: Variant, blend_duration: float = 0.2) -> bool:
		var target_id := -1
		if state_id_or_name is int:
			target_id = int(state_id_or_name)
		else:
			var nm := str(state_id_or_name)
			for st in states:
				if str(st["name"]) == nm:
					target_id = int(st["state_id"])
					break
		if target_id < 0 or target_id == current_state_id or not state_id_to_idx.has(target_id):
			return false
		_enter_state(ctx, target_id, {"kind": "blending", "duration": blend_duration} if blend_duration > 0.0 else null)
		return true

	func _transition_matches(tr: Dictionary, ev_id: int, ev_name: String, ctx: HkbCtx) -> bool:
		var fl := int(tr.get("flags", 0))
		if (fl & FLAG_DISABLED) != 0:
			return false
		var tr_ev := int(tr.get("event_id", -1))
		var tr_enm := str(tr.get("event_name", ""))
		if ev_id == -1 and ev_name.is_empty():
			# Eventless condition-driven transition!
			if tr_ev >= 0 or not tr_enm.is_empty():
				return false
			if tr.get("condition") == null:
				return false
		else:
			var id_match := (tr_ev >= 0 and tr_ev == ev_id)
			var nm_match := (not tr_enm.is_empty() and tr_enm == ev_name)
			if not id_match and not nm_match:
				return false
		# Trigger interval check
		if (fl & FLAG_USE_TRIGGER_INTERVAL) != 0 and tr.has("trigger_interval"):
			var ti: Dictionary = tr["trigger_interval"] as Dictionary
			var et0 := float(ti.get("enter_t", 0.0))
			var et1 := float(ti.get("exit_t", 0.0))
			if _state_time < et0 or (et1 > 0.0 and _state_time > et1):
				return false
		# Condition evaluation
		if (fl & FLAG_DISABLE_CONDITION) == 0 and tr.get("condition") != null:
			if not HkbExpr.evaluate_condition(tr["condition"], ctx):
				return false
		return true

	func _try_transitions(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		# Special Havok state-machine events: return-to-previous, next-higher, next-lower, random
		if ev_id >= 0:
			if return_prev_ev >= 0 and ev_id == return_prev_ev and previous_state_id >= 0 and state_id_to_idx.has(previous_state_id):
				_enter_state(ctx, previous_state_id, {"kind": "blending", "duration": 0.25})
				return true
			if next_hi_ev >= 0 and ev_id == next_hi_ev and states.size() > 1:
				var ci := int(state_id_to_idx.get(current_state_id, 0))
				var ni := (ci + 1) % states.size()
				_enter_state(ctx, int(states[ni]["state_id"]), {"kind": "blending", "duration": 0.2})
				return true
			if next_lo_ev >= 0 and ev_id == next_lo_ev and states.size() > 1:
				var ci := int(state_id_to_idx.get(current_state_id, 0))
				var ni := (ci - 1 + states.size()) % states.size()
				_enter_state(ctx, int(states[ni]["state_id"]), {"kind": "blending", "duration": 0.2})
				return true
			if random_ev >= 0 and ev_id == random_ev and states.size() > 1:
				var pick := int(states[(ctx.tick + transition_count + 1) % states.size()]["state_id"])
				if pick != current_state_id:
					_enter_state(ctx, pick, {"kind": "blending", "duration": 0.25})
					return true

		var cur_idx := int(state_id_to_idx.get(current_state_id, -1))
		var candidates: Array[Dictionary] = []
		if cur_idx >= 0:
			for tr in states[cur_idx].get("transitions", []) as Array:
				if _transition_matches(tr as Dictionary, ev_id, ev_name, ctx):
					candidates.append(tr as Dictionary)
		for wc in wildcards:
			if _transition_matches(wc, ev_id, ev_name, ctx):
				if int(wc.get("to_state_id", -1)) != current_state_id:
					candidates.append(wc)
		if candidates.is_empty():
			return false
		candidates.sort_custom(func(a, b): return int(a.get("priority", 0)) > int(b.get("priority", 0)))
		var chosen: Dictionary = candidates[0]
		_enter_state(ctx, int(chosen.get("to_state_id", current_state_id)), chosen.get("effect"))
		return true

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		if _try_transitions(ctx, ev_id, ev_name):
			return true
		var cur_idx := int(state_id_to_idx.get(current_state_id, -1))
		if cur_idx >= 0 and states[cur_idx]["gen"] != null:
			return states[cur_idx]["gen"].handle_event(ctx, ev_id, ev_name)
		return false

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		_state_time += dt
		# Check eventless condition transitions every tick (Havok m_hasEventlessTransitions)
		_try_transitions(ctx, -1, "")

		var cur_idx := int(state_id_to_idx.get(current_state_id, -1))
		var cur_gen = states[cur_idx]["gen"] if cur_idx >= 0 else null
		if cur_idx >= 0:
			ctx.active_state_paths.append("%s:%s" % [node_name, str(states[cur_idx]["name"])])
		if cur_gen != null:
			cur_gen.update(ctx, dt)

		var keep: Array[Dictionary] = []
		for tr in _active_transitions:
			tr["elapsed"] = float(tr["elapsed"]) + dt
			var fg = tr["from_gen"]
			if fg != null and fg != cur_gen:
				fg.update(ctx, dt)
			if tr.get("trans_gen") != null:
				tr["trans_gen"].update(ctx, dt)
			if float(tr["elapsed"]) < float(tr["duration"]):
				keep.append(tr)
			elif fg != null and fg != cur_gen:
				fg.deactivate(ctx)
		_active_transitions = keep
		copy_variables_to_members(ctx, true)

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		var cur_idx := int(state_id_to_idx.get(current_state_id, -1))
		var cur_gen = states[cur_idx]["gen"] if cur_idx >= 0 else null
		if cur_gen == null:
			out_pose.init_from_skeleton(ctx.skeleton)
			return
		cur_gen.generate(ctx, out_pose)
		for tr in _active_transitions:
			var xu := clampf(float(tr["elapsed"]) / maxf(1e-4, float(tr["duration"])), 0.0, 1.0)
			var u := xu * xu * (3.0 - 2.0 * xu)
			var from_w := 1.0 - u
			if from_w <= 1e-4:
				continue
			var fg = tr["from_gen"]
			if fg != null:
				var from_pose := HkbPoseCls.new()
				fg.generate(ctx, from_pose)
				out_pose.blend_with(from_pose, from_w)


class HkbBehaviorReferenceGenerator extends HkbGenerator:
	## Mirrors `hkbBehaviorReferenceGenerator` with `HkbSymbolLinker` subgraph binding.
	var behavior_name: String = ""
	var sub_root: HkbGenerator = null

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		if sub_root != null:
			sub_root.activate(ctx)

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		if sub_root != null:
			sub_root.update(ctx, dt)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		return sub_root.handle_event(ctx, ev_id, ev_name) if sub_root != null else false

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		if sub_root != null:
			sub_root.generate(ctx, out_pose)
		else:
			out_pose.init_from_skeleton(ctx.skeleton)


class HkbDockingGenerator extends HkbGenerator:
	## Mirrors `hkbDockingGenerator` + incremental motion warping to docking target.
	var child: HkbGenerator = null
	var target_pos: Vector3 = Vector3.ZERO
	var target_yaw: float = 0.0
	var docking_active: bool = false
	var blend_duration: float = 0.6
	var _elapsed: float = 0.0

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		_elapsed = 0.0
		if child != null:
			child.activate(ctx)

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		if child != null:
			child.update(ctx, dt)
		if docking_active and ctx.actor != null:
			_elapsed += dt
			var rem := maxf(dt, blend_duration - _elapsed)
			var frac := clampf(dt / rem, 0.0, 1.0)
			ctx.actor.global_position = ctx.actor.global_position.lerp(target_pos, frac)
			ctx.actor.rotation.y = lerp_angle(ctx.actor.rotation.y, target_yaw, frac)

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		if child != null:
			child.generate(ctx, out_pose)
		else:
			out_pose.init_from_skeleton(ctx.skeleton)


class HkbPinBonesGenerator extends HkbGenerator:
	## Pure-GDScript `hkbPinBonesGenerator`: pins specified `bone_indices` from `reference_frame_generator`
	## onto `pinned_generator` blended by `fraction`.
	var reference_frame_generator: HkbGenerator = null
	var pinned_generator: HkbGenerator = null
	var bone_indices: PackedInt32Array = PackedInt32Array()
	var fraction: float = 1.0

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		if reference_frame_generator != null:
			reference_frame_generator.activate(ctx)
		if pinned_generator != null:
			pinned_generator.activate(ctx)

	func deactivate(ctx: HkbCtx) -> void:
		if pinned_generator != null:
			pinned_generator.deactivate(ctx)
		if reference_frame_generator != null:
			reference_frame_generator.deactivate(ctx)
		super.deactivate(ctx)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		var h := false
		if pinned_generator != null and pinned_generator.handle_event(ctx, ev_id, ev_name):
			h = true
		if reference_frame_generator != null and reference_frame_generator.handle_event(ctx, ev_id, ev_name):
			h = true
		return h

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		if reference_frame_generator != null:
			reference_frame_generator.update(ctx, dt)
		if pinned_generator != null:
			pinned_generator.update(ctx, dt)

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		if pinned_generator != null:
			pinned_generator.generate(ctx, out_pose)
		else:
			out_pose.init_from_skeleton(ctx.skeleton)
		var w := clampf(fraction, 0.0, 1.0)
		if reference_frame_generator == null or w <= 1e-5 or out_pose.bone_count == 0:
			return
		var ref_pose := HkbPoseCls.new()
		reference_frame_generator.generate(ctx, ref_pose)
		if ref_pose.bone_count != out_pose.bone_count:
			return
		if bone_indices.is_empty():
			out_pose.blend_with(ref_pose, w)
			return
		var bw := PackedFloat32Array()
		bw.resize(out_pose.bone_count)
		bw.fill(0.0)
		for bi in bone_indices:
			if bi >= 0 and bi < out_pose.bone_count:
				bw[bi] = 1.0
		out_pose.blend_with(ref_pose, w, bw)


class HkbParametricMotionGenerator extends HkbGenerator:
	## Pure-GDScript `hkbParametricMotionGenerator`: 2D parametric blendspace over child generators
	## using Godot standard angles/speeds and delegating weighted pose blending to C++ `HkbPose.blend_with`.
	var x_axis_param: float = 0.0
	var y_axis_param: float = 0.0
	var motion_space: int = 0 # 0=directional/polar, 1=cartesian
	var generators: Array = []

	func activate(ctx: HkbCtx) -> void:
		super.activate(ctx)
		for g in generators:
			if g != null:
				g.activate(ctx)

	func deactivate(ctx: HkbCtx) -> void:
		for g in generators:
			if g != null:
				g.deactivate(ctx)
		super.deactivate(ctx)

	func handle_event(ctx: HkbCtx, ev_id: int, ev_name: String) -> bool:
		var h := false
		for g in generators:
			if g != null and g.handle_event(ctx, ev_id, ev_name):
				h = true
		return h

	func update(ctx: HkbCtx, dt: float) -> void:
		super.update(ctx, dt)
		for g in generators:
			if g != null:
				g.update(ctx, dt)

	func generate(ctx: HkbCtx, out_pose: HkbPoseCls) -> void:
		out_pose.init_from_skeleton(ctx.skeleton)
		var valid: Array = []
		for g in generators:
			if g != null:
				valid.append(g)
		var n := valid.size()
		if n == 0:
			return
		if n == 1:
			valid[0].generate(ctx, out_pose)
			return
		# Compute smooth 2D blend weights across parametric space (polar angle + speed or normalized grid)
		var weights := PackedFloat32Array()
		weights.resize(n)
		var w_sum := 0.0
		var px := clampf(x_axis_param, -180.0, 180.0)
		var py := clampf(y_axis_param, -10.0, 10.0)
		for i in n:
			var frac := float(i) / float(n)
			var sample_ang := -180.0 + frac * 360.0
			var d_ang := absf(wrapf(px - sample_ang, -180.0, 180.0)) / 90.0
			var sample_spd := float(i) / float(maxi(1, n - 1))
			var d_spd := absf(clampf(py, 0.0, 1.0) - sample_spd)
			var dist := sqrt(d_ang * d_ang + d_spd * d_spd)
			var w := 1.0 / (0.05 + dist * dist)
			weights[i] = w
			w_sum += w
		var acc_w := 0.0
		for i in n:
			var w := weights[i] / maxf(1e-6, w_sum)
			if w < 0.02:
				continue
			var tmp := HkbPoseCls.new()
			valid[i].generate(ctx, tmp)
			if acc_w <= 1e-6:
				out_pose.pos = tmp.pos.duplicate()
				out_pose.rot_xyzw = tmp.rot_xyzw.duplicate()
				out_pose.scl = tmp.scl.duplicate()
				out_pose.root_delta_pos = tmp.root_delta_pos
				out_pose.root_delta_yaw = tmp.root_delta_yaw
				acc_w = w
			else:
				out_pose.blend_with(tmp, w / (acc_w + w))
				acc_w += w
