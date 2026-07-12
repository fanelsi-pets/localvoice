#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: sign-notarize-dmg.sh /path/to/LocalVoice.app /path/to/LocalVoice.dmg}"
DMG_PATH="${2:?Usage: sign-notarize-dmg.sh /path/to/LocalVoice.app /path/to/LocalVoice.dmg}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi

if [[ -z "$IDENTITY" ]]; then
  echo "error: Developer ID Application certificate with its private key was not found." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

WHISPER_FRAMEWORK="$APP_PATH/Contents/Frameworks/whisper.framework"
if [[ -d "$WHISPER_FRAMEWORK" ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$WHISPER_FRAMEWORK"
fi

codesign \
  --force \
  --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements LocalVoice/LocalVoice.entitlements \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

scripts/create-dmg.sh "$APP_PATH" "$DMG_PATH"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait
else
  echo "error: set NOTARY_KEYCHAIN_PROFILE or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID." >&2
  exit 1
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

echo "Signed identity: $IDENTITY"
echo "Notarized DMG: $DMG_PATH"
echo "Checksum: $DMG_PATH.sha256"
