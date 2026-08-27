"""L0_013 - the Apple Silicon setup is thin, pinned, and safe to rerun."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest


REPO = Path(__file__).resolve().parents[2]
SETUP_SH = REPO / "setup.sh"
SETUP_PS1 = REPO / "setup.ps1"
SETUP_VERSIONS = REPO / "setup.versions.json"
MACOS_SETUP_GUIDE = REPO / "docs" / "setup-macos.md"


def test_macos_student_guide_uses_the_shared_workflow_and_bounded_permissions():
    assert MACOS_SETUP_GUIDE.is_file()
    guide = MACOS_SETUP_GUIDE.read_text(encoding="utf-8")
    normalized_guide = " ".join(guide.split())
    for expected in (
        "Apple Silicon (`arm64`)",
        "./setup.sh -SkipCoreTools",
        "shasum -a 256 -c",
        "pwsh -NoProfile -File src/embedded/build.ps1",
        "pwsh -NoProfile -File src/embedded/flash.ps1",
        "-Backend Rom",
        'open \"out/artifacts/host/NXP Cup Viewer.app\"',
        "System Settings > Privacy & Security",
        "Open Anyway",
        "Do not disable Gatekeeper globally",
        "SW3",
        "SW1 / RESET",
        "J11",
    ):
        assert expected in normalized_guide, f"Mac setup guide is missing {expected}"

    assert "build.sh" not in guide
    assert "flash.sh" not in guide


def test_macos_arm_toolchain_pin_matches_the_official_release():
    pins = json.loads(SETUP_VERSIONS.read_text(encoding="utf-8"))
    arm = pins["armGnu"]["macosArm64"]
    assert arm == {
        "releaseVersion": "14.2.rel1",
        "compilerVersion": "14.2.1",
        "compilerSha256": (
            "07bfe9e74cfe028af639bf38703b2259c608aedee6ff991752084a10b82da614"
        ),
        "archiveName": (
            "arm-gnu-toolchain-14.2.rel1-darwin-arm64-arm-none-eabi.tar.xz"
        ),
        "directoryName": (
            "arm-gnu-toolchain-14.2.rel1-darwin-arm64-arm-none-eabi"
        ),
        "archiveFormat": "tar.xz",
        "url": (
            "https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/"
            "binrel/arm-gnu-toolchain-14.2.rel1-darwin-arm64-arm-none-eabi.tar.xz"
        ),
        "sha256": (
            "c7c78ffab9bebfce91d99d3c24da6bf4b81c01e16cf551eb2ff9f25b9e0a3818"
        ),
    }


def test_shell_bootstrap_stays_thin_and_delegates_shared_setup():
    assert SETUP_SH.is_file()
    assert os.access(SETUP_SH, os.X_OK)
    shell = SETUP_SH.read_text(encoding="utf-8")
    assert "uname -s" in shell and "uname -m" in shell
    assert "brew install --formula powershell" in shell
    assert 'exec pwsh -NoProfile -File "$script_dir/setup.ps1" "$@"' in shell
    assert "arm-gnu-toolchain" not in shell
    assert "sha256" not in shell.lower()
    assert "out/" not in shell


def test_shared_setup_has_mac_archive_and_package_manager_boundaries():
    setup = SETUP_PS1.read_text(encoding="utf-8")
    for expected in (
        "$IsMacOS",
        "Expand-TarXz",
        "/usr/bin/ditto",
        "Install-ViaHomebrew",
        "brew install --formula",
        "arm-none-eabi-gcc$ExecutableSuffix",
        "GetUnixFileMode",
        "codesign --verify --deep --strict",
        "xcrun stapler validate",
    ):
        assert expected in setup
    assert "SetEnvironmentVariable" not in setup
    assert "setx" not in setup.lower()


@pytest.mark.skipif(sys.platform != "darwin", reason="requires macOS bootstrap tools")
def test_shell_bootstrap_handles_a_repository_path_with_spaces(tmp_path):
    checkout = tmp_path / "NXP Cup checkout"
    checkout.mkdir()
    shutil.copy2(SETUP_SH, checkout / "setup.sh")
    shutil.copy2(SETUP_PS1, checkout / "setup.ps1")
    shutil.copy2(SETUP_VERSIONS, checkout / "setup.versions.json")

    result = subprocess.run(
        [
            str(checkout / "setup.sh"),
            "-SkipArm",
            "-SkipCMake",
            "-SkipNinja",
            "-SkipCoreTools",
        ],
        cwd=tmp_path,
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert f"Repository: {checkout}" in result.stdout
    assert "NXP Cup Apple Silicon macOS Setup" in result.stdout
    assert "Setup Complete" in result.stdout


@pytest.mark.skipif(sys.platform != "darwin", reason="requires macOS bootstrap tools")
def test_bootstrap_recovers_the_standard_apple_silicon_homebrew_path():
    result = subprocess.run(
        [str(SETUP_SH), "-SkipArm", "-SkipCMake", "-SkipNinja", "-SkipCoreTools"],
        cwd=REPO,
        env={**os.environ, "PATH": "/usr/bin:/bin"},
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "NXP Cup Apple Silicon macOS Setup" in result.stdout
    assert "Setup Complete" in result.stdout


@pytest.mark.skipif(sys.platform != "darwin", reason="requires macOS PowerShell")
def test_unpublished_mac_runtime_requires_an_explicit_skip():
    result = subprocess.run(
        [
            "pwsh",
            "-NoProfile",
            "-File",
            str(SETUP_PS1),
            "-SkipArm",
            "-SkipCMake",
            "-SkipNinja",
        ],
        cwd=REPO,
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )

    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert "not been published yet" in output
    assert "Use -SkipCoreTools" in output
