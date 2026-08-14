#!/usr/bin/env bash
# Build a proper GameDock.app bundle from the SPM release build.
# Ad-hoc signed (fine for local use; replace with a Developer ID for distribution).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="build/GameDock.app"

echo ">> Assembling $APP ($CONFIG)"

BIN_DIR=".build/${CONFIG}"
if [ ! -f "${BIN_DIR}/GameDock" ]; then
  echo "!! Binary not found at ${BIN_DIR}/GameDock — run 'make build' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "${BIN_DIR}/GameDock" "$APP/Contents/MacOS/GameDock"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null 2>&1
echo ">> Done: $APP"
