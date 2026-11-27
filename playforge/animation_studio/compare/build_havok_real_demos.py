#!/usr/bin/env python3
"""Builds the official Havok 2015.1.0-r1 Hero & Soldier Behavior Demo capture executable
using unmodified official Havok DemoCommon + all 43 Hero/Soldier Behavior demos
+ real DX11/OpenGL hardware rendering into %TEMP%/codex_havok_real_demos/."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

SDK_ROOT = Path(os.environ.get("HAVOK_SDK_ROOT", r"D:\SDK\hk2015_1_0\hk2015_1_0_r1"))
DEMO_ROOT = SDK_ROOT / "Demo"
DEMOS_DIR = DEMO_ROOT / "Demos"
OUT_DIR = Path(os.environ.get("TEMP", r"C:\Temp")) / "codex_havok_real_demos"
CAPTURE_CPP = Path(__file__).resolve().parent / "havok_real_demo_capture.cpp"

# Minimal official DemoCommon sources required by hkDemoFramework + hkDefaultBehaviorWorldDemo
DEMOCOMMON_SOURCES = [
    r"DemoCommon\Classes\AllClasses.cpp",
    r"DemoCommon\DemoFramework\Init\PlatformInitDefault.cpp",
    r"DemoCommon\DemoFramework\MonitorStatsRecorder.cpp",
    r"DemoCommon\DemoFramework\hkDefaultBehaviorWorldDemo.cpp",
    r"DemoCommon\DemoFramework\hkDefaultDemo.cpp",
    r"DemoCommon\DemoFramework\hkDemo.cpp",
    r"DemoCommon\DemoFramework\hkDemoConsole.cpp",
    r"DemoCommon\DemoFramework\hkDemoDatabase.cpp",
    r"DemoCommon\DemoFramework\hkDemoFramework.cpp",
    r"DemoCommon\DemoFramework\hkDemoFrameworkDebug.cpp",
    r"DemoCommon\DemoFramework\hkDemoFrameworkOptions.cpp",
    r"DemoCommon\DemoFramework\hkDemoFrameworkRender.cpp",
    r"DemoCommon\DemoFramework\hkDemoFrameworkWin32.cpp",
    r"DemoCommon\DemoFramework\hkFloatingPointExceptionCheck.cpp",
    r"DemoCommon\DemoFramework\hkPerformanceCounterUtility.cpp",
    r"DemoCommon\DemoFramework\hkPseudoPad.cpp",
    r"DemoCommon\DemoFramework\hkTestDemo.cpp",
    r"DemoCommon\DemoFramework\hkTextDisplay.cpp",
    r"DemoCommon\Utilities\Animation\AnimationUtils.cpp",
    r"DemoCommon\Utilities\Asset\AssetManagementUtil.cpp",
    r"DemoCommon\Utilities\Behavior\BehaviorCompatLoader.cpp",
    r"DemoCommon\Utilities\Behavior\BehaviorUtils.cpp",
    r"DemoCommon\Utilities\Behavior\HeroDemoSymbols.cpp",
    r"DemoCommon\Utilities\Bitmap\Bitmap.cpp",
    r"DemoCommon\Utilities\CameraUtils\AnimatedCamera.cpp",
    r"DemoCommon\Utilities\CameraUtils\CameraUtils.cpp",
    r"DemoCommon\Utilities\Character\CharacterStepInput.cpp",
    r"DemoCommon\Utilities\Drawing\DrawUtils.cpp",
    r"DemoCommon\Utilities\ExceptionHandler\ExceptionHandler.cpp",
    r"DemoCommon\Utilities\ExceptionHandler\Win32ExceptionHandler.cpp",
    r"DemoCommon\Utilities\FileFinder\FileFinder.cpp",
    r"DemoCommon\Utilities\GameUtils\GeometryLoaderUtil.cpp",
    r"DemoCommon\Utilities\GameUtils\NpGameUtils.cpp",
    r"DemoCommon\Utilities\Geometry\GeometryMaker.cpp",
    r"DemoCommon\Utilities\GpuStats\GpuStatsUtil.cpp",
    r"DemoCommon\Utilities\Loading\LoadingUtil.cpp",
    r"DemoCommon\Utilities\Menu\DemoOrder.cpp",
    r"DemoCommon\Utilities\Menu\MenuDemo.cpp",
    r"DemoCommon\Utilities\Menu\MenuImageLarge.cpp",
    r"DemoCommon\Utilities\MonitorHelper\MonitorHelper.cpp",
    r"DemoCommon\Utilities\MonitorHelper\MonitorHelperMultithreaded.cpp",
    r"DemoCommon\Utilities\PathContainer\PathContainer.cpp",
    r"DemoCommon\Utilities\Replay\DemoReplay.cpp",
    r"DemoCommon\Utilities\SplashScreen\SplashScreen.cpp",
    r"DemoCommon\Utilities\Tweaker\Tweaker.cpp",
]

LIBS = [
    "d3d11.lib",
    "dxgi.lib",
    "d3dcompiler.lib",
    "opengl32.lib",
    "dxguid.lib",
    "xaudio2.lib",
    "user32.lib",
    "gdi32.lib",
    "ole32.lib",
    "oleaut32.lib",
    "shell32.lib",
    "advapi32.lib",
    "winmm.lib",
    "ws2_32.lib",
    "dbghelp.lib",
    "hkgBridge.lib",
    "hkgDx11.lib",
    "hkgOglES.lib",
    "hkgOglES2.lib",
    "hkgOgls.lib",
    "hkgDx9s.lib",
    "hkgSoundCommon.lib",
    "hkgSoundXAudio2.lib",
    "hkgCommon.lib",
    "ImGui.lib",
    "hkgImGui.lib",
    "hkpConstraint.lib",
    "hkpConstraintSolver.lib",
    "hknpPhysics.lib",
    "hknpInternal.lib",
    "hkgpConvexDecomposition.lib",
    "hkaInternal.lib",
    "hkaAnimation.lib",
    "hkaPhysicsBridge.lib",
    "hkbBehavior.lib",
    "hkbInternal.lib",
    "hkbScript.lib",
    "hkbUtilities.lib",
    "hkbAiBridge.lib",
    "hkbPhysicsBridge.lib",
    "hkndDestruction.lib",
    "hkndPhysics2012Bridge.lib",
    "hkndInternal.lib",
    "hkndAssetProcessing.lib",
    "hkndAssetConversion.lib",
    "hkndIntegration.lib",
    "hkgDestruction.lib",
    "hclCloth.lib",
    "hclInternal.lib",
    "hclSetup.lib",
    "hkgCloth.lib",
    "hclAnimationBridge.lib",
    "hclPhysicsBridge.lib",
    "hkaiPathfinding.lib",
    "hkaiInternal.lib",
    "hkaiVisualize.lib",
    "hkaiSpatialAnalysis.lib",
    "hkaiPhysicsBridge.lib",
    "hksVM.lib",
    "hkfxFx.lib",
    "hkfxFxInternal.lib",
    "hkInternal.lib",
    "hkGeometryUtilities.lib",
    "hkImageUtilities.lib",
    "hkVisualize.lib",
    "hkSceneData.lib",
    "hkBase.lib",
    "hkcdCollide.lib",
    "hkcdInternal.lib",
    "hkCompat.lib",
]


def discover_hero_soldier_behavior_demos() -> list[Path]:
    beh = DEMOS_DIR / "Behavior"
    decl_pat = re.compile(r"(HKB_DECLARE_\w+|HK_DEMO_DECLARE\w*)\s*\([^;]+?\)\s*;", re.S)
    found: list[Path] = []
    for root, _, files in os.walk(beh):
        for f in sorted(files):
            if not f.endswith(".cpp"):
                continue
            p = Path(root) / f
            txt = p.read_text(encoding="utf-8", errors="ignore")
            if not decl_pat.search(txt):
                continue
            hp = p.with_suffix(".h")
            htxt = hp.read_text(encoding="utf-8", errors="ignore") if hp.is_file() else ""
            full = txt + "\n" + htxt
            is_hero = bool(re.search(r"HeroProject\.hkt|Hero\.hkt|HeroWith|3rdPersonActionAdventure|Hero/|Hero\\|HeroDemo|HeroCharacter|Docking\.hkt", full))
            is_soldier = bool(re.search(r"US_Soldier_Project\.hkt|FireTeamLeader_Character\.hkt|Soldier/|Soldier\\|US_Soldier", full))
            if is_hero or is_soldier:
                found.append(p)
    return sorted(found)


def find_vs_devcmd() -> Path:
    vswhere = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe")
    vs = subprocess.check_output(
        [str(vswhere), "-latest", "-products", "*", "-property", "installationPath"],
        text=True,
    ).strip()
    return Path(vs) / "Common7" / "Tools" / "VsDevCmd.bat"


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    obj_dir = OUT_DIR / "obj"
    obj_dir.mkdir(parents=True, exist_ok=True)

    demos = discover_hero_soldier_behavior_demos()
    print(f"Discovered {len(demos)} Hero & Soldier Behavior demo .cpp files.")

    sources: list[Path] = []
    for rel in DEMOCOMMON_SOURCES:
        p = DEMOS_DIR / rel
        if not p.is_file():
            print(f"[ERROR] Missing DemoCommon source: {p}", file=sys.stderr)
            return 2
        sources.append(p)
    sources.extend(demos)
    sources.append(CAPTURE_CPP)

    # Use release libs (faster, clean)
    cfg = os.environ.get("HAVOK_CFG", "release")
    lib_dir = SDK_ROOT / "Lib" / "x64_vs2015" / cfg
    defs = [
        "/DWIN32", "/D_WIN32", "/D_WINDOWS", "/D_CONSOLE",
        "/DHK_TARGET_NAME=X64Vs2015",
        "/D_HAS_EXCEPTIONS=0",
        "/D_ALLOW_ITERATOR_DEBUG_LEVEL_MISMATCH",
        "/DHK_ENABLE_SCRIPT",
        "/DNDEBUG" if cfg == "release" else "/DHK_DEBUG",
        "/DHKS_BUILDRELEASE" if cfg == "release" else "/DHKS_BUILDDEVEL",
    ]
    incs = [
        f'/I"{DEMO_ROOT}"',
        f'/I"{SDK_ROOT / "Source"}"',
    ]

    # Compile in parallel using cl /MP with a response file
    exe_path = OUT_DIR / "havok_hero_soldier_demos.exe"
    rsp_compile = OUT_DIR / "compile.rsp"
    rsp_link = OUT_DIR / "link.rsp"

    # Build PCH once? No, /FI Demos/demos.h with /MP across 86 files takes ~10-15s on 16 threads!
    compile_lines = [
        "/nologo", "/c", "/MP", "/MD", "/O2", "/fp:fast", "/GR-", "/EHs-c-", "/W1", "/std:c++14",
        '/FI"Demos/demos.h"',
        '/FI"Common/Base/Types/hkExtraPragmas.h"',
        f'/Fo"{obj_dir}\\\\"',
        *defs,
        *incs,
    ]
    # Note: ensure unique obj names if any basenames collide!
    seen_stems: dict[str, Path] = {}
    objs: list[Path] = []
    to_compile: list[Path] = []
    force_rebuild = "--rebuild" in sys.argv
    for s in sources:
        stem = s.stem.lower()
        if stem in seen_stems:
            print(f"[WARN] Stem collision: {s} vs {seen_stems[stem]}")
        seen_stems[stem] = s
        obj = obj_dir / (s.stem + ".obj")
        objs.append(obj)
        if force_rebuild or not obj.is_file() or obj.stat().st_mtime < s.stat().st_mtime:
            to_compile.append(s)
            compile_lines.append(f'"{s}"')

    rsp_compile.write_text("\n".join(compile_lines) + "\n", encoding="utf-8")

    link_lines = [
        "/nologo",
        "/SUBSYSTEM:CONSOLE",
        "/ignore:4221",
        "/ignore:4049",
        "/ignore:4099",
        f'/OUT:"{exe_path}"',
        f'/LIBPATH:"{lib_dir}"',
        *(f'"{o}"' for o in objs),
        *LIBS,
    ]
    rsp_link.write_text("\n".join(link_lines) + "\n", encoding="utf-8")

    devcmd = find_vs_devcmd()
    bat = OUT_DIR / "do_build.cmd"
    compile_step = (
        f'echo === COMPILING {len(to_compile)} / {len(sources)} FILES ===\n'
        f'cl @"{rsp_compile}"\n'
        f'if errorlevel 1 exit /b %errorlevel%\n'
    ) if to_compile else 'echo === ALL OBJS UP TO DATE ===\n'
    bat.write_text(
        f'@echo off\n'
        f'call "{devcmd}" -arch=x64 -host_arch=x64\n'
        f'if errorlevel 1 exit /b %errorlevel%\n'
        f'{compile_step}'
        f'echo === LINKING {exe_path} ===\n'
        f'link @"{rsp_link}"\n'
        f'exit /b %errorlevel%\n',
        encoding="utf-8",
    )
    print(f"Building ({len(to_compile)} dirty / {len(sources)} total) into {exe_path} ...")
    res = subprocess.run(["cmd", "/c", str(bat)], capture_output=False)
    return res.returncode


if __name__ == "__main__":
    raise SystemExit(main())
