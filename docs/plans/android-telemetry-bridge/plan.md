+++
type = "plan"
id = "android-telemetry-bridge"
status = "active"
created = "2026-08-21"

[[steps]]
id = "resume-gate"
title = "Confirm the USB protocol and race-week Web viewer are stable enough to support an independent Android host"
status = "done"

[[steps]]
id = "device-inventory"
title = "Inventory the Moto G Power 5G (2023), Android build, USB-host feature, developer access, adapters, and bench power topology"
status = "done"
depends_on = ["resume-gate"]

[[steps]]
id = "toolchain-bootstrap"
title = "Provision a reproducible command-line Android build, install, test, and adb toolchain on the maintainer workstation"
status = "done"
depends_on = ["resume-gate"]

[[steps]]
id = "protocol-fixtures"
title = "Create JVM conformance fixtures for fragmented AVCU control, frame, stats, log, and telemetry traffic"
status = "done"
depends_on = ["resume-gate"]

[[steps]]
id = "android-foundation"
title = "Create the minimal native app with a bounded parser, explicit session state, diagnostics, and no actuator controls"
status = "done"
depends_on = ["toolchain-bootstrap", "protocol-fixtures"]

[[steps]]
id = "wireless-adb-loop"
title = "Establish wireless adb build-install-run-log collection while the phone USB-C port is occupied by the car"
status = "done"
depends_on = ["device-inventory", "android-foundation"]

[[steps]]
id = "android-usb-host-proof"
title = "Open the NXP Cup CDC interface from the phone and complete HELLO, SET_CHANNELS, PING, and CLOSE on real hardware"
status = "done"
depends_on = ["wireless-adb-loop"]

[[steps]]
id = "phone-preview"
title = "Display live RGB565 camera frames and connection state while exposing transport counters through diagnostics"
status = "done"
depends_on = ["android-usb-host-proof"]

[[steps]]
id = "wifi-relay-proof"
title = "Serve an embedded page and relay bounded camera and telemetry data to one browser over a controlled 5 GHz network"
status = "done"
depends_on = ["phone-preview"]

[[steps]]
id = "relay-backpressure"
title = "Prove slow or disconnected Wi-Fi clients cannot block USB reads, grow memory, or create unbounded display latency"
status = "done"
depends_on = ["wifi-relay-proof"]

[[steps]]
id = "compression-inventory"
title = "Inventory the Moto hardware video encoders and define bounded full-rate JPEG and H.264 measurements against the existing RGB565 stream"
status = "done"
depends_on = ["relay-backpressure"]

[[steps]]
id = "full-rate-jpeg"
title = "Benchmark full-camera-rate JPEG from RGB565 without blocking USB or growing latency"
status = "done"
depends_on = ["compression-inventory"]

[[steps]]
id = "hardware-h264"
title = "Prove and benchmark hardware-accelerated H.264 encoding from the existing RGB565 camera stream"
status = "done"
depends_on = ["compression-inventory"]

[[steps]]
id = "compressed-browser-delivery"
title = "Select and integrate the simplest compressed browser delivery path supported by measured phone performance"
status = "done"
depends_on = ["full-rate-jpeg", "hardware-h264"]

[[steps]]
id = "h264-browser-proof"
title = "Add an opt-in bounded H.264 fragmented-MP4 relay and prove playback in a normal browser"
status = "done"
depends_on = ["compressed-browser-delivery"]

[[steps]]
id = "hotspot-adb-proof"
title = "Determine whether authenticated wireless ADB and the relay remain reachable when the Moto supplies the race network as a hotspot"
status = "done"
depends_on = ["h264-browser-proof"]

[[steps]]
id = "phone-appliance-ui"
title = "Reduce the phone UI to live camera, clear connection state, and the browser address"
status = "done"
depends_on = ["phone-preview", "hotspot-adb-proof"]

