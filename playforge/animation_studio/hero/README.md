# Havok Hero 원본 재생

[Animation Studio](../project.godot)를 Godot 에디터로 열면 상단 메뉴 **프로젝트 → 도구 → Hero 제작 과정 가상 포인터 다시보기** 또는 하단 패널 **Hero 상태머신**에서 데모 에셋을 빈 씬에서 단계별로 조립하는 가상 포인터 제작 과정 다시보기(14단계, `0.0~14.0s`)와 1~5단계·255틱 로코모션 Rewind를 바로 조작할 수 있다. 에디터 실행 시 실제 `SceneTreeDock`·`FileSystemDock`·`InspectorDock`·3D 뷰포트 위에도 역할별 가상 포인터와 대상 강조 박스가 함께 표시된다. F5 실행 시 **Hero 상태머신 · 제작과정 다시보기 →** 또는 **Havok Hero · 원본 클립 →**을 선택하거나 [Hero 씬](hero.tscn) · [Hero 상태머신 스튜디오](hero_locomotion_studio.tscn)를 F6로 실행할 수 있다. 클립을 선택하고 타임라인을 끌거나 **+ 1/60 s**로 진행한다. **다음 SDK 기준 포즈**는 해당 시각에서 재생을 멈추고 모든 본의 로컬 위치·회전 오차 중 최댓값을 표시한다. 타임라인이 끝나면 클립의 시작 위치로 돌아간다.

## 가상 포인터 제작 과정 다시보기

[가상 포인터 오버레이](authoring_cursor_overlay.gd)와 [14단계 제작 타임라인](authoring_replay.gd)은 4개 역할(`에셋`·`리그·씬`·`상태머신`·`물리·IK`)과 단계 칩(`탐색`·`대상`·`실행`·`변경`·`완료`), 클릭 리플, 대상 위젯 강조 박스를 사용해 빈 씬 → `Motion` 노드 → 85본 와이어프레임 리그 → 18,050정점 스킨 바인딩 → 공유 지형 → `Idle`/`Idle→Walk`/`Walking`/`Running` 상태머신 → 카메라 추적 리드 → 지형 레이캐스트 2본 발 IK → 255틱 궤적 완성까지를 순서대로 재현한다. 타임라인을 뒤로 스크러빙하면 3D 씬 가시성, 씬 트리, 인스펙터 속성, 역할별 작업 로그, 상태머신 단계가 정확히 해당 시점으로 되감긴다.

```powershell
python playforge/tests/run.py --godot $env:GODOT_BIN --only animation_hero_studio
```

## 원본

Havok 2015.1.0-r1의 `Demo/Demos/Behavior/ShowCase/Hero/HeroDemo.cpp`에서 사용하는 캐릭터의 리그, 스킨, 텍스처와 이동 클립을 사용한다. 원본 파일 위치는 SDK의 `Demo/Demos/Resources/Behavior/GameAssets/Hero/` 기준이다.

| 선택 | 원본 |
| --- | --- |
| 캐릭터 | `CharacterAssets/Rig.hkt`, `CharacterAssets/textures/` |
| idle | `Animations/Idle/Idle_0.hkt` |
| walk | `Animations/Walk/Walk_0.hkt` |
| idle_to_walk | `Animations/Walk/Walk_Face_180.hkt` |
| run | `Animations/Run/Run_0.hkt` |
| turn | `Animations/Idle/Idle_To_Run_90.hkt` |

보유한 로컬 SDK에서 읽은 변환 결과는 `hero/generated/`에 생성한다. 이 폴더는 Git에서 제외한다. 다른 체크아웃에서는 같은 SDK에서 다시 생성한다.

## 새 체크아웃에서 생성하기

Windows x64에서 Python 3.10 이상과 Pillow, Visual Studio C++ 빌드 도구, SDK 프로젝트가 지정한 v140 도구 세트가 필요하다. 저장소 루트의 PowerShell에서 실행한다. 다른 경로에 설치한 경우 `$sdk` 값을 변경한다.

