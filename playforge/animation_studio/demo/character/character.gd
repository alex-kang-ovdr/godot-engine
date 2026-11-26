extends Node3D

signal step_event(side: String)

const TOOL_SOCKET_BONE: StringName = &"Hand.R"
const TOOL_SOCKET_OFFSET := Transform3D(
	Basis(
		Vector3(0.837, -0.259, -0.483),
		Vector3(0.225, 0.966, -0.130),
		Vector3(0.500, 0.000, 0.866)
	),
	Vector3(0.075, -0.015, 0.105)
)

const MAIN_COLOR := Color("#4bb7aa")
const LIGHT_COLOR := Color("#e9f1df")
const DARK_COLOR := Color("#1c3543")
const ARM_COLOR := Color("#367f82")
const AMBER_COLOR := Color("#f0a43a")
const CYAN_COLOR := Color("#79f2e4")

@onready var rig: Skeleton3D = $Rig
@onready var pose: SkeletonModifier3D = $Rig/Pose
@onready var player: AnimationPlayer = $Player
@onready var _tool_socket: BoneAttachment3D = $Rig/ToolSocket
var tool: Node3D


func _ready() -> void:
	rig.reset_bone_poses()
	_build_visuals()
	_tool_socket.bone_name = TOOL_SOCKET_BONE
	_tool_socket.transform = Transform3D.IDENTITY
	pose.active = true
	# The demo director owns both clocks and advances them in a fixed order.
	rig.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.root_node = ^".."
	player.root_motion_track = ^"Rig:Root"
	player.root_motion_local = true
	player.add_animation_library(&"", _make_animation_library())


func get_tool() -> Node3D:
	return tool


func get_tool_offset() -> Transform3D:
	return TOOL_SOCKET_OFFSET


func get_tool_socket_bone_name() -> StringName:
	return TOOL_SOCKET_BONE


func _emit_step(side: String) -> void:
	step_event.emit(side)


func _make_animation_library() -> AnimationLibrary:
	var library := AnimationLibrary.new()
	var stride := Animation.new()
	stride.resource_name = "Courier stride"
	stride.length = 1.0
	stride.step = 1.0 / 60.0
	stride.loop_mode = Animation.LOOP_LINEAR

	# The root is intentionally native to AnimationPlayer so its motion remains
	# available through root-motion accumulators while all other bone PRS is
	# sampled by the Pose modifier.
	var root_track := stride.add_track(Animation.TYPE_POSITION_3D)
	stride.track_set_path(root_track, ^"Rig:Root")
	stride.track_insert_key(root_track, 0.0, Vector3.ZERO)
	stride.track_insert_key(root_track, 1.0, Vector3(1.2, 0.0, 0.0))

	_add_rotation_track(stride, ^"Rig:HipLeft", Vector3.FORWARD, [0.0, 0.34, 0.0, -0.34, 0.0])
	_add_rotation_track(stride, ^"Rig:HipRight", Vector3.FORWARD, [0.0, -0.34, 0.0, 0.34, 0.0])
	_add_rotation_track(stride, ^"Rig:KneeLeft", Vector3.FORWARD, [0.02, -0.18, 0.02, 0.0, 0.02])
	_add_rotation_track(stride, ^"Rig:KneeRight", Vector3.FORWARD, [0.02, 0.0, 0.02, -0.18, 0.02])
	_add_rotation_track(stride, ^"Rig:ShoulderLeft", Vector3.FORWARD, [0.0, -0.22, 0.0, 0.22, 0.0])
	_add_rotation_track(stride, ^"Rig:ShoulderRight", Vector3.FORWARD, [0.0, 0.22, 0.0, -0.22, 0.0])
	_add_rotation_track(stride, ^"Rig:Hand.R", Vector3.RIGHT, [0.0, -0.14, 0.0, 0.14, 0.0])
	_add_rotation_track(stride, ^"Rig:Spine", Vector3.FORWARD, [0.0, -0.025, 0.0, 0.025, 0.0])

	var annotations := stride.add_track(Animation.TYPE_METHOD)
	stride.track_set_path(annotations, ^".")
	stride.track_insert_key(annotations, 0.25, {"method": "_emit_step", "args": ["L"]})
	stride.track_insert_key(annotations, 0.75, {"method": "_emit_step", "args": ["R"]})
	library.add_animation(&"stride", stride)
	return library