[[steps]]
id = "client-video-selection"
title = "Let the sole browser client select bounded JPEG, H.264, or raw RGB565 delivery while keeping JPEG as the default"
status = "done"
depends_on = ["full-rate-jpeg", "h264-browser-proof"]

[[steps]]
id = "bridge-lifecycle-solidification"
title = "Move long-lived USB, relay, encoder, network-change, and no-data-watchdog ownership out of the activity"
status = "pending"
depends_on = ["phone-appliance-ui", "client-video-selection"]

[[steps]]
id = "vehicle-integration"
title = "Validate battery life, heat, reconnects, RF behavior, and noninterference on the car; keep mounting and cable retention outside the software track"
status = "pending"
depends_on = ["client-video-selection", "hotspot-adb-proof"]

[[steps]]
id = "design-doc-intent-audit"
title = "Audit the Android design and protocol use against the implemented USB contract"
status = "done"
depends_on = ["compressed-browser-delivery"]

[[steps]]
id = "test-runtime-impact-audit"
title = "Audit app, host, hardware, and firmware validation coverage and runtime impact"
status = "done"
depends_on = ["compressed-browser-delivery"]

[[steps]]
id = "external-review"
title = "Obtain independent external review"
status = "pending"
depends_on = ["design-doc-intent-audit", "test-runtime-impact-audit"]

[[exit_criteria]]
id = "protocol-reuse"
title = "Android uses the same framed protocol as the Web viewer without a firmware fork"
status = "met"

[[exit_criteria]]
id = "unattended-loop"
title = "After one-time phone authorization and cable setup, an agent can build, test, deploy, start, inspect health, and collect logs without handling the phone"
status = "met"

[[exit_criteria]]
id = "portable-workstation"
title = "A clean Windows laptop can reproduce the pinned Android toolchain and build/deploy workflow without relying on this workstation's global state"
status = "pending"

[[exit_criteria]]
id = "usb-preview"
title = "The Moto G Power receives and displays the live AVC camera stream with observable parser and transport health"
status = "met"

[[exit_criteria]]
id = "browser-relay"
title = "One laptop browser receives a useful live camera and telemetry view over the phone's controlled 5 GHz network"
status = "met"

[[exit_criteria]]
id = "bounded-backpressure"
title = "A slow or absent Wi-Fi viewer cannot stall USB input or grow memory and always converges to the newest complete frame"
status = "met"

[[exit_criteria]]
id = "full-rate-compression"
title = "The phone sustains the camera frame rate through a bounded compressed-video path without degrading USB capture"
status = "met"

[[exit_criteria]]
id = "rf-bitrate"
title = "Measured compressed bitrate and latency are suitable for smooth one-viewer race-day use on a controlled 5 GHz link"
status = "met"

[[exit_criteria]]
id = "client-video-selection"
title = "The sole browser client can select JPEG, H.264, or raw RGB565 without restarting the app or changing firmware"
status = "met"

[[exit_criteria]]
id = "safe-reconnect"
title = "Connect, disconnect, app restart, and reconnect cannot enable motors or select a moving vehicle mode"
status = "met"

[[exit_criteria]]
id = "vehicle-fit"
title = "Phone battery runtime, heat, RF link, and USB session behavior are validated on the car; mounting remains outside software scope"
status = "pending"

[[exit_criteria]]
id = "design-doc-intent-audit"
title = "Android design and protocol documentation match implementation"
status = "met"

[[exit_criteria]]
id = "test-runtime-impact-audit"
title = "New tests are listed and runtime impact is reviewed"
status = "met"

[[exit_criteria]]
id = "external-review"
title = "Independent external review is complete"
status = "pending"

[[steps]]
id = "shared-web-dashboard"
title = "Extract the Formula One dashboard into src/web with shared presentation assets, separate WebSerial and Android relay adapters, generated standalone outputs, and drift/browser tests"
status = "active"
depends_on = ["client-video-selection"]

