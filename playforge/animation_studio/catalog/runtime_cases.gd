extends Node3D
## Runtime catalog probes (MotionExtraction, Attachments, Skinning, Scaling,
## Multithreading) powered by the internalized 50-bone HavokGirl SDK asset,
## aligned to Godot Standard coordinates (-Z forward, +Y up, SI meters, 9.81 m/s²).

const Standards := preload("res://catalog/havok_demo_standards.gd")

class HavokActorWrapper extends Node3D:
	var tool: Node3D
	var rig: Skeleton3D
	var player: AnimationPlayer
	var pack: Dictionary = {}

var family := ""
var case_path := ""
var _spec: Dictionary = {}
var _clip_name := "walk"
var _last_clip_time := 0.0
var elapsed := 0.0
var rig: Skeleton3D
var cpu_surface: ImmediateMesh
var _cpu_verts: PackedVector3Array = PackedVector3Array()
var _cpu_normals: PackedVector3Array = PackedVector3Array()
var _cpu_indices: PackedInt32Array = PackedInt32Array()
var _cpu_bone_idx := 1
var actor: HavokActorWrapper
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
var _worker_hero_pack: Dictionary = {}


func start_case(path: String, case_name: String) -> void:
	case_path = path.to_lower()
	_spec = Standards.resolve_demo_spec(path, case_name)
	var variant := case_name.to_lower()
	serial = "single-thread" in variant
	mirrored = "mirror" in variant or "mirroredmotion" in case_path
	blended = "blend" in case_path or "sampleandblend" in variant
	elapsed = 0.0
	traveled = 0.0
	heading = 0.0

	if "multithread" in case_path:
		family = "worker"
		_create_crowd()
	elif "skinning" in case_path or "scaling" in case_path:
		family = "skin"
		_create_skin()
	else:
		family = "actor"
		_create_actor()


func _create_actor() -> void:
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	var pack := Standards.spawn_aligned_character(cid, "MotionActor", Animation.LOOP_LINEAR)
	actor = HavokActorWrapper.new()
	actor.name = "HavokActor"
	actor.pack = pack
	actor.rig = pack["skeleton"] as Skeleton3D
	actor.player = pack["player"] as AnimationPlayer
	actor.add_child(pack["outer"] as Node3D)
	add_child(actor)

	# Mount physical hand tool on HavokGirl's R Hand (used by Attachments & gallery contract)
	var hand_idx := Standards.find_semantic_bone(actor.rig, "r_hand")
	var hand_att := BoneAttachment3D.new()
	hand_att.name = "HandToolAttachment"
	hand_att.bone_name = actor.rig.get_bone_name(hand_idx) if hand_idx >= 0 else actor.rig.get_bone_name(0)
	actor.rig.add_child(hand_att)
	var tool_node := MeshInstance3D.new()
	tool_node.name = "HandTool"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.34, 0.06)
	tool_node.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#f6ae54")
	mat.emission_enabled = true
	mat.emission = Color("#b86b1a")
	tool_node.material_override = mat
	tool_node.position = Vector3(0.0, 0.14, 0.0)
	hand_att.add_child(tool_node)
	actor.tool = tool_node

	_clip_name = Standards.pick_clip(pack, str(_spec.get("primary_clip", "walk")))
	actor.player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	actor.player.assigned_animation = StringName(_clip_name)
	actor.player.seek(0.0, true)
	_last_clip_time = 0.0

	if "charactercontroller" in case_path:
		controller = CharacterBody3D.new()
		controller.name = "HavokCharacterController"
		var shape := CapsuleShape3D.new()
		shape.radius = 0.28
		shape.height = 1.62
		var collision := CollisionShape3D.new()
		collision.shape = shape
		collision.position.y = 0.81
		controller.add_child(collision)
		add_child(controller)
		actor.reparent(controller)
	if mirrored:
		# Godot Standard left-right mirror across the X=0 symmetry plane (-Z forward)
		actor.scale.x = -1.0


