"""L0_002 - the Windows setup and component entry points agree with the tree."""

import json
from pathlib import Path
import re

REPO = Path(__file__).resolve().parents[2]

SETUP_SCRIPT = REPO / "setup.ps1"
SETUP_VERSIONS = REPO / "setup.versions.json"
SETUP_GUIDE = REPO / "docs/setup.html"
BUILDING_GUIDE = REPO / "docs/building-the-code.html"
ROOT_README = REPO / "README.md"
SRC_README = REPO / "src/README.md"
PRESETS = REPO / "src/embedded/CMakePresets.json"
FIRMWARE_BUILD = REPO / "src/embedded/build.ps1"
HOST_BUILD = REPO / "src/host/build.ps1"
ANDROID_BUILD = REPO / "src/android/build.ps1"
ANDROID_TOOL_BUILD = REPO / "src/android/tools/build-project.ps1"
HOST_VIEWER = REPO / "src/host/nxpc_viewer.cpp"
HOST_VIEWER_PLATFORM_WINDOWS = REPO / "src/host/nxpc_viewer_platform_windows.cpp"
HOST_VIEWER_PLATFORM_MACOS = REPO / "src/host/nxpc_viewer_platform_macos.mm"
ANDROID_RELAY_VIEWER = (
    REPO / "src/android/nxp_cup_bridge/app/src/main/res/raw/relay_viewer.html"
)


def test_setup_script_exists():
    assert SETUP_SCRIPT.is_file(), "setup.ps1 is missing"
    assert SETUP_VERSIONS.is_file(), "setup.versions.json is missing"
    text = SETUP_SCRIPT.read_text(encoding="utf-8") + SETUP_VERSIONS.read_text(
        encoding="utf-8"
    )
    for tool in (
        "arm-gnu-toolchain",
        "Kitware.CMake",
        "Ninja-build.Ninja",
        "astral-sh.uv",
        "MartinStorsjo.LLVM-MinGW.UCRT",
    ):
        assert tool in text, f"setup.ps1 does not provision {tool}"


def test_setup_pins_an_immutable_core_tools_release():
    pins = json.loads(SETUP_VERSIONS.read_text(encoding="utf-8"))
    core = pins["coreTools"]
    assert core["releaseVersion"] == "1.0.1"
    assert core["releaseTag"] == "core-tools-v1.0.1"
    assert core["sourceCommit"] == "ddedfb448406dcc0636b8763d5b4b14e69dca612"
    assert core["assetName"] == "nxp-cup-core-tools-win-x64-1.0.1.zip"
    assert f"/releases/download/{core['releaseTag']}/{core['assetName']}" in core["url"]
    assert "latest" not in core["url"].lower()
    assert len(core["sha256"]) == 64
    assert core["selfTestArguments"] == ["selftest"]


def test_setup_pins_and_verifies_the_arm_archive():
    pins = json.loads(SETUP_VERSIONS.read_text(encoding="utf-8"))
    arm = pins["armGnu"]
    assert arm["releaseVersion"] == "14.2.rel1"
    assert arm["compilerVersion"] == "14.2.1"
    assert len(arm["compilerSha256"]) == 64
    assert len(arm["sha256"]) == 64
    setup = SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "Get-FileHash" in setup
    assert "Get-VerifiedArchive" in setup


def test_root_readme_routes_students_to_the_authoritative_setup_guide():
    readme = ROOT_README.read_text(encoding="utf-8")
    assert "## Start here" in readme
    assert "[Windows setup guide](docs/setup.html)" in readme
    assert "[Building the Code](docs/building-the-code.html)" in readme
    assert "authoritative" in readme


