@tool
extends RefCounted
## Deterministic 14-step Hero demo authoring replay timeline (14.0 s total).
## Reconstructs scene nodes, inspector properties, state-machine build stage,
## virtual cursor focus, and action log at any arbitrary time (forward or rewind).

const STEP_DURATION := 1.0

const STEPS: Array[Dictionary] = [
	{
		"id": "scan_assets",
		"role": "assets",
		"phase": "search",
		"target": "asset_motion",
		"target_label": "FileSystem · hero_motion.res",
		"caption": "내재화 Hero 85본 리그·5클립(hero_motion.res) 확인",
		"log": "Godot 네이티브 에셋(hero_motion.res, hero_skin.glb) 스캔",
		"nodes": ["HeroDemoRoot"],
		"selected_node": "HeroDemoRoot",
		"inspector": {"scene": "hero_locomotion_studio.tscn", "rig_bones": "0 (빈 씬)"},
		"has_rig": false, "has_skin": false, "has_terrain": false, "has_trail": false,
		"stage": 1, "preview_tick": 0, "editor_dock": "filesystem",
	},
	{
		"id": "add_motion",
		"role": "level",
		"phase": "execute",
		"target": "scene_add_btn",
		"target_label": "SceneTree · + 노드 추가",
		"caption": "루트 모션 컨테이너 Motion(Node3D) 추가",
		"log": "Node3D 'Motion' 생성 (루트 변위·Yaw 적용 대상)",
		"nodes": ["HeroDemoRoot", "  ├─ Motion (Node3D)"],
		"selected_node": "Motion",
		"inspector": {"name": "Motion", "position": "(0.00, 0.00, 0.00)", "rotation.y": "0.0°"},
		"has_rig": false, "has_skin": false, "has_terrain": false, "has_trail": false,
		"stage": 1, "preview_tick": 0, "editor_dock": "scene",
	},
	{
		"id": "add_rig",
		"role": "level",
		"phase": "change",
		"target": "scene_row_rig",
		"target_label": "SceneTree · Motion/Rig",
		"caption": "Skeleton3D 'Rig' 추가 및 85본 바인드 포즈 구성",
		"log": "Skeleton3D 'Rig' 생성 — 85본 계층·Rest Pose 등록",
		"nodes": ["HeroDemoRoot", "  ├─ Motion (Node3D)", "  │   └─ Rig (Skeleton3D · 85본)"],
		"selected_node": "Motion/Rig",
		"inspector": {"bone_count": "85", "motion_scale": "1.00", "resource": "hero_motion.res"},
		"has_rig": true, "has_skin": false, "has_terrain": false, "has_trail": false,
		"stage": 1, "preview_tick": 0, "editor_dock": "inspector",
	},
	{
		"id": "bind_skin",
		"role": "assets",
		"phase": "execute",
		"target": "asset_skin",
		"target_label": "FileSystem · hero_skin.glb",
		"caption": "hero_skin.glb(18,050정점·6텍스처) 스킨 바인딩",
		"log": "MeshInstance3D 6개(10표면, 18,050정점) Rig 스킨 바인딩 완료",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
		],
		"selected_node": "Motion/Rig/HeroSkin",
		"inspector": {"skin_binds": "85 bones", "surfaces": "10", "format": "GLB (embedded PNG)"},
		"has_rig": true, "has_skin": true, "has_terrain": false, "has_trail": false,
		"stage": 1, "preview_tick": 0, "editor_dock": "filesystem",
	},
	{
		"id": "add_terrain",
		"role": "level",
		"phase": "execute",
		"target": "scene_row_terrain",
		"target_label": "SceneTree · Terrain",
		"caption": "공유 시험 지형(평지·계단 2단·경사면 10°) 배치",
		"log": "Terrain(LevelGround, FirstStep, SecondStep, Slope) 배치",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  └─ Terrain (평지 · 계단 · 경사면)",
		],
		"selected_node": "Terrain",
		"inspector": {"LevelGround": "y_top=-0.02m", "FirstStep": "+0.16m", "Slope": "-10.0°"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": false,
		"stage": 1, "preview_tick": 12, "editor_dock": "scene",
	},
	{
		"id": "sm_idle",
		"role": "graph",
		"phase": "target",
		"target": "sm_idle",
		"target_label": "StateMachine · 1. Idle",
		"caption": "상태머신 1단계: Idle 상태(clip: idle) 생성",
		"log": "상태 노드 'Idle' 등록 (clip: idle, 2.83s 루프)",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  └─ LocomotionSM (Idle)",
		],
		"selected_node": "LocomotionSM",
		"inspector": {"initial_state": "idle", "clip": "idle", "duration": "2.83 s"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": false,
		"stage": 1, "preview_tick": 20, "editor_dock": "bottom",
	},
	{
		"id": "sm_idle_to_walk",
		"role": "graph",
		"phase": "execute",
		"target": "sm_i2w",
		"target_label": "StateMachine · 2. Idle→Walk",
		"caption": "걷기 진입 상태(clip: idle_to_walk) 및 4틱 블렌드 연결",
		"log": "전이 'Idle → IdleToWalk' (clip: idle_to_walk, Smoothstep 4틱) 연결",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  └─ LocomotionSM (Idle → IdleToWalk)",
		],
		"selected_node": "LocomotionSM",
		"inspector": {"entry_clip": "idle_to_walk", "blend_in": "4 ticks", "entry_hold": "26 ticks"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": false,
		"stage": 2, "preview_tick": 42, "editor_dock": "bottom",
	},
	{
		"id": "sm_walk",
		"role": "graph",
		"phase": "change",
		"target": "sm_walk",
		"target_label": "StateMachine · 2. Walking",
		"caption": "26틱 후 Walking(clip: walk) 순환 상태 연결",
		"log": "상태 'Walking' (clip: walk, 8틱 Smoothstep 전이) 추가",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  └─ LocomotionSM (Idle/IdleToWalk/Walk)",
		],
		"selected_node": "LocomotionSM",
		"inspector": {"state": "walk", "clip": "walk", "yaw_gain": "2.0 rad/s"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": false,
		"stage": 2, "preview_tick": 72, "editor_dock": "bottom",
	},
	{
		"id": "sm_run",
		"role": "graph",
		"phase": "execute",
		"target": "sm_run",
		"target_label": "StateMachine · 3. Running",
		"caption": "Running(clip: run) 및 Smoothstep 4t/10t 정지 전이 추가",
		"log": "상태 'Running' 추가 — Walk→Run 4틱, Run→Idle 10틱 Smoothstep",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  └─ LocomotionSM (Idle/Walk/Run)",
		],
		"selected_node": "LocomotionSM",
		"inspector": {"state": "run", "walk_to_run": "4t (gain 2.0 유지)", "run_to_idle": "10t Smoothstep"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": false,
		"stage": 3, "preview_tick": 115, "editor_dock": "bottom",
	},
	{
		"id": "sm_camera_lead",
		"role": "graph",
		"phase": "change",
		"target": "sm_cam",
		"target_label": "Pipeline · 3. Camera Lead",
		"caption": "3인칭 카메라 추적 리드 각도 보정 적용",
		"log": "카메라 추적 리드(10*dt, 거리 5.0m) 반영 — 우회전 XZ 드리프트 0.1 mm",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  └─ LocomotionSM (+CameraLead)",
		],
		"selected_node": "LocomotionSM",
		"inspector": {"follow_distance": "5.0 m", "lead_scale": "10 * dt", "xz_drift_215t": "0.1 mm"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": false,
		"stage": 3, "preview_tick": 168, "editor_dock": "inspector",
	},
	{
		"id": "bind_foot_ik",
		"role": "ik",
		"phase": "execute",
		"target": "sm_ik",
		"target_label": "Pipeline · 4. Terrain Foot IK",
		"caption": "지형 레이캐스트 + 스윙 페이즈 2본 발 IK 바인딩",
		"log": "TerrainIK 연결 — 스탠스 접지 보정 + 공중 스윙 보폭 보존",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  ├─ LocomotionSM (+CameraLead)",
			"  └─ TerrainIK (2-Bone + SwingFade)",
		],
		"selected_node": "TerrainIK",
		"inspector": {"feet": "LeftLegFoot, RightLegFoot", "swing_fade": "0.14~0.26 m", "smooth_rate": "4.0 m/s"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": false,
		"stage": 4, "preview_tick": 140, "editor_dock": "bottom",
	},
	{
		"id": "bake_trail",
		"role": "ik",
		"phase": "change",
		"target": "viewport_3d",
		"target_label": "3D Viewport · 255틱 궤적 베이킹",
		"caption": "255틱 입력 시퀀스 베이킹 및 황금색 루트 궤적 생성",
		"log": "255틱(4.25s) 전체 포즈·루트 궤적 링 버퍼 베이킹 완료",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  ├─ LocomotionSM (+CameraLead)",
			"  ├─ TerrainIK (2-Bone + SwingFade)",
			"  └─ RewindTrail (255틱 버퍼)",
		],
		"selected_node": "RewindTrail",
		"inspector": {"recorded_ticks": "255 (60 Hz)", "transitions": "0/31/57/90/202", "state_mismatch": "0 ticks"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": true,
		"stage": 5, "preview_tick": 155, "editor_dock": "viewport",
	},
	{
		"id": "verify_turn_stop",
		"role": "graph",
		"phase": "target",
		"target": "timeline_bar",
		"target_label": "Rewind · 전이 구간 검증",
		"caption": "우회전 달리기(t=150~194) → 정지 블렌드(t=202) 검증",
		"log": "우회전 달리기·Smoothstep 정지(t=212 완전 정지) 궤적 검증",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  ├─ LocomotionSM (+CameraLead)",
			"  ├─ TerrainIK (2-Bone + SwingFade)",
			"  └─ RewindTrail (255틱 버퍼)",
		],
		"selected_node": "RewindTrail",
		"inspector": {"turn_tick": "150..194", "stop_blend": "202..212 (10t)", "root_rms": "0.031 m"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": true,
		"stage": 5, "preview_tick": 204, "editor_dock": "bottom",
	},
	{
		"id": "authoring_done",
		"role": "assets",
		"phase": "success",
		"target": "viewport_3d",
		"target_label": "Hero 데모 에셋 제작 완료",
		"caption": "Hero 로코모션 데모 제작 완료! 타임라인으로 자유 다시보기",
		"log": "제작 과정 리플레이 완료 — 언제든 타임라인을 되감아 재확인 가능",
		"nodes": [
			"HeroDemoRoot",
			"  ├─ Motion (Node3D)",
			"  │   └─ Rig (Skeleton3D · 85본)",
			"  │       └─ HeroSkin (6 메시 · 18,050정점)",
			"  ├─ Terrain (평지 · 계단 · 경사면)",
			"  ├─ LocomotionSM (+CameraLead)",
			"  ├─ TerrainIK (2-Bone + SwingFade)",
			"  └─ RewindTrail (255틱 버퍼)",
		],
		"selected_node": "HeroDemoRoot",
		"inspector": {"status": "READY", "bones": "85", "verts": "18,050", "replay_ticks": "255"},
		"has_rig": true, "has_skin": true, "has_terrain": true, "has_trail": true,
		"stage": 5, "preview_tick": 254, "editor_dock": "viewport",
	},
]


