@tool
class_name HkbBehaviorGraph
extends RefCounted
## Unified Pure-GDScript Havok `hkbBehaviorGraph` + `hkbCharacter` + `hkbWorld` VM.
##
## Loads ANY real extracted official `.hkt` Behavior Graph topology from
## `res://compare/assets/havok_hkb_graphs.json` (88 official SDK graphs, ZERO runtime `.hkt`
## dependency, ZERO baked poses, ZERO hardcoded tick schedules!) and evaluates it LIVE:
##   1. Real `hkbVariableValueSet` + `hkbVariableBindingSet` bidirectional variable bindings
##   2. Real `hkbCompiledExpressionSet` / `hkbCondition` dynamic transitions
##   3. Real `hkbStateMachine`, `hkbBlenderGenerator`, `hkbLayerGenerator`, `hkbClipGenerator`,
##      `hkbManualSelectorGenerator`, `hkbModifierGenerator`, `hkbBehaviorReferenceGenerator`
##   4. Real `hkbModifier` chains (`EvaluateExpression`, `EventsFromRange`, `EventDriven`,
##      `Timer`, `Delayed`, `Damping`, `Mirror`, `LookAt`, `Twist`, `FootIk`, `HandIk`,
##      `Attachment`, `Powered/RigidBodyRagdollControls`, `KeyframeBones`, `GetUp`, `Jiggler`)

const HkbCtx := preload("res://addons/animation_studio/hkb/hkb_context.gd")
const HkbPoseCls := preload("res://addons/animation_studio/hkb/hkb_pose.gd")
const HkbNodeCls := preload("res://addons/animation_studio/hkb/hkb_node.gd")
const HkbMods := preload("res://addons/animation_studio/hkb/hkb_modifiers.gd")
const HkbGens := preload("res://addons/animation_studio/hkb/hkb_generators.gd")
const HkbScriptGen := preload("res://addons/animation_studio/hkb/hkb_script_generator.gd")
const HavokGraphRt := preload("res://compare/havok_behavior_graph_runtime.gd")

const TOPOLOGY_JSON := "res://compare/assets/havok_hkb_graphs.json"
const FULL_CLIP_PACKS := {
	"hero": "res://compare/assets/clips/hero_full_clips.res",
	"soldier": "res://compare/assets/clips/soldier_full_clips.res",
	"firefighter": "res://compare/assets/clips/firefighter_full_clips.res",
	"ninja": "res://compare/assets/clips/ninja_full_clips.res",
	"misc": "res://compare/assets/clips/misc_behavior_clips.res",
}

static var _library_cache: Dictionary = {}
static var _full_clip_cache: Dictionary = {}

var graph_key: String = ""
var graph_name: String = ""
var ctx: HkbCtx = null
var root_generator: HkbGens.HkbGenerator = null
var nodes_by_id: Dictionary = {} # int -> HkbNode
var _activated: bool = false
var last_pose: HkbPoseCls = null


static func load_library() -> Dictionary:
	if not _library_cache.is_empty():
		return _library_cache
	if not FileAccess.file_exists(TOPOLOGY_JSON):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TOPOLOGY_JSON))
	if parsed is Dictionary:
		_library_cache = (parsed as Dictionary).get("graphs", {}) as Dictionary
	return _library_cache


static func list_graph_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for k in load_library().keys():
		out.append(str(k))
	out.sort()
	return out


static func clear_caches() -> void:
	_library_cache.clear()
	_full_clip_cache.clear()


static func load_full_clip_pack(family: String) -> Dictionary:
	var key := family.to_lower()
	if not FULL_CLIP_PACKS.has(key):
		key = "misc"
	if _full_clip_cache.has(key):
		return _full_clip_cache[key] as Dictionary
	var res_path := str(FULL_CLIP_PACKS[key])
	var out: Dictionary = {}
	if FileAccess.file_exists(res_path):
		var res = ResourceLoader.load(res_path)
		if res != null and res.has_method("to_motion_dict"):
			var md: Dictionary = res.call("to_motion_dict") as Dictionary
			var raw_clips: Dictionary = md.get("clips", {}) as Dictionary
			for ck in raw_clips.keys():
				out[str(ck).to_lower()] = raw_clips[ck]
	_full_clip_cache[key] = out
	return out


