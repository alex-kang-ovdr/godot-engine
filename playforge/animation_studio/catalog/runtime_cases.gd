extends Node3D

const Character := preload("res://demo/character/character.tscn")

var family := ""
var case_path := ""
var elapsed := 0.0
var rig: Skeleton3D
var cpu_surface: ImmediateMesh
var bind_mesh: Array = []
var actor
var traveled := 0.0
var heading := 0.0
var controller: CharacterBody3D
var crowd: MultiMesh
var samples: Array[Transform3D] = []
var max_difference := 0.0
var serial := false
var mirrored := false
var blended := false
var sample_usec := 0


func start_case(path: String, case_name: String) -> void:
	case_path = path.to_lower()
	var variant := case_name.to_lower()
	serial = "single-thread" in variant
	mirrored = "mirror" in variant or "mirroredmotion" in case_path
	blended = "blend" in case_path or "sampleandblend" in variant
	if "multithread" in case_path:
		family = "worker"
		_create_crowd()
	elif "skinning" in case_path or "scaling" in case_path:
		family = "skin"
		_create_skin()
	else:
		family = "actor"
		actor = Character.instantiate()
		add_child(actor)
		actor.pose.play_clip(actor.player, &"stride")
		if "charactercontroller" in case_path:
			controller = CharacterBody3D.new()
			var shape := CapsuleShape3D.new()
			shape.radius = 0.25
			shape.height = 1.6
			var collision := CollisionShape3D.new()
			collision.shape = shape
			collision.position.y = 0.8
			controller.add_child(collision)
			add_child(controller)
			actor.reparent(controller)
		if mirrored:
			actor.scale.z = -1.0


func _physics_process(delta: float) -> void:
	elapsed += delta
	match family:
		"worker":
			var start := Time.get_ticks_usec()
			if serial:
				for i in 12:
					_sample_actor(i)
			else:
				var job := WorkerThreadPool.add_group_task(_sample_actor, 12)
				WorkerThreadPool.wait_for_group_task_completion(job)
			sample_usec = Time.get_ticks_usec() - start
			for i in samples.size():
				crowd.set_instance_transform(i, samples[i])
			max_difference = samples[3].origin.distance_to(_segment(0, 3).origin)
		"skin":
			rig.set_bone_pose_rotation(1, Quaternion(Vector3.FORWARD, sin(elapsed * 2.0) * 0.9))
			if "/scaling/" in case_path:
				rig.set_bone_pose_scale(1, Vector3.ONE * (1.0 + 0.35 * sin(elapsed * 2.0)))
			if cpu_surface:
				_skin_on_cpu()
		"actor":
			actor.player.advance(delta)
			var movement: Vector3 = actor.player.get_root_motion_position()
			traveled += movement.length()
			if controller:
				controller.velocity = Vector3(movement.x / delta, controller.velocity.y - 9.8 * delta, 0)
				controller.move_and_slide()
				if controller.position.x > 1.5:
					controller.position.x = -1.5
			elif "basicmovement" in case_path or "/motionextraction/motionextraction" in case_path:
				heading += (0.65 + Input.get_axis("ui_left", "ui_right")) * delta
				actor.rotation.y = heading
				actor.position += actor.basis * movement
				actor.position.x = wrapf(actor.position.x, -1.75, 1.75)
				actor.position.z = wrapf(actor.position.z, -1.25, 1.25)
			elif not "attachments" in case_path:
				actor.position.x = fposmod(traveled, 2.8) - 1.4
			actor.rig.advance(delta)


func status_text() -> String:
	match family:
		"skin":
			return "%s · 정점 72개 · 본 회전 %.1f°" % ["CPU 가중합 스키닝" if cpu_surface else "엔진 가중치 메시 스키닝", rad_to_deg(rig.get_bone_pose_rotation(1).get_angle())]
		"worker":
			return "%s · 12개 리그 × 4개 관절 · %d µs · 직렬 기준점 오차 %.6f m" % ["단일 스레드" if serial else "WorkerThreadPool", sample_usec, max_difference]
		"actor":
			if "attachments" in case_path:
				return "손 본에 부착한 공구 · 손 소켓의 월드 높이 %.2f m" % actor.tool.global_position.y
			var description := "루트 변위 추출"
			if "mirrored" in case_path:
				description = "좌우 반사 리그의 루트 이동"
			elif "charactercontroller" in case_path:
				description = "CharacterBody3D 보행 · 바닥 접촉 %s" % str(controller.is_on_floor())
			elif "basicmovement" in case_path or "/motionextraction/motionextraction" in case_path:
				description = "회전 + 루트 이동 · 방향키로 조향"
			return "%s · 누적 %.2f m · 트랙 끝에서 표시 위치 순환" % [description, traveled]
	return ""


