# PlayForge Animation Studio — Godot 에디터 확장 Addon UI/UX 디자인 시안 요청서

- **문서 목적**: `addons/animation_studio` 표준 Godot `EditorPlugin` 에디터 확장의 **UI/UX 시각 디자인·컴포넌트 시스템·인터랙션 시안 제작 요청**
- **작성일**: 2026-11-27
- **기술 기반**: Godot `4.7.2` 표준 `EditorPlugin` 도킹 아키텍처 (`[엔진 수정] 없음 (0건)`, `[엔진 추가] 없음 (0건)`, `[확장 추가]` 기반)
- **참고 아키텍처 명세**: [ANIMATION_STUDIO_ARCHITECTURE_AND_API.md](ANIMATION_STUDIO_ARCHITECTURE_AND_API.md)

---

## 1. 프로젝트 개요 및 디자인 목표

PlayForge Animation Studio는 Godot 에디터 안에서 **실제 3D 씬에 배치된 캐릭터 인스턴스**(`Hero 85본 + 10 Lua + AI Pathfinding`, `4족 절차적 Locomotor`, `28종 내재화 캐릭터`)를 선택하고, **스켈레톤 계층 · 상태/파라미터/AI · 애니메이션 플로우 그래프**를 실시간으로 제어·검증·제작할 수 있는 에디터 확장 애드온입니다.

### 핵심 디자인 원칙 (Must-Have)
1. **Godot 기본 에디터와 이질감 없는 네이티브 도킹 경험**:
   - 커스텀 전체화면 뷰포트를 강제하지 않고 **Godot 표준 `3D` 뷰포트**를 그대로 사용합니다.
   - 모든 확장 창은 Godot 기본 도크(`씬`, `파일시스템`, `인스펙터`, `애니메이션` 하단 패널)와 동일하게 **드래그 이동·탭 병합·분할·접기·플로팅**이 가능한 좁은 폭/낮은 높이 대응 반응형 레이아웃으로 설계해야 합니다.
2. **인스턴스 중심 컨텍스트 전환 (Instance-Driven Context)**:
   - 3D 뷰포트 / 씬 트리 / 좌측 계층 도크 어느 곳에서 캐릭터를 선택하든 우측 **상태 도크**와 하단 **Animation Flow**가 해당 캐릭터 역할(`Hero + AI`, `4족 Locomotor`, `28종 캐릭터 비교`)에 맞춰 즉시 전환됩니다.
3. **고밀도 테크니컬 툴의 시각적 위계와 즉각적 피드백**:
   - 3D 오버레이(NavMesh, 140개 Spatial Analysis UserEdges, A\* 경로, 90개 도킹 라인)와 도크 UI 간 **색상 언어를 1:1 통일**해, 사용자가 도크의 상태/필터를 클릭했을 때 3D 뷰포트 변화를 즉각 인지할 수 있어야 합니다.
4. **데스크톱 로컬 포크 에디터 + 웹 에디터(WASM) 겸용**:
   - `1280×720`(최소/웹 기본), `1920×1080`(권장), `2560×1440`(고해상도/1.5x 스케일) 환경에서 텍스트 잘림이나 가로 스크롤 없이 동작해야 합니다.

### 타깃 사용자 (Personas)
- **애니메이터 / 테크니컬 애니메이터**: 28종 캐릭터 클립 검수, 85~114본 계층 포즈 확인, Float32 vs 16-bit 압축 정밀도·메모리 비교, 상태머신 전이 점검.
- **게임플레이 / AI 디자이너**: Hero 배경맵 위에서 엄폐·난간넘기·등반·도약 및 Spatial Analysis · A\* Pathfinding · CostModifier 경로 반응을 실시간 테스트.

---

## 2. 전체 에디터 워크스페이스 정보 구조 (IA) 및 레이아웃