[[steps]]
id = "remote-race-actions"
title = "Add capability-gated remote Race Start and Stop with deliberate browser controls and bounded USB-worker delivery"
status = "done"
depends_on = ["client-video-selection"]

[[steps]]
id = "android-f1-overlay"
title = "Remove the legacy Android relay presentation and carry the Formula One overlay over the proven relay adapter"
status = "done"
depends_on = ["client-video-selection"]

[[steps]]
id = "android-app-role-structure"
title = "Define a shared Kotlin core and choose one configurable app or separate viewer-only and relay app modules before parallel Android implementation"
status = "pending"
depends_on = ["shared-web-dashboard", "bridge-lifecycle-solidification"]
+++

# Android Telemetry Bridge

## Integration ownership

This plan retains Android USB-host, relay, compression, lifecycle, and device validation.
`docs/plans/nxp-cup-framework-migration` owns final package/product naming and the preserved
`AVCU` compatibility contract. Android changes consume the migration manifest and fixtures;
they do not independently rename protocol bytes or public firmware APIs.

## Shared Dashboard and App-Role Handoff

The active `shared-web-dashboard` step now has its intended source boundary in the
worktree. `src/web` owns transport-neutral dashboard markup, styling, presentation logic,
and the deterministic standalone-page generator. WebSerial connection, `AVCU` parsing,
system actions, and direct RGB565 input remain in `src/host/web/webserial_adapter.js`.
Android WebSocket connection, JPEG/H.264/raw mode selection, `AVCJ`/`AVC4`/`AVCR`, and
relayed `AVCU` telemetry plus typed Race Start/Stop forwarding remain in
`src/android/web/relay_adapter.js`. The generated host
and Android pages are committed, dependency-free runtime outputs checked by
`src/web/build.ps1 -Check`.

Do not use this extraction as permission to rewrite the proven Android relay. After the
shared dashboard and `bridge-lifecycle-solidification` are complete, the
`android-app-role-structure` step first chooses between one configurable APK and separate
viewer-only/relay application modules. Either choice reuses a shared Kotlin protocol,
USB-session, and latest-frame core; a viewer-only application must not carry the relay
server, compression workers, network permissions, or hotspot lifecycle by accident.
`docs/design/shared-web-dashboard.md` is the detailed source/output and test contract for
parallel agents.

## Current Status

On 2026-08-26, the shared-dashboard implementation and automated validation reached a
pause checkpoint. The generated-page drift check and all 14 Playwright browser tests
passed, including Android JPEG, H.264, raw RGB565, generic telemetry, and the initial
read-only relay behavior. The pinned offline Android build and JVM unit tests also passed using
the reusable tool cache at `C:\ELI\fit2026\avc\out\toolchains\android`; the resulting APK
is `out/artifacts/android/nxp_cup_bridge.apk`. The branch was then synchronized without
conflict through `origin/main` at `d96ebdd`; the shared-dashboard implementation is
committed as `2392828`. After synchronization, the plan audit, repeated offline Android
build, and full repository Python suite passed, with 95 tests passed and one skipped.

The APK was subsequently installed on the Moto G Power with state-preserving
`adb install -r`. Version `0.1.0` launched successfully and reported the expected idle
`waiting_for_NXP_Cup_USB_device` health state while connected to the development PC. The
first live browser check exposed slight overlap among the upper-right speed, battery, and
frame-rate panels on a short/wide viewport. Those panels now use one height-aware vertical
stack, with a 1280x480 browser geometry regression; all 15 browser tests passed, and the
rebuilt APK was reinstalled successfully. The step remains active rather than claiming
car-side completion. Next, move the phone to the car through the OTG adapter. Keep the
development PC on its normal network and use a second PC joined to the phone hotspot to
open the exact `http://<phone-address>:8765/` URL shown by the app. Re-run the real-phone
relay and direct WebSerial hardware checks before marking `shared-web-dashboard` done and
closing the step.

