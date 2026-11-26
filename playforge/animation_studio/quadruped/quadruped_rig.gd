@tool
extends RefCounted
## Procedural 28-bone Quadruped Creature Rig & Visual Builder.
## Zero external assets or hand-keyed clips: constructs an anatomically proportioned
## quadruped skeleton (spine, neck/head/ears, 3-segment tail, 2 front legs with
## backward elbows, 2 hind legs with forward stifles) plus stylized articulated
## body meshes and debug gizmos that work identically on Desktop and WebGL2 WASM.

const LEG_NAMES := ["FL", "FR", "HL", "HR"]
const LEG_BONES := {
	"FL": ["FrontL_Hip", "FrontL_Upper", "FrontL_Lower", "FrontL_Paw"],
	"FR": ["FrontR_Hip", "FrontR_Upper", "FrontR_Lower", "FrontR_Paw"],
	"HL": ["HindL_Hip", "HindL_Upper", "HindL_Lower", "HindL_Paw"],
	"HR": ["HindR_Hip", "HindR_Upper", "HindR_Lower", "HindR_Paw"],
}

# Anatomical proportions (meters, facing -Z forward in Godot Y-up right-handed coords)
const PELVIS_REST_Y := 0.78
const UPPER_LEN := 0.43
const LOWER_LEN := 0.43
const FRONT_Z := -0.46
const HIND_Z := 0.42
const LEG_X := 0.24

# Local rest paw offsets relative to Root on flat ground (y = 0)
const PAW_REST_OFFSETS := {
	"FL": Vector3(-LEG_X, 0.0, FRONT_Z),
	"FR": Vector3(LEG_X, 0.0, FRONT_Z),
	"HL": Vector3(-LEG_X, 0.0, HIND_Z),
	"HR": Vector3(LEG_X, 0.0, HIND_Z),
}


static func build_skeleton(rig: Skeleton3D) -> Dictionary:
	rig.clear_bones()
	var ids: Dictionary = {}

	var add := func(bname: String, parent_name: String, rest_pos: Vector3) -> int:
		var idx := rig.add_bone(bname)
		if not parent_name.is_empty() and ids.has(parent_name):
			rig.set_bone_parent(idx, int(ids[parent_name]))
		rig.set_bone_rest(idx, Transform3D(Basis.IDENTITY, rest_pos))
		ids[bname] = idx
		return idx

	# Core spine & head & tail (12 bones)
	add.call("Root", "", Vector3.ZERO)
	add.call("Pelvis", "Root", Vector3(0.0, PELVIS_REST_Y, 0.04))
	add.call("Spine1", "Pelvis", Vector3(0.0, 0.02, -0.22))
	add.call("Spine2", "Spine1", Vector3(0.0, 0.02, -0.24))
	add.call("Chest", "Spine2", Vector3(0.0, 0.01, -0.18))
	add.call("Neck", "Chest", Vector3(0.0, 0.14, -0.18))
	add.call("Head", "Neck", Vector3(0.0, 0.14, -0.18))
	add.call("EarL", "Head", Vector3(-0.09, 0.11, 0.04))
	add.call("EarR", "Head", Vector3(0.09, 0.11, 0.04))
	add.call("Tail1", "Pelvis", Vector3(0.0, 0.04, 0.24))
	add.call("Tail2", "Tail1", Vector3(0.0, -0.04, 0.24))
	add.call("Tail3", "Tail2", Vector3(0.0, -0.05, 0.22))

	# 4 Legs x 4 bones = 16 bones (total 28 bones)
	# Front legs attached to Chest; Hind legs attached to Pelvis.
	var front_specs := [
		{"id": "FL", "x": -LEG_X},
		{"id": "FR", "x": LEG_X},
	]
	for fs in front_specs:
		var b: Array = LEG_BONES[fs.id]
		add.call(b[0], "Chest", Vector3(fs.x, -0.05, 0.14))
		add.call(b[1], b[0], Vector3(0.0, 0.0, 0.0))
		add.call(b[2], b[1], Vector3(0.0, -UPPER_LEN, 0.08))
		add.call(b[3], b[2], Vector3(0.0, -LOWER_LEN, -0.08))

	var hind_specs := [
		{"id": "HL", "x": -LEG_X},
		{"id": "HR", "x": LEG_X},
	]
	for hs in hind_specs:
		var b: Array = LEG_BONES[hs.id]
		add.call(b[0], "Pelvis", Vector3(hs.x, -0.02, 0.36))
		add.call(b[1], b[0], Vector3(0.0, 0.0, 0.0))
		add.call(b[2], b[1], Vector3(0.0, -UPPER_LEN, -0.09))
		add.call(b[3], b[2], Vector3(0.0, -LOWER_LEN, 0.09))

	rig.reset_bone_poses()
	rig.force_update_all_bone_transforms()
	return ids