func _create_skin() -> void:
	rig = Skeleton3D.new()
	rig.name = "Rig"
	add_child(rig)
	rig.add_bone("Base")
	rig.add_bone("Tip")
	rig.set_bone_parent(1, 0)
	rig.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3.UP))
	rig.reset_bone_poses()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	for row in 9:
		var influence := smoothstep(0.5, 1.5, row * 0.25)
		for side in 8:
			var angle := TAU * side / 8.0
			var normal := Vector3(cos(angle), 0, sin(angle))
			vertices.append(normal * 0.28 + Vector3.UP * row * 0.25)
			normals.append(normal)
			colors.append(Color("#30b7a6").lerp(Color("#ffa752"), influence))
			bones.append_array(PackedInt32Array([0, 1, 0, 0]))
			weights.append_array(PackedFloat32Array([1.0 - influence, influence, 0, 0]))
			if row < 8:
				var a := row * 8 + side
				var b := row * 8 + (side + 1) % 8
				indices.append_array(PackedInt32Array([a, b, a+8, b, b+8, a+8]))
	var data := []
	data.resize(Mesh.ARRAY_MAX)
	data[Mesh.ARRAY_VERTEX] = vertices
	data[Mesh.ARRAY_NORMAL] = normals
	data[Mesh.ARRAY_COLOR] = colors
	data[Mesh.ARRAY_BONES] = bones
	data[Mesh.ARRAY_WEIGHTS] = weights
	data[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data)
	var surface := MeshInstance3D.new()
	surface.mesh = mesh
	surface.skeleton = ^"../Rig"
	surface.skin = rig.create_skin_from_rest_transforms()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface.material_override = material
	add_child(surface)
	if "/skinning/" in case_path:
		bind_mesh = data
		cpu_surface = ImmediateMesh.new()
		surface.skin = null
		surface.skeleton = NodePath()
		surface.mesh = cpu_surface
		_skin_on_cpu()


func _skin_on_cpu() -> void:
	var tip := rig.get_bone_global_pose(1) * rig.get_bone_global_rest(1).affine_inverse()
	var vertices: PackedVector3Array = bind_mesh[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = bind_mesh[Mesh.ARRAY_NORMAL]
	var weights: PackedFloat32Array = bind_mesh[Mesh.ARRAY_WEIGHTS]
	cpu_surface.clear_surfaces()
	cpu_surface.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in bind_mesh[Mesh.ARRAY_INDEX]:
		var w := weights[4*i+1]
		cpu_surface.surface_set_color(bind_mesh[Mesh.ARRAY_COLOR][i])
		cpu_surface.surface_set_normal(normals[i].lerp(tip.basis * normals[i], w).normalized())
		cpu_surface.surface_add_vertex(vertices[i].lerp(tip * vertices[i], w))
	cpu_surface.surface_end()


func _create_crowd() -> void:
	var link := BoxMesh.new()
	link.size = Vector3(0.13, 0.27, 0.13)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#54d1bc")
	link.material = material
	crowd = MultiMesh.new()
	crowd.transform_format = MultiMesh.TRANSFORM_3D
	crowd.mesh = link
	crowd.instance_count = 48
	samples.resize(crowd.instance_count)
	var display := MultiMeshInstance3D.new()
	display.multimesh = crowd
	add_child(display)


# Workers read the frozen tick time and write disjoint ranges of a pre-sized
# array. Scene and rendering resources are touched only after the barrier.
func _sample_actor(index: int) -> void:
	for joint in 4:
		samples[index * 4 + joint] = _segment(index, joint)


func _segment(index: int, joint: int) -> Transform3D:
	var p := Vector3((index % 4 - 1.5) * 0.78, 0.12, (floori(index / 4.0) - 1) * 0.7)
	var basis := Basis.IDENTITY
	for j in joint + 1:
		var phase := elapsed * 2.5 + index * 0.4 + j * 0.28
		var angle := sin(phase) * 0.30
		if blended:
			angle = lerpf(angle, cos(phase * 1.4) * 0.5, 0.5)
		if mirrored:
			angle = -angle
		basis *= Basis(Vector3.FORWARD, angle)
		var length := 0.32 if "mapping" in case_path or "retarget" in case_path else 0.27
		p += basis.y * length
	return Transform3D(basis, p)
