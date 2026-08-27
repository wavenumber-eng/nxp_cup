# Windows, macOS, and Browser Host Tools

This component contains the native Windows and Apple Silicon macOS
camera/telemetry viewer, the one-cable programming CLI, and the direct
WebSerial viewer. Students should begin with the platform setup guide: the
[Windows guide](../../docs/setup.html) or the
[Apple Silicon macOS guide](../../docs/setup-macos.md).

## Native build

Run from the repository root:

```powershell
.\src\host\build.ps1
```

On macOS, invoke the same build entry point through PowerShell 7:

```sh
pwsh -NoProfile -File src/host/build.ps1
```

LLVM-MinGW is the canonical Windows compiler installed by root
`setup.ps1 -IncludeMaintainerTools`; macOS uses AppleClang. Ordinary students use
the pinned Windows runtime or the Mac runtime built locally by `./setup.sh`.
The maintainer build produces the viewer and CLI, includes the pinned ROM
programmer, and publishes a runnable bundle under `out/artifacts/host`.

Useful commands:

```powershell
.\out\artifacts\host\nxpc_tool.exe selftest
.\out\artifacts\host\nxpc_tool.exe devices
.\out\artifacts\host\nxpc_tool.exe probe --frame --seconds 3
.\out\artifacts\host\nxpc_tool.exe program --image .\out\artifacts\embedded\nxp_cup_core0.bin
.\out\artifacts\host\nxpc_viewer.exe --test-seconds 5
```

The viewer test command expects a connected telemetry device; the CLI
`selftest` is the bench-free host smoke test. The viewer's firmware field
automatically resolves the published embedded image even when the viewer is
launched from `out\artifacts\host` instead of the repository root.

The equivalent macOS checks are:

```sh
out/artifacts/host/nxpc_tool selftest
out/artifacts/host/nxpc_tool devices
out/artifacts/host/nxpc_tool probe --frame --seconds 3
'out/artifacts/host/NXP Cup Viewer.app/Contents/MacOS/NXP Cup Viewer' --test-seconds 5
```

Create a deterministic, versioned portable zip and checksum with:

```powershell
.\src\host\package.ps1 -Version 1.0.0
```

On macOS, an ad-hoc package needs no Apple account or Developer ID certificate:

```sh
pwsh -NoProfile -File src/host/package.ps1 -Version 0.1.0 -SigningIdentity -
```

Packaging refuses to replace an existing version unless `-Force` is explicit.
Normal releases use `release.ps1`, which adds source-tree and release checks.

## Maintainer release

One command builds and tests the native and browser tools, packages the Windows
x64 runtime, verifies its manifest and checksum, and stops before upload:

```powershell
.\src\host\release.ps1 -Version 1.0.0
```

Run the same command from a clean commit with `-Publish` to create a draft
GitHub release, download and verify its archive, and then make it public. The
script does not push branches or change remotes. For local validation while
developing the script, `-AllowDirty` is accepted only without `-Publish`.

## Browser viewer and tests

```powershell
.\src\host\tools\build-web.ps1
.\src\host\serve.ps1
npm test --prefix .\src\host
```

`nxpc_usb_debug_viewer.html` is the generated standalone handoff and must not
depend on external assets. The browser and native tools consume the same
session-gated `AVCU` v1 firmware protocol.

The Formula One presentation is authored under `src/web`; this component owns the
WebSerial adapter at `web/webserial_adapter.js`. Run `src/web/build.ps1` to regenerate
the committed `nxpc_usb_debug_viewer.html`; do not hand-edit that output. Serial
discovery, `AVCU` parsing, control requests, race-action gating, and direct RGB565
transport remain host-owned adapter behavior.

Obsolete standalone USB receiver diagnostics and their one-off build wrappers
have been removed; normal native development uses the CMake/LLVM build above.
