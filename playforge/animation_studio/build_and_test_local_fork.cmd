@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"
for %%I in ("%PROJECT_DIR%\..\..") do set "REPO_ROOT=%%~fI"
for %%I in ("%REPO_ROOT%\..") do set "WORKTREES_ROOT=%%~fI"

set "FORK_ENGINE_DIR=%WORKTREES_ROOT%\Forge-Refactoring-engine"
set "FORK_EDITOR=%FORK_ENGINE_DIR%\bin\godot.windows.editor.x86_64.exe"
set "FORK_CONSOLE=%FORK_ENGINE_DIR%\bin\godot.windows.editor.x86_64.console.exe"
set "NATIVE_DIR=%PROJECT_DIR%\native"
set "NATIVE_DLL=%PROJECT_DIR%\addons\animation_studio\bin\animation_studio_pose_sampler.windows.template_debug.x86_64.dll"
set "GODOT_CPP_DEFAULT=%WORKTREES_ROOT%\godot-ball-simulator-plugin\third_party\godot-cpp"
if "%GODOT_CPP_DIR%"=="" set "GODOT_CPP_DIR=%GODOT_CPP_DEFAULT%"

set "REBUILD_ENGINE=0"
set "SKIP_NATIVE=0"
set "SKIP_TESTS=0"
set "LAUNCH_MODE=editor"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="--rebuild-engine" (set "REBUILD_ENGINE=1" & shift & goto parse_args)
if /I "%~1"=="--skip-native" (set "SKIP_NATIVE=1" & shift & goto parse_args)
if /I "%~1"=="--skip-tests" (set "SKIP_TESTS=1" & shift & goto parse_args)
if /I "%~1"=="--test-only" (set "LAUNCH_MODE=test-only" & shift & goto parse_args)
if /I "%~1"=="test-only" (set "LAUNCH_MODE=test-only" & shift & goto parse_args)
if /I "%~1"=="editor" (set "LAUNCH_MODE=editor" & shift & goto parse_args)
if /I "%~1"=="ai_hero" (set "LAUNCH_MODE=ai_hero" & shift & goto parse_args)
if /I "%~1"=="play" (set "LAUNCH_MODE=ai_hero" & shift & goto parse_args)
if /I "%~1"=="arena" (set "LAUNCH_MODE=arena" & shift & goto parse_args)
if /I "%~1"=="world" (set "LAUNCH_MODE=world" & shift & goto parse_args)
if /I "%~1"=="roster" (set "LAUNCH_MODE=roster" & shift & goto parse_args)
if /I "%~1"=="quadruped" (set "LAUNCH_MODE=quadruped" & shift & goto parse_args)
if /I "%~1"=="soldier" (set "LAUNCH_MODE=soldier" & shift & goto parse_args)
if /I "%~1"=="lab" (set "LAUNCH_MODE=lab" & shift & goto parse_args)
shift
goto parse_args
:args_done

echo ============================================================================
echo  [PlayForge Animation Studio] 로컬 포크 엔진 빌드 및 테스트 런처
echo  - 포크 엔진 경로 : %FORK_ENGINE_DIR%
echo  - 프로젝트 경로  : %PROJECT_DIR%
echo  - 실행 모드      : %LAUNCH_MODE%
echo ============================================================================
echo.

if not exist "%FORK_EDITOR%" set "REBUILD_ENGINE=1"

if "%REBUILD_ENGINE%"=="1" (
    echo [1/4] 로컬 포크 Godot 엔진 증분 빌드 실행 ^(SCons platform=windows target=editor winrt=no accesskit=no d3d12=no^)...
    if not exist "%FORK_ENGINE_DIR%\SConstruct" (
        echo [ERROR] 로컬 포크 엔진 SConstruct를 찾을 수 없습니다: %FORK_ENGINE_DIR%
        exit /b 1
    )
    py -3 -m SCons -C "%FORK_ENGINE_DIR%" platform=windows target=editor winrt=no accesskit=no d3d12=no
    if errorlevel 1 (
        echo [ERROR] 로컬 포크 Godot 엔진 빌드 실패!
        exit /b 1
    )
) else (
    echo [1/4] 로컬 포크 Godot 엔진 바이너리 확인 완료: %FORK_EDITOR%
    echo       ^(엔진 C++ 강제 재빌드 시 --rebuild-engine 옵션 사용^)
)

if "%SKIP_NATIVE%"=="0" (
    echo.
    echo [2/4] Animation Studio C++ GDExtension 빌드 ^(SCons platform=windows target=template_debug arch=x86_64^)...
    if exist "%GODOT_CPP_DIR%\SConstruct" (
        py -3 -m SCons -C "%NATIVE_DIR%" platform=windows target=template_debug arch=x86_64
        if errorlevel 1 (
            echo [ERROR] C++ GDExtension 빌드 실패!
            exit /b 1
        )
        echo       DLL 생성 확인: %NATIVE_DLL%
    ) else (
        echo [WARN] GODOT_CPP_DIR을 찾지 못해 기존 DLL을 유지합니다: %GODOT_CPP_DIR%
    )
) else (
    echo [2/4] C++ GDExtension 빌드 건너뜀 ^(--skip-native^)
)

if "%SKIP_TESTS%"=="0" (
    echo.
    echo [3/4] 로컬 포크 엔진 기반 Animation Studio 핵심 9종 회귀 테스트 실행...
    python "%REPO_ROOT%\playforge\tests\run.py" --godot "%FORK_CONSOLE%" --only animation_motion_v3,animation_editor_docks,animation_hero_arena,animation_hero_ai_pathfinding,animation_character_roster,animation_havok_port_parity,animation_soldier_compare,animation_quadruped_locomotor,animation_hero_studio
    if errorlevel 1 (
        echo [ERROR] 회귀 테스트 실패! 결과를 확인하세요: %REPO_ROOT%\playforge\tests\results\latest.json
        exit /b 1
    )
) else (
    echo [3/4] 회귀 테스트 건너뜀 ^(--skip-tests^)
)

echo.
if /I "%LAUNCH_MODE%"=="test-only" (
    echo [4/4] 빌드 및 테스트 완료 ^(test-only 모드^).
    exit /b 0
)

if /I "%LAUNCH_MODE%"=="editor" (
    echo [4/4] 로컬 포크 Godot 에디터 실행 ^(표준 3D 뷰포트 + 계층·상태·Animation Flow 도킹 패널^)...
    start "" "%FORK_EDITOR%" --editor --path "%PROJECT_DIR%" res://hero/arena/hero_arena_world.tscn
    exit /b 0
)

set "SCENE_PATH=res://hero/ai/hero_ai_demo.tscn"
if /I "%LAUNCH_MODE%"=="arena" set "SCENE_PATH=res://hero/arena/hero_arena.tscn"
if /I "%LAUNCH_MODE%"=="world" set "SCENE_PATH=res://hero/arena/hero_arena_world.tscn"
if /I "%LAUNCH_MODE%"=="roster" set "SCENE_PATH=res://characters/character_showcase.tscn"
if /I "%LAUNCH_MODE%"=="quadruped" set "SCENE_PATH=res://quadruped/quadruped_locomotor_studio.tscn"
if /I "%LAUNCH_MODE%"=="soldier" set "SCENE_PATH=res://soldier/soldier_demo.tscn"
if /I "%LAUNCH_MODE%"=="lab" set "SCENE_PATH=res://demo/animation_lab.tscn"

echo [4/4] 로컬 포크 엔진 플레이어 데모 실행: %SCENE_PATH%
start "" "%FORK_EDITOR%" --path "%PROJECT_DIR%" "%SCENE_PATH%"
exit /b 0