func load_from_library(key: String, rig_id: String = "") -> bool:
	var lib := load_library()
	if not lib.has(key):
		return false
	var eff_rig := rig_id
	if eff_rig.is_empty():
		var fam := key.split("/")[0].to_lower() if "/" in key else "hero"
		if fam == "soldier":
			eff_rig = "soldier"
		elif fam == "firefighter":
			eff_rig = "firefighter"
		elif fam == "ninja":
			eff_rig = "ninja"
		elif fam in ["hero", "herobodyik", "animationbundles"]:
			eff_rig = "hero"
		else:
			eff_rig = fam
	graph_key = key
	return load_from_dict(lib[key] as Dictionary, eff_rig)


func load_from_dict(graph_def: Dictionary, rig_id: String = "hero") -> bool:
	if graph_def.is_empty():
		return false
	graph_name = str(graph_def.get("graph_name", graph_key))
	ctx = HkbCtx.new()
	ctx.rig_id = rig_id
	ctx.configure_from_graph_def(graph_def)
	# Merge base 47-demo clip pack + supplemental full-library pack (zero SDK runtime dep)
	var merged: Dictionary = {}
	if rig_id == "hero" or rig_id == "soldier":
		merged.merge(load_full_clip_pack(rig_id), true)
		merged.merge(HavokGraphRt.load_clip_pack(rig_id), true)
	elif FULL_CLIP_PACKS.has(rig_id):
		merged.merge(load_full_clip_pack(rig_id), true)
	else:
		merged.merge(load_full_clip_pack("misc"), true)
	ctx.clip_pack = merged
	nodes_by_id.clear()
	root_generator = _instantiate_graph_nodes(graph_def, {}, 0)
	_activated = false
	return root_generator != null


