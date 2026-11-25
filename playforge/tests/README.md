# PlayForge 엔진 패치 회귀 시험

PlayForge 엔진 변경이 upstream 통합 과정에서 조용히 빠지거나 깨지는 일을 잡기 위한 헤드리스 회귀 시험이다.
시험 자산은 upstream 경로와 겹치지 않도록 최상위 `playforge/` 아래에 둔다. ENet/RPC E3 코어 변경 근거와 제거 조건은 [`../NET_DEBUG_E3_ADR.md`](../NET_DEBUG_E3_ADR.md)에 기록한다.

## 실행

```sh
# 저장소 루트에서. 편집기 실행 파일: --godot > 환경 변수 GODOT_BIN > bin/godot.windows.editor.x86_64.console.exe
python playforge/tests/run.py                 # 전체(약 45초, 숨김 예산 30초 소진 시험 포함)
python playforge/tests/run.py --quick         # 30초 소진 시험 생략
python playforge/tests/run.py --only avatar_seal,jolt_api
python playforge/tests/run.py --only enet_rpc_netdebug --godot <현재-소스로-빌드한-Godot>
python playforge/tests/run.py --repeat 2      # 모든 스위트를 두 번(안정성 확인)

# 스위트 하나를 직접 돌릴 때
bin/godot.windows.editor.x86_64.console.exe --headless --path playforge/tests/project res://avatar/avatar_seal.tscn
bin/godot.windows.editor.x86_64.console.exe --headless --fixed-fps 60 --path playforge/tests/project res://jolt/jolt_determinism.tscn
# ENet 장애 주입 / SceneMultiplayer RPC 프로파일링 (현재 소스 빌드 필요)
<현재-소스로-빌드한-Godot> --headless --path playforge/tests/project res://network/net_debug.tscn
```

- 각 시험 씬은 `PFTEST {json}` 한 줄씩 출력한다. `status`: `PASS`/`FAIL`(판정), `INFO`(측정값·시간, 판정 없음), `GAP`(패치 설계 밖 우회 관찰, 판정 없음), `NOT_COVERED`, 끝에 `SUMMARY`. 종료 코드는 FAIL이 있으면 1, 없으면 0.
- `run.py`는 모든 씬을 돌리고 `results/latest.json`(git 제외)에 모은다. FAIL, SUMMARY 없이 끝난 경우(엔진 중단), 시간 초과, 프로세스 간 결정성 불일치가 하나라도 있으면 종료 코드 1.
- 물리 스위트는 `--fixed-fps 60`으로 실시간 동기화를 끄고 돌린다. 물리 틱 수는 같으므로 결과 hash도 같다.
- 실행 파일이 보고한 엔진 커밋과 저장소 HEAD가 다르면 요약에 `MISMATCH`를 찍는다. 이때 실행 결과는 HEAD가 아니라 그 실행 파일에 대한 결과다.
- 시험은 코어 팩(`--playforge-core-pack`) 없이 돈다. 그래서 아바타는 엔진 내장 TPS 대체 아바타(`SealedCapsule`/`SealedCameraPivot` 등)다.

## 시험과 지키는 커밋

