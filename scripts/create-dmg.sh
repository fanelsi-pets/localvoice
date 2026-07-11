#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: create-dmg.sh /path/to/LocalVoice.app [output.dmg]}"
OUTPUT_PATH="${2:-LocalVoice.dmg}"
STAGING_DIR="$(mktemp -d)/LocalVoice"

cleanup() {
  rm -rf "$(dirname "$STAGING_DIR")"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/LocalVoice.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "LocalVoice" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"

shasum -a 256 "$OUTPUT_PATH" > "$OUTPUT_PATH.sha256"
echo "Created $OUTPUT_PATH"
echo "Created $OUTPUT_PATH.sha256"
