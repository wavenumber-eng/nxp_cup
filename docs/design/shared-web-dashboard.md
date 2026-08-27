# Shared Web Dashboard Handoff

## Purpose

Preserve the completed Formula One-style dashboard and reuse its presentation in two
different browser transports without coupling those transports together:

```text
                         shared dashboard presentation
                        /                             \
direct WebSerial + AVCU                                Android WebSocket relay
host RGB565 + controls                                 JPEG / H.264 / raw + AVCU
```

This is a source-ownership and build cleanup. It must not change firmware, wire values,
USB identities, relay framing, queue bounds, or Android lifecycle behavior.

## Implemented authoritative files

| Consumer | Authored input | Generated or packaged output |
| --- | --- | --- |
| Shared presentation | `src/web/dashboard/dashboard.html`, `.css`, `.js` | Both pages below |
| Direct WebSerial | `src/host/web/webserial_adapter.js` | `src/host/nxpc_usb_debug_viewer.html` |
| Android relay | `src/android/web/relay_adapter.js` | `src/android/nxp_cup_bridge/app/src/main/res/raw/relay_viewer.html`, embedded unchanged in `nxp_cup_bridge.apk` |

The shared source set contains the completed Formula One presentation. The Android
adapter preserves the proven JPEG, fragmented MP4 H.264, raw RGB565, generic telemetry,
video-mode behavior, and typed Race Start/Stop forwarding without importing WebSerial.
The generated `relay_viewer.html` is the sole Android HTML resource; no legacy or
parallel hand-authored presentation is packaged.

## Source ownership

The implemented boundary is:

```text
src/web/
  AGENTS.md
  README.md
  build.ps1
  dashboard/
    dashboard.html
    dashboard.css
    dashboard.js

src/host/web/
  webserial_adapter.js

src/android/web/
  relay_adapter.js

generated and committed:
  src/host/nxpc_usb_debug_viewer.html
  src/android/nxp_cup_bridge/app/src/main/res/raw/relay_viewer.html
```

`src/web/build.ps1` becomes the only dashboard bundler. It needs a normal build mode and
a non-writing `-Check` mode that fails when either checked output differs from a fresh
generation. The component must be added to `src/README.md` only when that entry point and
its tests exist.

Generated pages are committed because the direct viewer is a standalone handoff and the
Android APK must build offline without a separate web toolchain. Neither page may load a
CDN, remote font, JavaScript package, or other network asset.

## Presentation boundary

Share the visual shell, camera/video stage, Formula One styling, vehicle metrics,
connection/state badges, telemetry presentation, and small capability-controlled slots
for consumer actions. Keep the shared API transport-neutral: it receives already-decoded
frames, state, rates, named values, and available actions.

Do not move these concerns into shared presentation code:

- Web Serial discovery, port ownership, `AVCU` parsing, HELLO/channel/PING/CLOSE, typed
  race actions, direct RGB565 chunk assembly, or serial reconnect behavior;
- WebSocket setup, `/stream` URL selection, JPEG `AVCJ`, fragmented MP4 `AVC4`, raw
  `AVCR`, relayed `AVCU`, typed race-action forwarding, Media Source Extensions
  lifecycle, or mode replacement;
- Android USB, encoder, mailbox, server, network, foreground-service, or watchdog code.

Both adapters may expose the same capability- and telemetry-gated Race Start and Stop
controls. The relay adapter owns its bounded browser-to-USB action path as well as
JPEG/H.264/raw selection; it exposes no general actuator or vehicle-mode command. Hiding
an unsupported control is preferable to giving shared UI code transport knowledge.

## Android application roles

The current Android application is already a proven native phone viewer and Wi-Fi relay.
Do not ask a parallel agent to recreate it. After lifecycle solidification, first extract
or define a shared Kotlin core containing protocol constants/parsing, USB-session
ownership, complete-frame assembly, and bounded latest-frame publication.

Then decide explicitly between:

1. one application with a relay-enabled configuration; or
2. a shared library plus separate viewer-only and relay application modules.

A viewer-only deliverable must omit the HTTP/WebSocket server, compression workers,
network/hotspot permissions, and relay lifecycle. A relay deliverable may depend on the
shared core but must preserve all existing bounded backpressure and hardware evidence.

## Build and validation contract

The implementation is not complete until all of the following pass:

```powershell
.\src\web\build.ps1
.\src\web\build.ps1 -Check
npm test --prefix .\src\host
.\src\android\build.ps1 -Offline
python -m pytest -q
uvx --from wn-dev-std==2026.7.18 dev-std audit . --scope docs.plans
```

Add browser coverage for both generated pages. Retain existing WebSerial parsing,
origin, telemetry, and deliberate-action tests. Retain Android mode-selection checks and
exercise JPEG, H.264, raw RGB565, telemetry, reconnect, and bounded client queues. The
generated-page tests must also reject external runtime assets and detect source/output
drift.

Real-phone relay and direct WebSerial hardware checks remain required after the source
extraction because browser fixture success cannot prove USB ownership, encoder behavior,
or Wi-Fi backpressure.

## Parallel-agent boundary

One agent may own shared dashboard extraction and generated browser outputs. A separate
Android lifecycle/app-structure agent starts only after the shared output contract is
stable. Neither agent changes firmware protocol or broad documentation organization, and
both preserve the currently proven outputs until their replacements pass equivalent
tests.
