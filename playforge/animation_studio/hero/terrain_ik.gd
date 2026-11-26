extends RefCounted

const FEET := ["LeftLegFoot", "RightLegFoot"]
const THIGHS := ["LeftLegThigh1", "RightLegThigh1"]
const CALVES := ["LeftLegCalf", "RightLegCalf"]
const TERRAIN_LAYER := 1

var rig: Skeleton3D
var host: Node3D
var fixture: Node3D
var feet: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var hits: Array[bool] = [false, false]
var target_positions: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var target_normals: Array[Vector3] = [Vector3.UP, Vector3.UP]
var before_ik: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var smoothed_heights: Array[float] = [0.0, 0.0]


func setup(skeleton: Skeleton3D, parent: Node3D) -> bool:
	teardown()
	rig = skeleton
	host = parent
	if not is_instance_valid(rig) or not is_instance_valid(host):
		return false
	fixture = Node3D.new()
	fixture.name = "HeroTerrainIK"
	host.add_child(fixture)
	create_terrain()
	for i in 2:
		if rig.find_bone(THIGHS[i]) < 0 or rig.find_bone(CALVES[i]) < 0 or rig.find_bone(FEET[i]) < 0:
			teardown()
			return false
	reset()
	return true


func create_terrain() -> void:
	_add_body("LevelGround", Vector3(0, -0.12, 0), Vector3(30, 0.2, 30))
	var step := Vector3(-0.1, 0.08, 0.92)
	_add_box("FirstStep", step, Vector3(0.8, 0.16, 0.55), Color("#738279"))
	var step2 := Vector3(0.15, 0.22, 1.47)
	_add_box("SecondStep", step2, Vector3(0.8, 0.12, 0.55), Color("#829087"))
	var ramp := _box("Slope", Vector3(0.8, 0.13, 1.05), Vector3(1.0, 0.22, 1.8), Color("#687a70"))
	ramp.rotation.z = deg_to_rad(-10.0)
	fixture.add_child(ramp)
	var body := StaticBody3D.new()
	body.collision_layer = TERRAIN_LAYER
	body.collision_mask = 0
	body.position = ramp.position
	body.rotation = ramp.rotation
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 0.22, 1.8)
	shape.shape = box
	body.add_child(shape)
	fixture.add_child(body)


func _box(label: String, position: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = label
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material = material
	visual.mesh = mesh
	visual.position = position
	return visual


func _add_body(label: String, position: Vector3, size: Vector3) -> void:
	var visual := _box(label, position, size, Color("#596a62"))
	fixture.add_child(visual)
	var body := StaticBody3D.new()
	body.collision_layer = TERRAIN_LAYER
	body.collision_mask = 0
	body.position = position
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	fixture.add_child(body)


func _add_box(label: String, position: Vector3, size: Vector3, color: Color) -> void:
	fixture.add_child(_box(label, position, size, color))
	var body := StaticBody3D.new()
	body.name = label + "Collision"
	body.collision_layer = TERRAIN_LAYER
	body.collision_mask = 0
	body.position = position
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	fixture.add_child(body)


func step(delta: float) -> Dictionary:
	var space := host.get_world_3d().direct_space_state
	rig.force_update_all_bone_transforms()
	for i in 2:
		var foot := rig.find_bone(FEET[i])
		var ankle := rig.to_global(rig.get_bone_global_pose(foot).origin)
		before_ik[i] = ankle
		var query := PhysicsRayQueryParameters3D.create(ankle + Vector3.UP * 0.45, ankle + Vector3.DOWN * 0.8, TERRAIN_LAYER)
		var hit := space.intersect_ray(query)
		hits[i] = not hit.is_empty()
		target_normals[i] = hit.get("normal", Vector3.UP)
		target_positions[i] = hit.position + target_normals[i] * 0.025 if hits[i] else ankle
		smoothed_heights[i] = move_toward(smoothed_heights[i], target_positions[i].y, delta * 4.0)
		if hits[i]:
			var target := Vector3(target_positions[i].x, smoothed_heights[i], target_positions[i].z)
			adjust_leg(i, rig.to_local(target), rig.global_basis.inverse() * target_normals[i])
		feet[i] = rig.to_global(rig.get_bone_global_pose(foot).origin)
	return {"feet": feet.duplicate(), "before_ik": before_ik.duplicate(),
		"hits": hits.duplicate(), "targets": target_positions.duplicate(), "normals": target_normals.duplicate()}


func adjust_leg(side: int, target: Vector3, normal: Vector3) -> void:
	var hip := rig.find_bone(THIGHS[side])
	var knee := rig.find_bone(CALVES[side])
	var ankle := rig.find_bone(FEET[side])
	var h := rig.get_bone_global_pose(hip).origin
	var k := rig.get_bone_global_pose(knee).origin
	var pose := rig.get_bone_global_pose(ankle)
	var upper := h.distance_to(k)
	var lower := k.distance_to(pose.origin)
	var direction := (target - h).normalized()
	var distance := clampf(h.distance_to(target), absf(upper - lower) + 0.001, upper + lower - 0.001)
	var bend := (k - h).slide(direction).normalized()
	if direction.is_zero_approx() or bend.is_zero_approx():
		return
	var along := (upper * upper - lower * lower + distance * distance) / (2.0 * distance)
	var desired_knee := h + direction * along + bend * sqrt(maxf(0.0, upper * upper - along * along))
	rotate_bone(hip, (k - h).normalized(), (desired_knee - h).normalized())
	rig.force_update_all_bone_transforms()
	k = rig.get_bone_global_pose(knee).origin
	var current_ankle := rig.get_bone_global_pose(ankle).origin
	rotate_bone(knee, (current_ankle - k).normalized(), (h + direction * distance - k).normalized())
	rig.force_update_all_bone_transforms()
	var fitted := rig.get_bone_global_pose(ankle)
	fitted.basis = Basis(Quaternion(Vector3.UP, normal.normalized())) * pose.basis
	rig.set_bone_global_pose(ankle, fitted)
	rig.force_update_all_bone_transforms()


func rotate_bone(index: int, from: Vector3, to: Vector3) -> void:
	var pose := rig.get_bone_global_pose(index)
	pose.basis = Basis(Quaternion(from, to)) * pose.basis
	rig.set_bone_global_pose(index, pose)


func reset() -> void:
	for i in 2:
		var ankle := rig.to_global(rig.get_bone_global_pose(rig.find_bone(FEET[i])).origin)
		smoothed_heights[i] = ankle.y
		hits[i] = false


func teardown() -> void:
	if is_instance_valid(fixture):
		fixture.queue_free()
	fixture = null
	rig = null
	host = null