func _create_skin() -> void:
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	var pack := Standards.spawn_aligned_character(cid, "SkinActor", Animation.LOOP_LINEAR)
	actor = HavokActorWrapper.new()
	actor.name = "SkinHavokActor"
	actor.pack = pack
	actor.rig = pack["skeleton"] as Skeleton3D
	actor.player = pack["player"] as AnimationPlayer
	actor.add_child(pack["outer"] as Node3D)
	add_child(actor)
	rig = actor.rig
	_clip_name = Standards.pick_clip(pack, str(_spec.get("primary_clip", "scale" if "/scaling/" in case_path else "idle")))
	actor.player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	actor.player.assigned_animation = StringName(_clip_name)
	actor.player.seek(0.0, true)

	if "/skinning/" in case_path:
		# Extract a real subset of triangles from HavokGirl's skinned mesh for CPU vs GPU comparison
		var meshes := rig.find_children("*", "MeshInstance3D", true, false)
		if not meshes.is_empty():
			var mi := meshes[0] as MeshInstance3D
			if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
				var arr := mi.mesh.surface_get_arrays(0)
				_cpu_verts = arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
				_cpu_normals = arr[Mesh.ARRAY_NORMAL] as PackedVector3Array
				var idx_raw: PackedInt32Array = arr[Mesh.ARRAY_INDEX] as PackedInt32Array
				var max_idx := mini(idx_raw.size(), 900)
				_cpu_indices = idx_raw.slice(0, max_idx)
		_cpu_bone_idx = maxi(1, Standards.find_semantic_bone(rig, "spine"))
		cpu_surface = ImmediateMesh.new()
		var overlay := MeshInstance3D.new()
		overlay.name = "CPUSkinOverlay"
		overlay.mesh = cpu_surface
		overlay.position = Vector3(0.95, float(pack["ground_y"]), 0.0)
		overlay.rotation.y = float(pack["align_yaw"])
		var omat := StandardMaterial3D.new()
		omat.albedo_color = Color("#48d1b5")
		omat.cull_mode = BaseMaterial3D.CULL_DISABLED
		overlay.material_override = omat
		add_child(overlay)
		_skin_on_cpu()


func _skin_on_cpu() -> void:
	if cpu_surface == null or _cpu_verts.is_empty() or _cpu_indices.is_empty():
		return
	var bone_xf := rig.get_bone_global_pose(_cpu_bone_idx) * rig.get_bone_global_rest(_cpu_bone_idx).affine_inverse()
	cpu_surface.clear_surfaces()
	cpu_surface.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for vi: int in _cpu_indices:
		if vi < 0 or vi >= _cpu_verts.size():
			continue
		var v := _cpu_verts[vi]
		var n := _cpu_normals[vi] if vi < _cpu_normals.size() else Vector3.UP
		var w := clampf((v.y + 0.4) * 0.65, 0.0, 1.0)
		cpu_surface.surface_set_normal(n.lerp(bone_xf.basis * n, w).normalized())
		cpu_surface.surface_add_vertex(v.lerp(bone_xf * v, w))
	cpu_surface.surface_end()