On 2026-08-27, the Android relay gained the same narrowly scoped remote Race Start and
Stop behavior as the direct WebSerial viewer. The browser requires Race-mode telemetry,
the firmware system-action capability, and a 1.5-second hold before Start; Stop is
immediate. The native USB worker retains one pending action with Stop priority, and no
general actuator or mode command is exposed. The Formula One presentation remains the
sole generated Android HTML page, with the stacked readout regression retained.

The first GitHub-release candidate is also prepared. `src/android/release.ps1` validates
the shared generated pages, browser tests, clean Android build, package/version metadata,
APK signature, checksum, and provenance before allowing publication. Its `0.1.0` dry run
passed and emitted a versioned APK, SHA-256 file, and manifest under
`out/artifacts/android/releases`. This initial maintainer build remains debug-signed; the
manifest records the signing-certificate digest so update compatibility is explicit.

Execution was authorized on 2026-08-21. The native USB host, phone preview, and full-rate
one-browser Wi-Fi relay are complete on the real Rev A car. The Moto G Power serves its
embedded page at `http://<phone-address>:8765/`, preserves generic telemetry as normal
`AVCU`, and lets the sole browser select JPEG, H.264, or raw RGB565 while JPEG remains the
default. The original 240-frame JPEG run delivered 23.493 FPS at 1.972 Mbit/s with a
most-recent-frame age of about 24 ms while USB remained at 23.42 FPS and 2.870 MiB/s with
zero sequence or malformed-chunk errors. Headless Chrome decoded 120 frames in five
seconds with no page errors and nonblack canvas pixels. A two-second network-send
deadline now closes a client that stops reading. Six consecutive forced stalls kept USB
advancing, stayed near 56-59 MiB PSS after warm-up, and reconnected to a complete frame
within one source frame in the final recorded run. Six subsequent abrupt app-process
losses also recovered distinct firmware sessions 27-32, clean USB video, telemetry, and
recent Wi-Fi frames without cable handling. The relay explicitly selects the IPv4 stack
and binds the active WLAN address. A connected-device foreground service now keeps
CPU and Wi-Fi active through the secure lockscreen: live relay verification passed while
Android reported `Dozing`, screen off, and light idle. A 30-second loaded baseline held
27 C, 23.42 USB FPS, 2.869 MiB/s, 49-60 MiB PSS, and roughly 427-588 mA discharge. Physical
integration remains parked; the hotspot ADB/network proof is complete.

Android now owns the AVC VID/PID through a persistent attached-device association and
routes attach intents into a single activity, preventing duplicate USB readers. Repeated
physical detach/reconnect cycles reopened sequential sessions without another permission
prompt. The shorter bench adapter/cable combination passed an end-to-end 120-frame relay
check at 23.73 browser FPS and 23.42 USB FPS with zero sequence or malformed errors and a
zero-frame source/sent gap. A power-only car restart that does not cause Android to emit a
USB detach is not covered by this result; stale-session detection remains vehicle-
integration work.

The Moto cannot keep its normal Wi-Fi client connection while running Soft AP, but that
does not block the development loop. With the phone hosting the car over USB and serving
the `wavenumber` hotspot, the workstation joined the hotspot and authenticated adb at
the phone gateway. Android exposed the hotspot on `ap0`; the relay's earlier `wlan0`-
only address lookup incorrectly bound its server to loopback. The server now binds all
local interfaces so it survives client-Wi-Fi and Soft AP configurations. A hotspot
WebSocket proof received 120 consecutive JPEGs at 23.65 FPS with a zero-frame source/
sent gap while USB remained at 23.43 FPS with no sequence or malformed errors. Headless
Chrome rendered the live camera, and a screen-off proof continued to receive fresh
frames while Android reported `Dozing`. The tested hotspot was open and 2.4 GHz; WPA2/
WPA3, 5 GHz, venue RF, battery duration, and heat remain vehicle-integration work.

