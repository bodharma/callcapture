#!/usr/bin/env bash
# Build the CallCapture executable, refresh the .app bundle's Mach-O, and
# ad-hoc-sign it with the entitlements needed for mic / system-audio capture.
#
# The .app bundle ships under .build/CallCapture.app and has historically been
# assembled out-of-band — `swift build` only writes to .build/<config>/CallCapture
# and leaves the bundle's binary stale. Running ONLY `swift build` after a
# source change is therefore a trap: the change is in the SwiftPM binary, not
# in the bundle, so the running .app still has the old code (recent migration
# and PythonBridge fixes were both invisible until this script copied the
# fresh binary into the bundle). Always invoke this script after a change to
# Swift sources that needs to land in the running app.
#
# Usage:
#   ./Scripts/build-app.sh                # debug build (default)
#   ./Scripts/build-app.sh release        # release build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${1:-debug}"

cd "$APP_DIR"

echo "===> swift build ($CONFIG)"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release --product CallCapture
    SRC_BIN=".build/release/CallCapture"
else
    swift build --product CallCapture
    SRC_BIN=".build/arm64-apple-macosx/debug/CallCapture"
fi

APP_BUNDLE=".build/CallCapture.app"
DEST_BIN="$APP_BUNDLE/Contents/MacOS/CallCapture"

if [[ ! -d "$APP_BUNDLE/Contents/MacOS" ]]; then
    echo "error: bundle layout missing at $APP_BUNDLE — generate it once with whatever script assembled it originally." >&2
    exit 1
fi

if [[ ! -f "$SRC_BIN" ]]; then
    echo "error: built binary not found at $SRC_BIN" >&2
    exit 1
fi

echo "===> refreshing bundle binary"
cp "$SRC_BIN" "$DEST_BIN"

echo "===> signing"
"$SCRIPT_DIR/sign-app.sh" "$APP_BUNDLE"

echo
echo "Built and signed $APP_BUNDLE"
