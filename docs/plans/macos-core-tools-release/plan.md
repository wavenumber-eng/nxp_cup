+++
type = "plan"
id = "macos-core-tools-release"
status = "active"
created = "2026-08-26"

[[steps]]
id = "design-doc-intent-audit"
title = "Audit setup, firmware, host, packaging, release, and safety design intent against the macOS implementation"
status = "pending"
depends_on = ["macos-docs", "clean-mac-release-acceptance"]

[[steps]]
id = "test-runtime-impact-audit"
title = "Record macOS setup, build, package, browser, self-test, and hardware-test runtime and generated-output impact"
status = "pending"
depends_on = ["automated-macos-contract-tests", "clean-mac-release-acceptance"]

[[steps]]
id = "external-review"
title = "Obtain independent review of Mac device I/O, programming safety, release integrity, signing, setup failures, and student usability"
status = "pending"
depends_on = ["design-doc-intent-audit", "test-runtime-impact-audit"]

[[exit_criteria]]
id = "signoff"
title = "Focused firmware, rblhost, native host, setup, package, and release signoff passes on macOS and Windows"
status = "pending"

[[exit_criteria]]
id = "firmware-build"
title = "setup.sh installs the pinned repository-local Arm GNU toolchain on a clean supported Mac and the existing student build entry point publishes the competition AXF and BIN without MCUXpresso"
status = "pending"

[[exit_criteria]]
id = "native-core-tools"
title = "Pinned native Mac rblhost, nxpc_tool, and Dear ImGui viewer binaries build from recorded sources and pass bench-free self-tests"
status = "pending"

[[exit_criteria]]
id = "board-workflow"
title = "One Mac completes runtime discovery, AVCU camera and telemetry viewing, ROM-HID programming with full readback, reset, reconnect, and physical recovery"
status = "pending"

[[exit_criteria]]
id = "macos-release"
title = "A versioned Mac core-tools asset, checksum, licenses, and manifest are anonymously downloadable from an immutable GitHub Release and launch under the frozen signing policy"
status = "pending"

[[exit_criteria]]
id = "windows-regression"
title = "The existing Windows x64 setup, build, package, release dry run, ROM programming, viewer, payload names, and manifest contract remain supported"
status = "pending"

[[exit_criteria]]
id = "design-doc-intent-audit"
title = "Design docs, ADRs, and requirements match implementation"
status = "pending"

[[exit_criteria]]
id = "test-runtime-impact-audit"
title = "New tests are listed and runtime impact is reviewed"
status = "pending"

[[exit_criteria]]
id = "external-review"
title = "Independent external review is complete"
status = "pending"

[[steps]]
id = "baseline-apple-silicon"
title = "Record an Apple Silicon baseline for firmware, pinned rblhost, native host failures, installed tools, artifacts, and runtimes"
status = "done"

[[steps]]
id = "freeze-macos-release-contract"
title = "Freeze supported Mac architectures, minimum macOS, asset names, payload layout, app bundle identity, signing/notarization policy, provenance, and Windows coexistence"
status = "done"
depends_on = ["baseline-apple-silicon"]

[[steps]]
id = "reproducible-rblhost-build"
title = "Build pinned rblhost v0.2.0 reproducibly for each supported Mac architecture and record source, lockfile, Rust, dependency, linkage, license, and binary hashes"
status = "done"
depends_on = ["freeze-macos-release-contract"]

[[steps]]
id = "split-host-platform-boundaries"
title = "Separate shared AVCU parsing and bounded host behavior from Windows device, process, hashing, executable-discovery, and file-dialog implementations"
status = "done"
depends_on = ["freeze-macos-release-contract"]

[[steps]]
id = "macos-device-io"
title = "Implement bounded macOS CDC serial and ROM-HID discovery with explicit VID/PID matching, disconnect handling, and refusal to guess when multiple boards match"
status = "done"
depends_on = ["split-host-platform-boundaries"]

