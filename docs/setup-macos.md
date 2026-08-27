# Apple Silicon macOS setup and build

This is the student workflow for Apple Silicon (`arm64`) Macs running macOS 13
or newer. Intel Macs are not supported by the current native viewer package.

The Mac workflow uses the same repository-owned firmware build and flash scripts
as Windows. `setup.sh` only bootstraps PowerShell and delegates to the shared
`setup.ps1`; there are no separate Mac build or flash scripts.

## Before you start

You need:

- an Apple Silicon Mac with an internet connection;
- [Homebrew](https://brew.sh/);
- this repository downloaded or cloned locally;
- a data-capable USB cable connected to **J11** on the FRDM-MCXN947.

Open Terminal, change to the repository root, and run all commands below from
that directory unless a step says otherwise.

## 1. Install the build and host tools

```sh
./setup.sh
```

The script installs PowerShell through Homebrew if necessary, downloads and
verifies Arm GNU Toolchain 14.2.Rel1 under `out/toolchains`, and checks CMake and
Ninja. It then builds the native viewer and CLI locally from the pinned SDL,
Dear ImGui, and `rblhost` inputs committed to the repository. No Apple account,
Developer ID certificate, notarization, Rust, or MCUXpresso installation is
required.

Setup stages and validates the local host build before installing it under
`out/artifacts/host`. It is safe to rerun, does not modify shell profiles or
persist PATH changes, and should finish with `Setup Complete`. Confirm the host
self-test if needed:

```sh
out/artifacts/host/nxpc_tool selftest
```

## 2. Build the competition firmware

```sh
pwsh -NoProfile -File src/embedded/build.ps1
```

The normal outputs are:

- `out/artifacts/embedded/nxp_cup_core0.axf`
- `out/artifacts/embedded/nxp_cup_core0.bin`

For a clean rebuild, add `-Clean`:

```sh
pwsh -NoProfile -File src/embedded/build.ps1 -Clean
```

## 3. Connect, inspect, and flash the car

Connect the board's **J11** port. macOS may ask whether to allow the USB
accessory; approve the board connection. Confirm that exactly one runtime device
is visible:

```sh
out/artifacts/host/nxpc_tool devices
out/artifacts/host/nxpc_tool probe --frame --seconds 3
```

Flash the generated competition image with the normal repository command:

```sh
pwsh -NoProfile -File src/embedded/flash.ps1
```

The normal flash path requests ROM-HID mode, erases and writes the image,
performs a full readback and SHA-256 comparison, resets the board, and checks
that camera and telemetry reconnect. To require ROM-HID and keep any ROM error
visible, use:

```sh
pwsh -NoProfile -File src/embedded/flash.ps1 -Backend Rom
```

### Physical ROM recovery

If the running firmware cannot enter ROM mode:

1. Leave J11 connected.
2. Press and hold **SW3**.
3. Press and release **SW1 / RESET**.
4. Release **SW3**.
5. Run the explicit `-Backend Rom` flash command above.

This recovery does not require J-Link.

## 4. Open the viewer

```sh
open "out/artifacts/host/NXP Cup Viewer.app"
```

The viewer should show the live camera, connection status, telemetry values,
firmware programming controls, and the bounded debug log. Its firmware field
automatically finds `out/artifacts/embedded/nxp_cup_core0.bin` when the app is
launched from this checkout.

The normal student loop is now:

```sh
pwsh -NoProfile -File src/embedded/build.ps1
pwsh -NoProfile -File src/embedded/flash.ps1
open "out/artifacts/host/NXP Cup Viewer.app"
```

## Rebuild or package the Mac viewer (maintainers)

Ordinary setup already builds the host locally. A maintainer changing native
host code can install the optional repository test tools and rebuild the app
with:

```sh
./setup.sh -IncludeMaintainerTools
pwsh -NoProfile -File src/host/build.ps1
out/artifacts/host/nxpc_tool selftest
```

Create an ad-hoc, unnotarized Apple Silicon package without an Apple Developer
account or certificate using:

```sh
pwsh -NoProfile -File src/host/package.ps1 -Version 0.1.0 -SigningIdentity -
```

The ZIP and checksum are written under `out/artifacts/host/packages`.
Downloaded copies have no Apple Developer ID and are not notarized. Verify the
separate checksum before opening one. If macOS blocks its first launch, try to
open it once, then go to **System Settings > Privacy & Security**, scroll to
**Security**, and choose **Open Anyway** for NXP Cup Viewer. Authenticate and
confirm **Open**. Do not disable Gatekeeper globally.

## Troubleshooting

- If `setup.sh` cannot find Homebrew, install it from `brew.sh` and rerun setup.
- If the board is absent, confirm the cable supports data and is connected to
  J11, reconnect it, and rerun `nxpc_tool devices`.
- If more than one matching board is connected, disconnect the extra board; the
  tools deliberately refuse to guess.
- If a packaged copy is blocked after download, use the bounded **Open Anyway**
  process above.
- If flashing cannot reach the application, use the physical ROM recovery
  sequence.
