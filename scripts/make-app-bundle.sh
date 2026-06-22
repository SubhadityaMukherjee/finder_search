#!/usr/bin/env bash
# Builds the FinderSearch SwiftPM executable and wraps it in a macOS .app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="FinderSearch"
CONFIG="${CONFIG:-release}"

echo "==> swift build -c $CONFIG"
cd "$PROJECT_ROOT"
swift build -c "$CONFIG"

BUILD_DIR="$PROJECT_ROOT/.build/$CONFIG"
EXECUTABLE="$BUILD_DIR/$APP_NAME"

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "error: built executable not found at $EXECUTABLE" >&2
    exit 1
fi

INFO_PLIST="$PROJECT_ROOT/Sources/FinderSearchApp/Resources/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "error: Info.plist not found at $INFO_PLIST" >&2
    exit 1
fi

APP_BUNDLE="$PROJECT_ROOT/.build/$APP_NAME.app"

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "✓ Built $APP_BUNDLE"
echo "  Launch with: open \"$APP_BUNDLE\""