| 스위트 | 씬 | 지키는 커밋 | 확인 내용 |
| --- | --- | --- | --- |
| `source_markers` | (run.py 정적 검사) | 7건 전부 | 패치 표식 문자열이 소스에 남아 있는지. 실행으로 볼 수 없는 `70892ae8`(Jolt AVX2/FMA SIMD 빌드 플래그)은 이것만 지킨다 |
| `avatar_bootstrap` | `avatar/bootstrap_empty_3d.tscn` | `a18fb005`, `fe0b4fe1`, `ed003ce5` | 빈 3D 씬에 CoreHUD(layer 128, 봉인, root 내부 자식)·봉인 아바타·바닥·조명 자동 생성, CoreHUD와 아바타 내부 `Sealed*` 노드가 `get_children`/`get_node`/`find_child`에서 숨김, 표현 모드 0, `addons/playforge_avatar/` VFS 봉인, `playforge/avatar/spawn_position` 설정 반영(`ed003ce5`) |
| `avatar_bootstrap_cli_portrait` | 같은 씬 + `-- --avatar-presentation-mode=upper_body` | `fe0b4fe1` | CLI 덮어쓰기로 상반신 초상 UI(layer 115, 최소 128x128)만 뜨고 3D 아바타는 없음 |
| `avatar_seal` | `avatar/avatar_seal.tscn` | `a18fb005` | 봉인 아바타의 `queue_free`·`free`·`remove_child`·`reparent`·`set_script`·`visible=false`·`hide`·`scale` 축소·`process_mode`·`SceneTree.queue_delete` 차단. 각각 위반 카운터 증가와 상태 유지 확인, 봉인 안 된 대조 노드에서는 같은 조작이 효과 있음을 확인 |
| `corehud_seal` | `avatar/corehud_seal.tscn` | `a18fb005`, `fe0b4fe1` | CoreHUD CanvasLayer의 숨김·layer·offset·scale·transform·해제·제거·reparent·스크립트 교체 차단, 플랫폼 바 Control의 숨김·축소(<1)·알파 0.85 하한·해제·process_mode 차단, 사용자 `CanvasLayer.layer` > 100 → 100 클램프(트리 진입 전 포함) |
| `portrait_seal` | `avatar/portrait_seal.tscn` | `fe0b4fe1` | 초상 UI 최소 크기 하한(상반신 128x128, 전신 160x240): `size`·`custom_minimum_size` 클램프, `custom_maximum_size` 하한 미만 거부, 축소·투명화·숨김·해제 차단, `set_platform_min_size`가 스크립트에 노출되지 않음 |
| `portrait_mode_switch` | `avatar/portrait_mode_switch.tscn` | `fe0b4fe1` | 표현 모드 1 → 0 전환 시 초상 UI가 엔진 중단 없이 제거되는지 (**현재 FAIL, 아래 참고**) |
| `sealed_parent_free` | `avatar/sealed_parent_free.tscn` | `a18fb005` | 사용자 스크립트가 봉인 아바타의 부모(현재 씬)를 `queue_free` 해도 엔진이 살아남는지 (**현재 FAIL, 아래 참고**) |
| `hide_budget` | `avatar/hide_budget.tscn` | `ed003ce5` | 임시 숨김 30초 상한, 남은 예산 상한, 실시간 소모(`Engine.time_scale=0`에서도), 0.2초/초 충전, 만료 자동 표시, 소진 후 0.1초 미만이면 거부, CoreHUD 예산 별도, 통합 API |
| `vfs_seal` | `avatar/vfs_seal.tscn` | `a18fb005` | `res://addons/playforge_avatar/` 쓰기(`WRITE`/`WRITE_READ`, `..`·`//` 경로 변형 포함) `ERR_UNAUTHORIZED`로 거부, 사용자 PCK가 봉인 경로 파일을 주입하지 못함(같은 PCK의 비봉인 파일은 보임으로 setup 검증) |
| `seal_gaps` | `avatar/seal_gaps.tscn` | `a18fb005` | 관찰 전용(GAP). 아래 "설계 밖 우회 경로" |
| `jolt_api` | `jolt/jolt_api.tscn` | `83f5f345`, `e7a83dd7` | `PlayForgePhysicsBatch` 클래스·정적 메서드 7개, GSK 기본 모드 2·모드 왕복, 협역 계측(꺼짐 시 미집계, 켜짐 시 `pair_total = hits + misses`, GJK 호출·하이브리드 warm hit > 0, reset), `sync_multimesh_from_bodies`가 16개(직렬)·3000개(≥2048 병렬) 강체 변환과 custom 값을 MultiMesh 버퍼에 정확히 씀(공간 안·밖 강체 모두) |
| `jolt_determinism` | `jolt/jolt_determinism.tscn` | `83f5f345`, `c9050da1`, `e7a83dd7` | 상자 600개(병렬 pre_step 경로) 탑 + 90틱 폭발, 300틱. GSK 모드 2·0·1 각각 새 World3D로 같은 프로세스에서 두 번 → 1cm 양자화 hash 일치. 비트 단위 hash와 시간은 INFO |
| `jolt_determinism_cross_process` | (run.py가 위 스위트를 두 프로세스로 돌려 비교) | 같음 | 프로세스 간 1cm 양자화 hash 일치 (HavokProfile 벤치마크의 "같은 기기 반복 실행" 주장) |
| `jolt_contacts` | `jolt/jolt_contacts.tscn` | `c9050da1` | 강체 800개 + 감지 영역 + 한쪽만 감지하는 layer/mask 강체 + 정적 컨베이어. fast path 뒤에도 `body_entered`/`get_colliding_bodies`/영역 진입·퇴장/해제 후 접촉 제거가 보고되고, 엔진 오류 0건, 위치 유한·바닥 위. 시간은 INFO |
| `enet_rpc_netdebug` | `network/net_debug.tscn` | Forge-Refactoring-Multiplayer E3 | 별도 server/client `SceneMultiplayer` API에서 래퍼 없는 RPC 왕복, 양방향 지연·100% 손실·Off 복구, 메서드별 누적 profiler의 disable/re-enable 동작, ENet `pop_statistic`을 확인. 별도 host의 DTLS 설정 전환에서 지연 큐 폐기와 설정 보존도 검사하지만 DTLS 실통신은 검증하지 않는다. 현재 변경 소스로 빌드한 Godot가 필요 |