func _add_rotation_track(animation: Animation, path: NodePath, axis: Vector3, angles: Array[float]) -> void:
	var track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(track, path)
	var times: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]
	for key_index in times.size():
		animation.rotation_track_insert_key(track, times[key_index], Quaternion(axis, angles[key_index]))


func _build_visuals() -> void:
	var shell := _material(MAIN_COLOR, 0.30, 0.32)
	var shell_light := _material(LIGHT_COLOR, 0.08, 0.40)
	var dark := _material(DARK_COLOR, 0.38, 0.27)
	var arm := _material(ARM_COLOR, 0.35, 0.30)
	var amber := _material(AMBER_COLOR, 0.22, 0.30)
	var cyan := _material(CYAN_COLOR, 0.10, 0.22, true)
	var rubber := _material(Color("#253c42"), 0.0, 0.78)

	var torso := $Rig/BodyMount as BoneAttachment3D
	_add_box(torso, "TorsoShell", Vector3(0.34, 0.56, 0.48), shell, Vector3(0.0, 0.035, 0.0))
	_add_box(torso, "ChestPanel", Vector3(0.035, 0.23, 0.30), shell_light, Vector3(0.184, 0.075, 0.0))
	_add_box(torso, "CourierBadge", Vector3(0.025, 0.115, 0.125), amber, Vector3(0.208, 0.075, 0.0))
	_add_box(torso, "Belt", Vector3(0.36, 0.075, 0.50), dark, Vector3(0.0, -0.245, 0.0))
	_add_box(torso, "BeltClasp", Vector3(0.025, 0.065, 0.105), amber, Vector3(0.188, -0.245, 0.0))
	_add_box(torso, "SideParcel", Vector3(0.22, 0.24, 0.19), shell_light, Vector3(-0.01, -0.11, -0.265), Vector3(0.0, 0.0, -0.10))
	_add_box(torso, "ParcelStripe", Vector3(0.025, 0.20, 0.045), amber, Vector3(0.105, -0.11, -0.265))

	var head := $Rig/HeadMount as BoneAttachment3D
	_add_sphere(head, "HeadShell", 0.235, shell, Vector3.ZERO, Vector3(1.0, 0.91, 0.94))
	_add_box(head, "FaceVisor", Vector3(0.045, 0.155, 0.265), dark, Vector3(0.190, 0.012, 0.0))
	_add_sphere(head, "EyeLeft", 0.035, cyan, Vector3(0.220, 0.035, -0.070), Vector3(0.55, 1.0, 1.0))
	_add_sphere(head, "EyeRight", 0.035, cyan, Vector3(0.220, 0.035, 0.070), Vector3(0.55, 1.0, 1.0))
	_add_box(head, "MouthStatus", Vector3(0.014, 0.018, 0.10), amber, Vector3(0.220, -0.038, 0.0))
	_add_cylinder(head, "AntennaStem", 0.018, 0.20, dark, Vector3(0.0, 0.250, 0.0))
	_add_sphere(head, "AntennaLamp", 0.055, amber, Vector3(0.0, 0.365, 0.0))

	_build_arm($Rig/ShoulderLeftMount, $Rig/ElbowLeftMount, $Rig/HandLeftMount, arm, dark, shell_light, false)
	_build_arm($Rig/ShoulderRightMount, $Rig/ElbowRightMount, $Rig/HandRightMount, arm, dark, shell_light, true)
	_build_leg($Rig/HipLeftMount, $Rig/KneeLeftMount, $Rig/FootLeftMount, arm, dark, rubber)
	_build_leg($Rig/HipRightMount, $Rig/KneeRightMount, $Rig/FootRightMount, arm, dark, rubber)
	_build_tool()


func _build_arm(shoulder: BoneAttachment3D, elbow: BoneAttachment3D, hand: BoneAttachment3D, upper_material: Material, joint_material: Material, hand_material: Material, camera_side: bool) -> void:
	_add_sphere(shoulder, "ShoulderJoint", 0.105, joint_material, Vector3.ZERO, Vector3(1.0, 1.0, 1.05))
	_add_capsule(shoulder, "UpperArm", 0.072, 0.30, upper_material, Vector3(0.0, -0.145, 0.0))
	_add_box(shoulder, "ShoulderShell", Vector3(0.16, 0.13, 0.16), hand_material, Vector3(0.0, -0.08, 0.0))
	_add_sphere(elbow, "ElbowJoint", 0.075, joint_material)
	_add_capsule(elbow, "Forearm", 0.065, 0.27, upper_material, Vector3(0.0, -0.13, 0.0))
	_add_box(elbow, "WristCuff", Vector3(0.14, 0.07, 0.145), hand_material, Vector3(0.0, -0.235, 0.0))
	_add_box(hand, "HandPalm", Vector3(0.14, 0.12, 0.15), joint_material, Vector3(0.035, -0.015, 0.0))
	if camera_side:
		_add_sphere(hand, "ToolGrip", 0.075, hand_material, Vector3(0.025, -0.045, 0.05))