An opt-in H.264 browser proof is also complete without changing the default JPEG path.
The MediaTek encoder supplies baseline Annex-B SPS/PPS and one access unit per output;
the app packages it into a small ISO BMFF initialization segment and one-sample
`moof`/`mdat` fragments. The bounded relay waits for an IDR after connect or loss and
resends initialization before dependent frames. Chrome played 320x200 video at the
source rate: the measured ten-second steady window sent 238 frames (23.8 FPS) at about
0.6 Mbit/s with roughly 49 ms of browser buffer lead. USB stayed at 23.42 FPS and
2.869 MiB/s with zero sequence or malformed chunks. A recorded reconnect became
playable in 399 ms, and the H.264 non-reading-client watchdog proof passed.

The Android codec inventory reports the MediaTek `c2.mtk.avc.encoder` as a hardware,
vendor AVC encoder. At 320x200 it accepts planar, semiplanar, and flexible YUV420 byte
buffers as well as surface input, so the first H.264 proof can use a bounded RGB565-to-
YUV420 conversion without adding EGL or changing the camera firmware. The vendor codec
table advertises roughly 125-129 FPS at 320x240; the live measurement remains decisive
because it includes conversion, codec queueing, USB capture, preview, and relay load.

Both live compression probes now sustain the 23.42 FPS source while USB remains at
2.869-2.870 MiB/s with zero sequence and malformed-chunk errors. JPEG quality 70 measured
23.47 FPS, 1.956 Mbit/s, about 4.0 ms mean end-to-end encode latency, no drops after
startup, and 48 MiB PSS. MediaTek hardware H.264 at a 750 kbit/s target measured 23.38
FPS, 0.752 Mbit/s, about 50.8 ms mean latency, four bounded startup drops, and 74 MiB PSS.
The measured RF saving from H.264 is real, but full-rate JPEG is already only about eight
percent of raw RGB565 bandwidth and is much simpler for an ordinary browser to consume.
Use JPEG as the default one-browser path; H.264 is now a working opt-in if race-network
measurements justify its added framing and browser-decoder lifecycle. An initial 75 ms
inbound WebSocket poll capped the JPEG path
delivery at 13.2 FPS; reducing the bounded client-control poll to 5 ms removed the cap and
produced the 23.493 FPS result above. A repeated slow-reader test still closed the client
at the two-second watchdog, kept USB healthy, and remained bounded at about 59 MiB PSS.

The design audit confirms that firmware and the USB contract did not change: Android
still sends only `HELLO`, `SET_CHANNELS`, `PING`, and `CLOSE`, and contains no actuator or
vehicle-mode command. `AVCJ`, `AVC4`, and `AVCR` exist only between the phone and its
embedded browser; generic telemetry remains `AVCU`. The test/runtime audit covers JVM framing and
RGB565-to-I420 fixtures plus real-phone JPEG, H.264, WebSocket payload, slow-reader,
forced-restart, locked-screen, and Chrome decode proofs. With a live JPEG browser, a spot
sample showed about 50 MiB PSS, 25.9 percent process CPU in Android's eight-core `top`,
27 C battery temperature, and roughly 483 mA discharge. These are healthy development
measurements, not a substitute for a race-duration battery/thermal run.

The final race-week convenience slice is also complete. The phone screen now contains
the camera, a compact connection/mode line, the usable browser URL, and a large overlay
when the car is disconnected. The sole browser client selects `jpeg`, `h264`, or `raw`
through the page URL; JPEG remains the default and only the selected producer runs. A
same-process real-car check delivered 120 raw frames at 23.347 FPS / 23.907 Mbit/s, 120
H.264 frames at 22.696 FPS / 0.740 Mbit/s, and 120 JPEG frames at 23.706 FPS /
3.135 Mbit/s. USB stayed at about 23.42 FPS and 2.869 MiB/s with zero sequence or
malformed errors. Raw backpressure and six further process-restart cycles also passed.

## Concrete Hardware