static func build_visual_body(rig: Skeleton3D) -> Array[Node3D]:
	var created: Array[Node3D] = []
	var armor_dark := _mat(Color("#252d38"), 0.55, 0.32)
	var armor_mid := _mat(Color("#3a4759"), 0.45, 0.38)
	var armor_light := _mat(Color("#c9d4e3"), 0.30, 0.40)
	var joint_amber := _mat(Color("#f39c2b"), 0.35, 0.28)
	var visor_cyan := _mat(Color("#2cc7b8"), 0.15, 0.20, true)
	var paw_rubber := _mat(Color("#191f27"), 0.10, 0.80)

	# Torso & Pelvis plates
	var pelvis_att := _attach(rig, "Pelvis", created)
	_box(pelvis_att, Vector3(0.38, 0.22, 0.42), armor_dark, Vector3(0.0, 0.02, 0.12))
	_box(pelvis_att, Vector3(0.41, 0.06, 0.28), joint_amber, Vector3(0.0, 0.11, 0.10))

	var s1_att := _attach(rig, "Spine1", created)
	_box(s1_att, Vector3(0.32, 0.21, 0.28), armor_mid, Vector3(0.0, 0.02, -0.02))

	var s2_att := _attach(rig, "Spine2", created)
	_box(s2_att, Vector3(0.35, 0.24, 0.28), armor_mid, Vector3(0.0, 0.03, -0.02))

	var chest_att := _attach(rig, "Chest", created)
	_box(chest_att, Vector3(0.44, 0.28, 0.36), armor_dark, Vector3(0.0, 0.02, 0.02))
	_box(chest_att, Vector3(0.34, 0.07, 0.32), armor_light, Vector3(0.0, 0.16, 0.00))
	_box(chest_att, Vector3(0.28, 0.08, 0.04), visor_cyan, Vector3(0.0, 0.04, -0.17))

	# Neck, Head, Visor, Ears
	var neck_att := _attach(rig, "Neck", created)
	_capsule(neck_att, 0.095, 0.28, armor_mid, Vector3(0.0, 0.04, -0.04), Vector3(deg_to_rad(38.0), 0.0, 0.0))

	var head_att := _attach(rig, "Head", created)
	_box(head_att, Vector3(0.22, 0.16, 0.28), armor_dark, Vector3(0.0, 0.02, -0.06))
	_box(head_att, Vector3(0.14, 0.10, 0.18), armor_light, Vector3(0.0, -0.01, -0.22))
	_box(head_att, Vector3(0.23, 0.045, 0.08), visor_cyan, Vector3(0.0, 0.045, -0.14))

	for ear in ["EarL", "EarR"]:
		var ear_att := _attach(rig, ear, created)
		_box(ear_att, Vector3(0.045, 0.13, 0.06), joint_amber, Vector3(0.0, 0.05, 0.0), Vector3(deg_to_rad(-18.0), 0.0, 0.0))

	# Tail segments
	for idx in 3:
		var tname := "Tail%d" % (idx + 1)
		var t_att := _attach(rig, tname, created)
		var r := 0.055 - float(idx) * 0.012
		_capsule(t_att, r, 0.24, armor_mid if idx < 2 else joint_amber, Vector3(0.0, -0.01, 0.10), Vector3(deg_to_rad(90.0), 0.0, 0.0))

	# 4 Legs: upper thigh/arm, knee/elbow joint sphere, lower shin, paw pad
	for leg_id in LEG_NAMES:
		var b: Array = LEG_BONES[leg_id]
		var hip_att := _attach(rig, b[0], created)
		_sphere(hip_att, 0.088, joint_amber, Vector3.ZERO)

		var upper_att := _attach(rig, b[1], created)
		var upper_mid := Vector3(0.0, -UPPER_LEN * 0.5, 0.0)
		_capsule(upper_att, 0.068, UPPER_LEN * 0.96, armor_mid, upper_mid)
		_box(upper_att, Vector3(0.11, 0.18, 0.12), armor_dark, Vector3(0.0, -UPPER_LEN * 0.35, 0.0))

		var lower_att := _attach(rig, b[2], created)
		_sphere(lower_att, 0.068, joint_amber, Vector3.ZERO)
		_capsule(lower_att, 0.052, LOWER_LEN * 0.96, armor_light, Vector3(0.0, -LOWER_LEN * 0.5, 0.0))

		var paw_att := _attach(rig, b[3], created)
		_box(paw_att, Vector3(0.11, 0.06, 0.16), paw_rubber, Vector3(0.0, 0.03, -0.03))
		_box(paw_att, Vector3(0.09, 0.025, 0.05), visor_cyan, Vector3(0.0, 0.065, -0.08))

	return created


static func _attach(rig: Skeleton3D, bone_name: String, list: Array[Node3D]) -> BoneAttachment3D:
	var att := BoneAttachment3D.new()
	att.name = "Att_" + bone_name
	att.bone_name = bone_name
	rig.add_child(att)
	list.append(att)
	return att


static func _mat(col: Color, metallic: float, roughness: float, emissive := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = metallic
	m.roughness = roughness
	if emissive:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 1.5
	return m


static func _box(parent: Node3D, sz: Vector3, mat: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = sz
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


static func _sphere(parent: Node3D, r: float, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _capsule(parent: Node3D, r: float, h: float, mat: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi
