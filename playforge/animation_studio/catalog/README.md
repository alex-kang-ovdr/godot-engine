# Havok Animation · Behavior 사례 갤러리 (414개 전 항목 원본 에셋 내재화 · Godot 표준 정렬)

Godot 4.7.2에서 [프로젝트](../project.godot)를 열고 F5를 누른 뒤 **애니메이션 사례 목록 →**을 선택한다. [갤러리 씬](gallery.tscn)을 F6로 직접 실행할 수도 있다. 각 항목은 출처와 내재화된 원본 Havok 에셋 ID, Godot 표준 좌표계/카메라/루프 기본값, 실시간 실행 지표를 표시한다. 제품 필터(`Animation` / `Behavior`), 분야 필터, 영문 이름·경로 검색을 조합할 수 있다.

## 엔진 영향 범위

- **`[엔진 수정]`**: **없음 (0건)**
- **`[엔진 추가]`**: **없음 (0건)**
- **`[확장 추가]`**: `catalog/havok_demo_standards.gd` (`HavokDemoStandards`), `characters/assets/havok_girl_sdk.glb` / `havok_girl_sdk_motion.res` (50본·12클립), `characters/assets/crabby.glb` / `crabby_motion.res` (18본), `tests/havok_port_parity_verify.gd`
- **`[확장 수정]`**: `catalog/gallery.gd`, `catalog/clip_cases.gd`, `catalog/rig_cases.gd`, `catalog/runtime_cases.gd`, `catalog/timing_cases.gd`, `catalog/behavior_cases.gd`, `characters/character_store.gd` (`CharacterRosterStore`), `characters/catalog.json`, `tests/character_roster_verify.gd`, `tests/animation_gallery.gd`, `playforge/tests/run.py`, `build_and_test_local_fork.cmd`

## Havok 2015.1.0-r1 SDK vs Godot 4.7.2 기본값 통일표 (`HavokDemoStandards`)

| 항목 | Havok 2015.1.0-r1 SDK 기본값 | 기존 Godot 포팅 차이 | 통일된 Godot 표준 (`HavokDemoStandards`) |
| :--- | :--- | :--- | :--- |
| **좌표계 & 캐릭터 전방** | Z-up 3ds Max (~95%, `-Y` 전방) + Y-up Maya (~5%, `+X`/`+Z` 전방) | 캐릭터마다 raw 전방 혼재(`+Z`/`+X`/`-Z`), 일부 지면 오프셋 불일치 | **Godot 표준(`+Y` 상향, `-Z`/`Vector3.FORWARD` 전방, `+X` 우측, 오른손 좌표계)**. 전 30종 `ModelAlign` yaw 정렬 + 발바닥 `Y = 0.0 m` 접지 + 추출 루트 모션 `-Z` 전진 통일 |
| **카메라** | `hkgCamera::DEFAULT_FOV = 45.0°` 수직 FOV, `near = 0.1 m`, `far = 100.0 m`, 데모별 `(from, to, up)` | 단일 고정 카메라 `(3.5, 2.2, 5.0)`, `fov = 39°` | **`Camera3D.fov = 45.0°`**, **`keep_aspect = KEEP_HEIGHT`**, **`near = 0.1 m`**, **`far >= 100.0 m`**, **`up = Vector3.UP`**, 데모별 원본 `(from, to)`를 Godot `-Z` 전면 3/4 구도로 변환·적용 |
| **단위 & 물리** | SI `1.0 = 1.0 m`, 중력 `-9.81 m/s²`, 고정 `60 Hz` | 일부 `9.8 m/s²` 및 비표준 스케일 혼용 | 전 데모 **SI `1.0 m`**, 중력 **`9.81 m/s² (-Y)`**, 고정 **`60 Hz`** 통일 |
| **루프 기본값** | `hkaDefaultAnimationControl` (`maxCycles = 0`) · `hkbClipGenerator` (`MODE_LOOPING`) 기본 순환 | Godot `Animation` 기본값 `LOOP_NONE (0)`으로 전 83클립 정지 | 순환 클립 기본 **`Animation.LOOP_LINEAR`**, 원샷 액션(`protect`/`vault`/`slash` 등) **`LOOP_NONE`**, PingPong 데모(`ClipGeneratorModes`/`PingPongSync`/`AnimationTest`) **`LOOP_PINGPONG`** |

## 대상과 내재화 에셋 매핑 (총 121소스 · 414항목, 합성 로봇 0건, `.hkt`/SDK 런타임 의존성 0건)

Havok 2015.1.0-r1 SDK의 `Demo/Demos/Animation`(62소스·276항목)과 `Demo/Demos/Behavior`(59소스·138항목) 전체 **414개** 항목을 내재화된 **30종 원본 Havok SDK 캐릭터(`.glb` + 압축 `.res`)**로 구동한다.