The available handset is a **Moto G Power 5G (2023)**, not the older Moto G4 assumed in
early discussion. Motorola lists Android 13, a MediaTek Dimensity 930, 6 GB RAM, 256 GB
storage, a 5000 mAh battery, 185 g mass, USB-C with USB 2.0, and dual-band
802.11ac Wi-Fi with hotspot support:

- <https://en-ca.support.motorola.com/app/answers/detail/a_id/174789/~/moto-g-power-5g-%282023%29---specifications>
- <https://en-us.support.motorola.com/app/answers/detail/a_id/173296/~/wi-fi-hotspot---moto-g-power-5g-%282023%29>

Those facts remove the old Moto G4 concerns about micro-USB, Android 7, and 2.4 GHz-only
Wi-Fi. Bench inventory found the phone updated to Android 14/API 34 and verified its USB
host feature on the real car.

The car presents a conventional CDC ACM layout with NXP VID `0x1FC9`, PID `0x0094`,
bulk IN endpoint 2, bulk OUT endpoint 3, and 512-byte high-speed packets. The foundation
uses Android's USB-host APIs directly for discovery, permission, interface claims, CDC
control requests, and bounded endpoint transfers. It confirms the device by completing
the AVC framed `HELLO`, not by trusting VID/PID alone; no third-party serial dependency
was needed.

## Purpose

Use the phone as a wired in-car USB host and a Wi-Fi bridge through the same `AVCU`
protocol used by the PC viewer. The minimum useful product is:

```text
Rev A car -- USB CDC --> Android AVC parser --> phone preview
                                      |
                                      +--> latest complete frame --> JPEG/H.264/raw
                                           + generic telemetry
                                            --> embedded HTTP/WebSocket server
                                            --> laptop browser
```

The firmware must not gain an Android-specific protocol or code path. The app owns its
USB session and relay policy; it never selects vehicle mode or enables an actuator.

## MVP Boundary

The first executable slice is deliberately small:

1. Detect the attached NXP Cup CDC device, obtain user permission, open it, and complete
   `HELLO`, `SET_CHANNELS`, `PING`, and `CLOSE`.
2. Parse fragmented `AVCU` packets on a dedicated worker and show live RGB565 frames,
   connection state, and the usable viewer URL on the phone. Keep detailed counters in
   machine-readable diagnostics instead of consuming the display.
3. Serve a static page embedded in the APK and forward a client-selected full-rate JPEG,
   H.264, or raw RGB565 stream plus generic `AVCU` telemetry to one laptop browser over
   binary WebSocket. Default to JPEG.
4. Provide machine-readable logcat and HTTP health views so the development loop can
   verify USB state, session state, last frame age, rates, drops, and browser count.

The USB side remains the existing `AVCU` contract. On Wi-Fi, telemetry retains `AVCU`
framing while each independently decodable JPEG uses one small `AVCJ` envelope carrying
frame ID, dimensions, byte count, capture timestamp, and a dropped-before flag. The phone
may omit complete camera frames under backpressure, but it never forwards a partial frame
as complete. Camera frames use latest-complete-frame semantics throughout.

Raw full-rate video is about 24.1 Mbit/s. The completed first Wi-Fi proof sent every
fourth raw frame, about 5.9 FPS and 6.0 Mbit/s, while continuing to drain USB at full
rate. The later bounded paths keep the firmware and RGB565 camera mode fixed. JPEG
sustains the full 23.4 FPS at roughly 2-3 Mbit/s; hardware H.264 sustains the source rate
at roughly 0.6-0.75 Mbit/s but has dependent-frame recovery and decoder lifecycle; raw
now sustains the full source rate at about 24 Mbit/s as a diagnostic. Keep JPEG as the
default until venue RF testing makes H.264's bandwidth reduction valuable. Recording,
multi-client support, and a polished race dashboard remain deferred.

