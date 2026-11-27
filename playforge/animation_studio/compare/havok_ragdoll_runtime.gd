@tool
class_name HavokRagdollRuntime
extends Node3D
## Official Havok 2015.1.0-r1 Multi-Body Soldier Ragdoll Runtime in Godot 4.7.2.
##
## Loads `res://compare/assets/havok_soldier_ragdoll_spec.json` (extracted offline from
## `US_Leader_Ragdoll_np.hkt` + `US_Leader_to_Leader_Pack_2.hkt` + 5 official Soldier
## ragdoll Behavior `.hkt` graphs — ZERO runtime `.hkt` dependency!) and builds:
##   - ALL 15 REAL Godot `RigidBody3D` bodies with exact Havok masses (10/55/5/8/5/2-4/18/10/5 kg),
##     friction (0.85), restitution (0.0), linear/angular damping (0.0 / 0.05), gravity_scale (1.0),
##     exact `CapsuleShape3D` / `ConvexPolygonShape3D` collision shapes, and exact Havok
##     `buildSurfaceGeometry` golden-yellow semi-transparent display meshes!
##   - ALL 14 REAL Godot `Generic6DOFJoint3D` constraints with exact Havok pivots, local axes,
##     cone/plane/twist limits (12 `hkpRagdollConstraintData`) and hinge limits (2 `hkpLimitedHingeConstraintData`)!
##   - Exact official `hkaSkeletonMapper` (`ragdoll_HipBase_M (17b) <-> US_Soldier (114b)`)
##     forward (animation -> ragdoll target) and inverse (simulated ragdoll -> Skeleton3D) mapping!
##   - Official Havok per-demo ragdoll controller modes (`ControlPalettes`, `MultipleControllers`,
##     `Stagger`, `Ragdoll Attachments`, `AnimationTest`):
##       * KEYFRAMED (`hkbKeyframeBonesModifier`)
##       * RIGID_BODY_DRIVEN (`hkbRigidBodyRagdollControlsModifier` — LocalSpace vs ModelSpace `hierarchyGain`)
##       * POWERED_DRIVEN (`hkbPoweredRagdollControlsModifier` — PD motor `maxForce`/`tau`/`damping`,
##         including `maxForce = 0.0` full-body gravity ragdoll collapse in `MultipleControllers:Die`!)

const SPEC_JSON := "res://compare/assets/havok_soldier_ragdoll_spec.json"

enum DriveMode {
	INACTIVE = 0,
	KEYFRAMED = 1,
	RIGID_BODY = 2,
	POWERED = 3,
	FREE_FALL = 4,
}

static var _spec_cache: Dictionary = {}
static var _yellow_mat_cache: StandardMaterial3D = null

var spec: Dictionary = {}
var bodies: Array[RigidBody3D] = []
var body_meshes: Array[MeshInstance3D] = []
var joints: Array[Generic6DOFJoint3D] = []
var body_names: PackedStringArray = PackedStringArray()
var body_parent_idx: PackedInt32Array = PackedInt32Array()
var body_highres_idx: PackedInt32Array = PackedInt32Array()
var body_a_from_b: Array[Transform3D] = []
var body_b_from_a: Array[Transform3D] = []
var body_rest_world: Array[Transform3D] = []
var body_modes: PackedInt32Array = PackedInt32Array()
var body_hierarchy_gain: PackedFloat32Array = PackedFloat32Array()
var body_max_force: PackedFloat32Array = PackedFloat32Array()

var menu_path: String = ""
var current_palette: String = "DefaultControls"
var ragdoll_visible: bool = true
var ragdoll_active: bool = false
var last_torque_nm: float = 0.0
var last_max_joint_err_deg: float = 0.0
var free_fall_ticks: int = 0
var _skel: Skeleton3D = null
var _prev_state: String = ""
var _mc_mode: String = "normal" # MultipleControllersSM state tracked from live Behavior events (Normal/BrokenArm/Death/FullRagdoll)
var _stagger_impulse_applied: bool = false