```text
+---------------------------------------------------------------------------------------------------+
| [웹 전용 Topbar 34px] ◆ GODOT 4.7.2 WEB EDITOR | 상태 배지 | [로컬 포크 런처] [로컬 에디터 열기] [새로고침] |
+---------------------------------------------------------------------------------------------------+
| Godot 메뉴바 (씬 · 프로젝트 · 디버그 · 편집기 · 도움말)     [2D] [*3D*] [스크립트] [게임]      [▶][⏸][■] |
+-------------------------+---------------------------------------------+---------------------------+
| [좌측 상단: Godot 기본] | [중앙: Godot 표준 3D 뷰포트]                 | [우측 상단: Godot 기본]    |
| 씬 트리 (Hero_Arena 등)  |  - hero_arena_world.tscn 실배치 4+ 캐릭터   | 인스펙터                   |
+-------------------------+  - 클릭 선택 · 이동 기즈모(W/E/R) · F 포커스 | (AnimationStudioInstance  |
| [좌측 하단: 확장 도크]   |  - 3D 오버레이:                             |  @export 속성 직접 편집)   |
| ★ AnimStudio · 계층 ★   |    · 다층 NavMesh / 140 UserEdges 호(arc)   +---------------------------+
|  (파일시스템·이력 탭 병렬)|    · 활성 A* 경로 리본 / 목표 비콘           | [우측 하단: 확장 도크]     |
|  1. 씬 캐릭터 인스턴스   |    · 90개 도킹 라인 (Red/Green/Blue/Orange) | ★ AnimStudio · 상태 ★     |
|  2. + 배치 / 포커스 바   |                                             |  (선택 인스턴스 역할별 UI)  |
|  3. 스켈레톤 본 계층 트리 +---------------------------------------------+  · Hero Lua + AI 자율주행  |
|  4. 선택 본 실시간 포즈  | [하단 패널: 확장 도크 — ★ Animation Flow ★]  |  · 4족 Locomotor 보행제어  |
|                         |  (출력·디버거·오디오·애니메이션 탭 병렬)      |  · 28종 클립·16-bit 비교   |
|                         |  [연결 배지][▶/⏸][+1/60s][1.0x][===스크러버===]|                           |
|                         |  [인터랙티브 베지어 상태머신 / 파이프라인 그래프]|                           |
+-------------------------+---------------------------------------------+---------------------------+
```

### 도크 슬롯 규격 (Godot `EditorPlugin` 구현 기준)

| 도크 영역 | 구현 파일 `[변경 성격]` | Godot 슬롯 | 최소 크기 | 권장 폭/높이 |
| :--- | :--- | :--- | :---: | :---: |
| **좌측 도크** (`AnimStudio · 계층`) | `docks/hierarchy_dock.gd` `[확장 추가]` | `DOCK_SLOT_LEFT_BR` | `240 × 260 px` | 폭 `280~340 px` |
| **우측 도크** (`AnimStudio · 상태`) | `docks/state_dock.gd` `[확장 추가]` | `DOCK_SLOT_RIGHT_BL` | `260 × 260 px` | 폭 `300~380 px` |
| **하단 패널** (`Animation Flow`) | `docks/flow_bottom_panel.gd`, `flow_graph_canvas.gd` `[확장 추가]` | Bottom Panel (`Animation Flow`) | `360 × 210 px` | 높이 `220~300 px` |
| **웹 에디터 상단 바** *(웹 전용)* | `web_editor/index.html` `[확장 추가]` | Fixed Topbar | `100% × 34 px` | 높이 `34 px` |

---

## 3. 시안 제작 요청 화면 목록 (Screen-by-Screen 명세)

디자이너께 아래 **6개 핵심 화면(및 상태 변형)**에 대한 Figma 시안 및 컴포넌트 정의를 요청합니다.

---

### 시안 1. 좌측 도크 — `AnimStudio · 계층` (`hierarchy_dock.gd`)