```powershell
$sdk = 'D:/SDK/hk2015_1_0/hk2015_1_0_r1'
$hero = 'playforge/animation_studio/hero'
& "$hero/build_oracle.cmd" $sdk
if ($LASTEXITCODE -ne 0) { throw "SDK sampler build failed" }
python "$hero/export_motion.py" --sdk $sdk --oracle "$env:TEMP/codex_havok_oracle/hero_oracle.exe"
if ($LASTEXITCODE -ne 0) { throw "Hero motion export failed" }
python "$hero/export_skin.py" --sdk-root $sdk
if ($LASTEXITCODE -ne 0) { throw "Hero skin export failed" }
```

`motion.json`은 원본 프레임 간격의 재생 키를, `oracle.json`은 SDK에서 샘플링한 기준 포즈를 담는다. 같은 리그의 클립을 추가하려면 모션 변환 명령에 `--clip ID=Animations/하위폴더/파일.hkt`를 붙인다. `hero_skin.gltf`와 같은 폴더에 버퍼와 텍스처가 있어야 한다. 이 데모는 로컬 에디터와 헤드리스 실행에서 파일을 직접 읽는다.

엔진 실행 파일을 지정해 테스트한다.

```powershell
python playforge/tests/run.py --godot $env:GODOT_BIN --only animation_hero_parity
```

## 비교 범위

각 클립의 트랙과 본 사이의 바인딩을 따라 Godot Skeleton3D와 AnimationPlayer를 구성한다. Havok의 Z-up 오른손 좌표를 Godot의 Y-up으로 바꾸는 식은 `(x, z, -y)`다. 본 트랙과 별도로 추출된 루트 이동은 캐릭터 부모 노드에 적용한다.

[포즈 회귀 시험](../tests/hero_parity.gd)은 리그의 모델 좌표계에서 머리·손·발의 준비 자세 위치를 확인한다. 각 클립의 처음·끝 및 키 사이의 시각에 전신 본의 로컬 위치·회전·스케일과 추출 루트 이동·회전을 대조한다. 허용 오차는 위치 1 mm, 회전 0.005 rad, 스케일 벡터 차이 0.001이다.


## 이동 상태와 지형 발 IK

Hero 씬에서 **이동 · 발 IK**를 누르면 같은 스틱과 왼쪽 트리거 입력 255틱을 60 Hz로 반복한다. 입력은 대기 30틱, 전진 걷기 60틱, 전진 달리기 60틱, 달리는 중 오른쪽 입력 45틱, 입력 해제 60틱이다. **클립 검증**으로 돌아가 원본 포즈 검증을 계속한다.

Godot은 Hero SDK의 좌측 트리거 임계값, 스틱 보간과 정지 판정, 보행별 방향 보정 계수를 적용한다. 재생의 전진 입력은 월드 −Z 방향을 향한다. 출발할 때 원본 그래프가 선택한 `Walk_Face_180.hkt`가 리그를 해당 방향으로 돌린다. 기존 Hero 클립을 재생하면서 루트 이동을 루프 경계에서 누적한다. 각 발 아래의 충돌 지표를 확인해 두 관절을 풀고 발 방향을 면의 법선에 맞춘다. 동일한 상자 4개를 양쪽 엔진에 구성해 평지, 두 계단, 기울어진 지면을 대조하도록 했다. 원본 그래프에서 관측한 클립 겹침을 바탕으로 선형 블렌드를 적용한다. 나머지 방향별 출발과 전체 캐릭터 컨트롤러는 추가 포팅 범위다.

Godot 자체 시험은 동일 입력 재생 두 번을 대조한다. 두 엔진의 경로가 −Z 방향을 향하므로 +Z 계단에서의 발 IK는 별도 프로브로 확인한다. 저장소의 이전 변환 결과가 있으면 모션 변환 명령을 다시 실행해 걷기 진입 클립을 추가한다.

