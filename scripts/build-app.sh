#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Dimac"
CONFIG="${1:-release}"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST_SOURCE="$ROOT/Sources/Dimac/Resources/Info.plist"
EXECUTABLE_PATH="$BUILD_DIR/$APP_NAME"

cd "$ROOT"
swift build -c "$CONFIG" --product "$APP_NAME"

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    echo "Expected built executable at $EXECUTABLE_PATH" >&2
    exit 1
fi

if [[ ! -f "$INFO_PLIST_SOURCE" ]]; then
    echo "Missing Info.plist at $INFO_PLIST_SOURCE" >&2
    exit 1
fi

rm -rf "$APP_DIR"
install -d "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"

setopt local_options null_glob
for resource in "$ROOT"/Sources/Dimac/Resources/*; do
    [[ "${resource:t}" == "Info.plist" ]] && continue
    cp -R "$resource" "$RESOURCES_DIR/"
done

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