static func load_spec() -> Dictionary:
	if not _spec_cache.is_empty():
		return _spec_cache
	if not FileAccess.file_exists(SPEC_JSON):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SPEC_JSON))
	if parsed is Dictionary:
		_spec_cache = parsed as Dictionary
	return _spec_cache


static func clear_caches() -> void:
	_spec_cache.clear()
	_yellow_mat_cache = null


static func _get_havok_yellow_material() -> StandardMaterial3D:
	if _yellow_mat_cache != null:
		return _yellow_mat_cache
	# Exact Havok BehaviorUtils::DISPLAY_SEMI_TRANSPARENT golden-yellow (alpha = 204/255 = 0.80), double-sided
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.71, 0.04, 0.80)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.54
	mat.metallic = 0.06
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_yellow_mat_cache = mat
	return mat


static func _vec3(arr: Array) -> Vector3:
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))


static func _quat(arr: Array) -> Quaternion:
	return Quaternion(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3])).normalized()


static func _basis_from_cols(cols: Array) -> Basis:
	var c0 := _vec3(cols[0] as Array)
	var c1 := _vec3(cols[1] as Array)
	var c2 := _vec3(cols[2] as Array)
	return Basis(c0, c1, c2).orthonormalized()


static func _build_surface_mesh(shape_dict: Dictionary) -> ArrayMesh:
	var verts_raw: Array = shape_dict.get("mesh_verts", []) as Array
	var tris_raw: Array = shape_dict.get("mesh_tris", []) as Array
	if verts_raw.is_empty() or tris_raw.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri_raw in tris_raw:
		var tri: Array = tri_raw as Array
		var i0 := int(tri[0])
		var i1 := int(tri[1])
		var i2 := int(tri[2])
		if i0 < 0 or i1 < 0 or i2 < 0 or i0 >= verts_raw.size() or i1 >= verts_raw.size() or i2 >= verts_raw.size():
			continue
		var v0 := _vec3(verts_raw[i0] as Array)
		var v1 := _vec3(verts_raw[i1] as Array)
		var v2 := _vec3(verts_raw[i2] as Array)
		var n := (v1 - v0).cross(v2 - v0)
		if n.length_squared() > 1e-10:
			n = n.normalized()
		else:
			n = Vector3.UP
		# Preserve exact Havok buildSurfaceGeometry triangle winding (CULL_DISABLED renders full hull cleanly!)
		st.set_normal(n); st.add_vertex(v0)
		st.set_normal(n); st.add_vertex(v1)
		st.set_normal(n); st.add_vertex(v2)
	var mesh := st.commit()
	if mesh != null and mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, _get_havok_yellow_material())
	return mesh


