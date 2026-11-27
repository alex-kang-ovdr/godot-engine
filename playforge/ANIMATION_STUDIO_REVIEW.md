# Animation Studio 아키텍처·구현 계획 검토

2026-11-25 · `Forge-Refactoring-AnimationStudio` · 검토 기준은 엔진 포크 `Forge-Refactoring`의 `814b87c8` (Godot 4.7.2-stable)이다.

**검토 결론** — 기존 AnimationPlayer가 컷신·오디오·속성 트랙을 계속 재생하고, 선택한 캐릭터만 별도 포즈 평가기를 쓰는 하이브리드 방식을 시범 검증한다. 첫 판단 기준은 같은 씬에서 포즈·이동·이벤트를 중복 적용하지 않고 내장 IK까지 연결할 수 있는지다. ACL 도입, 엔진 패치, 12개월 일정은 이 검토로 확정하지 않는다.

## 두 자료에서 가져온 판단

| 자료 | 원안의 제안 | 이 브랜치의 판단 |
| --- | --- | --- |
| [런타임 및 에디터 아키텍처 전략 보고서](https://share.gemini.google/nNdnngUeYfi4) | 기존 AnimationTree 개선, 전면 대체, 하이브리드를 비교한다. Havok·NaturalMotion의 저작/실행 분리, Unity·Unreal의 병렬 평가와 디버깅을 참고해 하이브리드를 권한다. | 기존 캐릭터로 기준 성능을 측정하고 기존 상태 머신의 현재 상태·재생 위치부터 관찰한다. 포즈 평가와 씬 적용을 나눌 실익이 확인되는 캐릭터만 확장 대상으로 삼는다. |
| [차세대 캐릭터 애니메이션 시스템 구현 계획서](https://share.gemini.google/H2oOAslpBRHn) | GDExtension에서 클립을 굽고 워커가 포즈를 계산한다. 내장 모디파이어·Jolt·편집기와 연결한 뒤 몽타주, Rewind, 군중 LOD로 확장한다. | 공개 API에서 작은 수직 경로를 먼저 검증한다. 별도 포즈 버퍼를 도입해도 스켈레톤에 쓰는 비용, 물리 틱 동기화, 이벤트 전달 비용은 따로 남는다. |

## 엔진 소스와 대조한 결정

| 쟁점 | 기준 커밋에서 확인한 동작 | 적용 판단 |
| --- | --- | --- |
| 포즈 소유권 | `Skeleton3D::_find_modifiers()`는 직계 자식 중 모디파이어를 트리 순서로 수집한다. `_process_modifiers()`는 차례로 호출하고 포즈를 갱신한다. 공개 `set_bone_pose()`의 인자는 본 하나다. [스켈레톤 구현](../scene/3d/skeleton_3d.cpp) | 기본 포즈 주입기를 해당 스켈레톤의 첫 **모디파이어**로 둔다. 같은 본을 구동하는 기존 트랙은 명시적으로 분리하고 속성·오디오 트랙은 보존한다. 워커는 포즈 버퍼만 계산하고 메인 스레드의 본별 적용 시간을 별도 계측한다. |
| 리타게팅과 IK | `RetargetModifier3D`는 부모 스켈레톤 갱신 중 대상 자식 스켈레톤에 매핑된 포즈를 쓴다. 대상 포즈를 보정하는 모디파이어는 대상 스켈레톤 아래에 둔다. [리타게팅 계약](../doc/classes/RetargetModifier3D.xml) | 원본 스켈레톤에서 기본 포즈를 만든 뒤 대상의 TwoBoneIK3D와 SpringBoneSimulator3D를 평가한다. 씬 전체를 하나의 모디파이어 목록으로 자동 정렬하면 계층 간 의존성을 놓친다. |
| 재임포트·이벤트·루트 모션 | 씬 후처리 훅 `_post_process`와 AnimationMixer의 루트 모션 추출 API가 있다. [임포트 훅](../doc/classes/EditorScenePostImportPlugin.xml) · [루트 모션 API](../doc/classes/AnimationMixer.xml) | 가져온 AnimationLibrary는 보존하고 파생 클립만 재생성한다. 루트 변위는 물리 틱마다 한 공급자에서 한 번 소비한다. 메서드·오디오 키를 원본에 남길지 이벤트 큐로 옮길지 트랙별로 정하고 루프·전환·취소 경계에서 호출 횟수를 센다. |
| 디버거와 캡처 시점 | 상태 머신은 현재 노드와 재생 위치를 제공한다. 엔진은 모디파이어 처리 후 `skeleton_updated`를 보내고 스킨 갱신 후 원래 포즈를 복구한다. 디버거는 접두어별 메시지 캡처를 지원한다. [상태 머신](../doc/classes/AnimationNodeStateMachinePlayback.xml) · [갱신 순서](../scene/3d/skeleton_3d.cpp) · [디버거 채널](../doc/classes/EditorDebuggerPlugin.xml) | 첫 도구는 선택 캐릭터의 상태·틱·루트 변위를 보여준다. 최종 포즈는 갱신 신호 안에서 복사해 고정 용량 버퍼에 넣는다. Rewind는 기록을 미리보기에서 재생하며, 같은 입력을 다시 시뮬레이션했을 때의 결정성은 별도 시험한다. |
| 로컬 보조 물리와 능동 랙돌 | 내장 SpringBoneSimulator3D와 PhysicalBoneSimulator3D가 있다. PhysicalBone3D에 6DOF 설정이 있어도 내부 관절을 공개 API로 취득해 목표 포즈를 구동할 수 있는지는 별도 문제다. [PhysicalBone3D 공개 API](../doc/classes/PhysicalBone3D.xml) · [관절 구현](../scene/3d/physics/physical_bone_3d.cpp) | 장식물은 내장 스프링으로 시작한다. 능동 랙돌은 관절 하나에서 공개 API로 목표 추종·토크 제한·순간이동 리셋을 검증한 뒤 범위를 정한다. RBAN과 전신 랙돌은 같은 본을 동시에 제어하지 않도록 적용 대상을 지정한다. |

## 착수 순서와 통과 조건

1. **기준 씬과 공존 시험.** 동일 클립으로 기존 AnimationTree와 확장 평가기를 각각 재생한다. 고정 물리 틱에서 본별 위치·회전 오차, 누적 루트 변위, 이벤트 횟수를 기록한다. 루프 경계와 컷신 진입·복귀에서도 이동·이벤트가 한 번씩 반영되고, 같은 틱에 대상 IK가 새 포즈를 읽어야 한다. 재임포트 전후에는 본 매핑·사용자 오버라이드·이벤트 키를 비교한다.
2. **그래프와 저작 도구.** 위 조건을 만족하면 슬롯 하나와 상체 마스크 하나로 이동 중 공격을 검증한다. 관성 블렌딩은 전환 직전·직후의 포즈와 평가한 클립 수로 판단한다. 기본 상태 조회로 설명하기 어려운 전환부터 그래프 강조 표시와 Rewind 기록을 추가한다.
3. **성능과 물리 확장.** 동일 장비·빌드·클립·가시성 조건에서 기본 경로와 확장 경로를 비교한다. 원안의 **65본 × 200체, 메인 스레드 1.5 ms 이하**, **비압축 대비 메모리 70~85% 절감**은 목표치다. 워커 평가, 워커 대기, 메인 스레드 포즈 적용의 p50/p95와 상주 클립 바이트·복원 오차를 남긴다. 압축은 내장 `Animation.compress()`도 비교군에 포함한다. 릴리스 내보내기에서 에디터 의존성과 디버그 캡처 비용을 확인한 뒤 LOD·모션 매칭의 우선순위를 정한다. [내장 클립 압축](../doc/classes/Animation.xml)

## 첫 구현과 검증 기록 · 2026-11-25

[공존 런타임과 재현 명령](animation_studio/README.md)을 추가했다. Windows x64 디버그용 C++ 샘플러와 GDScript 경로는 같은 클립 분리·재생 시계를 쓴다. 압축 본 채널은 파생 클립에서 비활성화해 이중 평가를 피한다.

| 시험 | 확인한 결과 |
| --- | --- |
| 기본 AnimationTree 대조 | 기본 경로와 새 경로에서 같은 클립을 60 Hz로 90틱 재생했다. 위치·회전·스케일 차이는 비압축과 내장 압축 모두 허용 오차 이내였다. |
| 루프·컷신·모디파이어 | 0.25초씩 7회 진행한 루프에서 루트 이동은 3.5, 이벤트는 2회였다. 컷신 복귀 시 임시 클립은 0초에서 다시 시작했다. 별도 팔 리그에서 두 틱 연속 원본 포즈가 대상에 전달됐고 같은 틱의 IK가 손을 목표로 이동시켰다. |
| glTF 재임포트 | 이동 키의 끝값이 2.25에서 4.0으로 바뀌고 사용자 트랙의 2.25는 보존됐다. 재바인딩한 두 트랙의 중간 샘플은 각각 2.0과 1.125였다. |

테스트에 사용한 엔진은 4.7.2 디버그 실행 파일(`31e7ebb19`)이다. 이번 단계에서는 엔진 코어를 다시 빌드하지 않았다. 대규모 군중 성능, 릴리스 내보내기, 관성 블렌딩·물리 구동·Rewind는 후속 검증 대상이다.

## Havok 애니메이션 데모 대조 · 2026-11-26

[Godot 사례 갤러리](animation_studio/catalog/README.md)에서 Havok 2015.1.0-r1의 애니메이션 데모 소스 62개를 원본 경로로 추적할 수 있다. 등록 선언 115개를 변형별로 펼친 276개 선택 항목에 SDK 기능 설정에 따라 등록되는 40개가 포함된다.

블렌딩은 AnimationTree, 리타게팅은 RetargetModifier3D, 랙돌은 물리 본 체인으로 동작을 확인한다. 헤드리스 순회 시험은 각 항목의 장면 생성과 표시 상태를 확인하고, 분야별로 블렌드 트리 생성, 워커 계산 결과, 뼈 회전 또는 루트 이동을 추가 검사한다. 같은 Godot 실험을 공유하는 변형이 있어 항목 수를 독립 구현 수로 해석할 수 없다. Havok 코덱의 비트 단위 호환성, 전신 랙돌의 구동 정확도, 원본 하드웨어 성능은 별도 검증 대상이다.

포크 바이너리 `31e7ebb19`에서 애니메이션 테스트 5종을 2회 실행해 총 774개 검사가 통과했다. 네이티브 확장과 임포트 캐시를 제외한 프로젝트 사본에서도 공식 Godot 4.7.2로 갤러리 검사 282개가 통과했다.

## Hero 원본 에셋 대조 · 2026-11-26

[Hero 재생 씬과 재현 절차](animation_studio/hero/README.md)는 Behavior 쇼케이스의 원본 Rig.hkt와 idle·walk·run·turn 클립을 사용한다. 85본에 바인딩된 메시 6개(10개 표면, 정점 18,050개)와 디퓨즈 텍스처 6개를 변환했다. 실행 시 SDK가 샘플링한 기준 포즈로 이동해 Godot 재생 결과와 비교할 수 있다.

4개 클립에서 시작·끝과 키 사이의 기준 시각 18개를 골라 본 포즈 1,530개를 비교했다. Godot 4.7.2 공식 빌드에서 최대 로컬 위치 오차는 0.00012 mm, 회전 오차는 0.0185° 이하였다. 루트 이동의 최대 위치 오차도 0.00012 mm 이하였다. 별도 사본에서 걷기 기준 골반 위치를 20 mm 변경했을 때 걷기 검사만 실패했다. 원본 Behavior 그래프가 제어기 및 IK를 적용한 결과는 이 클립 시험의 비교 대상에 포함하지 않았다.

## Hero 이동과 지형 발 IK · 2026-11-26

[Hero 이동 재생 및 대조 절차](animation_studio/hero/README.md)를 추가했다. 동일한 스틱·트리거 시퀀스 255틱으로 대기·걷기·달리기·방향 전환·정지를 재생하고, 평지·계단·경사면에서 발목 위치를 보정한다. Godot 4.7.2 공식 빌드와 포크에서 이동·발 IK 검사 7개를 통과했다. 원본 Hero Behavior 대조 실행기는 빌드됐으나 SDK의 `hkb` 제품 키 검증 오류로 기준 트레이스를 만들지 못했다. 따라서 원본 상태 전이 시점과 발목 궤적 동등성은 미확인 상태다.

Behavior 키 등록 후 255틱 대조를 실행했다. 양쪽 스틱·트리거 입력은 일치했다. 상태 차이 28틱과 최대 월드 위치 오차 루트 22.690 m, 왼쪽 발목 22.668 m, 오른쪽 발목 22.764 m를 기록했다. [전이 및 위치 결과](animation_studio/hero/README.md#이동-상태와-지형-발-ik)를 참고한다.

255틱 이동 방향과 전이 보정 후 상태 불일치가 28틱에서 0틱으로 줄었다. 원본 그래프에서 확인한 `Walk_Face_180.hkt`를 걷기 진입에 사용했다. 이어서 원본 카메라 리드 각도(`hero_camera.lua`), Smoothstep 전환 블렌딩, `Walk→Run` 블렌드 중 보행 회전 속도 유지, 스윙 페이즈 발 IK 페이드아웃을 반영해 월드 위치 RMS를 루트 0.156 → 0.031 m, 왼쪽 발목 0.255 → 0.037 m, 오른쪽 발목 0.247 → 0.035 m로 줄였다. 남은 3~7 cm(최대 `tick 32`)는 스폰 원점에서 Havok 물리 캡슐과 `Slope` 모서리의 초기 충돌 및 수직 안착 차이다. [수정 전후 결과](animation_studio/hero/README.md#이동-방향과-상태-전이-대조)를 참고한다.

## 2단계: 상체 슬롯·관성 블렌딩·그래프 강조·Rewind · 2026-11-26

[그래프·관성·Rewind 랩](animation_studio/demo/graph_studio.tscn)과 런타임 모듈(`pose_buffer.gd`, `inertial_blender.gd`, `pose_graph.gd`, `pose_graph_modifier.gd`, `rewind_recorder.gd`)을 추가했다. `PoseGraphModifier`를 스켈레톤 첫 모디파이어로 배치해 모디파이어 처리 직후 `skeleton_updated` 신호 안에서 최종 포즈를 고정 용량 링 버퍼(300프레임)에 기록한다.

| 시험 (`animation_graph_rewind`) | 확인한 결과 |
| --- | --- |
| 상체 마스크 이동 중 공격 | `Spine` 하위 본 마스크로 이동 중 `attack` 슬롯 재생 시 하체 위치·회전 오차는 0.0, 상체는 0.838 rad 구동됐다. 완료 시 `slot_weight = 0.0`(평가 클립 1개)으로 복귀하고 도중 취소는 5틱 만에 블렌드아웃됐다. |
| 5차 다항식 관성 블렌딩 | `move → idle` 0.20초 관성 전환 전 구간에서 베이스 평가 클립 수는 1개를 유지했다. 전환 직전·직후 최대 회전 점프는 하드 컷 0.340 rad에서 0.020 rad로 줄었고, 완료 후 대상 포즈 오차는 0.0 rad로 수렴했다. |
| 그래프 강조·Rewind·결정성 | 전환·슬롯 활성 노드 메타데이터가 2D 그래프 캔버스에 표시·해제된다. 326틱 기록 시 버퍼는 300프레임 상한을 유지했고, 과거 틱 되감기 복원 오차와 2회 동일 입력 재생 차이는 모두 0.0이었다. |

## 3단계: 군중 성능·압축·능동 랙돌 검증 · 2026-11-26

공식 Godot 4.7.2 헤드리스 환경에서 65본 × 200체 군중 벤치마크([crowd_benchmark.gd](animation_studio/tests/crowd_benchmark.gd))와 단일 관절 능동 랙돌 시험([active_ragdoll.gd](animation_studio/tests/active_ragdoll.gd))을 실행했다.

| 시험 | 확인한 결과 |
| --- | --- |
| 65본 × 200체 성능 (`animation_crowd_benchmark`) | 기본 `AnimationPlayer` 200체는 포즈 평가·쓰기 p50 **6.302 ms** / p95 **8.269 ms**, `force_update_all_bone_transforms()` 포함 전체 p50 **7.293 ms** / p95 **9.345 ms**였다. GDScript `WorkerThreadPool`은 워커 대기 p50 **10.230 ms**(총합 p50 **11.354 ms**)가 병목이었다. 같은 양자화 버퍼를 C++ GDExtension `AnimationStudioCrowdEvaluator`(영구 8워커 풀)로 실행하면 13,000본 전수 갱신을 유지한 채 포즈 평가·쓰기 p50 **0.354 ms** / p95 **1.138 ms**(기본 대비 **17.8배 빠름**, 워커 대기 p50 0.076 ms + 메인 적용 p50 0.255 ms), `force_update_all_bone_transforms()` 포함 전체 p50 **1.226 ms** / p95 **1.991 ms**(기본 대비 **5.95배 빠름**, 1.5 ms p50 목표 충족)를 달성했다. C++와 GDScript 결과 차이는 0.000047 mm / 0.000052° 이내였다. |
| 클립 압축·오차 (65본 × 61키) | 내장 `Animation.compress(8192, 60, 4.0)`은 직렬화 크기를 122,546 → 62,214 B(**49.2% 절감**), 최대 오차 0.00067 mm / 0.0057°로 줄였다. 16비트 `QuantizedClip`은 상주 55,574 B로 비압축 추정(206,180 B) 대비 **73.0% 절감**(70~85% 목표 충족), 최대 오차 0.00033 mm / 0.0018°였다. |
| 능동 랙돌 단일 관절 (`animation_active_ragdoll`) | `PhysicalBone3D`는 `joint_type`만 노출하고 내부 6DOF 관절 취득·모터 API를 공개하지 않는다. 공개 API(`RigidBody3D` + `Generic6DOFJoint3D` + PD 토크 제어)로 +45° 목표 추종(44.996°, 오차 0.000064 rad), 토크 상한(0.4 N·m 제한 시 각속도 0.777 vs 4.089 rad/s), 고속 회전 중 `(50, 10, -30)` 순간이동 리셋(위치·속도·안정화 오차 0.0)을 통과했다. |

## Havok Animation · Behavior 전체 데모 카탈로그 통합 · 2026-11-26

[사례 갤러리](animation_studio/catalog/README.md)를 Havok 2015.1.0-r1의 `Demo/Demos/Animation`과 `Demo/Demos/Behavior` 전체로 확장했다. 등록 선언 218개를 펼쳐 총 **121개 소스 파일 / 414개 선택 항목**(Animation 276개 / 62소스 + Behavior 138개 / 59소스, 미해결 도메인·변형·누락 소스 각 0건)을 [catalog.json](animation_studio/catalog/catalog.json)에 통합하고, Behavior 실행기([behavior_cases.gd](animation_studio/catalog/behavior_cases.gd))를 Godot 내장 C++ 모디파이어(`TwoBoneIK3D`, `LookAtModifier3D`, `RetargetModifier3D`, `AnimationTree`, `BoneAttachment3D`), 커스텀 C++ GDExtension(`AnimationStudioCrowdEvaluator`), `PoseGraph`(`PingPong`·`EnforcedDuration`·`SynchronizedStart`·`ReturnToPrevious`·`Inertialize`), 2관절 `ActiveRagdollJoint` 팔레트, 도킹 모션 워핑, 그리고 로컬 Hero 원본 에셋(`hero/hero.tscn` 85본·18,050정점)으로 보강했다. `animation_gallery` 헤드리스 전수 순회 시험에서 **422개 검사(414개 전 항목 + 필터·복귀)**가 모두 통과했다.

## 동일 Hero 원본 에셋(85본·18,050정점) 성능·위치·비주얼 검증 · 2026-11-26

합성 리그가 아닌 Havok 원본 Hero(`Rig.hkt` 85본, `hero_skin.gltf` 18,050정점·10표면·6텍스처, `Idle_0`/`Walk_0`/`Run_0`/`Idle_To_Run_90.hkt`) 단일 에셋으로 성능·위치·비주얼을 함께 대조했다([hero_same_asset_verify.gd](animation_studio/tests/hero_same_asset_verify.gd)).

| 검증 항목 | 측정 결과 |
| --- | --- |
| 위치 (Havok `oracle.json` 1,530 본 포즈 대조) | 기본 `AnimationPlayer`는 로컬 0.00012 mm / 0.0184°, 말단(Head·양손·양발) 모델 공간 **0.0172 mm**였다. C++ `QuantizedClip` 경로는 로컬 0.00955 mm / 0.0178°, 말단 모델 공간 **0.0834 mm**였다. |
| 성능 (동일 Hero 85본 `Run_0.hkt` × 200체 = 17,000본/틱) | Havok SDK 2015.1.0-r1 네이티브(1T, O2)는 샘플링 p50 **0.079 ms** / 모델 행렬 전파 포함 **0.174 ms**였다. Godot 기본 `AnimationPlayer` 200체는 포즈 p50 **11.931 ms** / `force_update_all_bone_transforms()` 포함 **13.758 ms**였다. Godot C++ `AnimationStudioCrowdEvaluator`(8T, 16,800 비루트 본 전수 변경 확인)는 포즈 p50 **0.681 ms**(대기 0.122 + 적용 0.508 ms, 기본 대비 **17.5배 빠름**) / 행렬 전파 포함 **2.082 ms**(기본 대비 **6.6배 빠름**)였다. `Run_0` 상주 메모리는 73.0% 절감(46,474 B vs 비압축 추정 172,380 B)했다. |
| 비주얼 (`hero_skin.gltf` GPU 실렌더링, `run @ 0.25s`, 864×540) | 동일 카메라·조명에서 `AnimationPlayer`와 C++ `AnimationStudioCrowdEvaluator` 렌더링 픽셀 차이는 **MAE 0.0146 / 255**, **PSNR 57.06 dB**였으며 중앙 분할 비교 이미지에서 스키닝·텍스처·그림자 경계 불일치가 없었다. |

## 에디터 Hero 상태머신 · 가상 포인터 제작 과정 다시보기 · 2026-11-26

[에디터 플러그인](animation_studio/addons/animation_studio/editor_plugin.gd)과 공유 `@tool` 스튜디오([hero_locomotion_studio.tscn](animation_studio/hero/hero_locomotion_studio.tscn), [hero_sm_canvas.gd](animation_studio/hero/hero_sm_canvas.gd), [authoring_cursor_overlay.gd](animation_studio/hero/authoring_cursor_overlay.gd), [authoring_replay.gd](animation_studio/hero/authoring_replay.gd))를 추가하고 [project.godot](animation_studio/project.godot)에 활성화했다.

- **가상 포인터 제작 과정 다시보기 (`0.0~14.0s`, 14단계)**: 에디터 상단 **프로젝트 → 도구 → Hero 제작 과정 가상 포인터 다시보기** 또는 하단 **Hero 상태머신** 패널(및 F5 런타임)에서 역할별 가상 포인터(`에셋`·`리그·씬`·`상태머신`·`물리·IK`), 단계 칩(`탐색`·`대상`·`실행`·`변경`·`완료`), 클릭 리플, 대상 강조 박스로 에셋 제작 전 과정을 시청·되감기할 수 있다. 빈 씬 → `Motion` 노드 → 85본 와이어프레임 리그 → 18,050정점 스킨 바인딩 → 공유 지형 → 상태머신(`Idle`·`Idle→Walk`·`Walking`·`Running`·Smoothstep) → 카메라 추적 리드 → 지형 레이캐스트 2본 발 IK → 255틱 궤적까지 정방향·역방향 모두 결정적으로 재구성되며, 에디터 모드에서는 실제 `SceneTreeDock`·`FileSystemDock`·`InspectorDock`·3D 뷰포트 위에도 라이브 커서 오버레이를 구동한다.
- **255틱 로코모션 Rewind**: 1~5단계 제작 과정을 직접 선택해 즉시 재베이킹하고, 2D 상태머신 강조·스틱 인디케이터·3D 궤적·전이 점프(`t=0/31/57/90/150/202`)·타임라인 스크러빙으로 임의 틱을 다시볼 수 있다.
- **검증**: `animation_hero_studio` 헤드리스 검증 **12/12 PASS**(빈 씬 → 85본 와이어프레임 → 스킨 바인딩 → 12단계 완료 → `13.5s → 2.4s` 역방향 롤백, 1~5단계 상태 해제, 85본 포즈·루트 되감기 복원 오차 `0.0`)와 GPU 실렌더링 시각 검수를 통과했다.

## Hero 에셋 Godot 네이티브 내재화 (`.hkt`/SDK 의존성 제거) · 2026-11-26

로컬 `hero/generated/` 및 `.hkt`/Havok SDK 변환 절차 없이 새 체크아웃·에디터·런타임 어디서나 즉시 동작하도록 Hero 85본 에셋을 Godot 네이티브 포맷으로 내재화했다.

- **내재화 리소스**: [HeroMotionData](animation_studio/hero/hero_motion_data.gd) (`PackedFloat32Array` 압축 바이너리 [hero_motion.res](animation_studio/hero/assets/hero_motion.res), `627.5 KB` — 기존 4.65 MB JSON 대비 86.5% 절감, `.hkt`/SDK 경로 메타데이터 0건) + 단일 바이너리 glTF 2.0 [hero_skin.glb](animation_studio/hero/assets/hero_skin.glb) (`4.41 MB`, 18,050정점·10표면·6내장 PNG, JSON 청크 내 Havok 문자열 0건).
- **UI·스크립트·테스트 전환**: [hero.gd](animation_studio/hero/hero.gd), [hero_locomotion_studio.gd](animation_studio/hero/hero_locomotion_studio.gd), [authoring_replay.gd](animation_studio/hero/authoring_replay.gd), [hero_sm_canvas.gd](animation_studio/hero/hero_sm_canvas.gd), [behavior_cases.gd](animation_studio/catalog/behavior_cases.gd), [hud.tscn](animation_studio/demo/hud.tscn), [run.py](tests/run.py)를 모두 내재화 리소스 기본 로드로 전환하고 UI의 `.hkt`/SDK 표기를 정리했다. 기존 SDK 오라클·트레이스 비교 도구(`animation_hero_parity`, `animation_hero_behavior_native`)는 로컬 `hero/generated/`가 있을 때만 동작하는 선택(optional) 검증으로 유지했다.
- **검증 (`hero/generated/` 임시 제거 클린 체크아웃 모의)**: `animation_havok_demo`(57/57), `animation_hero_behavior`(11/11), `animation_hero_same_asset`(5/5), `animation_hero_studio`(12/12), `animation_gallery`(422/422) 총 **507/507 PASS** + GPU 실렌더링 검수 완료. 복구 후 선택 SDK 패리티 `animation_hero_parity` **11/11 PASS** 확인.

## Godot 웹 에디터 애드온 · NaturalMotion Morpheme 레이아웃 · 2026-11-26

[에디터 플러그인](animation_studio/addons/animation_studio/editor_plugin.gd)을 메인 화면 워크스페이스 **`Morpheme Studio`**(`_has_main_screen() -> true`)로 승격하고, NaturalMotion Morpheme Connect 스타일의 4도크 스튜디오 레이아웃([hero_locomotion_studio.gd](animation_studio/hero/hero_locomotion_studio.gd), [hero_sm_canvas.gd](animation_studio/hero/hero_sm_canvas.gd), [morpheme_timeline_canvas.gd](animation_studio/hero/morpheme_timeline_canvas.gd))과 Godot 4.7.2 웹 에디터 WASM 서버·런처([web_editor/serve_web_editor.cjs](animation_studio/web_editor/serve_web_editor.cjs), [web_editor/index.html](animation_studio/web_editor/index.html))를 추가했다.

- **구성**: 좌측(`Asset Manager` · `Scene Hierarchy` · `Control Parameters`), 중앙(`Morpheme Animation Network Graph` 베지어 와이어·노드 클릭 선택 | `3D Character Viewport`), 우측(`Attribute Editor` · `Authoring Event Log`), 하단(4트랙 `Event Tracks` 도프시트 + 트랜스포트 바) 및 전 화면 가상 포인터 오버레이.
- **에디터 GLB 호환성 수정**: Godot 에디터 모드에서 `GLTFDocument.generate_scene()`이 반환하는 `ImporterMeshInstance3D`를 지원하고 `append_from_buffer()`로 메모리 내 로드해 웹·데스크톱 에디터 모두에서 6개 스킨 메시(`18,050정점`)가 오류 없이 렌더링되도록 했다.
- **검증**: `animation_hero_studio` 헤드리스 **13/13 PASS**, 데스크톱 에디터(`HERO_SKIN_LOADED meshes=6`) 및 실제 Chrome **Godot 4.7.2 웹 에디터 WASM**(`CROSS_ORIGIN_ISOLATED=true`, `HERO_SKIN_LOADED meshes=6 web=true`, `ANIMATION_STUDIO_EDITOR_READY main_screen=Morpheme Studio web=true`, JS/GDScript 오류 0건) 실렌더링 스크린샷 검수 완료.

## 절차적 4족 보행 로코모션 (Unreal Engine Locomotor 참고) · 2026-11-27

Unreal Engine 공식 튜토리얼 *Procedural Animation with a Locomotor*(`EkxO`) 구조를 참고해 키프레임 클립 0개의 100% 절차적 4족 보행 로코모션과 가상 포인터 제작 과정 다시보기를 구현하고 Godot 웹·데스크톱 에디터 `Morpheme Studio` 메인 화면에 통합했다.

- **28본 절차적 리그 및 UE Locomotor 솔버**: [quadruped_rig.gd](animation_studio/quadruped/quadruped_rig.gd)(척추 12본 + 앞다리 뒤굽힘·뒷다리 앞굽힘 16본 + `BoneAttachment3D` 장갑/관절/꼬리)와 [quadruped_locomotor.gd](animation_studio/quadruped/quadruped_locomotor.gd)(`Foot Set 0/1` 위상 스케줄러, `Walk` 4박자·`Trot` 대각선·`Pace` 동측·`Gallop` 비대칭 보법, 예측 보폭 타깃, 지지 발 월드 고정 0 mm 미끄러짐, 포물선 계단 스윙 아크, 골반 높이·지형 피치/롤·선회 뱅킹·척추 S-웨이브·머리 수평 안정화·꼬리 파동, 4다리 Pole-Vector 2본 FBIK).
- **Morpheme 레이아웃 & 14단계 제작 과정 다시보기**: [quadruped_locomotor_studio.tscn](animation_studio/quadruped/quadruped_locomotor_studio.tscn), [quadruped_locomotor_studio.gd](animation_studio/quadruped/quadruped_locomotor_studio.gd), [quadruped_network_canvas.gd](animation_studio/quadruped/quadruped_network_canvas.gd), [quadruped_timeline_canvas.gd](animation_studio/quadruped/quadruped_timeline_canvas.gd), [quadruped_authoring_replay.gd](animation_studio/quadruped/quadruped_authoring_replay.gd). 빈 씬 → 28본 와이어프레임 → 크리처 바디 → 계단·경사·능선 코스 → Locomotor Foot Sets → Walk/Trot/Gallop → Pelvis/Spine → 4다리 FBIK → 300틱 궤적까지 정방향·역방향 되감기와 실시간 보법 전환(`Auto/Walk/Trot/Pace/Gallop`), 발 타깃 링·지지 다각형 3D 기즈모를 제공한다.
- **에디터 통합 & 검증**: [editor_plugin.gd](animation_studio/addons/animation_studio/editor_plugin.gd)에서 `4족 절차적 Locomotor` / `Hero 85본 상태머신` 상단 탭 전환 및 도구 메뉴를 제공한다. `animation_quadruped_locomotor` **12/12 PASS**(발 미끄러짐 `0.0 mm`, 대각선 Trot 위상 일치, 계단 등반 피치 적응, 300틱 포즈 되감기 오차 `0.0`, 역방향 제작 롤백), `animation_hero_studio` 13/13, `animation_havok_demo` 57/57 및 실제 Chrome **Godot 4.7.2 웹 에디터 WASM**(`active_tab=quadruped`, 오류 0건) 실렌더링 검수를 통과했다.

## Soldier 114본 · M4 에셋 추출·내재화 및 데모 비교 · 2026-11-27

Havok SDK 2015.1.0-r1의 `US_Leader_Pack_2.hkt`(Maya Y-up 114본 + M4 소총 3파츠 `buttstock`/`magazine`/`receiver`)와 전술 5클립(`idle` 5.55s, `walk` 1.55s, `jog` 3.31s, `run` 1.30s, `vault` 3.45s)을 추출해 Godot 네이티브 포맷으로 내재화하고, 데모 비교 씬 및 회귀 스위트를 추가했다. 클립 바인딩(`US_Soldier` 113본)과 리그(`US_Leader_Pack_2` 114본, 인덱스 90에 `pack_M` 배낭 본 삽입) 간의 1본 오프셋을 이름 기준 정합(`0..89 -> 0..89`, `90..112 -> 91..113`, `pack_M` 바인드 포즈 유지)으로 보정해 상·하체 및 M4 소총 자세를 일치시켰다.

- **내재화 리소스** (`.hkt`/SDK 문자열 0건): [soldier_motion.res](animation_studio/soldier/assets/soldier_motion.res) (`2,513.7 KB`, 114본·5클립 압축 `HeroMotionData`) + [soldier_skin.glb](animation_studio/soldier/assets/soldier_skin.glb) (`5,650.6 KB`, 9메시·51,170정점·3내장 PNG, M4 소총 `hkaBoneAttachment` 3파츠 포함, 역바인드 오차 `8.7e-6`).
- **비교 씬 & 에디터 통합**: [soldier_demo.tscn](animation_studio/soldier/soldier_demo.tscn), [soldier_demo.gd](animation_studio/soldier/soldier_demo.gd), [soldier_motion_store.gd](animation_studio/soldier/soldier_motion_store.gd). `Morpheme Studio` 메인 화면에 3번째 탭(`Soldier 114본 · M4 데모 비교`)과 도구 메뉴를 추가해 좌(`AnimationPlayer`)·우(`16-bit C++ QuantizedClip`) 나란히 재생과 실시간 본·M4 말단 오차 비교를 제공한다.
- **비교 검증 (`animation_soldier_compare` 7/7 PASS, `soldier/generated/` 유무 양쪽 통과)**:
  - **위치 (Havok SDK `oracle.json` 2,850 본 포즈 대조)**: `AnimationPlayer` 로컬 **`0.000106 mm` / `0.0030°`**, 말단(머리·양손·M4 `receiver`·양발) **`0.0176 mm`**; `QuantizedClip` 로컬 **`0.473 mm` / `0.704°`**, 말단 **`2.326 mm`**(`crowd_evaluator.gd`의 비정수 60 Hz 클립 끝단 샘플링 경계 보정 반영).
  - **성능 (동일 114본 `run` × 200체 = 22,800본/틱)**: `AnimationPlayer` 포즈 p50 `18.982 ms` / 전체 `22.354 ms` vs C++ `AnimationStudioCrowdEvaluator`(8T, 22,613본 전수 갱신) 포즈 p50 **`1.183 ms`** (**16.0배 빠름**) / 전체 **`4.221 ms`** (**5.30배 빠름**), 메모리 **73.1% 절감**.
  - **비주얼 (GPU 실렌더링 `run @ 0.40s`, 886×616)**: `AnimationPlayer` vs `QuantizedClip` **MAE `0.0709 / 255`**, **PSNR `47.30 dB`**(`walk`·`vault` 나란히 실렌더링 검수 완료).

## 전체 Havok SDK 캐릭터 28종 내재화 및 통합 로스터 데모 포팅 · 2026-11-27

Havok SDK 2015.1.0-r1 전체(`Behavior/GameAssets`, `Animation/ShowCase`, `Animation/Ragdoll`, `Animation/Retargeting`)의 애니메이션 캐릭터 에셋 **26종을 추가 추출·내재화**해 기존 `Hero`·`Soldier`와 합쳐 **총 28종(1,863본 · 119메시 · 225,471정점 · 83클립)** 전체 캐릭터 로스터를 `.hkt`/SDK 의존성 없이 Godot 네이티브(`.glb` + 압축 `HeroMotionData` `.res`)로 포팅했다.

- **내재화 자산 & 범용 파이프라인** (신규 26종 52파일: GLB `12.29 MB` + RES `6.10 MB` = 총 `18.39 MB`, `.hkt`/SDK 경로 문자열 0건):
  - `hkaPredictiveCompressedAnimation` 및 `hkaQuantizedAnimation`의 `--skeleton` 바인딩을 지원해 Orc 3종(`Orc Captain`, `Orc Grunt`, `Orc Troll`)을 포함한 전 클립을 정확히 샘플링했다.
  - `hkxVertexDescription.decls` 기반 인터리브·플래너 버텍스 스트림, `uint8`/`uint16` 조인트, `INT16` 양자화 UV, `hkaMeshBinding`(무 `hkxSkinBinding` 포함), `hkaBoneAttachment` 무기 파츠, `hkxTextureInplace` 인라인 텍스처(PNG/TGA) 및 외부 텍스처를 512px JPEG/PNG로 내장했다.
  - `FetidHulk`의 `hkxSkinBinding.nodeNames`(37개) vs `hkaSkeleton`(43본) 중복 리맵 문제를 감지·보정해 28종 전수 GPU 컨택트 시트 육안 검수를 통과했다.
- **통합 데모 쇼케이스 & 에디터 통합**: [catalog.json](animation_studio/characters/catalog.json), [character_store.gd](animation_studio/characters/character_store.gd), [character_showcase.tscn](animation_studio/characters/character_showcase.tscn), [character_showcase.gd](animation_studio/characters/character_showcase.gd).
  - 카테고리 필터(`전체 28` / `전투·액션 7` / `크리처 6` / `쇼케이스 6` / `리타게팅 9`), 3가지 보기 모드(**나란히 비교 `Float32 vs 16-bit C++`** / **단독 클로즈업** / **단체 퍼레이드**), 자동 포즈 AABB 프레이밍, 실시간 200체 C++ 벤치마크 버튼을 제공한다.
  - `Morpheme Studio` 메인 화면 4번째 탭(`전체 캐릭터 로스터 (28종 GLB/RES)`), 도구 메뉴 및 메인 런처 HUD 진입 버튼을 연동했다.
- **검증**: `animation_character_roster` **5/5 PASS**(28종 × 83클립 전수 로드·정합 최대 `2.13 mm` / `2.03°`, 최소 메모리 절감 **`72.9%`**, 9체 단체 퍼레이드 전환), `animation_soldier_compare` 7/7, `animation_hero_same_asset` 5/5, `animation_crowd_benchmark` 5/5, `animation_quadruped_locomotor` 12/12, `animation_hero_studio` 13/13 전체 통과.

## Hero 테스트 배경맵(`Environment.hkt`) · 10종 Lua 스크립트 복원 및 내재화 · 2026-11-27

Havok SDK 2015.1.0-r1의 공식 Hero 3인칭 액션 어드벤처 테스트 맵(`Hero/Terrain/Environment_np.hkt` + `Layer0_001CompleteMap_original.png`), 90개 월드 도킹 라인, 31종 파쿠르·엄폐·등반·검술 클립 및 **10종 Lua 스크립트(`hero.lua`, `hero_locomotion.lua`, `hero_camera.lua`, `hero_lines.lua`, `hero_docking.lua`, `hero_vaulting.lua`, `hero_climbing.lua`, `hero_cover.lua`, `hero_leaping.lua`, `hero_gamepad.lua`)**를 `.hkt`/Lua 외부 의존성 없이 Godot 네이티브로 추출·복원·내재화했다.

- **내재화 에셋** (`havok`/`.hkt`/SDK 문자열 0건):
  - [hero_environment.glb](animation_studio/hero/assets/hero_environment.glb) (`557.1 KB`) — `bluishEnv` 4,992정점 · 1,664삼각형, 2048px 베이크드 CompleteMap(AO+파쿠르 색상 표식) 내장, 런타임 `ConcavePolygonShape3D` 트라이메시 물리 충돌 생성.
  - [hero_arena_motion.res](animation_studio/hero/assets/hero_arena_motion.res) (`3,905.5 KB`) — 85본 Hero 파쿠르·엄폐·등반·도약·검술 **31클립** 압축 `HeroMotionData`.
  - [hero_arena_lines.json](animation_studio/hero/assets/hero_arena_lines.json) (`13.4 KB`) — `hero_lines.lua`의 **90개** 월드 도킹 라인(Red 낮음엄폐 10 · Green 높음엄폐 10 · Blue 등반난간 40 · Yellow 고플랫폼 12 · Orange 뛰어넘기난간 18, Z-up→Y-up 변환).
- **10종 Lua 로직 1:1 GDScript 복원**: [hero_lua_gamepad.gd](animation_studio/hero/arena/hero_lua_gamepad.gd), [hero_lua_lines.gd](animation_studio/hero/arena/hero_lua_lines.gd), [hero_lua_camera.gd](animation_studio/hero/arena/hero_lua_camera.gd), [hero_lua_controller.gd](animation_studio/hero/arena/hero_lua_controller.gd).
  - 스틱 보간(`0.9`)·데드존(`mag²<0.1`)·유지 타이머, 3모드 카메라(3인칭 5.0m / 등반 3.5m / 오버더숄더 Strafe + 벽면 레이캐스트 오클루전), `IsRightFootForward`(좌우 종아리 본 투영), 3프레임 지면 지지 레이캐스트 + `GravityFactor=3.38`, 전방 벽 밀기 감지(`dot<-0.7`), `radialSelectAnimation(4/8)`, `115° Turn180`, `jumpActions()` 최근접 경쟁(등반/도약/난간넘기), 양방향 난간 넘기 + 착지 평면 레이캐스트, 엄폐 이동·엄폐간 구르기·배면 난간넘기, 검 발도/납도/공격을 모두 복원했다.
- **플레이 가능 아레나 & 에디터 통합**: [hero_arena.tscn](animation_studio/hero/arena/hero_arena.tscn), [hero_arena.gd](animation_studio/hero/arena/hero_arena.gd). 6종 Lua 시나리오 즉시 시연 버튼, 자동 시연 투어, WASD/Space/E/R/F/Q 수동 조작, 90개 3D 도킹 라인 토글을 제공하며 `Morpheme Studio` 5번째 탭(`Hero 배경맵 · Lua 복원`) 및 런처 HUD에 연동했다.
- **검증**: `animation_hero_arena` **9/9 PASS**(실제 `Environment.glb` 트라이메시 지면 레이캐스트 `y=-0.0002m`, 엄폐·난간넘기 `3.35m`·`y=2.0m` 플랫폼 등반 `final_y=1.9999m`·도약·Strafe 카메라 전환 및 전체 7개 애니메이션 스위트 ALL GREEN, GPU 4종 스크린샷 검수 완료).

## Hero 맵 좌표·오프셋·비주얼 교정 & 표준 도킹 애드온(3D 뷰포트) 전환 · 2026-11-27

1. **Hero 배경맵 좌표계·오프셋·비주얼 정밀 교정**:
   - **원인 규명 (레이캐스트 + 85본 FK 감사)**:
     - **엄폐(Cover)**: `LINE_TYPE 0/1`의 `+edge_normal`이 벽체 내부(`+0.06~0.56m`), `-edge_normal`이 개방 공간이었음에도 `+n*0.35m`로 밀착시켜 벽 안으로 파묻히던 문제를 `closest - n * 0.04`, `yaw = atan2(-n.x, -n.z)`로 교정.
     - **등반·매달림(Climb/Hanging)**: `platform_idle`/`platform_climb` 클립 로컬 원점 `(0,0,0)` 자체가 이미 상단 립(양손 `Y=+0.02`, 몸통 `Y∈[-2.32, 0]`) 기준인데 추가로 `-1.55m`를 더해 바닥으로 파묻히던 문제를 `closest + n * 0.04` 립 기준 고정 앵커(완료 시 `closest - n * 0.48` 베이크)로 교정.
     - **난간 넘기(Vault)**: 경사 램프 난간 대신 지면 수평 `y=1.06m` 난간을 선택하고 `action_arc_height = max(0, barrier_h - 1.15)`로 이중 공중 부양 제거.
     - **비주얼(`HeroEnvironmentNode`)**: [hero_environment_node.gd](animation_studio/hero/arena/hero_environment_node.gd)에서 과노출 순백 바닥을 톤 보정(`tint_color=(0.64,0.69,0.75)`)하고 `1m/5m` 건축 바닥 그리드를 합성하면서 파쿠르 색상 띠(Red/Green/Blue/Yellow/Orange) 채도를 보존.
2. **표준 Godot Addon 도킹 UI & 표준 3D 뷰포트 인스턴스 연동**:
   - [editor_plugin.gd](animation_studio/addons/animation_studio/editor_plugin.gd)를 커스텀 메인 화면(`_has_main_screen()=true`)에서 **표준 Godot 애드온(`_has_main_screen()=false`)**으로 전환해 Godot 기본 `3D` 뷰포트를 그대로 사용.
   - 표준 도킹 패널 3종 구현: 좌측 도크 **`AnimStudio · 계층`**([hierarchy_dock.gd](animation_studio/addons/animation_studio/docks/hierarchy_dock.gd)), 우측 도크 **`AnimStudio · 상태`**([state_dock.gd](animation_studio/addons/animation_studio/docks/state_dock.gd)), 하단 패널 **`Animation Flow`**([flow_bottom_panel.gd](animation_studio/addons/animation_studio/docks/flow_bottom_panel.gd), [flow_graph_canvas.gd](animation_studio/addons/animation_studio/docks/flow_graph_canvas.gd)).
   - [animation_studio_instance.gd](animation_studio/addons/animation_studio/animation_studio_instance.gd) (`@tool class_name AnimationStudioInstance`)와 [hero_arena_world.tscn](animation_studio/hero/arena/hero_arena_world.tscn)으로 실제 3D 씬에 `Hero_Arena`(85본·10 Lua), `Soldier_M4`(114본), `Quadruped_Locomotor`(28본 절차적 IK), `OrcCaptain`(73본)을 배치해 3D 뷰포트·씬 트리·계층 도크 어느 곳에서 선택해도 3개 도킹 패널과 실시간 동기화되며, 28종 캐릭터 즉시 추가 배치(`+ 배치`) 및 3D 카메라 포커스를 지원.
3. **로컬 포크 엔진 즉시 실행 링크 & 웹 에디터 전체 창 개선**:
   - [serve_web_editor.cjs](animation_studio/web_editor/serve_web_editor.cjs)에 루프백(`127.0.0.1`/`::1`) 전용 `/launch-local-editor` 엔드포인트와 [open_local_fork_editor.cmd](animation_studio/open_local_fork_editor.cmd)를 추가해 로컬 포크 엔진(`Forge-Refactoring-engine`, Godot `4.7.2.stable.custom_build.31e7ebb19`)에서 `hero_arena_world.tscn`을 바로 열 수 있게 구성.
   - [index.html](animation_studio/web_editor/index.html) + [editor_frame.html](animation_studio/web_editor/editor_frame.html)(`canvasResizePolicy: 2`)로 웹 에디터 캔버스 크롭 없이 브라우저 전체 창 1:1 렌더링 및 마우스 좌표를 보정.
4. **검증**:
   - 로컬 포크 엔진 헤드리스 회귀 6종 **53/53 PASS**(`animation_editor_docks` 7/7, `animation_hero_arena` 9/9, `animation_character_roster` 5/5, `animation_soldier_compare` 7/7, `animation_quadruped_locomotor` 12/12, `animation_hero_studio` 13/13).
   - 로컬 포크 Godot 에디터 부팅(`ANIMATION_STUDIO_EDITOR_READY mode=standard_docks`, 오류 0건) 및 Godot 4.7.2 웹 에디터 라이브 브라우저 검증(`Hero_Arena` 매달림 + `Soldier_M4` 도크 전환·114본 트리·`Animation Flow` 그래프 동기화, 오류 0건) 완료.

## AI Pathfinding · Spatial Analysis · AI+Behavior Hero 전체 맵 자율 구동 데모 · 2026-11-27

Havok AI SDK(`SpatialAnalysisDemo`, `AbstractTraversalDemo`, `UserEdgesDemo`, `PreferHighPlacesCostModifier`, `Gdc2009AiTactical`, `DynamicSilhouette`, `PathFollowing` + `BehaviorBlockedDetector`)와 Havok Behavior Hero 10종 Lua 상태머신 구조를 참고해, **외부 `.hkt`/SDK 런타임 의존성 없이 100% Godot 네이티브로 Hero 맵 전체(`Y=-3.0m` 지하 참호 ~ `Y=+10.25m` 정상)를 AI 길찾기로 자율 주행·커버하는 데모**를 구현했다.

- **Spatial Analysis & 다층 NavMesh + Traversal UserEdge 자동 추출** ([hero_spatial_analysis.gd](animation_studio/hero/ai/hero_spatial_analysis.gd)):
  - `hero_environment.glb`의 1,602개 보행 가능 삼각형을 분석해 다층 2.5D NavGraph(**1,823 NavNodes · 13,472 WalkEdges**)를 구축하고, 6종 공간 분석기(`Vault` 12 · `ClimbUp` 21 · `Leap` 8 · `DropDown` 43 · `CoverWalk` 24 · `CoverRoll` 32 = **총 140개 Annotated UserEdges**) 및 다층 NavMesh/호(arc) 오버레이를 자동 생성한다.
- **3D A\* Pathfinding & Havok CostModifier / 동적 장애물 회피** ([hero_ai_pathfinder.gd](animation_studio/hero/ai/hero_ai_pathfinder.gd)):
  - `Shortest` / `PreferHighPlaces` / `TacticalCover` / `ParkourExpress` 4종 비용 수정자, Traversal UserEdge 비트마스크 실시간 필터링, 동적 장애물 실루엣 자동 재탐색을 지원한다.
- **AI + Behavior 브리지 (텔레포트 없는 자율 파쿠르·전술 구동)** ([hero_ai_behavior_driver.gd](animation_studio/hero/ai/hero_ai_behavior_driver.gd)):
  - AI A\* 경로 세그먼트와 로컬 스티어링을 실제 `HeroLuaGamepad`·`HeroLuaController` 이벤트로 변환해 `Walk/Run` · `115° Turn180` · `Low/High Cover` · `CoverRoll` · `Vault` · `Climbing/Hanging/ClimbUp` · `Skybridge Leap` · `DropDown` · `지하 참호(-3m)` · `정상(+10.25m)` · `DrawSword/Strafe/Attack` **12/12 전체 맵 기능**을 텔레포트 없이 연속 완주한다.
- **플레이 가능 데모 & 표준 3D 에디터 도크·로컬 포크 런처 통합**:
  - 단독 데모([hero_ai_demo.tscn](animation_studio/hero/ai/hero_ai_demo.tscn), [hero_ai_demo.gd](animation_studio/hero/ai/hero_ai_demo.gd)): 6종 미션 프리셋, 3D 맵 아무 지점 좌클릭 A\* 이동, CostModifier·UserEdge 필터·동적 장애물·오버레이 실시간 토글 및 12/12 커버리지 체크리스트 HUD.
  - 표준 3D 뷰포트 `Hero_Arena`([animation_studio_instance.gd](animation_studio/addons/animation_studio/animation_studio_instance.gd)) 및 우측 도크 **`AnimStudio · 상태`**([state_dock.gd](animation_studio/addons/animation_studio/docks/state_dock.gd))에서도 AI 자율 주행·오버레이를 직접 켜고 제어할 수 있으며, 로컬 포크 런처(`/local-fork`, `/launch-local-demo?scene=ai_hero`, `run_local_fork_demo.cmd`, `build_and_test_local_fork.cmd`)에 연동했다.
- **검증**: `animation_hero_ai_pathfinding` **8/8 PASS**([hero_ai_pathfinding_verify.gd](animation_studio/tests/hero_ai_pathfinding_verify.gd): 6종 Traversal 추출, 지면→`10.25m` 정상 A\*, `PreferHigh` 평균고도 `0.00m→4.12m`, `TacticalCover` `CoverWalk 3 + CoverRoll 2`, `FLAG_CLIMB` 필터 차단, 동적 장애물 회피 `min_dist=2.83m`, Grand Tour `Y=-3.00m~+10.25m` 및 12/12 기능 완주) + 전체 Animation Studio 7종 스위트 **61/61 PASS**, GPU 3종 스크린샷 육안 검수 완료.

## 디자인 시안 v3 반영 · 표준 도킹 UI 고도화 & Agent 리플레이/저널 구현 · 2026-11-27

`PlayForge_Motion_Studio_Final_v3_20261127` 디자인 시안(Hero·Quadruped·Character 도킹 뷰, NaturalMotion Network/Events/Physics, Agent Review/Branch & MCP 툴 계약)을 실제 Godot 4.7.2 표준 `EditorPlugin` 애드온에 내재화했다.

- **엔진 영향 범위**: **`[엔진 수정]` 없음 (0건)**, **`[엔진 추가]` 없음 (0건)** — 모든 구현은 `playforge/animation_studio/` 및 테스트 러너 이하 확장 영역에만 반영했다.
- **공통 테마·16종 벡터 SVG 아이콘 (`[확장 추가]`)**:
  - `addons/animation_studio/ui/studio_theme.gd` (`AnimationStudioTheme`): `design-tokens.json` 다크 토큰(`#12151b`/`#181d26`/`#151a22`/`#1e2430`, Amber `#f39c2b`, Teal `#2cc7b8`), `StyleBoxFlat` 카드·KPI·4족 접지·세그먼트 버튼·배너 빌더 및 `Image.load_svg_from_string()` 런타임 캐시.
  - `addons/animation_studio/icons/*.svg` (16종: `hero`, `quadruped`, `character`, `bone`, `ai-path`, `navmesh`, `vault`, `climb`, `leap`, `drop`, `cover`, `focus`, `play`, `pause`, `step`, `benchmark`).
- **v3 불변 저널 & 도메인 명령 코어 (`[확장 추가]`)**:
  - `addons/animation_studio/authoring/motion_journal.gd` (`MotionJournal`): `playforge.motion-journal/v1` 스키마, FNV-1a 32-bit 체크섬, 구조적 diff/inverseDiff, 분기(`b000 Main`, `b001...`), 읽기 전용 스냅샷 검토(`inspect`/`exit_review`), 트랜잭션 `undo`/`redo`, `requestId` 멱등성·충돌 검증, 세션 JSON 내보내기/체크섬 검증 복원.
  - `addons/animation_studio/authoring/motion_commands.gd` (`MotionCommands`): 8종 검증 도메인 명령(`set_parameters`, `set_event_range`, `set_event_strength`, `set_event_enabled`, `set_physics`, `set_transition`, `rename_node`, `move_node`), 8종 MCP 툴 계약 메서드(`motion_read_state`~`motion_redo_transaction`), `replace_step` 분기 교체, 4단계 Agent 시나리오 및 `sourceCommitId`/`sourceRevision` 연결 `frame_trace`.
- **표준 도킹 패널·3D 뷰포트 오버레이·웹 에디터 고도화 (`[확장 수정]` / `[확장 추가]`)**:
  - `[확장 수정]` `editor_plugin.gd`: 표준 3D 뷰포트 상단 메뉴 바(`CONTAINER_SPATIAL_EDITOR_MENU`)에 **5종 오버레이 필**(`NavMesh`, `UserEdges`, `A* Path`, `도킹 라인`, `Skeleton`) 추가, `따라가기` 카메라 추적 토글 및 빈 상태 CTA 연동.
  - `[확장 수정]` `animation_studio_instance.gd`: 개별 3D 오버레이 메시(`_ai_navmesh_mi`, `_ai_annot_mi`, `_ai_path_mi`, `_skeleton_wire_mi`, `_ai_obstacle_mi`), UserEdge 플래그 필터(`set_ai_allowed_flag`), 동적 장애물 토글(`set_ai_dynamic_obstacle`), 다음 A\* 상태(`next_ai_state`), 인스턴스별 `MotionCommands` 저널 바인딩 추가.
  - `[확장 수정]` `hierarchy_dock.gd`: 좌측 Amber 선택 바·역할 아이콘·상태 필·포커스 버튼이 포함된 리치 인스턴스 카드, `+ 배치`/`포커스`/`따라가기` 액션 바, 하단 고정 본 포즈 인스펙터 카드.
  - `[확장 수정]` `state_dock.gd`: 4종 컨텍스트 뷰 완성 — **Hero + AI**(6미션·`CostModifier`·5종 `UserEdge` 아이콘 칩·동적 장애물·12/12 커버리지 미니그리드·물리 리그 반응 Lab), **Quadruped**(5버튼 세그먼트 보행 바·2×2 `FL/FR/HL/HR` 접지 카드), **Character**(Float32/16-bit 세그먼트·네이티브 C++/Web 폴백 배너·2×2 KPI 카드·200체 벤치마크), **Empty State**(`Hero_Arena 선택하기`/`+ 새 캐릭터 배치` CTA).
  - `[확장 수정]` `flow_bottom_panel.gd` · `flow_graph_canvas.gd` + `[확장 추가]` `event_timeline_canvas.gd` · `agent_replay_panel.gd`: 하단 `Animation Flow` 3종 서브탭(**`플로우 그래프`** 5상태 노드·`AI 예정` 점선 배지·화살표·전이 시간 / **`이벤트 타임라인`** 3트랙 Behaviour Event 보드·속성 편집기·Frame Trace / **`Agent 리플레이 / 분기`** 4단계 실행·읽기 전용 Replay·중간 단계 미리보기 및 새 분기 교체·Undo/Redo·JSON 저장/복원).
  - `[확장 수정]` `web_editor/index.html`: v3 다크 헤더·배지·로컬 포크 런처 버튼 반영.
- **검증**: 신규 스위트 `animation_motion_v3`([motion_journal_v3_verify.gd](animation_studio/tests/motion_journal_v3_verify.gd)) **7/7 PASS** 포함 핵심 8종 회귀 **68/68 PASS (0 FAIL)**, 로컬 포크 Godot 4.7.2 에디터 기동(`ANIMATION_STUDIO_EDITOR_READY mode=standard_docks_v3`, 오류 0건), 라이브 Chrome **Godot 4.7.2 웹 에디터** 5개 뷰(Hero + AI 기본 도킹, 이벤트 타임라인, Agent 리플레이 4단계, Quadruped 4족 접지 그리드, Soldier 16-bit KPI) 실렌더링 스크린샷 육안 검수 통과(네트워크 오류 0건, 콘솔 오류 0건).

## Havok 414개 데모 원본 에셋 전면 내재화 · Godot 표준 좌표계/카메라/루프 통일 · 2026-11-27

Havok 2015.1.0-r1 SDK의 `Animation`(62소스·276항목) + `Behavior`(59소스·138항목) **414개 전 데모 포팅**에서 합성 16본 로봇(`demo/character/character.tscn`)과 막대 리그를 완전히 제거하고, **내재화된 30종 원본 Havok 에셋**과 **Godot 표준 좌표계(`+Y` 상향, `-Z` 전방, `+X` 우측, SI 미터, `9.81 m/s²`) · 표준 `Camera3D` (`fov = 45.0°`, `KEEP_HEIGHT`, `near = 0.1 m`, `far >= 100.0 m`) · Havok 동일 루프 기본값(`LOOP_LINEAR`/`LOOP_PINGPONG`/`LOOP_NONE`)** 기준으로 일치시켰다.

- **엔진 영향 범위**: **`[엔진 수정]` 없음 (0건)**, **`[엔진 추가]` 없음 (0건)**.
- **누락 원본 에셋 추가 내재화 (`[확장 추가]`)**:
  - `havok_girl_sdk` (`characters/assets/havok_girl_sdk.glb` 348.3 KB · `havok_girl_sdk_motion.res` 813.2 KB): 클래식 Animation SDK 50본 HavokGirl 리그 + 텍스처 메시 2개(3,965정점) + `extractedMotion` 포함 12클립(`idle`/`walk`/`run`/`wave`/`jumpland`/`walk_turn_l/r`/`run_turn_l/r`/`head_move`/`scale`/`protect`).
  - `crabby` (`characters/assets/crabby.glb` 284.8 KB · `crabby_motion.res` 1.1 KB): 18본 6족 SpiderCrab 원본 리그 + 텍스처 메시(2,408정점).
  - 총 내재화 로스터 **28종 → 30종** 확대 (`characters/catalog.json` `[확장 수정]`).
- **Godot 표준 패리티 레이어 & 캐시·루프 기본값 통일 (`[확장 추가]` / `[확장 수정]`)**:
  - `[확장 추가]` `catalog/havok_demo_standards.gd` (`HavokDemoStandards`): 전 30종 `CHARACTER_ALIGNMENT`(yaw·지면 Y 오프셋·높이), `hk_zup_to_godot()` / `hk_camera_to_godot()` / `apply_camera()`(`45.0° KEEP_HEIGHT` 전면 `-Z` 구도), 121소스→30종 에셋·클립·루프·카메라 매핑(`resolve_demo_spec()`), `-Z` 정렬 스폰(`spawn_aligned_character()`), `-Z` 루트 모션 변환(`sample_root_motion_delta()`), 모델 공간 시맨틱 리타게팅 + 발 접지 보정(`apply_semantic_retarget()`), 상체 트랙 필터·좌우 X-평면 클립 미러링.
  - `[확장 수정]` `characters/character_store.gd` (`CharacterRosterStore`): Havok `hkaDefaultAnimationControl`/`hkbClipGenerator` 기본값에 맞춰 순환 클립 기본 `Animation.LOOP_LINEAR`·원샷 클립 `LOOP_NONE` 적용, 스킨 템플릿·기본 클립 정적 캐시(`_skin_template_cache`/`_base_anim_cache`/`clear_caches()`) 추가해 414개 실에셋 갤러리 순회를 16초대로 단축.
  - `[확장 수정]` `catalog/gallery.gd`, `clip_cases.gd`, `rig_cases.gd`, `runtime_cases.gd`, `timing_cases.gd`, `behavior_cases.gd`: 전 6종 카탈로그 스크립트에서 `demo/character/character.tscn` 참조 0건 달성, 전면 조명(`-Z`)·45° FOV 카메라·원본 에셋(`havok_girl_sdk`, `crabby`, `siege_fiend` 4지 IK, `hero`, `soldier`, `zombie`, `firefighter` 4종 실제 GLB 스킨 스왑, `flying_imp`+`hivequeen`, `shulgoth`+`male_nocape`, `orc_captain` 군중 등) 전면 적용.
- **검증**:
  - 신규 패리티 스위트 `animation_havok_port_parity`([havok_port_parity_verify.gd](animation_studio/tests/havok_port_parity_verify.gd) `[확장 추가]`) **7/7 PASS** (`havok_girl_sdk` 50본 오차 `0.29 mm / 1.85°`, 30종 SI/지면 `Y=0` 정렬, `-Z` 루트 모션 전진, 루프 기본값 3종, 45° `KEEP_HEIGHT` 전면 카메라, 12종 대표 원본 스켈레톤 검증).
  - `animation_character_roster` **5/5 PASS (30종)**, `animation_gallery` **422/422 PASS (414개 전 항목 · 엔진 오류 0건)** 및 로컬 포크 핵심 9종 회귀 전수 통과.
  - RTX 4070 실 GPU 6종 스크린샷(`NormalBlending` HavokGirl, `Crabby` 18b IK, `BasicPoseRetargeting` Shulgoth+Male, `Quadruped` SiegeFiend 4/4 접지, `DockingBlend` Hero, `ClipGeneratorModes` Soldier) 육안 검수 완료.

## 실제 Havok 2015.1.0-r1 C++ SDK vs Godot 4.7.2 포팅 1:1 정밀 비교 (이벤트 타이밍 · 3D 위치) · 2026-11-27

실제 Havok 2015.1.0-r1 C++ 런타임(`hkbWorld` + `hknpWorld` + `hkbBehaviorGraph` + `hkbWorldListener::eventsRaisedCallback`)과 Godot 4.7.2 포팅을 **동일 에셋 · 동일 고정 60 Hz 틱 · 동일 입력**으로 1:1 정밀 대조하고, 내재화된 인터랙티브 비교 뷰어와 자동 회귀 스위트를 추가했다.

- **엔진 영향 범위**: **`[엔진 수정]` 없음 (0건)**, **`[엔진 추가]` 없음 (0건)** — 모든 구현은 확장 영역(`playforge/animation_studio/`, `playforge/tests/run.py`)에만 반영했다.
- **실제 Havok C++ 오라클 및 내재화 비교 자산 (`[확장 추가]`)**:
  - `compare/havok_behavior_oracle.cpp`, `compare/build_havok_behavior_oracle.cmd`: 실제 Havok 2015.1.0-r1 C++ SDK를 링크해 `hkbWorldListener::eventsRaisedCallback` 발화 이벤트, 활성 상태머신·클립 로컬타임, 루트 3D 위치/Yaw, 6개 랜드마크 본 월드 좌표를 60 Hz JSON으로 기록.
  - `compare/assets/hero_docking_clip.res` (`Idle_To_Cover_Standing`, 85본), `compare/assets/soldier_idle_ready_clip.res` (`idle_m4_ready`, 114본 `HipBase_M` 오프셋 정합), `compare/assets/havok_1to1_reference.json` (`663.8 KB`, `.hkt` 문자열 0건, 5개 대표 시나리오 1,445틱 기준 트레이스 내재화).
- **1:1 정밀 비교 엔진 · 인터랙티브 뷰어 · Hero 이벤트 정합 (`[확장 추가]` / `[확장 수정]`)**:
  - `[확장 수정]` `hero/locomotion.gd` (`HeroLocomotion`): 원본 `3rdPersonActionAdventure.hkt`와 동일한 전이·발소리 이벤트 스트림(`StartWalking`, `ToWalking`, `StartRunning`, `Stop`, `FootDown`, `FootUp`, `LeftDown`) 발화 추가.
  - `[확장 추가]` `compare/behavior_1to1_runner.gd` (`HavokBehavior1To1Runner`): 5개 대표 시나리오(`hero_locomotion_flat`, `hero_docking_blend`, `soldier_clip_modes`, `soldier_return_to_prev`, `quadruped_siegefiend`) 60 Hz 동시 시뮬레이션 및 이벤트 타이밍(`Δtick`/`Δms`), 상태머신 일치율, 클립 로컬타임, 루트 XZ/XYZ/Yaw, 6랜드마크 본(월드·포즈) RMS/Max mm 산출. `hkbDockingModifier`의 `hkQsTransform::setInterpolate4` 증분 NLERP 워핑을 1:1 재현해 `hero_docking_blend` 회전 오차를 `0.00°`, 포즈 오차를 `0.10 mm`까지 수렴.
  - `[확장 추가]` `compare/havok_1to1_compare.tscn` · `compare/havok_1to1_compare.gd` (`Havok1To1CompareViewer`): 실 스킨 캐릭터(Hero 85본 / Soldier 114본 / SiegeFiend 34본)와 Havok C++ 실측 랜드마크 리깅(Amber)·궤적·오차 링크를 **겹쳐 비교(Overlap)** / **나란히 비교(Side-by-Side)** 모드로 실시간 대조하며, 틱 스크러버·±1틱 스텝·클릭 시 해당 틱으로 즉시 점프하는 이벤트 타이밍 대조표를 제공 (`demo/hud.tscn`·`demo/hud.gd`·`build_and_test_local_fork.cmd` `compare` 모드 연동 `[확장 수정]`).
- **5개 대표 시나리오 1:1 실측 결과 (총 1,445틱 @ 60 Hz, 총 48건 이벤트 전수 `Δ0틱 / 0.00 ms` 일치)**:

| 시나리오 | 캐릭터 (본) | 틱 수 | 이벤트 일치 (`최대 Δ틱 / Δms`) | 상태 일치 | 클립 시간 RMS | 루트 XZ RMS (Yaw Max) | 포즈 랜드마크 RMS (Max) |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **`hero_locomotion_flat`** | Hero (85본) | 255 | **27 / 27 (`Δ0틱 · 0.00ms`)** | **100.0%** | **0.03 ms** | **0.01 mm** (`0.00°`) | **0.37 mm** (`8.35 mm`) |
| **`hero_docking_blend`** | Hero (85본) | 120 | **5 / 5 (`Δ0틱 · 0.00ms`)** | **100.0%** | **0.03 ms** | **0.00 mm** (`0.00°`) | **0.10 mm** (`1.41 mm`) |
| **`soldier_clip_modes`** | Soldier (114본) | 480 | **5 / 5 (`Δ0틱 · 0.00ms`)** | **100.0%** | **0.03 ms** | **0.00 mm** (`0.00°`) | **0.09 mm** (`1.15 mm`) |
| **`soldier_return_to_prev`** | Soldier (114본) | 340 | **5 / 5 (`Δ0틱 · 0.00ms`)** | **100.0%** | **0.03 ms** | **0.00 mm** (`0.00°`) | **0.57 mm** (`13.16 mm`) |
| **`quadruped_siegefiend`** | SiegeFiend (34본) | 250 | **6 / 6 (`Δ0틱 · 0.00ms`)** | **100.0%** | **0.02 ms** | **34.98 mm** (`2.02°`) | `Pelvis 2.46 mm` *(4다리 FootIK 차이 포함 84.71 mm)* |

- **검증**: 신규 회귀 스위트 `animation_havok_behavior_1to1`([havok_behavior_1to1_verify.gd](animation_studio/tests/havok_behavior_1to1_verify.gd) `[확장 추가]`) **20/20 PASS** 포함 Animation Studio 12종 전체 스위트 통과 및 RTX 4070 실 GPU 5종 스크린샷 육안 검수 완료.
