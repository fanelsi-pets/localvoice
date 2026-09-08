#!/bin/bash
# Sandboxed test build without notarization: Release build signed with Developer ID and the release
# entitlements (App Sandbox), so Meetings can be tested the way users run it (bookmarks, container).
# Usage: scripts/sign-local-release.sh [output dir, default dist]
set -euo pipefail

OUT_DIR="${1:-dist}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "error: Developer ID Application certificate with its private key was not found." >&2
  exit 1
fi

xcodebuild \
  -project LocalVoice.xcodeproj \
  -scheme LocalVoice \
  -configuration Release \
  -derivedDataPath .release-build \
  CODE_SIGNING_ALLOWED=NO \
  build | grep -E "error:|BUILD" || true

APP_SRC=".release-build/Build/Products/Release/LocalVoice.app"
[[ -d "$APP_SRC" ]] || { echo "error: app not found at $APP_SRC" >&2; exit 1; }
mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/LocalVoice.app"
ditto "$APP_SRC" "$OUT_DIR/LocalVoice.app"
APP="$OUT_DIR/LocalVoice.app"

WHISPER_FRAMEWORK="$APP/Contents/Frameworks/whisper.framework"
if [[ -d "$WHISPER_FRAMEWORK" ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$WHISPER_FRAMEWORK"
fi
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements LocalVoice/LocalVoice.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -E "app-sandbox|user-selected" || true
echo "Signed (not notarized): $APP — run with: open \"$APP\""