| 제품 · 원본 분야 | 내재화 원본 에셋 | Godot에서 실행하는 동작 |
| :--- | :--- | :--- |
| Animation · Playback, Blending, LayeringAndPartitions, Compression | `havok_girl_sdk` (50본 · 12클립) | `AnimationNodeBlend2`/`Add2`, 상체 트랙 마스크, X-평면 좌우 미러링, `Animation.compress(16384, 60, 0.5)`, 발소리 메서드 이벤트·속성/런타임 바인딩 |
| Animation · InverseKinematics (`Crabby`, `FootIk`, `LookAt`, `Reaching`) | `crabby` (18본), `havok_girl_sdk` (50본) | SpiderCrab 양측 `TwoBoneIK3D`, `FootIk` (`0.80x` 보행 + 지형 스텝), `LookAtModifier3D` 시선 추적, 왼팔 `TwoBoneIK3D` 리치 |
| Animation · Retargeting, SkeletalMapping | `shulgoth`+`male_nocape`, `singer`+`gingerbread`, `female_dress`+`male_nocape`, `bigbad`+`boy`, `havok_girl_sdk`+`firefighter` | 모델 공간 시맨틱 리타게팅 + 발 접지 보정 + 내장 `RetargetModifier3D` (`SkeletonProfileHumanoid`) |
| Animation · Ragdoll (`Dismemberment`, `ConstraintMatching`, 일반) | `zombie` (89본), `firefighter` (38본), `havok_girl_sdk` (50본) | 실제 스켈레톤 `PhysicalBoneSimulator3D` (SI `9.81 m/s²`, 핀/콘 관절, 활성/포즈 핸드오프) |
| Animation · MotionExtraction, Skinning, Scaling, Multithreading, Timings | `havok_girl_sdk` (50본), `firefighter` (38본) | `-Z` 표준 추출 루트 모션 + `CharacterBody3D`, CPU vs GPU 스키닝 비교, 본 스케일링, `WorkerThreadPool` 12레인 병렬/압축 샘플링 |
| Behavior · Hero ShowCase, Docking, Drivers, MovingPlatforms, Determinism | `hero` (85본 · 18,050정점) | Godot `-Z` 정렬 원본 Hero 쇼케이스, `-Z` 도킹 모션 워핑, `CharacterBody3D`·손/발 `TwoBoneIK3D`, 이동 플랫폼, 2인스턴스 결정성 대조 |
| Behavior · Quadruped (`QuadrupedDemo`, `SmoothNonPlanarTerrain`, `RotatingPlatform`) | `siege_fiend` (34본) | 원본 4족 SiegeFiend 4개 다리 체인(`UpperArm`/`Thigh`) 실 `TwoBoneIK3D` + 지형/회전 플랫폼 레이캐스트 접지 |
| Behavior · Generators, StateMachine, SaveState, ActiveRagdoll, GunSweep | `soldier` (114본) | `LOOP_LINEAR`/`LOOP_PINGPONG`/`LOOP_NONE` 생성기, `AnimationTree` 블렌더, `PoseGraph` 상태 전이·`ReturnToPrevious`·`SyncStart`, `RewindRecorder`, `ActiveRagdollJoint` |
| Behavior · Modifiers (`CharacterToCharacter`), Retargeting, SwapSkins, Crowd | `flying_imp`+`hivequeen`, `boy`+`girl`, `female_dress`+`ponytail`, `male_cape`+`nocape`, `firefighter`/`desert_dan`/`jungle_joe`/`snow_sam`, `orc_captain`, `ninja_blue` | `BoneAttachment3D` 캐릭터 간 부착, 실제 38본 공용 리그 런타임 `.glb` 스킨 스왑, C++ GDExtension `AnimationStudioCrowdEvaluator` 16체 병렬 군중 평가 |

## 재현과 검증

```powershell
python playforge/tests/run.py --only animation_character_roster,animation_havok_port_parity,animation_gallery
```

- `animation_character_roster`: 내재화 30종 전 캐릭터 로드, Float32 vs 16-bit C++ 정밀도 및 메모리 절감 검증.
- `animation_havok_port_parity`: 합성 로봇/SDK 의존성 0건, 30종 SI 스케일·지면 `Y=0` 접지, `-Z` 루트 모션 전진 방향, `havok_girl_sdk` 50본 포즈 패리티, 루프 기본값 3종, `45° KEEP_HEIGHT` 전면 카메라 패리티 검증.
- `animation_gallery`: 414개 전 항목 + 필터·복귀 (**422/422 PASS**, 엔진 오류 0건).
