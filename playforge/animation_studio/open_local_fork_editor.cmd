@echo off
setlocal
set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "FORK_EDITOR=D:\Github\GoDotProjects-worktrees\Forge-Refactoring-engine\bin\godot.windows.editor.x86_64.exe"
set "FALLBACK_EDITOR=D:\Github\GoDotProjects\Godot_v4.7.2-stable_win64.exe"

if exist "%FORK_EDITOR%" (
    echo [Animation Studio] Launching local fork Godot Editor: "%FORK_EDITOR%"
    start "" "%FORK_EDITOR%" --editor --path "%PROJECT_DIR%" res://hero/arena/hero_arena_world.tscn
    exit /b 0
)

if exist "%FALLBACK_EDITOR%" (
    echo [Animation Studio] Fork binary not found; launching fallback Godot 4.7.2: "%FALLBACK_EDITOR%"
    start "" "%FALLBACK_EDITOR%" --editor --path "%PROJECT_DIR%" res://hero/arena/hero_arena_world.tscn
    exit /b 0
)

echo [Animation Studio] ERROR: Neither local fork Godot binary nor fallback Godot 4.7.2 was found.
pause
exit /b 1