static func total_duration() -> float:
	return float(STEPS.size()) * STEP_DURATION


static func step_count() -> int:
	return STEPS.size()


static func evaluate_at(time_sec: float) -> Dictionary:
	var total := total_duration()
	var t := clampf(time_sec, 0.0, total)
	var idx := clampi(int(floor(t / STEP_DURATION)), 0, STEPS.size() - 1)
	var local_u := clampf((t - float(idx) * STEP_DURATION) / STEP_DURATION, 0.0, 1.0)
	var step: Dictionary = STEPS[idx]

	# Click ripple peaks right as cursor arrives (local_u in 0.25..0.65)
	var click_pulse := 0.0
	if local_u >= 0.25 and local_u <= 0.70:
		click_pulse = 1.0 - (local_u - 0.25) / 0.45

	# Smoothly advance preview_tick inside the active step for live motion feel
	var base_tick: int = int(step.preview_tick)
	var next_tick: int = int(STEPS[mini(idx + 1, STEPS.size() - 1)].preview_tick)
	var preview_tick := base_tick
	if idx >= 5 and next_tick > base_tick:
		preview_tick = int(round(lerpf(float(base_tick), float(next_tick), local_u)))

	var logs: Array[String] = []
	for i in idx + 1:
		var s: Dictionary = STEPS[i]
		var role_tag := "에셋"
		match s.role:
			"level": role_tag = "리그·씬"
			"graph": role_tag = "상태머신"
			"ik": role_tag = "물리·IK"
		logs.append("[%02d:%02d] [%s] %s" % [i, 0, role_tag, s.log])

	return {
		"time": t,
		"duration": total,
		"step_index": idx,
		"local_u": local_u,
		"click_pulse": click_pulse,
		"step": step,
		"preview_tick": preview_tick,
		"logs": logs,
	}
