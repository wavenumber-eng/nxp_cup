"""L1_001 - the supported competition image compiles.

This is the gate that makes changes to the source list, the linker scripts, or
the capture backends safe to attempt. It needs no board.

Maintainer metadata checks and ad-hoc diagnostic builds use separate build
directories; they are not student-facing presets.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
EMBEDDED = REPO / "src" / "embedded"
def _have(tool: str) -> bool:
    return shutil.which(tool) is not None


def _arm_toolchain_available() -> bool:
    if _have("arm-none-eabi-gcc"):
        return True
    if list((REPO / "out" / "toolchains").glob(
            "arm-gnu-toolchain-*-arm-none-eabi/bin/arm-none-eabi-gcc.exe")):
        return True
    if list((REPO / "out" / "toolchains").glob(
            "arm-gnu-toolchain-*-arm-none-eabi/bin/arm-none-eabi-gcc")):
        return True
    return Path("C:/nxp/MCUXpressoIDE_25.6.136/ide/tools/bin/arm-none-eabi-gcc.exe").is_file()


pytestmark = [
    pytest.mark.skipif(not _have("cmake"), reason="cmake not on PATH; run setup.ps1"),
    pytest.mark.skipif(not _arm_toolchain_available(),
                       reason="no arm-none-eabi toolchain found; run setup.ps1"),
]


def _cmake(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["cmake", *args], cwd=EMBEDDED,
                          capture_output=True, text=True, timeout=1800)


def _build(preset: str) -> Path:
    cfg = _cmake("--preset", preset)
    assert cfg.returncode == 0, f"configure failed for {preset}:\n{cfg.stdout}\n{cfg.stderr}"
    build = _cmake("--build", "--preset", preset)
    assert build.returncode == 0, f"build failed for {preset}:\n{build.stdout}\n{build.stderr}"
    axf = REPO / "out" / "build" / "embedded" / preset / "nxp_cup_core0.axf"
    assert axf.is_file(), f"{preset} produced no nxp_cup_core0.axf at {axf}"
    return axf


def test_competition_builds():
    """The race image. If only one thing builds, it is this one."""
    axf = _build("competition")
    assert axf.stat().st_size > 0


@pytest.mark.skipif(not _have("uv"), reason="uv not on PATH; run setup.ps1")
def test_source_list_has_not_drifted():
    """The committed source list is the source of truth. If the MCUXpresso
    project changed without regenerating it, say so here rather than letting
    the difference sit unnoticed."""
    powershell = "powershell.exe" if sys.platform == "win32" else "pwsh"
    arguments = [powershell, "-NoProfile"]
    if sys.platform == "win32":
        arguments.extend(["-ExecutionPolicy", "Bypass"])
    arguments.extend([
        "-File", str(REPO / "src/embedded/tools/maintainer/build_cmake.ps1"),
        "-CheckDrift", "-BuildDir",
        str(REPO / "out" / "build" / "embedded" / "drift-check"),
    ])
    result = subprocess.run(
        arguments,
        cwd=REPO, capture_output=True, text=True, timeout=1800,
    )
    assert "[DRIFT]" not in result.stdout, (
        "the committed source list differs from MCUXpresso project metadata; "
        "run .\\src\\embedded\\tools\\maintainer\\build_cmake.ps1 -Regenerate, then review and commit\n" + result.stdout
    )