def test_student_setup_guide_uses_current_commands_and_paths():
    assert SETUP_GUIDE.is_file(), "docs/setup.html is missing"
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    for required in (
        ".\\setup.ps1",
        ".\\src\\embedded\\build.ps1",
        ".\\src\\embedded\\flash.ps1",
        ".\\out\\artifacts\\host\\nxpc_viewer.exe",
        "out\\artifacts\\embedded\\nxp_cup_core0.bin",
        "out\\artifacts\\embedded\\nxp_cup_core0.axf",
        "-Backend Rom",
        "-ArmArchive",
        "-CoreToolsArchive",
    ):
        assert required in guide, f"setup guide is missing {required}"

    for stale in (
        ".\\build.ps1",
        ".\\build_viewer.ps1",
        "bin\\firmware",
        "bin\\host",
        "build\\cmake",
        "scripts\\android",
        "Flashing is done with Segger Ozone",
    ):
        assert stale not in guide, f"setup guide retains stale instruction {stale}"


def test_student_setup_guide_covers_bounded_permission_and_recovery_help():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    for expected in (
        "Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass",
        "normal, non-administrator window",
        "Group Policy",
        "AppLocker",
        "winget is missing or blocked",
        "J11",
        "SW3",
        "SW1 / RESET",
        "data, not a charge-only cable",
    ):
        assert expected in guide
    assert "-Scope LocalMachine" not in guide
    assert "-ExecutionPolicy Unrestricted" not in guide


def test_student_setup_guide_opens_the_repository_in_vscode():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    assert "PowerShell tab in Windows Terminal" in guide
    assert "https://code.visualstudio.com/docs/setup/windows" in guide
    assert "Visual Studio Code User Installer for Windows" in guide
    assert "does not require administrator access" in guide
    assert "<pre>code .</pre>" in guide
    assert "File &gt; Open Folder" in guide


def test_student_setup_guide_explains_how_to_get_the_repository():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    assert "https://github.com/wavenumber-eng/nxp_cup" in guide
    assert "Code &gt; Download ZIP" in guide
    assert "extract it" in guide
    assert "C:\\nxp_cup" in guide
    assert "git clone https://github.com/wavenumber-eng/nxp_cup.git nxp_cup" in guide
    assert "folder that directly" in guide and "contains <code>setup.ps1</code>" in guide


def test_student_setup_guide_permits_bounded_ai_setup_help():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    assert "AI assistance is permitted for setup" in guide
    assert "understand these instructions" in guide
    assert "troubleshoot installation issues" in guide
    assert "Do not share passwords, access tokens" in guide
    assert "do not" in guide and "disable Windows security or bypass device controls" in guide


def test_student_setup_guide_assumes_a_personal_laptop():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    assert "assume a personal laptop" in guide
    assert "unusual case that a school or employer manages" in guide


def test_student_setup_guide_has_a_complete_tool_summary():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    assert '<h2 id="installed-tools">Installed tools summary</h2>' in guide
    for expected in (
        "Visual Studio Code is installed manually",
        "Arm GNU Toolchain 14.2.Rel1",
        "CMake",
        "Ninja",
        "Core tools 1.0.1",
        "nxpc_viewer.exe",
        "nxpc_tool.exe",
        "rblhost.exe",
        "SDL2.dll",
        "uv",
        "LLVM-MinGW",
        "It does not install Rust, Cargo",
    ):
        assert expected in guide


def test_student_setup_guide_local_links_resolve():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    assert '<meta name="viewport"' in guide
    for target in re.findall(r'(?:href|src)="([^"]+)"', guide):
        if "://" in target or target.startswith("#"):
            continue
        assert (SETUP_GUIDE.parent / target).resolve().is_file(), target


def test_student_setup_guide_shows_the_programming_connections():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    assert guide.count('assets/FRDM-MCXN947--PROGRAMMING.jpg') == 2
    assert "J11 high-speed USB connection for normal programming" in guide
    assert "optional J17 J-Link debug connection" in guide
    assert "SW1 reset button" in guide
    assert "SW3 ISP recovery button" in guide