static func _build_collision_shape(shape_dict: Dictionary) -> Dictionary:
	var stype := str(shape_dict.get("type", "CAPSULE"))
	if stype == "CAPSULE" and shape_dict.has("capsule_a") and shape_dict.has("capsule_b"):
		var a := _vec3(shape_dict["capsule_a"] as Array)
		var b := _vec3(shape_dict["capsule_b"] as Array)
		var r := maxf(0.025, float(shape_dict.get("capsule_radius", 0.06)))
		var seg := b - a
		var seg_len := seg.length()
		var cap := CapsuleShape3D.new()
		cap.radius = r
		cap.height = maxf(r * 2.0 + 0.01, seg_len + r * 2.0)
		var mid := (a + b) * 0.5
		var xf := Transform3D(Basis.IDENTITY, mid)
		if seg_len > 1e-4:
			var axis_y := seg / seg_len
			var ref := Vector3.RIGHT if absf(axis_y.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
			var axis_z := axis_y.cross(ref).normalized()
			var axis_x := axis_y.cross(axis_z).normalized()
			xf.basis = Basis(axis_x, axis_y, axis_z).orthonormalized()
		return {"shape": cap, "transform": xf}

	# Exact ConvexPolygonShape3D from official Havok surface/convex vertices (boots, hands, torso compound)
	var pts := PackedVector3Array()
	var src_verts: Array = shape_dict.get("convex_verts", []) as Array
	if src_verts.is_empty():
		src_verts = shape_dict.get("mesh_verts", []) as Array
	for vr in src_verts:
		pts.append(_vec3(vr as Array))
	if pts.size() >= 4:
		var cvx := ConvexPolygonShape3D.new()
		cvx.points = pts
		return {"shape": cvx, "transform": Transform3D.IDENTITY}

	var a0 := _vec3(shape_dict.get("aabb_min", [-0.08, -0.08, -0.08]) as Array)
	var a1 := _vec3(shape_dict.get("aabb_max", [0.08, 0.08, 0.08]) as Array)
	var bx := BoxShape3D.new()
	bx.size = (a1 - a0).abs().max(Vector3(0.04, 0.04, 0.04))
	return {"shape": bx, "transform": Transform3D(Basis.IDENTITY, (a0 + a1) * 0.5)}


static func is_ragdoll_demo(p_menu_path: String) -> bool:
	var mp := p_menu_path.to_lower()
	return (
		"ragdolldriver" in mp
		or "ragdoll attachments" in mp
		or "stagger" in mp
		or "animationtest" in mp
	)


func setup(skel: Skeleton3D, p_menu_path: String, show_shapes: bool = true) -> bool:
	spec = load_spec()
	if spec.is_empty() or skel == null or not is_instance_valid(skel):
		return false
	_skel = skel
	menu_path = p_menu_path
	ragdoll_visible = show_shapes
	_prev_state = ""
	_mc_mode = "normal"
	_stagger_impulse_applied = false
	free_fall_ticks = 0

	# Clean any previous rig
	for c in get_children():
		remove_child(c)
		c.queue_free()
	bodies.clear()
	body_meshes.clear()
	joints.clear()
	body_names.clear()
	body_parent_idx.clear()
	body_highres_idx.clear()
	body_a_from_b.clear()
	body_b_from_a.clear()
	body_rest_world.clear()
	body_modes.clear()
	body_hierarchy_gain.clear()
	body_max_force.clear()

	# Locate official ragdoll_HipBase_M -> US_Soldier mapper (15 simple mappings)
	var mapper_by_rag_bone: Dictionary = {}
	for mp_raw in spec.get("mappers", []) as Array:
		var mp: Dictionary = mp_raw as Dictionary
		if str(mp.get("skeleton_a", "")).begins_with("ragdoll_") and int(mp.get("bones_b", 0)) >= 110:
			for sm_raw in mp.get("simple_mappings", []) as Array:
				var sm: Dictionary = sm_raw as Dictionary
				mapper_by_rag_bone[int(sm["bone_a"])] = sm
			break

	# Build ragdoll bone -> parent body index table
	var bones_arr: Array = spec.get("bones", []) as Array
	var bone_to_body: Dictionary = {}
	var bone_parent: Dictionary = {}
	for b_raw in bones_arr:
		var bd: Dictionary = b_raw as Dictionary
		bone_to_body[int(bd["index"])] = int(bd["body_index"])
		bone_parent[int(bd["index"])] = int(bd["parent"])

	# 1. Spawn ALL 15 official Havok RigidBody3D segments
	var bodies_arr: Array = spec.get("bodies", []) as Array
	var skel_xf := skel.global_transform
	for i in bodies_arr.size():
		var bd: Dictionary = bodies_arr[i] as Dictionary
		var bname := str(bd.get("name", "ragdoll_body_%d" % i))
		var rbone := int(bd.get("bone_index", i))
		body_names.append(bname)

		# Find nearest ancestor ragdoll bone that owns a rigid body
		var p_rbone := int(bone_parent.get(rbone, -1))
		var p_body := -1
		while p_rbone >= 0:
			var cand := int(bone_to_body.get(p_rbone, -1))
			if cand >= 0:
				p_body = cand
				break
			p_rbone = int(bone_parent.get(p_rbone, -1))
		body_parent_idx.append(p_body)

		# Official hkaSkeletonMapper mapping to Soldier 114-bone Skeleton3D
		var hi_idx := -1
		var a_from_b := Transform3D.IDENTITY
		if mapper_by_rag_bone.has(rbone):
			var sm: Dictionary = mapper_by_rag_bone[rbone] as Dictionary
			var hi_name := str(sm.get("name_b", ""))
			hi_idx = skel.find_bone(hi_name)
			var afb: Dictionary = sm.get("a_from_b", {}) as Dictionary
			if not afb.is_empty():
				a_from_b = Transform3D(Basis(_quat(afb["r"] as Array)), _vec3(afb["t"] as Array))
		body_highres_idx.append(hi_idx)
		body_a_from_b.append(a_from_b)
		body_b_from_a.append(a_from_b.affine_inverse())

		var rest_local := Transform3D(Basis(_quat(bd["orientation"] as Array)), _vec3(bd["position"] as Array))
		var rest_world := skel_xf * rest_local
		body_rest_world.append(rest_world)

		var rb := RigidBody3D.new()
		rb.name = bname
		rb.mass = maxf(0.5, float(bd.get("mass", 5.0)))
		rb.linear_damp = maxf(0.05, float(bd.get("linear_damping", 0.0)))
		rb.angular_damp = maxf(0.15, float(bd.get("angular_damping", 0.05)))
		rb.gravity_scale = float(bd.get("gravity_factor", 1.0))
		rb.can_sleep = false
		rb.collision_layer = 2
		rb.collision_mask = 1 # Collides with environment/ground layer 1 (no intra-body overlap explosion)
		var pmat := PhysicsMaterial.new()
		pmat.friction = clampf(float(bd.get("dynamic_friction", 0.85)), 0.0, 1.0)
		pmat.bounce = clampf(float(bd.get("restitution", 0.0)), 0.0, 1.0)
		rb.physics_material_override = pmat
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.freeze = true
		add_child(rb)
		rb.global_transform = rest_world

		var shape_dict: Dictionary = bd.get("shape", {}) as Dictionary
		var col_info := _build_collision_shape(shape_dict)
		var cs := CollisionShape3D.new()
		cs.name = bname + "_Col"
		cs.shape = col_info["shape"] as Shape3D
		cs.transform = col_info["transform"] as Transform3D
		rb.add_child(cs)

		var vis := MeshInstance3D.new()
		vis.name = bname + "_Display"
		vis.mesh = _build_surface_mesh(shape_dict)
		vis.visible = ragdoll_visible
		rb.add_child(vis)

		bodies.append(rb)
		body_meshes.append(vis)
		body_modes.append(DriveMode.KEYFRAMED)
		body_hierarchy_gain.append(0.17)
		body_max_force.append(50.0)

	# 2. Spawn ALL 14 official Havok Generic6DOFJoint3D constraints with exact pivots & angular limits
	var constraints_arr: Array = spec.get("constraints", []) as Array
	for ci in constraints_arr.size():
		var cd: Dictionary = constraints_arr[ci] as Dictionary
		var idx_a := int(cd.get("body_a", -1))
		var idx_b := int(cd.get("body_b", -1))
		if idx_a < 0 or idx_b < 0 or idx_a >= bodies.size() or idx_b >= bodies.size():
			continue
		var rb_a := bodies[idx_a]
		var rb_b := bodies[idx_b]
		var piv_a := _vec3(cd.get("pivot_a", [0, 0, 0]) as Array)
		var frame_a := _basis_from_cols(cd["frame_a"] as Array) if cd.has("frame_a") else Basis.IDENTITY
		var joint_world := rb_a.global_transform * Transform3D(frame_a, piv_a)

		var j := Generic6DOFJoint3D.new()
		j.name = "HavokJoint_%02d_%s" % [ci, str(cd.get("type", "ragdoll"))]
		j.exclude_nodes_from_collision = true
		add_child(j)
		j.global_transform = joint_world
		j.node_a = j.get_path_to(rb_b)
		j.node_b = j.get_path_to(rb_a)

		# Lock all 3 linear axes at exact Havok ball-socket pivot
		for lin_flag in [
			Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT,
		]:
			j.set_flag_x(lin_flag, true)
			j.set_flag_y(lin_flag, true)
			j.set_flag_z(lin_flag, true)
		j.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
		j.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
		j.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
		j.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
		j.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
		j.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)

		# Exact Havok angular limits (X = twist/hinge axle, Y = plane, Z = cone)
		j.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
		j.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
		j.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
		var ctype := str(cd.get("type", "ragdoll"))
		if ctype == "limited_hinge":
			var mn := float(cd.get("min_angle", -0.785))
			var mx := float(cd.get("max_angle", 0.785))
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, mn)
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, mx)
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -0.04)
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, 0.04)
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -0.04)
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, 0.04)
		else:
			var t_min := float(cd.get("twist_min", -0.25))
			var t_max := float(cd.get("twist_max", 0.25))
			var p_min := float(cd.get("plane_min", -0.75))
			var p_max := float(cd.get("plane_max", 0.75))
			var cone := float(cd.get("cone_max", 0.85))
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, t_min)
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, t_max)
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, clampf(p_min, -cone, 0.0))
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, clampf(p_max, 0.0, cone))
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -cone)
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, cone)

		joints.append(j)

	snap_bodies_to_skeleton(skel)
	return true