#### 현재 기능 구성
1. **헤더 바**: 섹션 제목(`씬 캐릭터 인스턴스`), 카운트 필(`4개`), `새로고침` 아이콘 버튼.
2. **씬 캐릭터 인스턴스 리스트**:
   - 각 행 정보: 역할 아이콘/색상 점 + 노드명 + 캐릭터/본 수 + **실시간 활성 상태 태그**
     - 예: `Hero_Arena` · `Hero 85본 · 10 Lua` · `[Hanging]` 또는 `[AI: ClimbUp]`
     - 예: `Soldier_M4` · `114본` · `[Float32]` / `[16-bit C++]`
     - 예: `Quadruped_Locomotor` · `28본` · `[TROT]`
     - 예: `OrcCaptain` · `73본` · `[Float32]`
   - 단일 클릭: 3D 뷰포트 + 씬 트리 + 인스펙터 + 우측/하단 도크 동시 선택.
   - 더블클릭: 3D 뷰포트 카메라 자동 `Focus Selection`.
3. **인스턴스 스폰 & 포커스 액션 바**:
   - 드롭다운(Hero Arena / 4족 Locomotor / 28종 전체 캐릭터 + 본 수) + `+ 배치` 버튼 + `포커스` 버튼.
4. **스켈레톤 본 계층 섹션**:
   - 헤더(`스켈레톤 본 계층`) + 인라인 검색 입력창(`본 검색...`, clear 버튼 포함).
   - 계층형 `Tree` (`BoneName [#index]`, 접기/펼치기, 검색 시 플랫 필터링).
   - **하단 고정 포즈 리드아웃 카드**: 선택 본의 `[#idx] BoneName`, `Local Pos (X,Y,Z)`, `Local Rot (deg)`, `Global Pos (X,Y,Z)` 고정폭 숫자(`tabular-nums`) 표시.

#### 디자인 개선 요청 포인트
- 현재 `ItemList` 단순 텍스트 행을 **역할별 컬러 인디케이터 + 상태 배지 칩(Chip) + 우측 호버 포커스 아이콘** 형태로 정돈해 주세요.
- 본 계층 트리와 하단 포즈 카드 사이에 드래그 가능한 스플리터(또는 접기 가능한 포즈 Inspector 카드) 시안을 제안해 주세요.

---

### 시안 2. 우측 도크 — `AnimStudio · 상태` (`state_dock.gd`) — 3가지 역할별 컨텍스트 변형

상단 공통 헤더: **바인딩 인스턴스 제목**, **역할 배지**, **실시간 좌표 `(X, Y, Z)` · 활성 상태 · 활성 클립 요약 바**.

#### 변형 2-A: `Hero Arena + AI Pathfinding` (`role == "hero_arena"`)
- **AI Pathfinding 자율 주행 섹션 (핵심 신규 기능)**:
  - 메인 토글 스위치: `AI Pathfinding 자율 주행 (Spatial Analysis + A*)`
  - 미션 프리셋 2열 버튼 그리드: `AI 풀코스 100%`, `AI 정상 10.25m`, `AI 전술 엄폐`, `AI 난간 슬라럼` *(확장: `지하 참호 탈출`, `고지대 선호`)*
  - *(Phase 2 요청 포함)* `CostModifier` 드롭다운(`Shortest` / `PreferHigh` / `TacticalCover` / `ParkourExpress`), UserEdge 필터 칩(`Vault` `Climb` `Leap` `Drop` `Cover`), 동적 장애물 토글
  - 실시간 AI 요약 카드: 현재 목표 웨이포인트 `(N/9)`, 현재 구간 타입(`Walk`/`Vault`/`ClimbUp`/`Leap`/`DropDown`/`CoverRoll`), 경로 길이(`m`), **12/12 전체 맵 기능 커버리지 미니 체크 그리드**
