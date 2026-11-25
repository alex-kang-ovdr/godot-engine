# Animation Studio 포즈 재생

Godot 4.7용 런타임 애드온이다. 한 캐릭터의 선택한 본 트랙을 첫 번째 `SkeletonModifier3D`에서 평가한다. 같은 `AnimationPlayer`가 재생 시계, 루트 모션, 이벤트와 나머지 트랙을 담당한다. Windows x64 디버그 빌드에서는 C++ GDExtension으로 한 캐릭터의 트랙들을 한 번에 평가할 수 있다. 확장을 설치하지 않은 프로젝트는 GDScript로 같은 경로를 실행한다.

## 캐릭터에 적용

1. 이 프로젝트의 `addons/animation_studio`를 게임 프로젝트의 같은 경로에 둔다.
2. 대상 `Skeleton3D`에 `SkeletonModifier3D` 자식을 추가하고 [pose_modifier.gd](addons/animation_studio/pose_modifier.gd)를 붙인다. 다른 모디파이어보다 앞에 두고 아래 예시처럼 `PoseModifier`로 이름을 짓는다.
3. 사용할 `AnimationPlayer`의 라이브러리에서 클립을 선택한다. 루트 모션을 쓸 때는 플레이어의 `root_motion_track`을 먼저 지정한다.

```gdscript
@onready var pose = $Skeleton3D/PoseModifier
@onready var player: AnimationPlayer = $AnimationPlayer

func start_walk() -> void:
    if not pose.play_clip(player, &"locomotion/walk"):
        push_warning("걷기 클립을 시작할 수 없습니다.")

func start_cutscene() -> void:
    pose.stop_clip()
    player.play(&"cinematics/intro")
```

`play_clip()`은 원본 리소스를 보존하고 스냅샷으로 파생 클립을 만든 뒤 0초부터 재생한다. 파생 클립 이름은 `AnimationStudioRuntime/pose`이므로 플레이어 신호에도 이 이름이 전달된다. 재생 중에는 원본 수정이 영향을 주지 않고, 다음 호출에 변경이 반영된다. `stop_clip()`은 임시 라이브러리를 해제한다. 루트 변위는 캐릭터 이동 코드가 플레이어에서 한 번만 소비한다.

같은 플레이어를 쓰는 활성 `AnimationTree`, 중복 본 채널, 이미 사용 중인 임시 라이브러리 이름은 바인딩 시 검사한다. 재생 도중 다른 애니메이터가 같은 본을 구동할 때는 먼저 `stop_clip()`으로 제어권을 넘긴다. 현재 재생 전환은 하드 컷이며, 크로스페이드·몽타주·워커 병렬 평가는 후속 단계다.

## Windows x64 네이티브 샘플러 빌드

검증 환경은 Godot 4.7.2, godot-cpp `6cceaf6a`, MSVC 19.44와 SCons 4.11.1이다. 저장소 루트의 x64 개발자 셸에서 `GODOT_CPP_DIR`을 Godot 4.7 API를 제공하는 godot-cpp 소스 디렉터리로 지정하고 실행한다.

```powershell
py -3 -m SCons -C playforge/animation_studio/native platform=windows target=template_debug arch=x86_64
```

빌드가 완료되면 DLL과 확장 설명자가 애드온의 `bin/` 아래에 생긴다. 소스 체크아웃에서 실행하는 Windows 디버그 경로를 지원한다. 배포 템플릿·모바일 패키지에 네이티브 라이브러리를 포함하는 작업은 남아 있다.

## 검증

저장소 루트에서 `GODOT_BIN`을 Godot 편집기 실행 파일로 지정한다.

```powershell
python playforge/tests/run.py --only animation_coexistence,animation_pose_parity,animation_compressed_parity
python playforge/animation_studio/tests/reimport/run_gltf_reimport.py
```

첫 명령은 본 포즈·이벤트·루트 모션·컷신·리타게팅·IK의 공존과 기본 AnimationTree 대비 90틱 포즈 오차를 검사한다. 결과 JSON의 `pose_error.data.native`로 사용한 평가기를 확인할 수 있다. 둘째 명령은 임시 프로젝트에서 glTF를 다시 가져와 변경한 키와 유지한 사용자 트랙을 검사한다. [리뷰의 통과 조건](../ANIMATION_STUDIO_REVIEW.md)