## 현재 발견된 엔진 문제 (시험이 FAIL로 남겨 둠)

봉인 노드의 **부모를 권한 범위 밖에서 해제**하면 엔진이 힙 손상(`0xC0000374`)으로 중단된다.
`Node`의 `NOTIFICATION_PREDELETE`가 `data.parent->remove_child(this)`를 부르는데, 자식이 봉인돼 있으면 `remove_child`가 봉인 검사(a18fb005 `scene/main/node.cpp`)에 막혀 자식 포인터가 부모의 `children`에 남는다. 그 뒤 해제된 포인터를 다시 해제하면서 `~Node`의 `Condition "data.parent" is true` 오류 뒤 중단된다.

- `portrait_mode_switch`: 플랫폼 자체 API `set_avatar_presentation_mode(0)`가 초상 레이어를 `PlatformSealScope` 안에서 `queue_free` 하지만, 실제 해제는 다음 프레임 `SceneTree::_flush_delete_queue()`에서 권한 범위 밖으로 일어나 중단된다. 초상 모드(1·2)에서 3D 모드(0)로 바꾸는 정상 경로다.
- `sealed_parent_free`: 사용자 스크립트가 `get_tree().current_scene.queue_free()`만 해도 아바타가 그 씬의 자식이라 같은 방식으로 중단된다.

씬 전환·종료(`_flush_scene_change`, `unload_current_scene`, `SceneTree::finalize`)는 권한 범위 안이라 이 문제가 없다. 시험을 통과시키려고 고치지 않았다.

## 설계 밖 우회 경로 (GAP, 판정 없음)

패치가 막겠다고 한 setter는 모두 막히지만, 다음 경로로는 숨김·축소·제거와 같은 효과를 낼 수 있었다. 패치 보강 판단 자료로 기록만 한다.

- `SceneTree.node_added` 신호로 숨김 처리된 CoreHUD와 내부 Control 참조를 얻을 수 있다(조회 래퍼 우회). 이 시험도 이 경로로 CoreHUD를 잡는다.
- `avatar.transform`에 축소 basis를 넣으면 크기가 줄어든다(`Node3D.set_scale`만 봉인). 위반 카운터도 늘지 않는다.
- 아바타 `global_position`, CoreHUD 플랫폼 바 `position` 변경은 막히지 않아 화면 밖으로 옮겨 사실상 숨길 수 있다.
- `root.remove_child(current_scene)`로 봉인 아바타를 부모째 트리에서 뺄 수 있다.
- Windows에서 `res://addons/PlayForge_Avatar/...`처럼 대소문자만 바꾼 경로로 봉인 디렉터리에 쓸 수 있다(`PackedData::is_path_sealed`가 대소문자 구분).

