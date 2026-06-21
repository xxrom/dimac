#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"

if [[ -z "$DEVELOPER_DIR_PATH" ]]; then
    echo "xcode-select is not configured. Install Xcode and select its developer directory first." >&2
    exit 1
fi

if [[ "$DEVELOPER_DIR_PATH" == "/Library/Developer/CommandLineTools" ]]; then
    echo "swift test needs the full Xcode toolchain because XCTest is unavailable in Command Line Tools-only setups." >&2
    echo "Install Xcode, then run:" >&2
    echo "  sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

cd "$ROOT"
swift test "$@"
