#!/usr/bin/env bash
# Build the CallCapture executable, assemble a self-contained .app bundle
# (Swift binary + bundled PyInstaller worker), and ad-hoc-sign it with the
# entitlements needed for mic / system-audio capture.
#
# `swift build` only writes to .build/<config>/CallCapture and never touches a
# bundle, so running ONLY `swift build` after a source change is a trap: the
# change is in the SwiftPM binary, not in the running .app. This script always
# (re)assembles the bundle via assemble-app.sh — wiping and recreating
# .build/CallCapture.app from the fresh binary and the frozen worker — then
# signs it. Always invoke this script after a change to Swift sources that
# needs to land in the running app. The frozen worker is rebuilt with
# PyInstaller when it is missing, when FORCE_WORKER_REBUILD is set, or when any
# worker source is newer than the built binary — so a worker source change
# (e.g. new cost-tracking code) can never silently ship a stale frozen worker.
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

WORKER_SRC="$APP_DIR/../python-worker"
WORKER_DIST="$WORKER_SRC/dist/call-capture-worker"
WORKER_BIN="$WORKER_DIST/call-capture-worker"

# Rebuild the frozen worker when it is missing, when forced, or when any worker
# source is newer than the frozen binary. The previous "build only if missing"
# guard silently shipped a stale worker whenever app/ changed after the first
# freeze: the cost-tracking feature merged AFTER the worker was frozen, so the
# bundled worker emitted no cost fields and the app stored NULL session costs.
worker_needs_build=0
if [[ ! -x "$WORKER_BIN" ]]; then
    worker_needs_build=1
elif [[ -n "${FORCE_WORKER_REBUILD:-}" ]]; then
    worker_needs_build=1
elif [[ -n "$(find "$WORKER_SRC/app" "$WORKER_SRC/packaging" "$WORKER_SRC/pyproject.toml" -newer "$WORKER_BIN" 2>/dev/null | head -1)" ]]; then
    echo "===> worker source newer than frozen binary — rebuilding"
    worker_needs_build=1
fi
if [[ "$worker_needs_build" == "1" ]]; then
    echo "===> building worker (PyInstaller)"
    ( cd "$WORKER_SRC" \
        && source .venv/bin/activate 2>/dev/null || true \
        && pyinstaller --clean --noconfirm packaging/call-capture-worker.spec )
fi

echo "===> assembling .app"
"$SCRIPT_DIR/assemble-app.sh" "$CONFIG" "$WORKER_DIST"

echo "===> signing (ad-hoc)"
"$SCRIPT_DIR/sign-app.sh" "$APP_DIR/.build/CallCapture.app"

echo
echo "Built and signed $APP_DIR/.build/CallCapture.app"
