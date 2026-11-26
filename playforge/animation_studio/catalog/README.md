# Havok Animation 사례 갤러리

Godot 4.7.2에서 [프로젝트](../project.godot)를 열고 F5를 누른 뒤 **애니메이션 사례 목록 →**을 선택한다. [갤러리 씬](gallery.tscn)을 F6로 직접 실행할 수도 있다. 각 항목은 출처와 Godot에서 실행하는 동작을 표시한다. 검색은 원본 영문 이름과 경로에 적용된다.

## 대상과 구현

Havok 2015.1.0-r1 SDK의 `Demo/Demos/Animation`을 대상으로 했다. 등록 선언 115개를 변형별로 펼치면 소스 파일 62개에서 선택 항목 276개가 나온다. 40개 항목은 SDK 기능 설정에 따라 등록된다. 원본 사례와 조건부 변형을 [목록](catalog.json)에 기록하고, 원본 데이터 대신 이 프로젝트의 로봇, 관절 체인, 가중치 메시, 보행 클립으로 동작을 구성했다. 실행에는 SDK가 필요 없다.

| 원본 분야 | Godot에서 볼 수 있는 동작 | 범위 |
| --- | --- | --- |
| Playback, Blending, LayeringAndPartitions | 클립 재생 제어, 이벤트, 속성 트랙, 일반·가산 블렌딩, 상체 필터 | 마스크와 파티션을 Godot 트랙 필터로 표현한다. |
| Retargeting, SkeletalMapping | 비율이 다른 리그 간 포즈 전달과 명시적 본 매핑 | 원본 캐릭터별 매핑·체인 설정은 공유 예제로 대체한다. |
| InverseKinematics, Ragdoll | 움직이는 목표를 향한 IK, 시선·발 목표, 물리 본 체인 | 원본의 다리 수, 전신 제어기와 시나리오별 물리 솔버의 동등성은 검증하지 않았다. |
| MotionExtraction, MeshAndDeformation | 회전하는 루트 이동, 캐릭터 컨트롤러, 손 부착물, 2본 가중합 CPU 스키닝과 엔진 스키닝 | 절차적 메시와 합성 클립을 사용한다. |
| Multithreading, 파티션 병렬 예제 | 고정된 입력에서 리그별 관절을 계산하고 워커 완료 후 표시한다. 단일 스레드와 비교할 기준점을 표시한다. | 원본 잡 그래프와 프로세서별 최적화는 재현 범위 밖이다. |
| Compression, Test/Feature/Compression/Timings | 내장 압축과 원본의 샘플 차이, 샘플 단독·블렌드 평가 시간 및 누적 샘플 수 | Spline·Predictive 등 Havok 코덱별 항목은 Godot 내장 압축 경로를 공유한다. 시간은 이 기기와 이 입력의 관측값이다. |

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
