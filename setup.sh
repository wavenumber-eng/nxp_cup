#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$(uname -s)" != "Darwin" ]; then
  echo "setup.sh supports macOS only. On Windows, run .\\setup.ps1." >&2
  exit 2
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "The first Mac setup supports Apple Silicon arm64 only." >&2
  exit 2
fi

if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ]; then
  PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
  export PATH
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required. Install it from https://brew.sh, then rerun ./setup.sh." >&2
  exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "Installing PowerShell 7 with Homebrew..."
  brew install --formula powershell
fi
if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 is still unavailable after Homebrew setup." >&2
  exit 1
fi

exec pwsh -NoProfile -File "$script_dir/setup.ps1" "$@"
