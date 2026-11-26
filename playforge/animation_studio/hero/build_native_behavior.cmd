@echo off
setlocal EnableDelayedExpansion
set "sdk_root=%~1"
if not defined sdk_root set "sdk_root=D:\SDK\hk2015_1_0\hk2015_1_0_r1"
set "out_dir=%TEMP%\codex_havok_behavior"
if not exist "%out_dir%" mkdir "%out_dir%"
where cl.exe >nul 2>nul
if errorlevel 1 (
	set "vswhere=C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
	if not exist "!vswhere!" exit /b 10
	for /f "usebackq delims=" %%V in (`"!vswhere!" -latest -products * -property installationPath`) do set "vsroot=%%V"
	if not defined vsroot exit /b 11
	call "!vsroot!\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64
	if errorlevel 1 exit /b !errorlevel!
)
if not exist "%sdk_root%\Source\Common\Base\hkBase.h" exit /b 12
cl /nologo /MD /EHsc /std:c++14 /O2 /DWIN32 /D_WINDOWS /D_CONSOLE /DHK_TARGET_NAME=X64Vs2015 /D_HAS_EXCEPTIONS=0 /I"%sdk_root%\Source" /I"%sdk_root%\Demo" /Fo"%out_dir%\native_behavior.obj" /Fe"%out_dir%\native_behavior.exe" "%~dp0native_behavior.cpp" /link /LIBPATH:"%sdk_root%\Lib\x64_vs2015\dev" hkBase.lib hkCompat.lib hkSceneData.lib hkInternal.lib hkVisualize.lib hkGeometryUtilities.lib hkImageUtilities.lib hkcdInternal.lib hkcdCollide.lib hkaAnimation.lib hkaInternal.lib hkaPhysicsBridge.lib hkbBehavior.lib hkbUtilities.lib hkbInternal.lib hkbPhysicsBridge.lib hkbScript.lib hknpPhysics.lib hkpConstraint.lib hkpConstraintSolver.lib hknpInternal.lib hksVM.lib hksSingleFileVM.lib
exit /b %errorlevel%
