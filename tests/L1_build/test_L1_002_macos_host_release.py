"""L1_002 - the macOS host package is reproducible and release-valid."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import zipfile

import pytest


REPO = Path(__file__).resolve().parents[2]
PACKAGE = REPO / "src" / "host" / "package.ps1"
RELEASE = REPO / "src" / "host" / "release.ps1"
VERSION = "0.0.1-test"
PACKAGE_NAME = f"nxp-cup-core-tools-macos-arm64-{VERSION}"


pytestmark = pytest.mark.skipif(
    sys.platform != "darwin" or platform.machine() != "arm64" or not shutil.which("pwsh"),
    reason="requires Apple Silicon macOS and PowerShell 7",
)


def _run(*arguments: str, timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["pwsh", "-NoProfile", "-File", *arguments],
        cwd=REPO,
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
    )


@pytest.fixture(scope="module")
def package_candidate(tmp_path_factory):
    first = _run(str(PACKAGE), "-Version", VERSION, "-Force")
    assert first.returncode == 0, first.stdout + first.stderr
    archive = REPO / "out" / "artifacts" / "host" / "packages" / f"{PACKAGE_NAME}.zip"
    checksum = archive.with_suffix(".zip.sha256")
    first_hash = hashlib.sha256(archive.read_bytes()).hexdigest()

    second = _run(
        str(PACKAGE), "-Version", VERSION, "-SkipBuild", "-Force"
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == first_hash

    extracted = tmp_path_factory.mktemp("macos package")
    unpacked = subprocess.run(
        ["ditto", "-x", "-k", str(archive), str(extracted)],
        text=True,
        capture_output=True,
        check=False,
        timeout=60,
    )
    assert unpacked.returncode == 0, unpacked.stdout + unpacked.stderr
    return archive, checksum, extracted, first_hash


def test_package_archive_is_deterministic_and_self_describing(package_candidate):
    archive, checksum, _, archive_hash = package_candidate
    assert checksum.read_text(encoding="utf-8") == f"{archive_hash}  {archive.name}\n"

    with zipfile.ZipFile(archive) as bundle:
        infos = bundle.infolist()
        assert all(info.date_time == (2000, 1, 1, 0, 0, 0) for info in infos)
        assert [info.filename for info in infos] == sorted(
            (info.filename for info in infos), key=str.casefold
        )
        manifest = json.loads(bundle.read("manifest.json"))
        assert manifest["schemaVersion"] == 2
        assert manifest["releaseVersion"] == VERSION
        assert manifest["platform"] == "macos"
        assert manifest["architecture"] == "arm64"
        assert manifest["minimumOsVersion"] == "13.0"
        assert manifest["bundleIdentifier"] == "com.wavenumber.nxpc.viewer"
        assert manifest["signing"] == {
            "state": "adhoc",
            "identity": "-",
            "hardenedRuntime": True,
            "notarized": False,
        }
        for entry in manifest["files"]:
            payload = bundle.read(entry["name"])
            assert len(payload) == entry["size"]
            assert hashlib.sha256(payload).hexdigest() == entry["sha256"]


def test_extracted_package_preserves_modes_signatures_and_selftest(package_candidate):
    _, _, extracted, _ = package_candidate
    app = extracted / "NXP Cup Viewer.app"
    executables = [
        extracted / "nxpc_tool",
        extracted / "rblhost",
        app / "Contents" / "MacOS" / "NXP Cup Viewer",
        app / "Contents" / "Resources" / "bin" / "rblhost",
    ]
    assert all(path.stat().st_mode & 0o100 for path in executables)
    for executable in executables:
        architecture = subprocess.run(
            ["lipo", "-archs", str(executable)],
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        assert architecture.returncode == 0
        assert architecture.stdout.strip() == "arm64"

    signature = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    assert signature.returncode == 0, signature.stdout + signature.stderr
    selftest = subprocess.run(
        [str(extracted / "nxpc_tool"), "selftest"],
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )
    assert selftest.returncode == 0, selftest.stdout + selftest.stderr
    assert "selftest=ok" in selftest.stdout


@pytest.mark.skipif(
    os.environ.get("NXPC_RUN_RELEASE_DRY_RUN") != "1",
    reason="set NXPC_RUN_RELEASE_DRY_RUN=1 for the full browser/package release gate",
)
def test_macos_release_dry_run_reaches_the_no_upload_gate():
    result = _run(
        str(RELEASE), "-Version", VERSION, "-Platform", "MacOS",
        "-AllowDirty", "-Force", timeout=900,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "15 passed" in result.stdout
    assert "Dry run complete; nothing was uploaded." in result.stdout
    assert f"Release tag: core-tools-macos-v{VERSION}" in result.stdout