[[steps]]
id = "macos-programmer-integration"
title = "Port pinned programmer discovery, bounded subprocess execution, temporary readback, SHA-256 verification, and rblhost invocation to macOS"
status = "done"
depends_on = ["reproducible-rblhost-build", "macos-device-io", "split-host-platform-boundaries"]

[[steps]]
id = "macos-viewer-app"
title = "Build the Dear ImGui and SDL viewer as a usable macOS app with native firmware selection, executable-relative discovery, live telemetry, and programming integration"
status = "done"
depends_on = ["macos-device-io", "macos-programmer-integration"]

[[steps]]
id = "portable-build-entry-points"
title = "Make the existing firmware and host PowerShell entry points select pinned platform tools and outputs while preserving the Windows command contract"
status = "done"
depends_on = ["reproducible-rblhost-build", "macos-viewer-app"]

[[steps]]
id = "macos-package-contract"
title = "Produce a deterministic Mac core-tools archive with the viewer app, nxpc_tool, rblhost, licenses, manifest, hashes, architecture metadata, and verified launch behavior"
status = "done"
depends_on = ["portable-build-entry-points"]

[[steps]]
id = "multi-platform-release-flow"
title = "Extend the guarded dry-run and GitHub release workflow to validate and publish Mac assets without weakening or replacing the Windows release contract"
status = "done"
depends_on = ["macos-package-contract"]

[[steps]]
id = "macos-student-setup"
title = "Add a thin setup.sh bootstrap and extend setup pins and setup.ps1 to install pinned repository-local Mac Arm GNU, CMake, Ninja, PowerShell, and verified core tools"
status = "active"
depends_on = ["multi-platform-release-flow"]

[[steps]]
id = "automated-macos-contract-tests"
title = "Add Mac-aware setup, firmware build, host self-test, package, manifest, timeout, parser, and release dry-run coverage"
status = "pending"
depends_on = ["portable-build-entry-points", "macos-package-contract", "macos-student-setup"]

[[steps]]
id = "macos-board-acceptance"
title = "On the FRDM-MCXN947, prove runtime CDC discovery, AVCU camera and telemetry display, ROM entry, erase/write/full readback/reset, reconnect, and physical recovery"
status = "pending"
depends_on = ["macos-viewer-app", "automated-macos-contract-tests"]

[[steps]]
id = "clean-mac-release-acceptance"
title = "From a clean supported Mac, prove online and offline setup, firmware build, signed/notarized artifact launch, flash, viewer use, anonymous GitHub download, and checksum verification"
status = "pending"
depends_on = ["macos-board-acceptance", "multi-platform-release-flow", "macos-student-setup"]

[[steps]]
id = "macos-docs"
title = "Document the single Mac student workflow, contributor release flow, recovery, signing behavior, architecture limits, and offline handoff"
status = "pending"
depends_on = ["clean-mac-release-acceptance"]
+++

# macOS Firmware and Core Tools Release

Extend the proven competition firmware and core-tools workflow to macOS without regressing the existing Windows student path.

## Integration ownership

This plan owns a thin root `setup.sh` bootstrap, macOS support in the shared setup/build
implementation, the pinned Rust `rblhost` binary, `nxpc_tool`, the Dear ImGui viewer,
portable Mac packaging, and Mac GitHub Release assets. `student-windows-tool-bootstrap`
retains the Windows setup and release contract. `cmake-build-and-toolchain` retains the
competition firmware build definition. This plan consumes both and may add platform-aware
behavior, but it does not publish a second firmware build/flash workflow or alter
competition firmware behavior.

DECIDED 2026-08-26: the first public Mac release supports Apple Silicon `arm64` only.
Intel and universal binaries are outside this plan. A later plan may add Intel support when
compatible hardware is available for clean-machine, launch, viewer, and board acceptance;
cross-compilation alone is not acceptance evidence.

## Baseline on 2026-08-26

The Apple Silicon workshop Mac runs Darwin 25.5.0 and already has CMake 4.3.0, Ninja
1.13.2, MCUXpresso IDE 25.6.136, SEGGER J-Link, Python 3, Node, npm, and Chrome. It did not
have PowerShell or Rust globally installed.

