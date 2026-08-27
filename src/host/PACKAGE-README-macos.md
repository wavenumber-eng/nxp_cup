# NXP Cup core tools for macOS arm64

This folder is the prebuilt Apple Silicon student runtime. Keep the command-line
files together; the viewer app may also be moved independently.

- `NXP Cup Viewer.app` shows camera frames and telemetry and can program the
  normal firmware image.
- `nxpc_tool` provides command-line device checks and ROM-HID programming.
- `rblhost` is the pinned NXP ROM-HID programmer used by the command-line tool.
  The app carries a separate self-contained copy.

After extracting the ZIP, open the viewer in Finder or run this from its folder:

```sh
open "NXP Cup Viewer.app"
```

This package has no Apple Developer ID and is not notarized. It uses only an
ad-hoc code signature, which does not identify or establish trust in the
publisher. Verify the ZIP against its separately supplied `.zip.sha256` file
before opening it.

On a downloaded copy, macOS may block the first launch. Try to open the app
once, then open **System Settings > Privacy & Security**, scroll to **Security**,
and choose **Open Anyway** for NXP Cup Viewer. Authenticate and confirm **Open**.
Only make this exception for a package whose checksum you obtained from the
project organizer and verified.

The viewer can select the firmware file through its file picker. The
command-line equivalent is:

```sh
./nxpc_tool program --image /path/to/nxp_cup_core0.bin
```

Programming uses the board's ROM-HID bootloader and does not require J-Link.
See the repository setup documentation for board bootloader entry and optional
J-Link recovery instructions.

`manifest.json` identifies the release and contains SHA-256 digests for every
regular payload file. The manifest records the package's ad-hoc signing and
unnotarized state. License notices for redistributed components are included.
