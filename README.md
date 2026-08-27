# NXP Cup

This repository contains the organizer-supplied NXP Cup platform used at FIT:
MCXN947 firmware, Windows/browser host tools, an Android telemetry relay, shared
libraries, tests, and teaching material.

The current integrated platform release is **1.0.0**.

## Start here

Students: open the **[Windows setup guide](docs/setup.html)** after downloading
or cloning the repository. It is the authoritative guide for PowerShell
permissions, setup on a personal laptop, building, ROM-HID flashing through
J11, the viewer, physical recovery, and offline archives.

After setup, use **[Building the Code](docs/building-the-code.html)** for the
short, repeatable edit, build, flash, and viewer workflow.

To understand where student code belongs and how frames, modes, callbacks, and
safety gates fit together, open the self-contained
**[How the Firmware Runs](docs/learn/framework-structure.html)** lesson.

The normal path, run from a PowerShell tab in **Windows Terminal** at the
repository root, is:

```powershell
code .
.\setup.ps1
.\src\embedded\build.ps1
.\src\embedded\flash.ps1
.\out\artifacts\host\nxpc_viewer.exe
```

The setup script provisions the pinned Arm GNU compiler, CMake, Ninja, and the
verified `core-tools-v1.0.1` Windows viewer/flash bundle. Toolchains, cached
downloads, and generated state stay under the ignored `out` directory; the
script does not persist environment variables. If Windows blocks PowerShell,
winget, USB access, or downloaded executables, follow the permission guidance in
the setup guide rather than changing machine-wide security policy.

## Maintainer and component setup

Maintainers who need to rebuild the native host can opt into `uv` and
LLVM-MinGW with:

```powershell
.\setup.ps1 -IncludeMaintainerTools
```

Android SDK licenses require a separate explicit setup:

```powershell
.\src\android\setup.ps1 -AcceptLicenses
```

Component entry points are:

```powershell
.\src\embedded\build.ps1   # Rev A competition firmware
.\src\embedded\flash.ps1   # ROM-HID first, then J-Link Commander
.\src\host\build.ps1       # Maintainer rebuild of the Windows viewer and CLI
.\src\android\build.ps1    # Android unit tests and debug APK
```

Generated artifacts are published under `out\artifacts`. The normal student
firmware loop is edit, build, and run `flash.ps1`. Flashing prefers ROM-HID and
automatically falls back to the command-line J-Link backend. RTT and lower-level
maintainer tools live under `src\embedded\tools`.

## Code formatting

Run clang-format over all repository-owned C and C++ code from the root:

```powershell
.\scripts\tools\clang_format.ps1
.\scripts\tools\clang_format.ps1 -Check
```

Imported SDK, generated, and vendor sources are intentionally excluded.

See [`src/README.md`](src/README.md) for the source-tree map. Students and LLM
assistants should read the nearest `AGENTS.md` before editing a component.
