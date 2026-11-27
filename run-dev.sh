#!/bin/bash
# Dev launcher for CallCapture
# Builds, bundles, and launches with Python worker in dev mode

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$REPO_DIR/macos-app"
WEB_DIR="$REPO_DIR/web"
BUNDLE="$APP_DIR/.build/CallCapture.app"

# The app serves the web UI from web/dist (CALLCAPTURE_WEB_DIR below). Build it the first
# time; after web changes run `npm run build` (or `npx vite build --watch`) in web/.
if [ ! -f "$WEB_DIR/dist/index.html" ]; then
    echo "Building the web UI into web/dist (needs Node 22+)..."
    (cd "$WEB_DIR" && { [ -d node_modules ] || npm ci; } && npm run build)
fi

echo "Building Swift app..."
cd "$APP_DIR" && swift build 2>&1

echo "Updating app bundle..."
cp "$APP_DIR/.build/debug/CallCapture" "$BUNDLE/Contents/MacOS/CallCapture"

# Re-sign after swapping the binary. Copying a fresh executable in invalidates
# the bundle's signature (identifier reverts to swift-build's CallCapture-<hash>
# and the entitlements are dropped), which denies the Core Audio process tap
# ("failed to create audiotap"). sign-app.sh restores the com.callcapture.app
# identifier + the audio-input entitlement (ad-hoc).
echo "Signing app bundle (ad-hoc + entitlements)..."
"$APP_DIR/Scripts/sign-app.sh" "$BUNDLE"

echo "Launching CallCapture (dev mode)..."
export CALLCAPTURE_DEV_MODE=1
export CALLCAPTURE_WORKER_DIR="$REPO_DIR/python-worker"
export CALLCAPTURE_WEB_DIR="$WEB_DIR/dist"

# Kill existing instances if running. Match both the bundled binary and a
# raw `swift build` / `swift run` debug binary so no orphan keeps a menu bar
# icon alive after relaunch.
pkill -9 -f "CallCapture.app/Contents/MacOS/CallCapture" 2>/dev/null || true
pkill -9 -f "\.build/debug/CallCapture" 2>/dev/null || true
pkill -9 -x "CallCapture" 2>/dev/null || true
sleep 0.5

open "$BUNDLE" --env CALLCAPTURE_DEV_MODE=1 --env CALLCAPTURE_WORKER_DIR="$REPO_DIR/python-worker" \
    --env CALLCAPTURE_WEB_DIR="$WEB_DIR/dist"
echo "App launched. Check menu bar for waveform icon."