- **수동 파쿠르 · Lua 시나리오 섹션 (접기/펼치기 Accordion 권장)**:
  - 6종 시나리오 버튼: `로코모션`, `엄폐(Cover)`, `볼트(Vault)`, `클라임(Climb)`, `도약(Leap)`, `스트레이프`
  - 5종 Lua 이벤트 버튼: `JumpButton`, `Action`, `WeaponToggle`, `Attack`, `Strafe`
  - 옵션 토글: `자동 파쿠르 투어 순환`, `90개 도킹 라인 오버레이 표시`
- **실시간 Lua 상태 & 변수 카드**:
  - 상태 / 최근 이벤트 / 카메라 모드 / 활성 도킹 라인 번호
  - 변수 키-값 2열 테이블(`CharacterSpeed`, `Direction`, `SwordEquipped`, `CoverEdgeAngle`, `VaultHeight`, `ClimbHeight`, `LeapDistance`, `IsFalling`)

#### 변형 2-B: `4족 절차적 Locomotor` (`role == "quadruped"`)
- **보행 모드 세그먼트 컨트롤**: `Auto` · `Walk` · `Trot` · `Pace` · `Gallop`
- **목표 속도 슬라이더** (`0.00 ~ 5.50 m/s`, 구간별 Walk/Trot/Gallop 임계 눈금 표시 제안) + `제자리 순환 보행` 토글
- **실시간 동역학 텔레메트리 카드**:
  - 활성 보행 배지, 실속도(`m/s`), Pelvis 높이(`Y`)/Pitch/Roll 수치
  - **4발 접지 시각 인디케이터 (`FL` / `FR` / `HL` / `HR`)**: `PLANTED`(청록 채움) vs `SWING`(주황 외곽선) + 최대 접지 슬립(`0.00 mm`) 강조 표시

#### 변형 2-C: `28종 캐릭터 로스터 & 16-bit C++ 비교` (`role == "character"`)
- **캐릭터 전환 드롭다운** (28종 검색 가능/카테고리 뱃지 포함 시안 제안: `전투 7` · `크리처 6` · `쇼케이스 6` · `리타게팅 9`)
- **재생 클립 선택 드롭다운**
- **평가 엔진 전환 카드**: `Float32 AnimationPlayer` vs `16-bit C++ QuantizedClip` 세그먼트 토글 (+ Native C++ DLL 활성 / GDScript 폴백 상태 배지)
- **정밀도 · 메모리 비교 KPI 카드**:
  - `Max Pos Err (mm)` · `Max Rot Err (°)` · `World FK Err (mm)` · `메모리 절감률 (73.0%)` · `상주 메모리 (KB)`
- **200-에이전트 C++ 크라우드 벤치마크 버튼 & 결과 배너**:
  - 예: `200 Agents × 22,800 bones/tick → 1.183 ms/tick [C++ Native 8T]`

#### 변형 2-D: `빈 상태 (Empty State)`
- 3D 뷰포트에서 `AnimationStudioInstance`가 아닌 노드(예: 조명, 카메라, 배경맵)가 선택되었을 때의 안내 카드 + `[Hero_Arena 선택하기]` / `[새 캐릭터 배치]` 빠른 액션 버튼.

---

### 시안 3. 하단 패널 — `Animation Flow` (`flow_bottom_panel.gd` + `flow_graph_canvas.gd`)

#### 상단 트랜스포트 & 타임라인 스크러버 바 (높이 `32~36 px`)
- 좌측: **연결 인스턴스 필** (`연결: Soldier_M4 [character]`), 역할 아이콘
- 중앙-좌: `재생/일시정지` 아이콘 버튼, `+1/60s` 단일 프레임 스텝 버튼, 배속 드롭다운(`0.25x ~ 2.0x`)
- 중앙-우: **클립 타임라인 스크러버** (현재 플레이헤드, 루프 구간, 향후 이벤트 마커 표시 가능하도록 확장 여지 설계)
- 우측: `0.67 / 5.55s · idle` 고정폭 타임코드 & 활성 클립 태그