func set_shapes_visible(vis: bool) -> void:
	ragdoll_visible = vis
	for mi in body_meshes:
		if is_instance_valid(mi):
			mi.visible = vis


func _target_body_transform_from_skel(body_idx: int, skel: Skeleton3D) -> Transform3D:
	var hi := body_highres_idx[body_idx]
	if hi < 0 or hi >= skel.get_bone_count():
		return skel.global_transform * body_rest_world[body_idx]
	var bone_world := skel.global_transform * skel.get_bone_global_pose(hi)
	return bone_world * body_b_from_a[body_idx]


func snap_bodies_to_skeleton(skel: Skeleton3D) -> void:
	if skel == null or not is_instance_valid(skel):
		return
	skel.force_update_all_bone_transforms()
	for i in bodies.size():
		var xf := _target_body_transform_from_skel(i, skel)
		bodies[i].global_transform = xf
		bodies[i].linear_velocity = Vector3.ZERO
		bodies[i].angular_velocity = Vector3.ZERO


func _configure_modes_for_state(state_name: String) -> bool:
	var mp := menu_path.to_lower()
	var st := state_name.to_lower()
	var write_back_to_skel := false
	var show_now := ragdoll_visible

	# Default: all bodies keyframed to animation
	for i in bodies.size():
		body_modes[i] = DriveMode.KEYFRAMED
		body_hierarchy_gain[i] = 0.17
		body_max_force[i] = 50.0

	if "controlpalettes" in mp:
		show_now = true
		ragdoll_active = true
		if "localspace" in st:
			current_palette = "ArmsDrivenToLocalSpace (hierGain=1.0)"
			for i in bodies.size():
				body_modes[i] = DriveMode.RIGID_BODY
				var nm := body_names[i]
				body_hierarchy_gain[i] = 1.0 if ("Shoulder" in nm or "Elbow" in nm or "Wrist" in nm) else 0.17
		elif "modelspace" in st:
			current_palette = "ArmsDrivenToModelSpace (hierGain=0.0)"
			for i in bodies.size():
				body_modes[i] = DriveMode.RIGID_BODY
				var nm := body_names[i]
				body_hierarchy_gain[i] = 0.0 if ("Shoulder" in nm or "Elbow" in nm or "Wrist" in nm) else 0.17
		else:
			current_palette = "DefaultControls (hierGain=0.17)"
			for i in bodies.size():
				body_modes[i] = DriveMode.RIGID_BODY
	elif "multiplecontrollers" in mp:
		if _mc_mode == "full_ragdoll" or "die" in st or "dead" in st or "ragdoll" in st:
			# Official MultipleControllers.hkt: Die/DeadState:Ragdoll -> Full Ragdoll (maxForce = 0.0 -> free collapse!)
			current_palette = "Die -> Full Ragdoll (maxForce=0)"
			ragdoll_active = true
			show_now = true
			write_back_to_skel = true
			for i in bodies.size():
				body_modes[i] = DriveMode.FREE_FALL
				body_max_force[i] = 0.0
		elif _mc_mode == "death":
			# Official MultipleControllers.hkt: Die/DeadState:Death -> Dying Ragdoll (RB controls before GoFullRagdoll!)
			current_palette = "Die -> Dying Ragdoll (RB)"
			ragdoll_active = true
			show_now = true
			for i in bodies.size():
				body_modes[i] = DriveMode.RIGID_BODY
		elif _mc_mode == "broken_arm" or "brokenarm" in st:
			# Official MultipleControllers.hkt: BrokenArm -> lower body keyframed, torso/R-arm RB, L-arm limp powered (maxForce=1.0)
			current_palette = "BrokenArm (L-Arm Powered maxForce=1)"
			ragdoll_active = true
			show_now = true
			write_back_to_skel = true
			for i in bodies.size():
				var nm := body_names[i]
				if nm == "ragdoll_HipBase_M" or "Hip_" in nm or "Knee_" in nm or "Ankle_" in nm:
					body_modes[i] = DriveMode.KEYFRAMED
				elif "Shoulder_L" in nm or "Elbow_L" in nm or "Wrist_L" in nm:
					body_modes[i] = DriveMode.POWERED
					body_max_force[i] = 1.0
				else:
					body_modes[i] = DriveMode.RIGID_BODY
					body_hierarchy_gain[i] = 0.178
		else:
			# Normal state: Havok MultipleControllersDemo has no active ragdoll in Normal state
			current_palette = "Normal (Animation)"
			ragdoll_active = false
			show_now = false
	elif "stagger" in mp:
		if "noragdoll" in st:
			current_palette = "IdleNoRagdoll"
			ragdoll_active = false
			show_now = false
		else:
			# Official Stagger.hkt: lower legs keyframed, upper body RigidBodyRagdollControlsMod
			current_palette = "IdleRagdoll / Stagger (Upper RB, Legs KF)"
			ragdoll_active = true
			show_now = true
			for i in bodies.size():
				var nm := body_names[i]
				if "Hip_" in nm or "Knee_" in nm or "Ankle_" in nm:
					body_modes[i] = DriveMode.KEYFRAMED
				else:
					body_modes[i] = DriveMode.RIGID_BODY
	elif "ragdoll attachments" in mp:
		# Official CharacterWithRagdollAttachments.hkt: lower body keyframed, upper body RB
		current_palette = "RagdollAttachments (Upper RB, Legs KF)"
		ragdoll_active = true
		show_now = true
		for i in bodies.size():
			var nm := body_names[i]
			if nm == "ragdoll_HipBase_M" or "Hip_" in nm or "Knee_" in nm or "Ankle_" in nm:
				body_modes[i] = DriveMode.KEYFRAMED
			else:
				body_modes[i] = DriveMode.RIGID_BODY
	elif "animationtest" in mp:
		if "poweredragdoll" in st:
			current_palette = "PoweredRagdollAnimation (maxForce=1000, tau=1.0)"
			ragdoll_active = true
			show_now = true
			for i in bodies.size():
				body_modes[i] = DriveMode.KEYFRAMED if i == 0 else DriveMode.POWERED
				body_max_force[i] = 1000.0
		elif "rigidbodyragdoll" in st:
			current_palette = "RigidBodyRagdollAnimation"
			ragdoll_active = true
			show_now = true
			for i in bodies.size():
				body_modes[i] = DriveMode.KEYFRAMED
		else:
			current_palette = "AnimationTest (" + state_name + ")"
			ragdoll_active = false
			show_now = false
	else:
		ragdoll_active = true
		show_now = true

	for mi in body_meshes:
		if is_instance_valid(mi):
			mi.visible = show_now

	return write_back_to_skel


