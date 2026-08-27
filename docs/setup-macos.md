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
- the organizer-provided `nxp-cup-core-tools-macos-arm64-0.1.0.zip` and matching
  `.zip.sha256` file; and
- a data-capable USB cable connected to **J11** on the FRDM-MCXN947.

Open Terminal, change to the repository root, and run all commands below from
that directory unless a step says otherwise.

## 1. Install the firmware build tools

The current preview viewer ZIP does not yet have a stable public URL pinned in
`setup.versions.json`, so explicitly skip that download while installing the
firmware toolchain:

```sh
./setup.sh -SkipCoreTools
```

The script installs PowerShell through Homebrew if necessary, downloads and
verifies Arm GNU Toolchain 14.2.Rel1 under `out/toolchains`, and checks CMake and
Ninja. It is safe to rerun and does not modify shell profiles or persist PATH
changes.

## 2. Install the unsigned viewer package

First verify the ZIP in the directory containing both downloaded files. For
example, if they are in Downloads:

```sh
(cd ~/Downloads && shasum -a 256 -c nxp-cup-core-tools-macos-arm64-0.1.0.zip.sha256)
```

Continue only when the result says `OK`. Extract the package into the normal
repository artifact location:

```sh
mkdir -p out/artifacts/host
ditto -x -k ~/Downloads/nxp-cup-core-tools-macos-arm64-0.1.0.zip out/artifacts/host
out/artifacts/host/nxpc_tool selftest
```

The package has no Apple Developer ID and is not notarized. On first launch,
macOS may block it. Try opening it once, then go to **System Settings > Privacy
& Security**, scroll to **Security**, and choose **Open Anyway** for NXP Cup
Viewer. Authenticate and confirm **Open**. Only approve a package after its
checksum has passed.

## 3. Build the competition firmware

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

## 4. Connect, inspect, and flash the car

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

## 5. Open the viewer

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

## Rebuild the Mac viewer from source (maintainers)

Students use the prebuilt ZIP. A maintainer changing native host code can set up
the additional build tools and rebuild the app with:

```sh
./setup.sh -SkipCoreTools -IncludeMaintainerTools
pwsh -NoProfile -File src/host/build.ps1
out/artifacts/host/nxpc_tool selftest
```

Create an ad-hoc, unnotarized Apple Silicon package without an Apple Developer
account or certificate using:

```sh
pwsh -NoProfile -File src/host/package.ps1 -Version 0.1.0 -SigningIdentity -
```

The ZIP and checksum are written under `out/artifacts/host/packages`.

## Troubleshooting

- If `setup.sh` cannot find Homebrew, install it from `brew.sh` and rerun setup.
- If the board is absent, confirm the cable supports data and is connected to
  J11, reconnect it, and rerun `nxpc_tool devices`.
- If more than one matching board is connected, disconnect the extra board; the
  tools deliberately refuse to guess.
- If the app is blocked after download, use the bounded **Open Anyway** process
  above. Do not disable Gatekeeper globally.
- If flashing cannot reach the application, use the physical ROM recovery
  sequence.
