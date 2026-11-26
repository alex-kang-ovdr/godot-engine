# Havok Hero 원본 재생

[Animation Studio](../project.godot)를 실행해 **Havok Hero · 원본 클립 →**을 선택하거나 [Hero 씬](hero.tscn)을 F6로 실행한다. 클립을 선택하고 타임라인을 끌거나 **+ 1/60 s**로 진행한다. **다음 SDK 기준 포즈**는 해당 시각에서 재생을 멈추고 모든 본의 로컬 위치·회전 오차 중 최댓값을 표시한다. 타임라인이 끝나면 클립의 시작 위치로 돌아간다.

## 원본

Havok 2015.1.0-r1의 `Demo/Demos/Behavior/ShowCase/Hero/HeroDemo.cpp`에서 사용하는 캐릭터의 리그, 스킨, 텍스처와 이동 클립을 사용한다. 원본 파일 위치는 SDK의 `Demo/Demos/Resources/Behavior/GameAssets/Hero/` 기준이다.

| 선택 | 원본 |
| --- | --- |
| 캐릭터 | `CharacterAssets/Rig.hkt`, `CharacterAssets/textures/` |
| idle | `Animations/Idle/Idle_0.hkt` |
| walk | `Animations/Walk/Walk_0.hkt` |
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

Godot은 Hero SDK의 좌측 트리거 임계값, 스틱 데드존, 입력 해제 시 정지 지연과 보행별 방향 보정 계수를 적용한다. 기존 Hero 클립을 재생하면서 루트 이동을 루프 경계에서 누적한다. 각 발 아래의 충돌 지표를 확인해 두 관절을 풀고 발 방향을 면의 법선에 맞춘다. 동일한 상자 4개를 양쪽 엔진에 구성해 평지, 두 계단, 기울어진 지면을 대조하도록 했다. 방향별 출발·정지 전환 클립, 보행 블렌딩과 캐릭터 컨트롤러는 추가 포팅 범위다.

Godot 자체 시험은 동일 입력 재생 두 번을 대조한다. 공식 Godot 4.7.2에서 255틱 동안 지면 감지 510회, 높은 지면 감지 59회, IK 적용 후 목표에 최소 5 mm 가까워진 발목 샘플 504회를 기록했다.

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

현재 설치본에서 실행기는 컴파일·링크와 캐릭터 생성까지 진행했다. Havok 런타임은 `Product:hkb Key Code is invalid or is for a different product version`을 반환했고 기준 트레이스 생성을 중단했다. 대조 시험은 입력과 상태를 틱별로 비교하고 위치 허용 오차를 1 cm로 둔다. 기준 트레이스가 없는 상태에서도 명시적으로 실행하면 실패를 보고한다.