def test_student_setup_guide_shows_the_first_run_sequence():
    guide = SETUP_GUIDE.read_text(encoding="utf-8")
    visible_text = re.sub(r"\s+", " ", guide)
    for image in (
        "assets/setup.png",
        "assets/gnu_downlaod.png",
        "assets/GNU_EXTRACT.png",
        "assets/setup_complete.png",
    ):
        assert guide.count(image) == 2
    assert "your folder can have a different name or location" in visible_text
    assert "Keep the terminal open while the progress counter advances" in visible_text
    assert "After the SHA-256 check passes" in visible_text
    assert "Success ends with <strong>Setup Complete</strong>" in visible_text


def test_building_guide_covers_the_happy_build_and_flash_path():
    assert BUILDING_GUIDE.is_file(), "docs/building-the-code.html is missing"
    guide = BUILDING_GUIDE.read_text(encoding="utf-8")
    for expected in (
        "command-line CMake and Ninja build",
        "Ninja recompiles only what changed",
        "AI or LLM",
        "code .",
        ".\\setup.ps1",
        ".\\src\\embedded\\build.ps1",
        ".\\src\\embedded\\flash.ps1",
        ".\\out\\artifacts\\host\\nxpc_viewer.exe",
        "out\\artifacts\\embedded\\nxp_cup_core0.bin",
        "program=ok",
        "Program from the host viewer",
        "Program and reconnect",
        "Programming complete; preview reconnected",
        "J-Link is not required",
    ):
        assert expected in guide


def test_building_guide_uses_the_annotated_j11_image_and_local_resources():
    guide = BUILDING_GUIDE.read_text(encoding="utf-8")
    visible_text = re.sub(r"\s+", " ", guide)
    assert guide.count('assets/FRDM-MCXN947--PROGRAMMING.jpg') == 2
    assert guide.count('assets/build_complete.png') == 2
    assert guide.count('assets/cl_program_complete.png') == 2
    assert guide.count('assets/START_VIEWER.png') == 2
    assert guide.count('assets/NXPC_VIEWER.png') == 2
    assert guide.count('assets/VIEWER_PROGRAMMING_IN_PROGRESS.png') == 2
    assert guide.count('assets/VIEWER_PROGRAMMING_COMPLETE.png') == 2
    assert "Connect the PC to <strong>J11</strong>" in visible_text
    assert ".\\src\\embedded\\build.ps1 -Clean" in visible_text
    assert "A fresh clone does not require <code>-Clean</code>" in visible_text
    assert "ends with <code>probe=ok</code>" in visible_text
    assert "viewer executable lives under" in visible_text
    assert "normally finds the BIN produced by the build" in visible_text
    assert "out\\artifacts\\embedded\\nxp_cup_core0.bin" in visible_text
    assert "No buttons are needed for a normal update" in visible_text
    assert "restarts into ROM ISP automatically" in visible_text
    assert "no valid firmware is running" in visible_text
    assert "VIDEO DISCONNECTED</strong> and <strong>MCXN947 ROM connected" in visible_text
    assert "keep J11 connected while erase, write, and verify finish" in visible_text
    for target in re.findall(r'(?:href|src)="([^"]+)"', guide):
        if "://" in target or target.startswith("#"):
            continue
        local_target = target.split("#", 1)[0]
        assert (BUILDING_GUIDE.parent / local_target).resolve().is_file(), target


def test_setup_script_does_not_persist_environment():
    text = SETUP_SCRIPT.read_text(encoding="utf-8")
    assert "setx" not in text.lower()
    assert "[Environment]::SetEnvironmentVariable" not in text


def test_setup_compiler_builds_the_native_host():
    setup = SETUP_SCRIPT.read_text(encoding="utf-8")
    host_build = HOST_BUILD.read_text(encoding="utf-8")
    assert "MartinStorsjo.LLVM-MinGW.UCRT" in setup
    assert 'Get-Command "clang++"' in host_build
    assert '"Ninja Multi-Config"' in host_build
    assert '"cmake-clang"' in host_build
    assert '"cmake-clang-macos-arm64"' in host_build
    assert '[ValidateSet("Clang", "MSVC")]' in host_build


