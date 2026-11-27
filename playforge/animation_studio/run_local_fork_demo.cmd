@echo off
chcp 65001 >nul
setlocal

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"
for %%I in ("%PROJECT_DIR%\..\..\..") do set "WORKTREES_ROOT=%%~fI"

set "FORK_EDITOR=%WORKTREES_ROOT%\Forge-Refactoring-engine\bin\godot.windows.editor.x86_64.exe"
if not exist "%FORK_EDITOR%" (
    echo [ERROR] 로컬 포크 엔진 바이너리를 찾을 수 없습니다: %FORK_EDITOR%
    echo         먼저 build_and_test_local_fork.cmd --rebuild-engine 을 실행하세요.
    pause
    exit /b 1
)

set "MODE=%~1"
if "%MODE%"=="" (
    echo ============================================================================
    echo  [PlayForge Animation Studio] 로컬 포크 엔진 즉시 실행 메뉴
    echo  엔진: %FORK_EDITOR%
    echo ============================================================================
    echo   1. 로컬 포크 Godot 에디터 ^(표준 3D 뷰포트 + 계층·상태·Animation Flow 도킹^)
    echo   2. AI Pathfinding · Spatial Analysis Hero 전체 맵 데모 ^(hero_ai_demo.tscn^)
    echo   3. Hero 배경맵 · 10종 Lua 파쿠르 아레나 플레이 ^(hero_arena.tscn^)
    echo   4. 4캐릭터 3D 광장 씬 플레이 ^(hero_arena_world.tscn^)
    echo   5. 전체 28종 캐릭터 로스터 데모 ^(character_showcase.tscn^)
    echo   6. 4족 절차적 Locomotor 스튜디오 ^(quadruped_locomotor_studio.tscn^)
    echo   7. Soldier 114본 · M4 비교 데모 ^(soldier_demo.tscn^)
    echo   8. Animation Studio 메인 런처 ^(animation_lab.tscn^)
    echo ============================================================================
    set /p "PICK=번호를 선택하세요 [1-8, 기본=2]: "
    if "%PICK%"=="" set "PICK=2"
    if "%PICK%"=="1" set "MODE=editor"
    if "%PICK%"=="2" set "MODE=ai_hero"
    if "%PICK%"=="3" set "MODE=arena"
    if "%PICK%"=="4" set "MODE=world"
    if "%PICK%"=="5" set "MODE=roster"
    if "%PICK%"=="6" set "MODE=quadruped"
    if "%PICK%"=="7" set "MODE=soldier"
    if "%PICK%"=="8" set "MODE=lab"
)

if /I "%MODE%"=="editor" (
    start "" "%FORK_EDITOR%" --editor --path "%PROJECT_DIR%" res://hero/arena/hero_arena_world.tscn
    exit /b 0
)

set "SCENE=res://hero/ai/hero_ai_demo.tscn"
if /I "%MODE%"=="arena" set "SCENE=res://hero/arena/hero_arena.tscn"
if /I "%MODE%"=="world" set "SCENE=res://hero/arena/hero_arena_world.tscn"
if /I "%MODE%"=="roster" set "SCENE=res://characters/character_showcase.tscn"
if /I "%MODE%"=="quadruped" set "SCENE=res://quadruped/quadruped_locomotor_studio.tscn"
if /I "%MODE%"=="soldier" set "SCENE=res://soldier/soldier_demo.tscn"
if /I "%MODE%"=="lab" set "SCENE=res://demo/animation_lab.tscn"

echo [Animation Studio] 로컬 포크 엔진 실행: %SCENE%
start "" "%FORK_EDITOR%" --path "%PROJECT_DIR%" "%SCENE%"
exit /b 0