Using an isolated PowerShell 7.6.3 archive, the unchanged
`src/embedded/build.ps1 -Clean` command configured with MCUXpresso Arm GCC 14.2.1, built
all 87 Ninja steps, verified 84 C compile commands, and published the normal artifacts.
The 357,104-byte BIN has SHA-256
`be41ecc5085d71f804bfa3d61eb61a293c75805b899a137d8bac340c63ec6811`.
This proves the firmware and its PowerShell build wrapper already work on this Mac when
PowerShell and a compatible Arm compiler are present. Clean-machine provisioning and
cross-platform tests remain open.

Using an isolated Rust/Cargo 1.96.1 toolchain, upstream `rblhost` v0.2.0 commit
`7a775dde2c44bd345a1ac067698afa999bd71be0` built with its checked-in lockfile in about
21 seconds. The result is a 2.8 MB arm64 Mach-O, reports `rblhost 0.2.0`, and links only
macOS system libraries and frameworks. It has not yet been exercised against an MCXN947
in ROM HID mode.

The current native host build fails before CMake because `build.ps1` unconditionally
resolves Visual Studio's `ProgramFiles(x86)` path. Beyond that first failure,
`nxpc_host_core.cpp` uses SetupAPI, HID, registry, and Win32 serial APIs;
`nxpc_programmer.cpp` uses Win32 process, timeout, temporary-file, executable-path, and
BCrypt APIs; `nxpc_viewer.cpp` uses the Windows common file dialog and executable-path
APIs; CMake links Windows system libraries and consumes a Windows-only SDL2 package and
`rblhost.exe`. These are real platform ports, not packaging-only changes.

## Release contract decisions

DECIDED 2026-08-26: the first Mac release contract is:

- Apple Silicon `arm64`, minimum macOS 13, validated on physical Apple Silicon hardware;
- `nxp-cup-core-tools-macos-arm64-<version>.zip` and matching `.zip.sha256` assets on a
  separate immutable `core-tools-macos-v<version>` release line while Windows stays pinned
  to `core-tools-v1.0.1`;
- a top-level `NXP Cup Viewer.app` with bundle identifier
  `com.wavenumber.nxpc.viewer`, plus top-level executable `nxpc_tool` and `rblhost` CLI
  files, manifests, README, and license notices;
- a self-contained app copy of `rblhost` under `Contents/Resources/bin` so programming
  still works when the app is moved independently of the extracted CLI files;
- SDL2 built statically from the repository's pinned source, with no non-system dynamic
  libraries in the app or CLI payload;
- manifest schema 2 with `platform = "macos"`, `architecture = "arm64"`, minimum OS,
  bundle identifier, signing/notarization state, source commit, exact upstream rblhost
  commit and Rust version, build-tool versions, and hashes for every regular payload file;
- Developer ID Application signing, hardened runtime, and successful Apple notarization
  are mandatory for `-Publish`; signing credentials and notary profiles remain outside the
  repository. Local dry runs may use ad-hoc signing but must record `notarized = false` and
  cannot enter the publish path;
- versioned staging, deterministic archive ordering/timestamps/modes, outer SHA-256,
  anonymous post-publication download verification, and no mutation of the Windows asset.

Do not add assets to an already immutable release, claim notarization without a successful
Apple notary result, or publish an Intel/universal asset without a later plan and compatible
machine validation.

## Implementation boundaries

Keep AVCU parsing, frame publication, bounded logs, reconnect state, programming stages,
firmware validation, and the UI shared. Isolate platform code behind narrow device I/O,
process execution, hashing, executable discovery, and file-dialog boundaries. macOS CDC
I/O must remain bounded and must select devices by the existing VID/PID rather than by a
fragile `/dev/cu.*` name. ROM HID discovery must preserve the current refusal to choose
silently when more than one matching board is present.

The Mac programmer uses the same pinned `rblhost` version and the same query, erase,
write, complete readback, SHA-256 comparison, and reset sequence as Windows. J-Link may
remain an optional recovery fallback, but a GitHub core-tools release is not complete
until the ordinary ROM-HID path works on hardware. Do not redistribute SEGGER software.

