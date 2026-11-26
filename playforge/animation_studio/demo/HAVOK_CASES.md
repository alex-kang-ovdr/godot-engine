# Havok 애니메이션 데모 참조와 테스트 매트릭스

검토일 2026-11-26. Havok Animation 2015.1.0-r1의 Windows SDK 소스를 읽고 Godot 4.7.2에서 관찰할 수 있는 동작으로 옮겼다. 아래 수치와 캐릭터는 이 프로젝트의 테스트 데이터다.

로컬 SDK 경로는 `D:\SDK\hk2015_1_0\hk2015_1_0_r1`이다. [실행할 데모](animation_lab.tscn) · [회귀 테스트](../tests/havok_demo.gd)

## 참조-테스트 매트릭스

| SDK 원본과 함수 | 소스에서 관찰한 동작 | Animation Studio 테스트 픽스처와 확인 |
| --- | --- | --- |
| `Demo/Demos/Animation/Api/MotionExtraction/MotionExtraction/MotionExtractionDemo.cpp` — `MotionExtractionDemo::stepDemo()` | `getDeltaReferenceFrame(m_timestep, deltaMotion)`으로 현재 이동량을 얻고 `m_currentMotion.setMulEq()`로 누적한다. 애니메이션을 진행·샘플링한 뒤 누적 변환을 메시 스키닝에 적용한다. 세 애니메이션의 가중치를 좌우 입력에 따라 섞는다. | **합성 조건:** 1초 주기, 캐릭터 로컬 +X로 사이클당 1.2 단위. `tests/havok_demo.gd`에서 1사이클 및 루프 경계 통과 후 누적 이동량, 포즈의 루트 트랙 제외, 캐릭터 heading을 적용했을 때의 월드 이동 방향을 확인한다. SDK 데모의 애셋 이동량이나 속도는 이 수치로 가정하지 않는다. |
| `Demo/Demos/Animation/Api/Playback/Annotation/AnnotationDemo.cpp` — `AnnotationDemo::stepDemo()` | 매 틱 `getNumAnnotations(delta + delay)`와 `getAnnotations()`로 애니메이션 주석을 조회한다. 소스는 `delta=0.016`, `delay=0.25`를 사용하고, 샘플 포즈의 본 모델 공간 위치에 주석 텍스트와 화살표를 표시한다. 주석은 본 ID와 연결된다. | **합성 조건:** 주기 1초의 왼쪽/오른쪽 마커를 각각 0.25초와 0.75초에 둔다. `tests/havok_demo.gd`에서 정방향 재생의 마커 식별자·발생 횟수·루프 경계 통과를 검사한다. 마커 시간과 이름, 단발 이벤트 검사는 테스트용 값이며 SDK 자산의 주석 내용을 재현하지 않는다. |
| `Demo/Demos/Animation/Api/MeshAndDeformation/Attachments/AttachmentsDemo.cpp` — `AttachmentsDemo::stepDemo()` | 결합 포즈를 샘플링하고 본의 모델 공간 변환을 가져온다. `worldFromBone * ba->m_boneFromAttachment`를 계산해 연결된 표시 오브젝트를 갱신한다. 오프셋은 첨부 데이터에서 읽는다. | **합성 조건:** 애니메이션되는 손 본과 고정된 로컬 툴 소켓 오프셋을 만든다. `tests/havok_demo.gd`에서 소켓 월드 변환이 `hand_global * socket_local`과 일치하고 손의 회전·이동을 따라가는지 확인한다. 오프셋 값은 테스트 픽스처 값이며 SDK 첨부 애셋에서 가져오지 않는다. |

## 소스 및 자산 사용 범위

원본 파일에는 Havok SDK의 기밀 및 배포 제한 고지가 있다. 배포 대상에는 자체 제작한 Godot 씬·메시·클립·테스트만 포함한다.

## 실행 결과 · 2026-11-26

Godot 4.7.2 Windows에서 데모 회귀 테스트를 실행했다. 포크 실행 파일 `31e7ebb19`와 네이티브 샘플러 조합으로 두 번 실행했고, 공식 `ed1daf0bf` 실행 파일과 GDScript 조합에서도 깨끗한 프로젝트 사본으로 확인했다. 씬 전환 뒤 데모 카메라가 활성 상태인지 검사하며, 포크의 플랫폼 바와 데모 조작부가 겹치지 않는지도 기본 씬 렌더링으로 확인했다.

- 캐릭터를 Y축으로 90° 돌리고 두 주기를 진행했을 때 이동 거리는 2.4000001 m였고 월드 Z 변위는 −2.399999 m였다.
- 0.5배·1배·2배 재생에서 주기마다 좌우 이벤트가 한 번씩 발생했다. 일시정지 후 한 틱 진행과 초기화 후 재시작도 통과했다.
- 스켈레톤 갱신 신호에서 얻은 444개 샘플에서 예상 손 소켓과 실제 공구의 최대 위치 오차는 0 m였다. 방향과 로컬 오프셋 검사도 모두 통과했다.