WebSocket uses TCP because an ordinary browser cannot consume arbitrary UDP datagrams.
Bounded application queues prevent TCP backpressure from becoming growing latency: keep
at most the newest complete relay frame, drop superseded frames with counters, and close
a client that cannot drain within a fixed limit. USB input must never wait for Wi-Fi.

## Network Shape

Development and race operation have different best first configurations:

- **Development:** put the workstation and phone on the same controlled 5 GHz access
  point or travel router. This gives the most reliable wireless `adb` connection while
  the phone's only USB-C port is connected to the car.
- **Race candidate:** manually enable the phone's 5 GHz hotspot, restart the bridge so it
  binds the hotspot address, and join the projector laptop to it. Device inventory reports
  no concurrent STA+AP support, so this disconnects `yellow` and wireless adb. The hotspot
  client path and post-switch address must still be tested before relying on it. The saved
  phone configuration observed on 2026-08-21 is an **open**, 2.4 GHz `wavenumber`
  hotspot; that is acceptable only for this short bench experiment. Race use requires a
  deliberate WPA2/WPA3 configuration and 5 GHz validation.
- **Optional follow-up:** Android's local-only hotspot API is available from API 26 and
  can create a no-Internet network for nearby clients. Android 13-targeted apps require
  `NEARBY_WIFI_DEVICES`. Programmatic hotspot control is not required for the first proof.

A travel router remains the fallback if Motorola's hotspot isolates clients, prevents
wireless debugging, or behaves poorly in the venue.

## Unattended Development Loop

The repository now provisions a maintainer-only reproducible toolchain without relying
on global `adb`, Android SDK, Java/JDK, Gradle, or Android Studio state:

- JDK 17;
- Android command-line tools, platform-tools, one pinned SDK platform, and build-tools;
- a checked-in Gradle wrapper so no global Gradle is required;
- scripted build, JVM tests, debug APK install/update, app start, health probe, and
  filtered log collection.

Prefer command-line provisioning in a documented maintainer location over making Android
Studio state part of the build. Android Studio may be installed for interactive work but
must not be required by automation or students.

The setup must also be portable to the maintainer laptop for travel to Guatemala:

- provide one PowerShell bootstrap entry point that starts from a normal clean Windows
  account and provisions the JDK and Android command-line tools into an ignored,
  repository-relative tool cache;
- pin and record every tool version, download source, and integrity hash rather than
  depending on whatever is globally installed on this PC;
- keep the Gradle wrapper and all required build configuration in the repository;
- provide a verification command that prints the resolved Java, SDK, build-tools,
  platform-tools, and Gradle versions before building;
- document the one-time Android SDK license step and the phone's separate RSA/wireless
  debugging pairing required on each workstation;
- once the online bootstrap works, prepare or document an optional offline cache/archive
  so poor event-site Internet does not prevent rebuilding or reinstalling the app.

Do not commit Android SDKs, JDKs, Gradle caches, signing secrets, phone RSA keys, or APK
build output. The repository carries the bootstrap recipe and version manifest; generated
tools remain replaceable local state.

One-time attended setup is unavoidable:

1. Enable developer options and USB debugging, authorize the workstation RSA key, and
   grant the app permission for the NXP Cup USB device.
2. Establish wireless debugging. If Motorola's Android 13 wireless-pairing UI is not
   reliable, use the Android-documented fallback: connect to the workstation once,
   run `adb tcpip 5555`, then `adb connect <phone-address>:5555` after moving the phone's
   USB-C port to the car.
3. Connect the phone to the car with a known data-capable USB-C OTG adapter/cable, power
   the car independently, and leave the vehicle in a safe non-moving mode.

After that setup, `src/android/tools/android_loop.ps1` builds, tests, installs, starts,
waits for a healthy framed session, verifies complete frames through the phone's
WebSocket, captures diagnostics, and exits nonzero on failure. Structured
`NXP_CUP_BRIDGE_HEALTH` logcat records and the HTTP `/health` endpoint make the proof
independent of a person looking at either screen. Use `-SkipRelay` only for a deliberate
USB-only diagnostic run.