def test_component_builds_publish_under_out():
    firmware = FIRMWARE_BUILD.read_text(encoding="utf-8")
    host = HOST_BUILD.read_text(encoding="utf-8")
    android = ANDROID_BUILD.read_text(encoding="utf-8")
    ignore = (REPO / ".gitignore").read_text(encoding="utf-8")
    assert "out\\artifacts\\embedded" in firmware
    assert "nxp_cup_core0.axf" in firmware
    assert "out/artifacts/host" in host
    assert "nxpc_viewer.exe" in host
    assert "out\\artifacts\\android" in android
    assert '"nxp_cup_bridge.apk"' in android
    assert "app-debug.apk" in android
    assert "out/" in ignore


def test_host_viewer_uses_published_firmware_location():
    viewer = HOST_VIEWER.read_text(encoding="utf-8")
    windows_platform = HOST_VIEWER_PLATFORM_WINDOWS.read_text(encoding="utf-8")
    macos_platform = HOST_VIEWER_PLATFORM_MACOS.read_text(encoding="utf-8")
    assert 'fs::path("out") / "artifacts" / "embedded" / "nxp_cup_core0.bin"' in viewer
    assert "current_executable_path" in viewer
    assert "GetModuleFileNameW" in windows_platform
    assert "[[NSBundle mainBundle] executableURL]" in macos_platform
    assert "out\\build\\embedded\\competition\\nxp_cup_core0.bin" not in viewer
    assert 'ImGui::Button("Program and reconnect"' in viewer
    assert 'ImGui::CalcTextSize("Browse...")' in viewer
    assert "ImGui::GetContentRegionAvail().x" in viewer
    assert 'ImGui::Button("Browse...", ImVec2(browse_button_width, 0.0f))' in viewer
    assert "SetNextItemWidth(-78.0f)" not in viewer
    assert "Erase application flash" not in viewer
    assert "erase_confirmation" not in viewer


def test_android_build_uses_provisioned_gradle_and_supports_offline_builds():
    text = ANDROID_TOOL_BUILD.read_text(encoding="utf-8")
    assert "$script:NxpCupAndroidGradle" in text
    assert "gradlew.bat" not in text
    assert '"--offline"' in text


def test_android_relay_viewer_has_prominent_video_mode_controls():
    viewer = ANDROID_RELAY_VIEWER.read_text(encoding="utf-8")
    assert "aspect-ratio: 8 / 5" in viewer
    for mode in ("jpeg", "h264", "raw"):
        assert f'data-video="{mode}"' in viewer
        assert f'?video={mode}&amp;replace=1' in viewer


def test_readmes_are_the_current_component_map():
    root = ROOT_README.read_text(encoding="utf-8")
    source_map = SRC_README.read_text(encoding="utf-8")
    for command in (
        ".\\src\\embedded\\build.ps1",
        ".\\src\\host\\build.ps1",
        ".\\src\\android\\build.ps1",
    ):
        assert command in root
    for component in ("embedded", "host", "android", "common"):
        assert component in source_map


def test_only_competition_preset_is_student_facing():
    data = json.loads(PRESETS.read_text(encoding="utf-8"))
    visible = [p["name"] for p in data["configurePresets"] if not p.get("hidden")]
    assert visible == ["competition"]


def test_toolchain_discovery_prefers_local():
    toolchain = REPO / "src/embedded/nxp_cup_core0/cmake/mcuxpresso-toolchain.cmake"
    text = toolchain.read_text(encoding="utf-8")
    assert "NXPC_ARM_TOOLCHAIN_DIR" in text
    assert "out/toolchains" in text
    assert text.index("out/toolchains") < text.index("MCUXpressoIDE")