The Dear ImGui presentation and existing controls stay shared. macOS-specific work is
limited to SDL build/link behavior, app packaging, native file selection, executable and
firmware discovery, device I/O, and launch/signing integration. The direct WebSerial page
remains useful diagnostics but is not a substitute for the requested native viewer.

## Setup and release behavior

Add `setup.sh` as the ordinary Mac setup command while retaining `setup.ps1` as the shared
provisioning implementation and Windows entry point. `setup.sh` stays deliberately thin:
it verifies Apple Silicon macOS, ensures Homebrew and PowerShell 7 are available with
visible failures, and delegates to the platform-aware `setup.ps1`. It must not duplicate
archive pins, checksums, staging, rollback, or core-tools manifest validation in shell. It
must be safe to rerun, resolve the repository relative to its own path, work from a folder
containing spaces, and return the delegated setup exit code.

The Mac setup downloads the official Arm GNU 14.2.Rel1
`darwin-arm64-arm-none-eabi` archive, verifies its pinned archive and compiler hashes,
stages it safely, and installs it under `out/toolchains`. The ordinary Mac firmware build
must resolve that repository-local compiler before PATH or MCUXpresso. MCUXpresso remains
only an optional maintainer fallback and must be absent during clean-machine acceptance;
the setup must never install or require it.

Retain `src/embedded/build.ps1`, `src/embedded/flash.ps1`, and `src/host/build.ps1` as the
component entry points. Mac documentation may invoke them with `pwsh -File`; parallel
`build.sh` or `flash.sh` workflows are outside this plan. CMake and Ninja may be accepted
from a verified usable existing installation or installed through Homebrew after that
behavior is frozen. Homebrew or installation failure must be actionable and nonzero;
neither script may edit shell profiles or obscure administrator prompts.

The release flow remains guarded: local dry run by default, explicit publish, clean source
commit already present on GitHub, immutable version/tag checks, draft upload, downloaded
asset revalidation, anonymous public download verification, and no remote or branch
mutation. A multi-host build must not make publication possible with only a subset of the
required platform assets.

## Validation strategy

Bench-free tests cover protocol parsing, bounded buffering, device-selection rules,
subprocess output and timeout limits, firmware validation, programmer result parsing,
self-tests, package manifests, deterministic archives, setup rollback/idempotency,
documented commands, and release dry runs. Run these on Apple Silicon and every additional
claimed architecture. Preserve the existing Windows suite as a required regression gate.

Board acceptance uses a Rev A FRDM-MCXN947 and both runtime CDC and physical ROM ISP. It
must show live camera frames and telemetry in the native viewer, session reconnect after
reset, programming through J11, full-length readback with matching SHA-256, and recovery
from a nonfunctional application. Record cable/port assumptions, device identities,
durations, failures, and whether macOS requested any device or security permission.

Final acceptance starts from a clean supported Mac without MCUXpresso, an Arm compiler,
Rust, Cargo, or repository-global tool state. `setup.sh` must install the pinned local Arm
toolchain and the build evidence must show the compiler path under this checkout's `out`.
Acceptance then covers online and offline setup, competition build, artifact publication,
native tool launch from the downloaded archive, flash, viewer, cache reuse, corrupt
archive rejection, Gatekeeper behavior, and anonymous GitHub asset verification.

## Constraints

- Preserve the Rev A competition image, AVCU version-1 bytes, USB VID/PID, safety gates,
  command lease, and bounded runtime behavior.
- Do not add line following, PID, active differential, or a completed race solution.
- `setup.sh` is the one approved Mac bootstrap; do not restore root component wrappers or
  add parallel Mac build/flash scripts.
- Do not weaken Windows package verification, release immutability, or anonymous download
  guarantees to make the Mac asset easier to publish.
- Do not commit generated release archives under the source tree or redistribute software
  without license authorization.
- Do not change repository remotes, push, or publish as an incidental implementation step.
