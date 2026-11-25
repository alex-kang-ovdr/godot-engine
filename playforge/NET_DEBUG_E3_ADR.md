# E3 ADR: ENet 장애 주입과 RPC 프로파일링

상태: 포크 구현과 회귀 fixture 작성 완료. upstream 제출 여부는 아직 확인·결정되지 않았다.

## 이유와 범위

PlayForge의 임의 `@rpc` 호출은 사용자 노드 메서드로 바로 선언할 수 있다. addon 래퍼만으로는 래퍼를 거치지 않는 메서드를 빠짐없이 계측하거나 직렬화된 RPC payload 크기를 읽을 수 없다. 누적 메서드별 송수신 계측은 `SceneRPCInterface` 경계에 있어야 한다. 패킷 지연과 손실은 ENet의 실제 데이터그램 처리 경계에 적용해야 ENet의 신뢰성, 재전송, throttle 동작을 그대로 관찰할 수 있다. 별도 addon 전송 구현은 이 동작을 대체하게 되므로 동등한 대안이 아니다.

기존 `MultiplayerDebugger::RPCProfiler`는 노드/ObjectID별 계측이며 디버거 프레임마다 결과를 비운다. 새 프로파일러는 각 `SceneMultiplayer` 인스턴스 안에서 메서드별·누적·원격 호출만 계측한다. 두 결과의 키와 수명, 집계 단위가 다르므로 합산하지 않는다. 로컬 실행은 새 프로파일러에 포함하지 않는다. 이 API는 Godot 디버거 프로파일러를 대체하거나 수정하지 않는다.

ENet 장애 주입은 해당 ENet host의 datagram 송수신에만 적용한다. 기존 인증, 복제, 기본 peer 설정, 신뢰성 정책, throttle 정책은 바꾸지 않는다. 설정은 로컬 런타임 디버그 명령으로 조절하며 `NetEmulation.Off`로 즉시 해제할 수 있다. 이 API는 `builtin_enet` 구현에 한정된다.

Epic의 [Unreal Engine Network Emulation 문서](https://dev.epicgames.com/documentation/unreal-engine/using-network-emulation-in-unreal-engine)와 [Network Profiler 문서](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-the-network-profiler-in-unreal-engine)는 지연·손실 테스트와 RPC별 트래픽 확인의 유사한 개발자 용례를 보여준다. 이는 사용 사례의 참고이며 구현 또는 API 호환성을 뜻하지 않는다. 이 포크에서 지원하는 명령은 아래 네 가지와 `Off`뿐이다. Unreal의 지연 min/max·variance·jitter, 순서 변경·복제, 프로파일 프리셋은 지원하지 않는다.

| 명령 | 값과 단위 | 방향 |
| --- | --- | --- |
| `NetEmulation.PktLag <ms>` | 정수 0–60000, 밀리초 | outgoing |
| `NetEmulation.PktIncomingLag <ms>` | 정수 0–60000, 밀리초 | incoming |
| `NetEmulation.PktLoss <percent>` | 유한한 수 0–100, 퍼센트 | outgoing 손실 확률 |
| `NetEmulation.PktIncomingLoss <percent>` | 유한한 수 0–100, 퍼센트 | incoming 손실 확률 |
| `NetEmulation.Off` | 인자 없음 | 모든 방향의 지연·손실을 0으로 복원하고 대기 datagram을 다음 host poll에서 배출 가능하게 함 |

## 계측 해석

`SceneMultiplayer.get_rpc_profile()`은 메서드별 `{sent, received, sent_bytes, received_bytes}` 누적 snapshot을 반환한다. byte 값은 RPC 메시지 인코딩 크기이며 ENet 헤더, 재전송 횟수, 암호화 오버헤드, UDP/IP·OS 네트워크 오버헤드를 포함하지 않는다. ENet `pop_statistic()`은 host 전송 통계이며 RPC 메서드에 귀속되지 않는다. 이 두 계층의 수치는 별도로 살핀다.

## 회귀와 사용 예시

`playforge/tests/project/network/net_debug.tscn`은 한 프로세스에서 별도 `SceneMultiplayer` API와 ENet server/client를 구성하고, 래퍼 없는 `@rpc` 왕복, 양방향 지연·손실, `Off` 복구, profiler 누적/중지/재시작, ENet host 통계를 검증한다. 100% 손실은 unreliable RPC에 적용해 재전송 없이 복구 동작을 결정적으로 검사한다. 임시 ENet host에서 loopback UDP datagram을 지연 큐에 둔 뒤 DTLS client 설정으로 전환하는 검사는 큐 폐기 카운터와 impairment 설정 보존만 확인한다. DTLS handshake나 암호화된 실통신을 검증하지 않는다.

검증 기록: Windows SCons 빌드가 68.44초에 완료됐다. 현재 소스 바이너리에서 `python playforge/tests/run.py --only enet_rpc_netdebug --repeat 2`를 실행해 매회 33/33 검사가 통과했다. 이전 단일 실행에서는 설정 outgoing 지연 120 ms에서 130.6 ms를 관측했다. DTLS 설정 전환 검사는 큐 폐기·설정 보존만 확인하며 실통신 결과는 포함하지 않는다.

저장소 루트에서 현재 소스로 빌드한 Godot 실행 파일을 지정해 실행한다:

```sh
python playforge/tests/run.py --only enet_rpc_netdebug --godot <현재-소스로-빌드한-Godot>
```

직접 실행:

```sh
<현재-소스로-빌드한-Godot> --headless --path playforge/tests/project res://network/net_debug.tscn
```

GDScript 런타임에서 로컬 디버그 제어와 두 계층 통계 조회:

```gdscript
var scene_mp := multiplayer as SceneMultiplayer
scene_mp.set_rpc_profiling_enabled(true)
var rpc_snapshot: Dictionary = scene_mp.get_rpc_profile()

var enet: ENetConnection = multiplayer.multiplayer_peer.get_host()
enet.apply_debug_packet_command("NetEmulation.PktLag 120")
enet.apply_debug_packet_command("NetEmulation.PktLoss 5")
var impairment: Dictionary = enet.get_debug_packet_simulation()
var enet_sent_bytes := enet.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
enet.apply_debug_packet_command("NetEmulation.Off")
```

`pop_statistic()`은 읽은 항목을 초기화하므로 샘플 구간별로 값을 수집한다. 예시는 로컬 개발용 런타임 제어이며 네트워크 클라이언트가 원격으로 설정을 변경하는 프로토콜이 아니다.

ENet `pop_statistic()`은 ENet host 단위 wire 통계다. RPC 프로파일의 method별 payload 통계와 구분하며 둘을 더하지 않는다.

## upstream 상태와 제거 조건

이 ADR이 기록되는 시점에 변경은 엔진 포크에만 있으며 upstream 반영 여부는 미확인이다. upstream Godot에 동일 범위의 `SceneMultiplayer` 누적 profiler와 ENet host datagram 시뮬레이션 기능이 제공되면, `enet_rpc_netdebug`를 upstream 빌드에서 실행해 동등한 결과를 확인한 뒤 포크 코드를 제거한다. 또한 ENet 기본 전송을 더 이상 사용하지 않거나 이 디버그 기능을 유지할 필요가 없어지면 기능과 fixture를 함께 제거한다. 제거 시 지연·양방향 손실·Off 복구 및 profiler 의미가 유지되는 대체 검증을 먼저 확보한다.