func _instantiate_graph_nodes(graph_def: Dictionary, link: Dictionary, depth: int) -> HkbGens.HkbGenerator:
	var raw_nodes: Array = graph_def.get("nodes", []) as Array
	var local_map: Dictionary = {} # local_id -> HkbNode

	# Pass 1: instantiate every node with its own Havok type & variable bindings
	for nd_raw in raw_nodes:
		var nd: Dictionary = nd_raw as Dictionary
		var nid := int(nd.get("id", -1))
		var tp := str(nd.get("type", ""))
		var inst: HkbNodeCls = _create_node_instance(tp, nd, link)
		local_map[nid] = inst
		if depth == 0:
			nodes_by_id[nid] = inst

	# Pass 2: wire child references cleanly (preserving DAG sharing!)
	for nd_raw in raw_nodes:
		var nd: Dictionary = nd_raw as Dictionary
		var nid := int(nd.get("id", -1))
		var inst = local_map.get(nid)
		if inst == null:
			continue
		var tp := str(nd.get("type", ""))
		match tp:
			"hkbStateMachine":
				var sm: HkbGens.HkbStateMachine = inst as HkbGens.HkbStateMachine
				for st_raw in nd.get("states", []) as Array:
					var st: Dictionary = (st_raw as Dictionary).duplicate(true)
					st["gen"] = local_map.get(int(st.get("gen", -1)))
					for tr_raw in st.get("transitions", []) as Array:
						var tr: Dictionary = tr_raw as Dictionary
						if tr.get("effect") is Dictionary:
							var eff: Dictionary = tr["effect"] as Dictionary
							if eff.has("transition_gen"):
								eff["trans_gen_obj"] = local_map.get(int(eff["transition_gen"]))
					sm.add_state_dict(st)
				for wc in sm.wildcards:
					if wc.get("effect") is Dictionary:
						var eff: Dictionary = wc["effect"] as Dictionary
						if eff.has("transition_gen"):
							eff["trans_gen_obj"] = local_map.get(int(eff["transition_gen"]))
			"hkbBlenderGenerator":
				var bg: HkbGens.HkbBlenderGenerator = inst as HkbGens.HkbBlenderGenerator
				for ch_raw in nd.get("children", []) as Array:
					var ch: Dictionary = (ch_raw as Dictionary).duplicate(true)
					ch["gen"] = local_map.get(int(ch.get("gen", -1)))
					ch["bone_weights"] = _to_pfa(ch.get("bone_weights"))
					bg.children.append(ch)
			"hkbLayerGenerator":
				var lg: HkbGens.HkbLayerGenerator = inst as HkbGens.HkbLayerGenerator
				for ly_raw in nd.get("layers", []) as Array:
					var ly: Dictionary = (ly_raw as Dictionary).duplicate(true)
					ly["gen"] = local_map.get(int(ly.get("gen", -1)))
					ly["bone_weights"] = _to_pfa(ly.get("bone_weights"))
					lg.layers.append(ly)
			"hkbManualSelectorGenerator":
				var msg: HkbGens.HkbManualSelectorGenerator = inst as HkbGens.HkbManualSelectorGenerator
				for gid in nd.get("generators", []) as Array:
					msg.generators.append(local_map.get(int(gid)))
			"hkbModifierGenerator":
				var mg: HkbGens.HkbModifierGenerator = inst as HkbGens.HkbModifierGenerator
				mg.modifier = local_map.get(int(nd.get("modifier", -1))) as HkbMods.HkbModifier
				mg.generator = local_map.get(int(nd.get("generator", -1))) as HkbGens.HkbGenerator
			"hkbModifierList":
				var ml: HkbMods.HkbModifierList = inst as HkbMods.HkbModifierList
				for mid in nd.get("modifiers", []) as Array:
					ml.modifiers.append(local_map.get(int(mid)))
			"hkbEventDrivenModifier":
				var edm: HkbMods.HkbEventDrivenModifier = inst as HkbMods.HkbEventDrivenModifier
				edm.child_modifier = local_map.get(int(nd.get("modifier", -1))) as HkbMods.HkbModifier
			"hkbDelayedModifier":
				var dm: HkbMods.HkbDelayedModifier = inst as HkbMods.HkbDelayedModifier
				dm.child_modifier = local_map.get(int(nd.get("modifier", -1))) as HkbMods.HkbModifier
			"hkbBehaviorReferenceGenerator":
				var brg: HkbGens.HkbBehaviorReferenceGenerator = inst as HkbGens.HkbBehaviorReferenceGenerator
				if depth < 4 and not brg.behavior_name.is_empty():
					var sub_key := _resolve_sub_behavior_key(brg.behavior_name)
					var lib := load_library()
					if not sub_key.is_empty() and lib.has(sub_key):
						var sub_def: Dictionary = lib[sub_key] as Dictionary
						var sub_link := ctx.link_subgraph_symbols(sub_key, sub_def)
						brg.sub_root = _instantiate_graph_nodes(sub_def, sub_link, depth + 1)
			"hkbDockingGenerator":
				var dg: HkbGens.HkbDockingGenerator = inst as HkbGens.HkbDockingGenerator
				var cids: Array = nd.get("children_ids", []) as Array
				if not cids.is_empty():
					dg.child = local_map.get(int(cids[0])) as HkbGens.HkbGenerator
			"hkbScriptGenerator":
				var sg: HkbScriptGen = inst as HkbScriptGen
				var cid := int(nd.get("child", -1))
				if cid < 0:
					var scids: Array = nd.get("children_ids", []) as Array
					if not scids.is_empty():
						cid = int(scids[0])
				sg.child = local_map.get(cid)
			"hkbPinBonesGenerator":
				var pbg: HkbGens.HkbPinBonesGenerator = inst as HkbGens.HkbPinBonesGenerator
				var ref_id := int(nd.get("ref_gen", -1))
				var pin_id := int(nd.get("pinned_gen", -1))
				if ref_id < 0 or pin_id < 0:
					var pcids: Array = nd.get("children_ids", []) as Array
					if pcids.size() >= 2:
						ref_id = int(pcids[0])
						pin_id = int(pcids[1])
				pbg.reference_frame_generator = local_map.get(ref_id) as HkbGens.HkbGenerator
				pbg.pinned_generator = local_map.get(pin_id) as HkbGens.HkbGenerator
			"hkbParametricMotionGenerator":
				var pmg: HkbGens.HkbParametricMotionGenerator = inst as HkbGens.HkbParametricMotionGenerator
				var gids: Array = nd.get("generators", nd.get("children_ids", [])) as Array
				for gid in gids:
					pmg.generators.append(local_map.get(int(gid)))

	var root_id := int(graph_def.get("root_node", 0))
	return local_map.get(root_id) as HkbGens.HkbGenerator