#### 메인 캔버스 — 인터랙티브 베지어 플로우 그래프 (`flow_graph_canvas.gd`)
어두운 블루프린트 도트/라인 그리드(`#151a22`) 위에 역할별 그래프가 자동 전환되며, **노드를 직접 클릭해 3D 뷰포트 캐릭터의 상태를 즉시 바꿀 수 있음**을 직관적으로 표현해야 합니다.

1. **Hero Lua 상태머신 그래프 (10개 노드)**:
   - `Idle`, `Run`, `Strafe`, `Attack`, `Cover`, `Jump / Fall`, `Vault`, `Hanging`, `ClimbUp`, `Leap`
   - 베지어 전이선 + 방향 화살표 + 활성 상태 좌측 액센트 바(`#f39c2b`) & 글로우 테두리(`#2cc7b8`)
2. **Quadruped Procedural Locomotor 파이프라인 그래프 (7개 노드)**:
   - `[Walk / Trot / Pace / Gallop]` → `[Foot Set 0.0mm World-Lock]` + `[Pelvis & Spine]` → `[4-Limb 2B IK]`
3. **28종 캐릭터 평가 파이프라인 그래프 (5개 노드)**:
   - `[Native .res]` → `[Float32 Player]` / `[16-bit C++ QuantizedClip]` → `[Pose Parity]` → `[Skeleton3D]`

#### 노드 시각 상태 매트릭스 (시안 필수 포함)
- `Default` · `Hover (클릭 가능 힌트)` · `Active (현재 실행 중 + 펄스/강조 바)` · `Transitioning (블렌드 중 진행률 바)` · `AI-Planned Next (AI 경로상 다음 예정 상태 하이라이트 — Phase 2 제안)`

---

### 시안 4. 표준 3D 뷰포트 오버레이 & 공간 시각화 언어

표준 Godot 3D 뷰포트 위에 애드온이 그리는 **시각 오버레이의 색상 충돌 방지 및 가독성 시안**을 요청합니다.
- **90개 도킹 라인 (`HeroEnvironmentNode`)**:
  - Red `#ef4444` (낮음 엄폐) · Green `#22c55e` (높음 엄폐) · Blue `#3b82f6` (등반 난간) · Yellow `#facc15` (고플랫폼) · Orange `#f59e0b` (볼트 난간) · 활성 도킹 타깃 `#ffffff`
- **Spatial Analysis & AI Pathfinding 오버레이 (`HeroSpatialAnalysis`, `HeroAiPathfinder`)**:
  - 다층 NavMesh 반투명 폴리곤: 지하 참호(`#1fd194`), 지면(`#1ab8d9`), 중단 플랫폼(`#388ff5`), 고지대 스카이브릿지(`#8f70f5`), 정상 10.25m(`#f5c22e`)
  - 140개 Traversal UserEdges 호(Arc): `Vault` `#f59e0b`, `ClimbUp` `#38bdf8`, `Leap` `#e879f9`, `DropDown` `#4ade80`, `CoverWalk` `#ef4444`, `CoverRoll` `#22c55e`
  - 활성 A\* 경로 리본 (`#fde047` + 구간별 Traversal 강조) + 목표 비콘 기둥 + 동적 장애물 실루엣 반투명 실린더 (`#f24040`)
- **3D 뷰포트 우상단(또는 상단 플로팅) 미니 오버레이 툴바 제안 (Phase 2)**:
  - `NavMesh` · `UserEdges` · `A* Path` · `도킹 라인` · `AI 클릭 이동 모드` 원클릭 토글 필(Pill) 바.

---

### 시안 5. Phase 2 고도화 통합 UX 시안 요청 (선택 확장 범위)

