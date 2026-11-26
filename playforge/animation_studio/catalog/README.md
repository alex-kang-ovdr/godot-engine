# Havok Animation · Behavior 사례 갤러리

Godot 4.7.2에서 [프로젝트](../project.godot)를 열고 F5를 누른 뒤 **애니메이션 사례 목록 →**을 선택한다. [갤러리 씬](gallery.tscn)을 F6로 직접 실행할 수도 있다. 각 항목은 출처와 Godot에서 실행하는 동작을 표시한다. 제품 필터(`Animation` / `Behavior`), 분야 필터, 영문 이름·경로 검색을 조합할 수 있다.

## 대상과 구현

Havok 2015.1.0-r1 SDK의 `Demo/Demos/Animation`과 `Demo/Demos/Behavior`를 모두 대상으로 했다. 등록 선언 218개를 변형별로 펼치면 소스 파일 **121개**에서 선택 항목 **414개**(Animation 276개 / 62소스 + Behavior 138개 / 59소스)가 나온다. 조건부 등록 128개와 미등록 소스 1개를 포함해 [목록](catalog.json)에 기록하고, 원본 데이터 대신 이 프로젝트의 로봇, 4족/2족 관절 체인, 능동 랙돌, 포즈 그래프·관성 블렌더·Rewind, 병렬 워커 군중으로 동작을 구성했다. 실행에는 SDK가 필요 없다.

| 제품 · 원본 분야 | Godot에서 볼 수 있는 동작 | 범위 |
| --- | --- | --- |
| Animation · Playback, Blending, LayeringAndPartitions | 클립 재생 제어, 이벤트, 속성 트랙, 일반·가산 블렌딩, 상체 필터 | 마스크와 파티션을 Godot 트랙 필터로 표현한다. |
| Animation · Retargeting, SkeletalMapping | 비율이 다른 리그 간 포즈 전달과 명시적 본 매핑 | 원본 캐릭터별 매핑·체인 설정은 공유 예제로 대체한다. |
| Animation · InverseKinematics, Ragdoll | 움직이는 목표를 향한 IK, 시선·발 목표, 물리 본 체인 | 원본의 다리 수, 전신 제어기와 시나리오별 물리 솔버의 동등성은 검증하지 않았다. |
| Animation · MotionExtraction, MeshAndDeformation | 회전하는 루트 이동, 캐릭터 컨트롤러, 손 부착물, 2본 가중합 CPU 스키닝과 엔진 스키닝 | 절차적 메시와 합성 클립을 사용한다. |
| Animation · Multithreading, Compression, Timings | 워커 병렬 평가, 내장 압축 샘플 차이, 평가 시간 및 누적 샘플 수 | Havok 코덱별 항목은 Godot 내장 압축 경로를 공유한다. |
| Behavior · Api/Docking | 정지·이동·다중·매달림 목표 마커로 캐릭터 정렬 및 접합 수렴 | `behavior_cases.gd`의 도킹 이동·수렴 거리 계측으로 재현한다. |
| Behavior · Api/Drivers | 2족/4족 발 IK(경사·회전 플랫폼), 손 IK, `CharacterBody3D` 컨트롤러, 공개 API 능동 랙돌(`ActiveRagdollJoint`) | 4족 레이캐스트 접지, 회전 플랫폼, PD 토크 제어 관절을 실행한다. |
| Behavior · Api/Generators, StateMachine, Sequence | `PoseGraph` + `InertialBlender` 상태 전이, 속도/기준포즈 생성기, 시퀀스, 상체 슬롯 | 관성 전환과 단일 베이스 클립 평가, 전이 횟수를 계측한다. |
| Behavior · Api/Modifiers, ShowCase, Test, UseCase | 소켓 부착(캐릭터·오브젝트), 시선/조준(`LookAt`/`GunSweep`), 리타게팅, 이동 플랫폼, 상태 저장·복원(`RewindRecorder`), 상체 부분/충격 반응(`Stagger`), 스킨 교체, 2인스턴스 결정성 대조, 병렬 군중(`Orcs`/성능) | 원본 `.hkt` 그래프 자산 대신 공유 Godot 리그·그래프 런타임으로 핵심 동작을 재현한다. |

## 재현과 검증

저장소 루트에서 Godot 편집기 경로를 `GODOT_BIN`에 지정하고 실행한다.

```powershell
python playforge/tests/run.py --only animation_gallery,animation_havok_demo
```

[회귀 테스트](../tests/animation_gallery.gd)는 모션 실험실에서 갤러리를 연 뒤 모든 항목을 선택해 물리 틱과 표시 프레임을 진행한다. 실행 노드·표시 객체·상태 출력, 주요 런타임 실험의 측정값, 검색·분야 필터와 복귀 경로를 확인한다. 원본 SDK 실행 결과와 포즈·프레임 시간을 수치 비교하는 시험은 별도 과제다.

같은 SDK 버전에서 목록을 다시 생성할 때는 다음 명령을 사용한다.

```powershell
python playforge/animation_studio/catalog/generate_catalog.py D:/SDK/hk2015_1_0/hk2015_1_0_r1
```