func _resolve_sub_behavior_key(raw_name: String) -> String:
	var stem := raw_name.replace("\\", "/").get_file()
	if stem.to_lower().ends_with(".hkt"):
		stem = stem.substr(0, stem.length() - 4)
	var lib := load_library()
	var prefix := graph_key.split("/")[0] + "/" if "/" in graph_key else ""
	if not prefix.is_empty() and lib.has(prefix + stem):
		return prefix + stem
	for k in lib.keys():
		if str(k).to_lower().ends_with("/" + stem.to_lower()):
			return str(k)
	return ""


func _create_node_instance(tp: String, nd: Dictionary, link: Dictionary) -> HkbNodeCls:
	match tp:
		"hkbStateMachine":
			var sm := HkbGens.HkbStateMachine.new()
			sm.init_common(nd, link)
			sm.configure(nd)
			return sm
		"hkbClipGenerator":
			var cg := HkbGens.HkbClipGenerator.new()
			cg.init_common(nd, link)
			cg.configure(nd)
			return cg
		"hkbBlenderGenerator":
			var bg := HkbGens.HkbBlenderGenerator.new()
			bg.init_common(nd, link)
			bg.flags = int(nd.get("flags", 0))
			bg.ref_threshold = float(nd.get("ref_threshold", 0.0))
			bg.blend_parameter = float(nd.get("blend_param", 0.0))
			bg.subtract_last_child = bool(nd.get("subtract_last", false))
			return bg
		"hkbLayerGenerator":
			var lg := HkbGens.HkbLayerGenerator.new()
			lg.init_common(nd, link)
			lg.flags = int(nd.get("flags", 0))
			return lg
		"hkbManualSelectorGenerator":
			var msg := HkbGens.HkbManualSelectorGenerator.new()
			msg.init_common(nd, link)
			msg.selected_index = int(nd.get("selected_idx", 0))
			return msg
		"hkbReferencePoseGenerator":
			var rpg := HkbGens.HkbReferencePoseGenerator.new()
			rpg.init_common(nd, link)
			return rpg
		"hkbModifierGenerator":
			var mg := HkbGens.HkbModifierGenerator.new()
			mg.init_common(nd, link)
			return mg
		"hkbBehaviorReferenceGenerator":
			var brg := HkbGens.HkbBehaviorReferenceGenerator.new()
			brg.init_common(nd, link)
			brg.behavior_name = str(nd.get("behavior_name", ""))
			return brg
		"hkbDockingGenerator":
			var dg := HkbGens.HkbDockingGenerator.new()
			dg.init_common(nd, link)
			return dg
		"hkbScriptGenerator":
			var sg := HkbScriptGen.new()
			sg.init_common(nd, link)
			sg.configure(nd)
			return sg
		"hkbPinBonesGenerator":
			var pbg := HkbGens.HkbPinBonesGenerator.new()
			pbg.init_common(nd, link)
			pbg.fraction = float(nd.get("fraction", 1.0))
			var b_raw: Array = nd.get("bones", []) as Array if nd.get("bones") is Array else []
			var bia := PackedInt32Array()
			for bi in b_raw:
				bia.append(int(bi))
			pbg.bone_indices = bia
			return pbg
		"hkbParametricMotionGenerator":
			var pmg := HkbGens.HkbParametricMotionGenerator.new()
			pmg.init_common(nd, link)
			pmg.x_axis_param = float(nd.get("x_param", 0.0))
			pmg.y_axis_param = float(nd.get("y_param", 0.0))
			pmg.motion_space = int(nd.get("motion_space", 0))
			return pmg
		_:
			if tp.ends_with("Modifier") or tp == "hkbModifierList" or tp == "hkbSequence":
				return HkbMods.build_modifier(nd, link)
			var gen := HkbGens.HkbGenerator.new()
			gen.init_common(nd, link)
			return gen