## 다루지 않는 것과 이유

| 항목 | 커밋 | 이유 |
| --- | --- | --- |
| `--playforge-core-pack`로 실제 코어 팩을 마운트해 우선권을 갖는지, 코어 팩 `avatar_controller.gd`/`avatar_rig.gd`/`avatar_portrait_ui.gd` 경로(아바타 스폰·`PlayerCharacter` 부착·`configure_portrait`) | `a18fb005`, `fe0b4fe1`, `ed003ce5` | 코어 팩 산출물(.pck)과 `addons/playforge_avatar` 소스가 이 저장소에 없다. 엔진 내장 대체 아바타 경로만 시험한다 |
| `--playforge-ugc-pack` 인자 | `a18fb005` | `--main-pack`으로 바뀌는 인자 처리일 뿐이고, 봉인 경로 덮어쓰기 차단은 `load_resource_pack`으로 같은 `PackedData::add_path` 검사를 시험한다 |
| `PlayForgeAvatarSpawn` 씬 노드·`world_binding=attach_player_character`·`camera_mode` 설정 | `ed003ce5` | 코어 팩 스크립트가 있어야 동작한다 |
| CoreHUD 버튼(메뉴·카메라·래그돌·이모트·나가기) 동작 | `a18fb005` | 입력 장치·코어 팩 아바타 메서드가 필요하다. 나가기는 프로세스를 끝낸다 |
| `FileAccess` 봉인이 실제 코어 팩 안 파일을 보호하는지 | `a18fb005` | 코어 팩이 없어 디스크 경로로만 시험한다 |
| `core/math/aabb.h` 무분기 AABB 컬링의 정확성 | `83f5f345` | 스크립트로 직접 부를 경로가 없다. 물리·렌더 시험에서 간접적으로만 지난다 |
| Jolt SIMD(AVX2/FMA) 빌드 플래그가 실제 바이너리에 들어갔는지 | `70892ae8` | 실행 중 관찰할 방법이 없다. `source_markers`가 SCsub 표식만 확인한다 |
| 락프리 JobSystem의 동시성 결함(경쟁 조건) | `83f5f345` | 헤드리스 스모크로는 증명할 수 없다. 결정성·오류 0건으로 간접 확인만 한다 |
| 기기 간·OS 간 결정성 | `70892ae8`, `e7a83dd7` | 같은 기기 반복 실행만 시험한다(패치 기록 JoltPhysics.md의 결정성 범위와 같음) |
| 성능 수치 | Jolt 4건 | 시간과 협역 카운터는 INFO로만 기록하고 판정하지 않는다 |
| 웹(`WEB_ENABLED`)·모바일 빌드 경로 | 전부 | Windows 편집기 바이너리로만 돈다 |

## 파일

- `run.py` 실행기, `.gitignore`(결과·Godot 캐시·실행 중 임시 디렉터리 제외)
- `project/project.godot` 시험 프로젝트(Jolt 사용, `playforge/avatar/spawn_position = (3, 0.5, -2)`)
- `project/lib/pf_test.gd` 결과 출력·오류 수집(`Logger`)·봉인 시도 헬퍼, `evil_*.gd` 스크립트 교체 시도용
- `project/avatar/*`, `project/jolt/*` 시험 씬과 스크립트
- `project/network/*` ENet 장애 주입 및 SceneMultiplayer RPC 프로파일링 회귀 fixture
- 상위 설명과 설계 근거: [`../NET_DEBUG_E3_ADR.md`](../NET_DEBUG_E3_ADR.md)