func _create_crowd() -> void:
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	_worker_hero_pack = Standards.spawn_aligned_character(cid, "WorkerLeadHavok", Animation.LOOP_LINEAR)
	var hero_outer: Node3D = _worker_hero_pack["outer"] as Node3D
	hero_outer.position = Vector3(0.0, 0.0, -1.6)
	add_child(hero_outer)
	var hplayer: AnimationPlayer = _worker_hero_pack["player"] as AnimationPlayer
	hplayer.play(StringName(Standards.pick_clip(_worker_hero_pack, str(_spec.get("primary_clip", "run_turn_l")))))

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
			actor.player.advance(delta)
			var base_rot := rig.get_bone_pose_rotation(1)
			var twist := Quaternion(Vector3.UP, sin(elapsed * 2.4) * 0.45 + 0.12)
			rig.set_bone_pose_rotation(1, (base_rot * twist).normalized())
			if "/scaling/" in case_path:
				var s := 1.0 + 0.28 * sin(elapsed * 2.2)
				var head_b := Standards.find_semantic_bone(rig, "head")
				var spine_b := Standards.find_semantic_bone(rig, "spine")
				rig.set_bone_pose_scale(spine_b, Vector3.ONE * s)
				if head_b >= 0:
					rig.set_bone_pose_scale(head_b, Vector3.ONE * (1.0 + 0.40 * sin(elapsed * 2.6)))
			rig.force_update_all_bone_transforms()
			if cpu_surface != null:
				_skin_on_cpu()
		"actor":
			var prev_t := _last_clip_time
			actor.player.advance(delta)
			var cur_t := actor.player.current_animation_position
			_last_clip_time = cur_t
			var movement := Standards.sample_root_motion_delta(actor.pack, _clip_name, prev_t, cur_t)
			if movement.length() < 1e-4:
				# Fallback Godot Standard -Z stride velocity for stationary clips (e.g. idle/attachments)
				movement = Vector3(0.0, 0.0, -1.25 * delta)
			traveled += movement.length()
			if controller != null:
				var vx := movement.x / maxf(delta, 1e-4)
				var vz := movement.z / maxf(delta, 1e-4)
				controller.velocity = Vector3(vx, controller.velocity.y - Standards.GRAVITY_MPS2 * delta, vz)
				controller.move_and_slide()
				if controller.position.z < -2.2:
					controller.position.z = 2.0
			elif "basicmovement" in case_path or "/motionextraction/motionextraction" in case_path:
				heading += (0.55 + Input.get_axis("ui_left", "ui_right")) * delta
				actor.rotation.y = heading
				actor.position += actor.basis * movement
				actor.position.x = wrapf(actor.position.x, -1.8, 1.8)
				actor.position.z = wrapf(actor.position.z, -1.8, 1.8)
			elif not "attachments" in case_path:
				# Advance smoothly along Godot Standard -Z forward track
				actor.position.z = 1.6 - fposmod(traveled, 3.2)
			actor.rig.force_update_all_bone_transforms()


func status_text() -> String:
	var cid := str(_spec.get("primary_char", "havok_girl_sdk"))
	match family:
		"skin":
			var bc := rig.get_bone_count() if rig != null else 0
			return "%s [%s %db] · 본 회전 %.1f°" % [
				"CPU vs GPU 스키닝 비교" if cpu_surface != null else ("실시간 본 스케일링" if "/scaling/" in case_path else "GPU 가중치 메시 스키닝"),
				cid, bc, rad_to_deg(rig.get_bone_pose_rotation(1).get_angle())]
		"worker":
			return "%s [%s 50b] · 12개 리그 × 4개 관절 · %d µs · 직렬 오차 %.6f m" % [
				"단일 스레드" if serial else "WorkerThreadPool", cid, sample_usec, max_difference]
		"actor":
			if "attachments" in case_path:
				return "BoneAttachment3D [%s 50b] · 오른손 소켓 월드 높이 %.2f m" % [cid, actor.tool.global_position.y]
			var desc := "Godot 표준(-Z) 루트 변위 추출"
			if "mirrored" in case_path:
				desc = "좌우 X-평면 반사(-Z 전방) 루트 이동"
			elif "charactercontroller" in case_path:
				desc = "CharacterBody3D(-Z 보행 · g=9.81 m/s²) · 바닥 접촉 %s" % str(controller.is_on_floor())
			elif "basicmovement" in case_path or "/motionextraction/motionextraction" in case_path:
				desc = "회전 + -Z 루트 이동 · 방향키 조향"
			return "%s [%s 50b '%s'] · 누적 %.2f m" % [desc, cid, _clip_name, traveled]
	return ""


func _sample_actor(index: int) -> void:
	for joint in 4:
		samples[index * 4 + joint] = _segment(index, joint)


func _segment(index: int, joint: int) -> Transform3D:
	var p := Vector3((index % 4 - 1.5) * 0.85, 0.12, (floori(index / 4.0) - 1) * 0.75 + 0.6)
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