```powershell
python playforge/tests/run.py --godot $env:GODOT_BIN --only animation_hero_behavior
```

Havok 대조는 같은 SDK 버전의 Behavior 제품 키가 활성화된 SDK 환경을 사용한다. 실행기는 Hero 프로젝트의 3인칭 Behavior 그래프와 Physics 캐릭터 변형을 로드하고 공유 시험 지형에서 상태, 루트 위치, 좌우 발목 위치를 기록하도록 구성됐다.

```powershell
$sdk = 'D:/SDK/hk2015_1_0/hk2015_1_0_r1'
$hero = 'playforge/animation_studio/hero'
$project = "$sdk/Demo/Demos/Resources/Behavior/GameAssets/Hero/Project/HeroProject.hkt"
& "$hero/build_native_behavior.cmd" $sdk
if ($LASTEXITCODE -ne 0) { throw "Havok Behavior runner build failed" }
& "$env:TEMP/codex_havok_behavior/native_behavior.exe" $project "$hero/generated/behavior_trace.json"
if ($LASTEXITCODE -ne 0) { throw "Havok Behavior simulation failed" }
python playforge/tests/run.py --godot $env:GODOT_BIN --only animation_hero_behavior_native
```

### 이동 방향과 상태 전이 대조

Havok과 Godot에서 같은 스틱·트리거 입력 255틱을 사용했다. 전이 시점은 0부터 센다. Havok 쪽은 `Locomotion State Machine`의 현재 상태를 기록했다.

| 상태 | 수정 전 Godot | 수정 후 Godot | Havok |
| --- | ---: | ---: | ---: |
| Idle | 0 | 0 | 0 |
| Idle to Walk | — | 31 | 31 |
| Walking | 30 | 57 | 57 |
| Running | 90 | 90 | 90 |
| 정지 후 Idle | 201 | 202 | 202 |

상태 불일치는 28틱에서 0틱으로 줄었다. 아래 수치는 같은 지형에서 궤적 정렬 없이 구한 월드 거리다. 발목 오차에는 루트 경로 차이가 포함된다.

| 대상 | 1차 보정 (m) | 2차 보정 (m) | 최대 1차 → 2차 (m) | 마지막 틱 1차 → 2차 (m) |
| --- | ---: | ---: | ---: | ---: |
| 루트 | 0.156 | 0.031 | 0.322 → 0.065 | 0.322 → 0.032 |
| 왼쪽 발목 | 0.255 | 0.037 | 0.506 → 0.074 | 0.316 → 0.049 |
| 오른쪽 발목 | 0.247 | 0.035 | 0.456 → 0.074 | 0.327 → 0.043 |

2차 보정에서는 Havok 원본 스크립트(`hero_camera.lua`, `hero_locomotion.lua`)의 3인칭 카메라 리드 각도, 전환 블렌딩의 Smoothstep 커브 및 틱 길이(`Idle` 10틱, `Walk→Run` 4틱), `Walk→Run` 블렌드 중 보행 회전 속도(`2.0`) 유지, 그리고 스윙 페이즈 발 IK 페이드아웃을 반영했다. `t=40..254`(215틱, 11.3 m 이동·회전·정지) 구간의 XZ 누적 오차는 0.1 mm 수준이다. 남은 3~7 cm(최대 오차 `tick 32`)는 스폰 원점 `(0, 0, 0)`에서 Havok 물리 캐릭터 캡슐이 공유 지형의 `Slope` 모서리와 겹쳐 초기 32틱 동안 밀리는 현상과, 평지(`y = -0.02`) 대비 물리 캡슐 수직 안착(`+0.028 m`) 및 Godot 평지 발 IK 보정(`-0.02 m`) 차이에서 비롯된다.

수정 후 공식 Godot 4.7.2의 반복 재생에서 같은 결과를 얻었으며, 세 위치 검사는 물리 캡슐 초기 충돌·수직 오프셋으로 인해 여전히 1 cm 허용치를 초과한다.
