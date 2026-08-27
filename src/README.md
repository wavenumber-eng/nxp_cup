# Source Components

| Folder | Purpose | Normal command | Student edits |
| --- | --- | --- | --- |
| `embedded` | FRDM-MCXN947 firmware, MCUXpresso project, CMake build, and hardware tools | `.\src\embedded\build.ps1` | Normally the VISION exercise and RACE mode named in `embedded/AGENTS.md` |
| `host` | Native Windows/macOS camera and telemetry viewer and CLI plus the direct WebSerial viewer | `src/host/build.ps1` | No |
| `android` | Maintainer phone USB-host and Wi-Fi telemetry relay | `.\src\android\build.ps1` | No |
| `web` | Shared Formula One dashboard presentation and standalone-page generator | `.\src\web\build.ps1` | No |
| `common` | Shared linked libraries used by the embedded and host components | Built through a consumer | No |

Each buildable component owns its build entry point and detailed README. Read the
nearest `AGENTS.md` before using an LLM to change component code.

On Windows, invoke the PowerShell scripts directly, such as
`.\src\embedded\build.ps1`. On macOS, invoke those same scripts with PowerShell
7, such as `pwsh -NoProfile -File src/embedded/build.ps1`; do not create parallel
Mac build or flash wrappers. See the [Apple Silicon macOS guide](../docs/setup-macos.md).

The shared Formula One presentation under `web` generates the committed direct WebSerial
and Android relay pages. Transport adapters remain with their consumers. Use
`.\src\web\build.ps1 -Check` to detect generated-output drift; do not use `src/common`
for browser assets because that folder has embedded linked-source ownership.