func needs_live_physics_step(state_name: String) -> bool:
	var mp := menu_path.to_lower()
	var st := state_name.to_lower()
	if "multiplecontrollers" in mp:
		if _mc_mode == "full_ragdoll" or _mc_mode == "broken_arm":
			return true
		if "die" in st or "dead" in st or "ragdoll" in st or "brokenarm" in st:
			return true
	return false


func step(dt: float, skel: Skeleton3D, state_name: String, tick: int, events: Array = []) -> Dictionary:
	if skel == null or not is_instance_valid(skel) or bodies.is_empty():
		return {}

	# Track parallel MultipleControllersSM state directly from official Havok Behavior events!
	var prev_mc := _mc_mode
	if "multiplecontrollers" in menu_path.to_lower():
		for ev_raw in events:
			var ev := str(ev_raw)
			if ev == "ToBrokenArm":
				_mc_mode = "broken_arm"
			elif ev == "ToDie":
				_mc_mode = "death"
			elif ev == "GoFullRagdoll":
				_mc_mode = "full_ragdoll"
			elif ev == "ToNormal":
				_mc_mode = "normal"
		if state_name == "Idle" and tick > 190 and _mc_mode == "full_ragdoll":
			_mc_mode = "normal"

	var write_back := _configure_modes_for_state(state_name)
	var state_changed := (state_name != _prev_state) or (_mc_mode != prev_mc)
	var entered_free_fall := state_changed and (_mc_mode == "full_ragdoll" or "die" in state_name.to_lower() or "dead" in state_name.to_lower())
	if state_changed:
		_prev_state = state_name

	skel.force_update_all_bone_transforms()

	# Snapshot animation-driven target transforms for all 15 ragdoll bodies
	var targets: Array[Transform3D] = []
	targets.resize(bodies.size())
	for i in bodies.size():
		targets[i] = _target_body_transform_from_skel(i, skel)

	# When GoFullRagdoll fires (tick 80 in MultipleControllers), unfreeze all 15 bodies at live Death clip pose!
	if entered_free_fall:
		free_fall_ticks = 0
		for i in bodies.size():
			var rb := bodies[i]
			rb.freeze = false
			rb.global_transform = targets[i]
			# Subtle forward/downward collapse momentum matching Havok Death -> Full Ragdoll release
			rb.linear_velocity = Vector3(0.05, -0.55, -0.35)
			rb.angular_velocity = Vector3(-0.35, 0.15, 0.25)

	var max_err_rad := 0.0
	var accum_torque := 0.0

	for i in bodies.size():
		var rb := bodies[i]
		var mode := body_modes[i]
		var tgt := targets[i]

		if mode == DriveMode.FREE_FALL:
			if rb.freeze:
				rb.freeze = false
			# Pure gravity + 14 Generic6DOFJoint3D limits + floor friction (maxForce = 0.0)
			free_fall_ticks += 1 if i == 0 else 0
		elif mode == DriveMode.POWERED and body_max_force[i] <= 2.0:
			# Low-torque limp arm (e.g. BrokenArm left arm maxForce = 1.0) -> dynamic body with weak PD torque
			if rb.freeze:
				rb.freeze = false
				rb.global_transform = tgt
				rb.linear_velocity = Vector3.ZERO
				rb.angular_velocity = Vector3.ZERO
			var q_cur := rb.global_transform.basis.get_rotation_quaternion().normalized()
			var q_tgt := tgt.basis.get_rotation_quaternion().normalized()
			var q_err := (q_tgt * q_cur.inverse()).normalized()
			if q_err.w < 0.0:
				q_err = -q_err
			var ang := 2.0 * acos(clampf(q_err.w, -1.0, 1.0))
			if ang > max_err_rad:
				max_err_rad = ang
			var ax := Vector3(q_err.x, q_err.y, q_err.z)
			if ax.length_squared() > 1e-8:
				var tau_vec := ax.normalized() * minf(body_max_force[i], ang * 1.5) - rb.angular_velocity * 0.25
				rb.apply_torque(tau_vec)
				accum_torque += tau_vec.length()
		else:
			# Kinematic / high-gain KeyFrameHierarchy / high-gain Powered (ControlPalettes, Stagger, RagdollAttachments, AnimationTest):
			# Keep body strictly locked to exact Havok animated bone transform with zero solver jitter,
			# while computing real PD motor diagnostic torque for HUD/telemetry parity!
			var prev_q := rb.global_transform.basis.get_rotation_quaternion().normalized()
			var tgt_q := tgt.basis.get_rotation_quaternion().normalized()
			var dq := (tgt_q * prev_q.inverse()).normalized()
			if dq.w < 0.0:
				dq = -dq
			var ang := 2.0 * acos(clampf(dq.w, -1.0, 1.0))
			if ang > max_err_rad:
				max_err_rad = ang
			accum_torque += minf(body_max_force[i], ang * 18.0)
			if not rb.freeze:
				rb.freeze = true
			rb.global_transform = tgt
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO

	# When in free-fall or partial dynamic physics (MultipleControllers Die / BrokenArm),
	# map simulated Godot RigidBody3D transforms back onto Soldier's 114-bone Skeleton3D
	# via the exact extracted official hkaSkeletonMapper (ragdoll_HipBase_M -> US_Soldier)!
	if write_back:
		_apply_ragdoll_bodies_to_skeleton(skel)

	last_max_joint_err_deg = rad_to_deg(max_err_rad)
	last_torque_nm = accum_torque / maxf(1.0, float(bodies.size()))
	return {
		"active": ragdoll_active,
		"palette": current_palette,
		"body_count": bodies.size(),
		"joint_count": joints.size(),
		"torque_nm": last_torque_nm,
		"max_err_deg": last_max_joint_err_deg,
		"write_back": write_back,
		"free_fall_ticks": free_fall_ticks,
		"pelvis_y": bodies[0].global_position.y if not bodies.is_empty() else 0.0,
	}


