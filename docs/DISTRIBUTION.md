# Developer ID distribution

LocalVoice releases distributed outside the Mac App Store must be signed with
`Developer ID Application`, submitted to Apple's notary service, and stapled
before the DMG is uploaded to GitHub Releases.

## One-time local setup

1. Join the Apple Developer Program and add the Account Holder account in Xcode.
2. In Xcode, open **Settings → Accounts → Manage Certificates** and create a
   **Developer ID Application** certificate.
3. Confirm that the certificate and its private key are installed:

   ```bash
   security find-identity -v -p codesigning
   ```

4. Create an app-specific password for the Apple Account, then store the
   notarization credentials in Keychain:

   ```bash
   xcrun notarytool store-credentials "LocalVoice-notary" \
     --apple-id "APPLE_ID_EMAIL" \
     --team-id "APPLE_TEAM_ID" \
     --password "APP_SPECIFIC_PASSWORD"
   ```

## Local signed release

Build the unsigned Release app, then sign and notarize it:

```bash
xcodebuild \
  -project LocalVoice.xcodeproj \
  -scheme LocalVoice \
  -configuration Release \
  -derivedDataPath .release-build \
  CODE_SIGNING_ALLOWED=NO \
  build

NOTARY_KEYCHAIN_PROFILE="LocalVoice-notary" \
  scripts/sign-notarize-dmg.sh \
  .release-build/Build/Products/Release/LocalVoice.app \
  dist/LocalVoice.dmg
```

The script signs the embedded Whisper framework and app with Hardened Runtime
and a secure timestamp, signs the DMG, waits for notarization, staples the
ticket, validates Gatekeeper acceptance, and regenerates the SHA-256 checksum.

## GitHub Actions secrets

The tag-triggered release workflow requires:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_NOTARY_KEY_P8_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

Export the Developer ID certificate together with its private key from Keychain
Access as a password-protected `.p12`. Store only its base64 representation in
GitHub Actions; never commit the certificate, private key, passwords, or API key.

Create an App Store Connect API key with access suitable for notarization and
store the `.p8` file as base64 plus its Key ID and Issuer ID. GitHub Actions uses
a temporary keychain and deletes it with the hosted runner after the job.