현재 단독 데모 씬(`hero_locomotion_studio.tscn`, `quadruped_locomotor_studio.tscn`, `hero_ai_demo.tscn`)에 존재하는 고급 기능을 표준 도킹 애드온 안으로 매끄럽게 통합하기 위한 시안입니다:
1. **하단 `Animation Flow` 패널 탭 확장**: `[플로우 그래프]` | `[멀티트랙 이벤트 타임라인]` | `[제작 과정 리플레이 (가상 포인터)]` 서브 탭 전환 UX.
2. **가상 포인터 제작 과정 리플레이 오버레이**: 에디터의 실제 도크(`씬`, `파일시스템`, `인스펙터`, `3D 뷰포트`)를 가리키는 스포트라이트 하이라이트 + 단계 캡션 배너(`authoring_cursor_overlay.gd` 시각 고도화).
3. **28종 캐릭터 썸네일/카드 선택 팝오버**: `+ 배치` 및 캐릭터 전환 드롭다운을 썸네일·카테고리 필터·본/클립 배지가 있는 경량 팝오버로 업그레이드.

---

### 시안 6. 웹 에디터 Topbar & 로컬 포크 런처 (`/local-fork`)

- **웹 에디터 상단 34px Topbar** (`web_editor/index.html`): 브랜드 + 모드 필 + 실시간 상태 텍스트 + `[로컬 포크 런처]` + `[로컬 포크 에디터 열기]` + `[새로고침]`.
- **웹 로딩 오버레이**: 37MB 에셋 + WASM 단계별 프로그레스 바 + 오류 박스.
- **로컬 포크 빌드·테스트 런처 대시보드** (`web_editor/local_fork.html`): 엔진/C++ DLL 상태 카드, 7종 실행 카드 그리드, 원클릭 C++ 빌드·회귀 테스트 실행 로그 터미널 카드.

---

## 4. 현재 디자인 토큰 (Baseline Palette & Typography)

디자이너가 Godot 다크 테마와 조화롭게 개선·재정의할 수 있도록 현재 구현 기준 토큰을 공유합니다.

| 용도 | 토큰명 (제안) | 현재 Hex | 비고 |
| :--- | :--- | :---: | :--- |
| **Canvas / Graph BG** | `surface.canvas` | `#151a22` | 블루프린트 배경 + `rgba(255,255,255,0.04)` 24px 그리드 |
| **Node Surface (Default)** | `surface.node` | `#1e2430` | 테두리 `#3c4a60` |
| **Node Surface (Hover)** | `surface.node.hover` | `#253042` | 테두리 `#f39c2b` |
| **Node Surface (Active)** | `surface.node.active` | `#1c3638` | 테두리 `#2cc7b8` + 좌측 4px 바 `#f39c2b` |
| **Primary Brand / Highlight** | `accent.amber` | `#f39c2b` / `#f6b44d` | 섹션 헤더, 활성 인스턴스, 포크 실행 CTA |
| **Secondary / Active Telemetry** | `accent.teal` | `#2cc7b8` / `#7fd6cc` | 활성 경로/상태, 정상 수치, 연결 배지 |
| **Text Primary / Muted** | `text.primary` / `text.muted` | `#e8f0f8` / `#9eb0c7` | 한글 `Malgun Gothic` / Godot 기본 UI 폰트 |
| **Traversal: Vault** | `semantic.vault` | `#f59e0b` | 오렌지 난간 · Vault 호 |
| **Traversal: ClimbUp** | `semantic.climb` | `#38bdf8` | 블루 등반 난간 · ClimbUp 호 |
| **Traversal: Leap** | `semantic.leap` | `#e879f9` | 마젠타 스카이브릿지 도약 호 |
| **Traversal: DropDown** | `semantic.drop` | `#4ade80` | 라임 하강 · 참호 진입 호 |
| **Tactical: Cover Low / High** | `semantic.cover.low` / `.high` | `#ef4444` / `#22c55e` | 빨강 낮음 엄폐 / 초록 높음 엄폐 & 구르기 |
| **Active A\* Path** | `semantic.path` | `#fde047` | 3D 뷰포트 활성 경로 리본 |

