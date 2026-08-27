# NXP rblhost vendor record

- Upstream: `https://github.com/nxp-mcuxpresso/rblhost`
- Version: `v0.2.0`
- Source commit: `7a775dde2c44bd345a1ac067698afa999bd71be0`
- Windows x64 binary: `rblhost.exe`
- Windows x64 SHA-256: `6CAE03C432489E0BD8A658F91E5899E7D1153B6859BE02C7A76798F2885CD2A8`
- macOS arm64 binary: `rblhost-macos-arm64`
- macOS arm64 SHA-256: `D75BABE663D783AD83A5C5B760EF0581080227031F8D74256FC282D3D2C76344`
- Toolchain used: Rust/Cargo 1.96.1, release profile with the upstream lockfile
- License: BSD-3-Clause; see `LICENSE` in this directory.
- Windows imported and bench-validated: 2026-08-23
- macOS arm64 reproducible build validated: 2026-08-26

The retained platform executable is the default ROM programmer packaged beside
`nxpc_viewer` and `nxpc_tool`. The Windows x64 build has passed FRDM-MCXN947 J11
USB-HID property query, erase-all, write-memory at address zero, full-length
readback, reset, and application/camera recovery using VID/PID `1FC9:014F`.

The macOS arm64 build was reproduced byte-for-byte from two separate clean
source paths using the recorded Rust version and upstream lockfile. Hardware
ROM-HID acceptance remains required before a Mac core-tools release.

`build.versions.json` is the machine-readable source, toolchain, file-name, and
hash contract. `src/host/tools/build-rblhost.ps1` verifies a clean pinned source
checkout and publishes a validated maintainer build under `out`.
