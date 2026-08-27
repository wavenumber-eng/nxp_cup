# Android Agent Guide

This component consumes the existing `AVCU` v1 session and must not independently
rename wire bytes, USB identities, or public firmware fields. Keep USB reading,
compression, and network delivery bounded; slow clients must never block the USB
reader or grow memory without limit.

Use `setup.ps1` only with explicit Android license acceptance and `build.ps1` for
unit tests plus APK assembly. Hardware/deploy scripts under `tools` are
maintainer-only and require an explicitly selected phone when ambiguity exists.
Use `release.ps1` for versioned APK release candidates; publication requires a clean
source commit already present on GitHub and preserves the existing debug-signing status
until a separate signing plan is explicitly approved.

The generated `res/raw/relay_viewer.html` combines shared presentation from `src/web`
with the Android-owned `web/relay_adapter.js`. Preserve its WebSocket, video-mode, and
bounded decode behavior; never edit the generated page directly. It is the sole Android
HTML resource and contains the current Formula One presentation, not the removed legacy
page. Keep remote vehicle control limited to firmware-capability-gated Race Start and
Stop with the deliberate hold-to-start behavior and bounded native action queue. Do not
create a second relay implementation or split APK roles until the plan's lifecycle and
app-role structure dependencies are satisfied. See `docs/design/shared-web-dashboard.md`.
