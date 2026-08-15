#!/usr/bin/env bash
# Build a proper Leblanc.app bundle from the SPM build.
# Ad-hoc signed (fine for local use; replace with a Developer ID for distribution).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="build/Leblanc.app"

echo ">> Assembling $APP ($CONFIG)"

BIN_DIR=".build/${CONFIG}"
if [ ! -f "${BIN_DIR}/Leblanc" ]; then
  echo "!! Binary not found at ${BIN_DIR}/Leblanc — run 'make build' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "${BIN_DIR}/Leblanc" "$APP/Contents/MacOS/Leblanc"
cp Info.plist "$APP/Contents/Info.plist"

# Fonts + any SPM resources live in the generated resource bundle.
RES_BUNDLE="$(find .build -maxdepth 3 -name 'GameDock_GameDock.bundle' | head -1)"
if [ -n "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

# Release: strip symbols (smaller binary) before ad-hoc signing.
if [ "$CONFIG" = "release" ]; then
  strip -x "$APP/Contents/MacOS/Leblanc" 2>/dev/null || true
fi

codesign --force --sign - "$APP" >/dev/null 2>&1
echo ">> Done: $APP ($CONFIG)"