- **타이포그래피 기준**: 섹션 타이틀 `13px SemiBold`, 컨트롤/본문 `12px Regular`, 서브/노드 보조 라벨 `10~11px`, 실시간 좌표·ms·mm 수치 `Tabular Numerals (고정폭 숫자)` 권장.
- **Godot 테마 핸드오프 참고**: Godot `Theme` 리소스에서 `StyleBoxFlat`(배경색, 1px 테두리, `corner_radius` 4~6px, 패딩), SVG 아이콘(`16×16` 단색 화이트 — Godot `modulate` 틴트 적용), 커스텀 `_draw()` 캔버스용 JSON/상수 토큰으로 바로 옮길 수 있게 설계해 주세요.

---

## 5. 디자이너 산출물 요청 체크리스트

- [ ] **1. 전체 워크스페이스 마스터 시안** (`1920×1080` 기본 + `1280×720` 컴팩트 브레이크포인트)
- [ ] **2. 좌측 도크 `AnimStudio · 계층`** (기본 / 검색 필터 / 본 선택 포즈 리드아웃 / `+ 배치` 팝오버 상태)
- [ ] **3. 우측 도크 `AnimStudio · 상태`** 4종 상태 (`Hero + AI 자율주행` / `4족 Locomotor` / `28종 캐릭터 16-bit 비교` / `빈 상태`)
- [ ] **4. 하단 패널 `Animation Flow`** 3종 그래프 (`Hero 10-노드` / `4족 파이프라인` / `28종 평가 파이프라인`) + 노드 5종 상태 컴포넌트 + Phase 2 타임라인 탭 시안
- [ ] **5. 3D 뷰포트 오버레이 범례 & 플로팅 토글 툴바 시안**
- [ ] **6. 디자인 토큰 & 아이콘 셋** (Figma Variables / StyleBoxFlat 수치 + `16×16` SVG 아이콘 목록: Hero, Quadruped, Character, Bone, AI Path, NavMesh, Vault, Climb, Leap, Drop, Cover, Focus, Play/Pause, Step, Benchmark)

---

## 6. 현재 동작 중인 라이브 참고 환경 및 캡처

- **Godot 4.7.2 웹 에디터 (실제 표준 도킹 애드온 동작 중)**:
  - 로컬: http://127.0.0.1:4792/
  - 외부 HTTPS: https://boxed-elements-screen-statistics.trycloudflare.com/
- **로컬 포크 엔진 런처 대시보드**:
  - http://127.0.0.1:4792/local-fork
  - AI Pathfinding Hero 데모 직접 실행: http://127.0.0.1:4792/launch-local-demo?scene=ai_hero
- **현재 구현 기준 실제 캡처 증빙**:
  - 표준 3D 뷰포트 + 좌/우/하단 3종 도킹 패널 (`Hero_Arena` 매달림 + `Soldier_M4` 선택 동기화): [final_step_51.png](file:///C:/Users/taru0/.gemini/antigravity/brain/487d6b9b-26c6-49d0-9725-e5c14f876928/browser_evidence/3706e5fd-5295-4a44-adb3-1ba2379999f6/final_step_51.png)
  - 3D 광장 4개 캐릭터 배치 뷰: [hero_arena_world_4chars.png](file:///C:/Users/taru0/.gemini/antigravity/brain/487d6b9b-26c6-49d0-9725-e5c14f876928/scratch/hero_env_work/hero_arena_world_4chars.png)
  - AI Pathfinding · Spatial Analysis 다층 NavMesh + 140 UserEdges + A\* 경로 조감도: [hero_ai_overview_spatial.png](file:///C:/Users/taru0/.gemini/antigravity/brain/487d6b9b-26c6-49d0-9725-e5c14f876928/scratch/hero_ai_work/hero_ai_overview_spatial.png)
  - AI Pathfinding 12/12 기능 달성 & 정상 10.25m 등반 실행 화면: [hero_ai_summit_12of12.png](file:///C:/Users/taru0/.gemini/antigravity/brain/487d6b9b-26c6-49d0-9725-e5c14f876928/scratch/hero_ai_work/hero_ai_summit_12of12.png)
