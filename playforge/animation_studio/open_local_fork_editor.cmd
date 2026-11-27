@echo off
chcp 65001 >nul
setlocal
set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"
for %%I in ("%PROJECT_DIR%\..\..\..") do set "WORKTREES_ROOT=%%~fI"

set "FORK_EDITOR=%WORKTREES_ROOT%\Forge-Refactoring-engine\bin\godot.windows.editor.x86_64.exe"
set "FALLBACK_EDITOR=D:\Github\GoDotProjects\Godot_v4.7.2-stable_win64.exe"
set "NATIVE_DLL=%PROJECT_DIR%\addons\animation_studio\bin\animation_studio_pose_sampler.windows.template_debug.x86_64.dll"

if exist "%NATIVE_DLL%" (
    echo [Animation Studio] Native C++ GDExtension DLL 감지됨: %NATIVE_DLL%
) else (
    echo [Animation Studio] 참고: C++ DLL 미빌드 상태^(GDScript 폴백 사용, build_and_test_local_fork.cmd로 빌드 가능^)
)

if exist "%FORK_EDITOR%" (
    echo [Animation Studio] 로컬 포크 Godot 에디터 실행: "%FORK_EDITOR%"
    start "" "%FORK_EDITOR%" --editor --path "%PROJECT_DIR%" res://hero/arena/hero_arena_world.tscn
    exit /b 0
)

if exist "%FALLBACK_EDITOR%" (
    echo [Animation Studio] 로컬 포크 바이너리 미발견; 대체 Godot 4.7.2 실행: "%FALLBACK_EDITOR%"
    start "" "%FALLBACK_EDITOR%" --editor --path "%PROJECT_DIR%" res://hero/arena/hero_arena_world.tscn
    exit /b 0
)

echo [Animation Studio] ERROR: 로컬 포크 Godot 바이너리를 찾을 수 없습니다.
pause
exit /b 1