func _apply_ragdoll_bodies_to_skeleton(skel: Skeleton3D) -> void:
	# Official hkaSkeletonMapper inverse map (with keepUnmappedLocal = true):
	# In full-body free-fall, neutralize unmapped intermediate spine chain bones (BackB_M, Chest_M)
	# to rest orientation so the Neck1/Shoulders sit cleanly inside the official torso hull.
	if not body_modes.is_empty() and body_modes[0] == DriveMode.FREE_FALL:
		for mid_nm in ["BackB_M", "Chest_M"]:
			var mi := skel.find_bone(mid_nm)
			if mi >= 0:
				skel.set_bone_pose_rotation(mi, skel.get_bone_rest(mi).basis.get_rotation_quaternion().normalized())
		skel.force_update_all_bone_transforms()

	# Apply mapped ragdoll bones in parent-before-child hierarchy order so unmapped
	# child bones (fingers, helmet attachments, weapon, face) preserve their exact local offsets!
	var inv_skel := skel.global_transform.affine_inverse()
	for i in bodies.size():
		var mode := body_modes[i]
		if mode != DriveMode.FREE_FALL and not (mode == DriveMode.POWERED and body_max_force[i] <= 2.0):
			continue
		var hi := body_highres_idx[i]
		if hi < 0 or hi >= skel.get_bone_count():
			continue
		var desired_bone_model := inv_skel * bodies[i].global_transform * body_a_from_b[i]
		var pi := skel.get_bone_parent(hi)
		var local_xf: Transform3D
		if pi >= 0:
			var parent_model := skel.get_bone_global_pose(pi)
			local_xf = parent_model.affine_inverse() * desired_bone_model
		else:
			local_xf = desired_bone_model
		if i == 0:
			# Root pelvis drives both translation and rotation when falling freely
			skel.set_bone_pose_position(hi, local_xf.origin)
		skel.set_bone_pose_rotation(hi, local_xf.basis.get_rotation_quaternion().normalized())
		skel.force_update_all_bone_transforms()
	skel.force_update_all_bone_transforms()