static func _to_pfa(raw: Variant) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if raw is Array:
		out.resize((raw as Array).size())
		for i in (raw as Array).size():
			out[i] = float(raw[i])
	return out


func set_variable(name_or_idx: Variant, value: Variant) -> bool:
	return ctx.set_var(name_or_idx, value) if ctx != null else false


func get_variable(name_or_idx: Variant, fallback: Variant = 0.0) -> Variant:
	return ctx.get_var(name_or_idx, fallback) if ctx != null else fallback


func raise_event(name_or_id: Variant, payload: Dictionary = {}) -> int:
	return ctx.enqueue_event(name_or_id, payload) if ctx != null else -1


func find_first_state_machine() -> HkbGens.HkbStateMachine:
	if root_generator is HkbGens.HkbStateMachine:
		return root_generator as HkbGens.HkbStateMachine
	for n in nodes_by_id.values():
		if n is HkbGens.HkbStateMachine:
			return n as HkbGens.HkbStateMachine
	return null


func step(dt: float, skel: Skeleton3D, actor_node: Node3D = null) -> Dictionary:
	if ctx == null or root_generator == null:
		return {}
	ctx.skeleton = skel
	ctx.actor = actor_node
	ctx.world_3d = actor_node.get_world_3d() if (actor_node != null and is_instance_valid(actor_node)) else (skel.get_world_3d() if (skel != null and is_instance_valid(skel)) else null)
	ctx.dt = dt
	ctx.active_state_paths.clear()
	ctx.active_modifier_names.clear()
	ctx.ragdoll_control_commands.clear()
	ctx.foot_ik_control_command.clear()
	ctx.attachment_commands.clear()

	if not _activated:
		root_generator.activate(ctx)
		_activated = true

	# 1. Dispatch queued events (Havok hkbBehaviorGraph::handleEvent)
	var frame_evs := ctx.begin_frame_events()
	for ev in frame_evs:
		root_generator.handle_event(ctx, int(ev["id"]), str(ev["name"]))

	# 2. Update graph & pre_modify (bindings + expressions + timers + damping + state transitions)
	root_generator.update(ctx, dt)

	# 3. Generate pose & run pose modifiers (LookAt, Mirror, Twist, FootIK, HandIK, Jiggler)
	var pose := HkbPoseCls.new()
	root_generator.generate(ctx, pose)
	last_pose = pose
	ctx.root_motion_delta_pos = pose.root_delta_pos
	ctx.root_motion_delta_yaw = pose.root_delta_yaw

	if skel != null and is_instance_valid(skel):
		pose.apply_to_skeleton(skel)

	if ctx.attachment_manager != null and ctx.attachment_manager.has_method("step"):
		ctx.attachment_manager.call("step", dt)

	ctx.tick += 1
	ctx.elapsed += dt
	return get_telemetry()


func get_telemetry() -> Dictionary:
	if ctx == null:
		return {}
	var ev_names := PackedStringArray()
	for ev in ctx.get_frame_events():
		ev_names.append(str(ev["name"]))
	return {
		"graph_key": graph_key,
		"graph_name": graph_name,
		"tick": ctx.tick,
		"node_count": nodes_by_id.size(),
		"variable_count": ctx.var_names.size(),
		"event_count": ctx.event_names.size(),
		"active_states": ctx.active_state_paths,
		"active_modifiers": ctx.active_modifier_names,
		"frame_events": ev_names,
		"ragdoll_commands": ctx.ragdoll_control_commands,
		"foot_ik": ctx.foot_ik_control_command,
		"variables": ctx.dump_variables(),
	}