func _build_leg(hip: BoneAttachment3D, knee: BoneAttachment3D, foot: BoneAttachment3D, leg_material: Material, joint_material: Material, boot_material: Material) -> void:
	_add_sphere(hip, "HipJoint", 0.09, joint_material)
	_add_capsule(hip, "Thigh", 0.080, 0.30, leg_material, Vector3(0.0, -0.145, 0.0))
	_add_sphere(knee, "KneeJoint", 0.082, joint_material)
	_add_box(knee, "KneeCap", Vector3(0.10, 0.12, 0.155), _material(AMBER_COLOR, 0.22, 0.30), Vector3(0.045, 0.0, 0.0))
	_add_capsule(knee, "Shin", 0.070, 0.30, leg_material, Vector3(0.0, -0.145, 0.0))
	_add_box(foot, "Boot", Vector3(0.27, 0.12, 0.20), boot_material, Vector3(0.075, -0.025, 0.0))
	_add_box(foot, "BootToe", Vector3(0.025, 0.055, 0.13), _material(AMBER_COLOR, 0.22, 0.30), Vector3(0.205, -0.005, 0.0))


func _build_tool() -> void:
	tool = Node3D.new()
	tool.name = "Tool"
	tool.transform = TOOL_SOCKET_OFFSET
	_tool_socket.add_child(tool)
	var tool_body := _material(Color("#ee8d31"), 0.22, 0.28)
	var screen := _material(CYAN_COLOR, 0.08, 0.18, true)
	_add_box(tool, "Handle", Vector3(0.12, 0.32, 0.115), _material(DARK_COLOR, 0.32, 0.35), Vector3(-0.015, -0.225, 0.0), Vector3(0.0, 0.0, -0.12))
	_add_box(tool, "HandleGrip", Vector3(0.13, 0.13, 0.13), _material(Color("#f1be61"), 0.15, 0.42), Vector3(-0.015, -0.31, 0.0))
	_add_box(tool, "ScannerHead", Vector3(0.47, 0.23, 0.18), tool_body, Vector3(0.12, -0.045, 0.0), Vector3(0.0, 0.0, 0.04))
	_add_box(tool, "ScannerSide", Vector3(0.29, 0.12, 0.018), screen, Vector3(0.12, -0.025, 0.101))
	_add_box(tool, "ScannerLabel", Vector3(0.09, 0.045, 0.022), _material(LIGHT_COLOR, 0.08, 0.42), Vector3(0.23, -0.113, 0.102))
	_add_cylinder(tool, "ScannerEmitter", 0.09, 0.045, screen, Vector3(0.37, -0.045, 0.0), Vector3(0.0, 0.0, PI * 0.5))
	_add_cylinder(tool, "EmitterRim", 0.105, 0.026, _material(Color("#ffca63"), 0.16, 0.30), Vector3(0.394, -0.045, 0.0), Vector3(0.0, 0.0, PI * 0.5))


func _material(color: Color, metallic: float, roughness: float, emissive: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.6
	return material


func _add_box(parent: Node3D, node_name: String, size: Vector3, material: Material, position: Vector3, rotation: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _add_mesh(parent, node_name, mesh, material, position, rotation)


func _add_sphere(parent: Node3D, node_name: String, radius: float, material: Material, position: Vector3 = Vector3.ZERO, scale: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	var instance := _add_mesh(parent, node_name, mesh, material, position)
	instance.scale = scale
	return instance


func _add_capsule(parent: Node3D, node_name: String, radius: float, height: float, material: Material, position: Vector3) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	return _add_mesh(parent, node_name, mesh, material, position)


func _add_cylinder(parent: Node3D, node_name: String, radius: float, height: float, material: Material, position: Vector3, rotation: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	return _add_mesh(parent, node_name, mesh, material, position, rotation)


func _add_mesh(parent: Node3D, node_name: String, mesh: Mesh, material: Material, position: Vector3, rotation: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	parent.add_child(instance)
	return instance
