@tool
extends RefCounted
## Deterministic 14-step Procedural Quadruped Locomotor Authoring Replay (14.0s).
## Modeled after Unreal Engine's "Procedural Animation with a Locomotor" (EkxO):
## builds from an empty scene -> 28-bone quadruped wireframe -> articulated creature body ->
## obstacle terrain -> Control Rig Locomotor Node (Foot Sets, Walk/Trot/Gallop gaits,
## Pelvis/Spine terrain pitch & roll) -> 4-Limb FBIK -> 300-tick trajectory & zero-slide verification.

const STEP_DURATION := 1.0

const STEPS: Array[Dictionary] = [
	{
		"id": "init_blueprint",
		"role": "assets",
		"phase": "search",
		"target": "asset_rig",
		"target_label": "Asset Manager · quadruped_rig.gd",
		"caption": "절차적 4족 리그·Locomotor 설계 확인 (키프레임 클립 0개)",
		"log": "절차적 모듈(quadruped_rig.gd, quadruped_locomotor.gd) 스캔 — 클립 0개",
		"nodes": ["QuadrupedDemoRoot"],
		"selected_node": "QuadrupedDemoRoot",
		"inspector": {"mode": "100% Procedural", "animation_clips": "0", "reference": "UE Locomotor (EkxO)"},
		"has_rig": false, "has_body": false, "has_terrain": false, "has_gizmos": false, "has_trail": false,
		"stage": 1, "preview_tick": 0, "editor_dock": "filesystem",
	},
	{
		"id": "add_root",
		"role": "level",
		"phase": "execute",
		"target": "scene_add_btn",
		"target_label": "Scene Hierarchy · + 노드 추가",
		"caption": "루트 이동 드라이버 LocomotorRoot(Node3D) 추가",
		"log": "Node3D 'LocomotorRoot' 생성 (속도·Yaw 스프링 적분기)",
		"nodes": ["QuadrupedDemoRoot", "  ├─ LocomotorRoot (Node3D)"],
		"selected_node": "LocomotorRoot",
		"inspector": {"name": "LocomotorRoot", "max_speed": "4.9 m/s", "yaw_damping": "5.0 rad/s"},
		"has_rig": false, "has_body": false, "has_terrain": false, "has_gizmos": false, "has_trail": false,
		"stage": 1, "preview_tick": 0, "editor_dock": "scene",
	},
	{
		"id": "build_skeleton",
		"role": "level",
		"phase": "change",
		"target": "scene_row_rig",
		"target_label": "Scene Hierarchy · QuadrupedRig (28본)",
		"caption": "28본 4족 스켈레톤(척추·머리·꼬리·앞/뒷다리 4체인) 생성",
		"log": "Skeleton3D 28본 구성 — 앞다리 뒤굽힘·뒷다리 앞굽힘 해부학 비율",
		"nodes": ["QuadrupedDemoRoot", "  ├─ LocomotorRoot (Node3D)", "  │   └─ QuadrupedRig (28본 와이어프레임)"],
		"selected_node": "QuadrupedRig",
		"inspector": {"bones": "28 (Spine 12 + Legs 16)", "ride_height": "0.78 m", "limb_len": "0.43 + 0.43 m"},
		"has_rig": true, "has_body": false, "has_terrain": false, "has_gizmos": false, "has_trail": false,
		"stage": 1, "preview_tick": 0, "editor_dock": "inspector",
	},
	{
		"id": "bind_body",
		"role": "assets",
		"phase": "execute",
		"target": "asset_locomotor",
		"target_label": "Asset Manager · 절차적 크리처 외형",
		"caption": "28본 관절 장갑·바이저·꼬리·발바닥 메시 바인딩",
		"log": "BoneAttachment3D 기반 크리처 바디·관절 링·발 패드 부착 완료",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
		],
		"selected_node": "CreatureBody",
		"inspector": {"attachments": "28 bones", "legs": "FL, FR, HL, HR", "clips_used": "0 (100% procedural)"},
		"has_rig": true, "has_body": true, "has_terrain": false, "has_gizmos": false, "has_trail": false,
		"stage": 1, "preview_tick": 8, "editor_dock": "filesystem",
	},
	{
		"id": "add_terrain",
		"role": "level",
		"phase": "execute",
		"target": "scene_row_terrain",
		"target_label": "Scene Hierarchy · CourseTerrain",
		"caption": "계단 2단(+0.18/+0.32m)·경사로·측면 능선 시험 지형 배치",
		"log": "CourseTerrain(LevelGround, Step1, Step2, Ramp, Ridge) 배치",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  └─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
		],
		"selected_node": "CourseTerrain",
		"inspector": {"Step1": "+0.18 m", "Step2": "+0.32 m", "LateralRidge": "+0.24 m sine bump"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": false, "has_trail": false,
		"stage": 1, "preview_tick": 18, "editor_dock": "scene",
	},
	{
		"id": "add_foot_sets",
		"role": "graph",
		"phase": "target",
		"target": "loco_front",
		"target_label": "Locomotor · Foot Set 0 (Front) & 1 (Hind)",
		"caption": "UE Locomotor 노드 등록: 앞다리(FL/FR)·뒷다리(HL/HR) Foot Set 분리",
		"log": "Foot Set 0(FL, FR) · Foot Set 1(HL, HR) 앵커 및 예측 보폭 타깃 연결",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  └─ LocomotorNode (FootSet 0/1)",
		],
		"selected_node": "LocomotorNode",
		"inspector": {"FootSet0": "FL, FR (front)", "FootSet1": "HL, HR (hind)", "stance_lock": "World-locked (0mm slide)"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": false,
		"stage": 1, "preview_tick": 40, "editor_dock": "bottom",
	},
	{
		"id": "setup_walk_gait",
		"role": "graph",
		"phase": "execute",
		"target": "loco_gait",
		"target_label": "Locomotor · 4-Beat Walk Gait",
		"caption": "4박자 걷기(Walk) 위상 오프셋 [0.50, 0.00, 0.25, 0.75] 구성",
		"log": "Walk 보법 설정 — Duty 72% (항상 3발 이상 접지), 발 미끄러짐 0mm 잠금",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  └─ LocomotorNode (Walk 4-Beat)",
		],
		"selected_node": "GaitScheduler",
		"inspector": {"gait": "Walk (4-beat)", "phases": "FL.50 FR.00 HL.25 HR.75", "duty_factor": "0.72"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": false,
		"stage": 1, "preview_tick": 65, "editor_dock": "bottom",
	},
	{
		"id": "setup_trot_gait",
		"role": "graph",
		"phase": "change",
		"target": "loco_hind",
		"target_label": "Locomotor · Diagonal Trot Gait",
		"caption": "대각선 속보(Trot: FL+HR / FR+HL 쌍) 및 속도 비례 주기 연결",
		"log": "Trot 보법 추가 — 대각선 위상 [0.0, 0.5, 0.5, 0.0], 스윙 포물선 0.20m",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  └─ LocomotorNode (Walk ↔ Trot)",
		],
		"selected_node": "GaitScheduler",
		"inspector": {"gait": "Trot (diagonal)", "pairs": "FL+HR & FR+HL", "step_height": "0.20 m"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": false,
		"stage": 2, "preview_tick": 122, "editor_dock": "bottom",
	},
	{
		"id": "setup_gallop",
		"role": "graph",
		"phase": "execute",
		"target": "cp_gait",
		"target_label": "Control Param · Gallop & Turn Banking",
		"caption": "비대칭 습보(Gallop) 위상 [0.00, 0.18, 0.55, 0.72] 및 선회 뱅킹 추가",
		"log": "Gallop 보법(Duty 40%, 부유 구간) 및 고속 선회 원심 뱅킹 활성화",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  └─ LocomotorNode (Walk/Trot/Pace/Gallop)",
		],
		"selected_node": "CP: GaitPreset",
		"inspector": {"gait": "Gallop (rotary)", "phases": "0.00 / 0.18 / 0.55 / 0.72", "duty_factor": "0.40"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": false,
		"stage": 3, "preview_tick": 235, "editor_dock": "bottom",
	},
	{
		"id": "pelvis_spine_dynamics",
		"role": "ik",
		"phase": "change",
		"target": "loco_pelvis",
		"target_label": "Locomotor · Pelvis & Spine Dynamics",
		"caption": "골반 높이·지형 피치/롤·척추 S-웨이브·머리 수평 안정화·꼬리 파동",
		"log": "PelvisSettings 활성화 — 앞/뒤 발 높이차 피치, 좌/우 롤, 머리 역보정",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  ├─ LocomotorNode (4 Gaits)",
			"  └─ PelvisSpineDynamics (Pitch/Roll/Tail)",
		],
		"selected_node": "Pelvis & Spine",
		"inspector": {"ride_height": "0.78 m", "terrain_pitch": "±28°", "head_stabilize": "counter-pitch 80%"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": false,
		"stage": 3, "preview_tick": 145, "editor_dock": "inspector",
	},
	{
		"id": "bind_fbik_terrain",
		"role": "ik",
		"phase": "execute",
		"target": "node_fbik",
		"target_label": "Pipeline · 4-Limb FBIK + Terrain Raycast",
		"caption": "4다리 Pole-Vector 2본 FBIK + 계단/경사 지형 레이캐스트 결합",
		"log": "4다리 FBIK 연결 — 앞팔 뒤굽힘(+Z)·뒷무릎 앞굽힘(-Z) 극벡터 + 계단 등반",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  ├─ LocomotorNode (4 Gaits)",
			"  ├─ PelvisSpineDynamics (Pitch/Roll/Tail)",
			"  └─ FourLimbFBIK (+TerrainRaycast)",
		],
		"selected_node": "4-Limb FBIK",
		"inspector": {"front_pole": "+Z (backward elbow)", "hind_pole": "-Z (forward stifle)", "step_clearance": "sine + terrain boost"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": false,
		"stage": 4, "preview_tick": 108, "editor_dock": "bottom",
	},
	{
		"id": "bake_course_trail",
		"role": "ik",
		"phase": "change",
		"target": "viewport_3d",
		"target_label": "3D Viewport · 300틱 코스 궤적 & 발 타깃",
		"caption": "300틱(5.0s) 전체 코스 베이킹: 걷기→계단 속보→우회전 능선→습보→정지",
		"log": "300틱 28본 포즈·발 타깃 링·지지 다각형·루트 궤적 베이킹 완료",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  ├─ LocomotorNode (4 Gaits)",
			"  ├─ PelvisSpineDynamics (Pitch/Roll/Tail)",
			"  ├─ FourLimbFBIK (+TerrainRaycast)",
			"  └─ RewindTrail (300틱 버퍼)",
		],
		"selected_node": "RewindTrail",
		"inspector": {"recorded_ticks": "300 (60 Hz)", "gaits": "Idle→Walk→Trot→Gallop→Idle", "foot_slide": "0.0 mm"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": true,
		"stage": 5, "preview_tick": 188, "editor_dock": "viewport",
	},
	{
		"id": "verify_gait_tracks",
		"role": "graph",
		"phase": "target",
		"target": "timeline_bar",
		"target_label": "Gait Tracks · 4발 위상 & 무미끄러짐 검증",
		"caption": "하단 5트랙 도프시트에서 FL/FR·HL/HR 대각선 위상과 지형 피치 검증",
		"log": "4발 접지·스윙 트랙 및 Pelvis Pitch 지형 적응 곡선 검증 완료",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  ├─ LocomotorNode (4 Gaits)",
			"  ├─ PelvisSpineDynamics (Pitch/Roll/Tail)",
			"  ├─ FourLimbFBIK (+TerrainRaycast)",
			"  └─ RewindTrail (300틱 버퍼)",
		],
		"selected_node": "GaitTracks",
		"inspector": {"walk_planted": ">= 3/4 paws", "trot_pairing": "FL+HR / FR+HL", "max_slide_mm": "0.0 mm"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": true,
		"stage": 5, "preview_tick": 244, "editor_dock": "bottom",
	},
	{
		"id": "done",
		"role": "assets",
		"phase": "success",
		"target": "viewport_3d",
		"target_label": "절차적 4족 Locomotor 제작 완료",
		"caption": "절차적 4족 보행 로코모션 완성! 보법 전환 및 타임라인 자유 다시보기",
		"log": "제작 과정 리플레이 완료 — Walk/Trot/Pace/Gallop 전환 및 되감기 가능",
		"nodes": [
			"QuadrupedDemoRoot",
			"  ├─ LocomotorRoot (Node3D)",
			"  │   └─ QuadrupedRig (28본)",
			"  │       └─ CreatureBody (절차적 장갑·관절)",
			"  ├─ CourseTerrain (평지 · 2단 계단 · 경사 · 능선)",
			"  ├─ LocomotorNode (4 Gaits)",
			"  ├─ PelvisSpineDynamics (Pitch/Roll/Tail)",
			"  ├─ FourLimbFBIK (+TerrainRaycast)",
			"  └─ RewindTrail (300틱 버퍼)",
		],
		"selected_node": "QuadrupedDemoRoot",
		"inspector": {"status": "READY", "bones": "28", "clips": "0 (100% Procedural)", "ticks": "300"},
		"has_rig": true, "has_body": true, "has_terrain": true, "has_gizmos": true, "has_trail": true,
		"stage": 5, "preview_tick": 292, "editor_dock": "viewport",
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

	var click_pulse := 0.0
	if local_u >= 0.25 and local_u <= 0.70:
		click_pulse = 1.0 - (local_u - 0.25) / 0.45

	var base_tick: int = int(step.preview_tick)
	var next_tick: int = int(STEPS[mini(idx + 1, STEPS.size() - 1)].preview_tick)
	var preview_tick := base_tick
	if idx >= 5 and next_tick != base_tick:
		preview_tick = int(round(lerpf(float(base_tick), float(next_tick), local_u)))

	var logs: Array[String] = []
	for i in idx + 1:
		var s: Dictionary = STEPS[i]
		var role_tag := "에셋"
		match s.role:
			"level": role_tag = "리그·씬"
			"graph": role_tag = "Locomotor"
			"ik": role_tag = "FBIK·지형"
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