Physical cable insertion, USB permission after app uninstall/default reset, phone reboot,
hotspot permission dialogs, and car power cycling remain attended boundaries unless
additional switching hardware is deliberately added. With the persistent AVC device
association intact, ordinary physical detach/reconnect no longer needs another USB
permission response.

## Test Strategy

- Pure JVM tests feed the Kotlin parser synthetic and captured byte streams covering
  fragmentation, garbage recovery, unknown IDs, sequence gaps, `DROPPED_BEFORE`, mixed
  message classes, and reconnects.
- A protocol conformance fixture checks Kotlin constants and field decoding against
  packets produced from the C protocol definition. Do not introduce an NDK dependency
  merely to share a small packed header.
- Android tests cover USB permission/state transitions, lifecycle restart, bounded
  queues, phone preview model, WebSocket slow-client behavior, and `/health` output.
- Hardware tests use the existing competition image and record sustained USB and relay
  rates, last-frame age, all app drop counters, and firmware stats.
- Disconnect/reconnect tests prove that app or network state cannot select TEST/STUDENT
  mode or enable motors.

## Power and Mechanical Safety

In USB host mode the phone sources VBUS. The car is independently battery-powered, so the
first bench check must confirm the cable and board do not create an unintended back-power
path. For the MVP, run the phone from its own 5000 mAh battery and do not attempt to charge
it while it hosts the car. Powered hubs or charge-through OTG adapters add failure modes
and should be evaluated only if measured runtime requires them.

Before vehicle use, validate phone temperature, battery drain, cable retention, connector
strain relief, the 185 g mass and mounting location, and whether the relay car remains a
fair competition vehicle. A dedicated demonstration car remains the cleanest race-day
choice.

## Boundaries and Deferred Work

- No general remote motor, steering, servo, or vehicle-mode commands.
- No firmware fork and no Android-specific packet IDs for the MVP.
- No dependency on Android Chrome Web Serial or WebUSB.
- No app-store release, account system, cloud service, or venue network.
- Dashboard presentation polish is owned by `shared-web-dashboard`; the generic data
  path and health evidence remain acceptance requirements.
- No recording in the current relay. JPEG, hardware H.264, and raw diagnostics all consume
  the existing live RGB565 stream without changing the camera format.
- No replacement of the standalone PC Web Serial viewer.

The next Android structure pass is deliberately parked behind the student-firmware work.
Its target boundary is: the activity owns display only; a foreground service owns the USB
session, latest-frame hub, selected encoder, relay, network-address changes, and a no-data
watchdog; the relay server owns one-client negotiation and bounded backpressure. Exactly
one encoder may run, logcat and `/health` remain the machine-readable diagnostics, and
the change must add lifecycle/reconnect tests before altering this proven race-week path.
It does not include actuator commands, shared-dashboard implementation, or student
firmware changes; those concerns retain their separate owners.

The inspected Bunny Vision firmware/software tree contains useful CDC host-side lineage
but no reusable Android/Gradle application or confirmed WebUSB spike. Treat claims of an
existing phone browser spike in older notes as stale unless an artifact is found later.

## Source Material

- `docs/plans/usb-debug-telemetry/plan.md`
- `docs/research/AVC_USB_Debug_Display_Current_State.md`
- `docs/research/AVC_USB_Debug_Transport_Protocol.md`
- `docs/research/AVC_RaceDay_Wireless_Frame_Relay.md`
- `src/common/nxpc_usb_debug/nxpc_usb_debug_protocol.h`
- `src/host/`
- Android USB host documentation:
  <https://developer.android.com/develop/connectivity/usb/host>
- Android USB-host debugging over network:
  <https://developer.android.com/develop/connectivity/usb>
- Android local-only hotspot documentation:
  <https://developer.android.com/develop/connectivity/wifi/localonlyhotspot>
