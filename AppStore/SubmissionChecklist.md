# LocalVoice Mac App Store submission

## Build

- Use the shared `LocalVoice App Store` scheme.
- Archive configuration: `AppStore`.
- Store version: `3.2.0` (`CFBundleVersion` 321).
- Bundle identifier: `app.localvoice.LocalVoice`.
- Confirm the archive uses automatic signing for paid team `MJS369PZL8`.
  Xcode archives with an Apple Development identity, then applies App Store
  distribution signing during validation/upload. If Xcode cannot create a
  managed distribution identity, open **Settings → Accounts → Manage
  Certificates…** and create **Apple Distribution** manually.
- Run **Validate App** in Xcode Organizer before upload.
- Upload the archive through **TestFlight & App Store**. Do not upload a DMG.

The `APP_STORE` compilation condition disables the GitHub update workflow,
AppleScript/browser automation, and custom-command delivery. The App Store
entitlements intentionally omit Apple Events automation.

## Release gate: text insertion

The direct-distribution build inserts text into another app by posting a
Cmd–V event after temporarily placing the transcription on the pasteboard.
That path depends on Accessibility/CGEvent behavior. Apple documents use of
accessibility APIs in assistive apps and arbitrary cross-app automation as
activities that are incompatible with App Sandbox.

Before uploading a production build:

1. Run the sandboxed `LocalVoice App Store` build on a clean macOS account.
2. Verify that Accessibility can be granted and that Cmd–V reaches TextEdit,
   Safari, Notes, Slack, and Microsoft Word.
3. If sandboxing blocks the event, do not submit the current binary as a
   full-system dictation utility. Choose either:
   - an App Store edition that keeps the result in LocalVoice with an explicit
     **Copy** action; or
   - continued Developer ID distribution for automatic cross-app insertion.
4. Describe the exact tested insertion flow in App Review notes. Do not add a
   temporary-exception entitlement without Apple approval.

## App Store Connect

- Create a macOS app record for `app.localvoice.LocalVoice`.
- SKU suggestion: `LOCALVOICE-MAC-001`.
- Primary category: Productivity.
- Accept the current Paid Apps Agreement.
- Complete banking and tax information.
- In **Monetization → Pricing and Availability**, choose the United States as
  the base storefront and select the **USD 4.99** price point.
- Add support and privacy-policy URLs.
- Complete App Privacy for Audio Data and Other User Content used for app functionality.
- Answer export compliance based on system HTTPS only; the App Store build sets
  `ITSAppUsesNonExemptEncryption` to `NO`.

## Assets

- Add 3–6 macOS screenshots without transparency.
- Recommended size: 2880×1800; accepted alternative: 1440×900.
- Prepare English and Ukrainian product-page metadata.
- Confirm the app icon has no transparency and renders at all required sizes.

## TestFlight acceptance

- Fresh install completes onboarding without a pre-existing API key.
- Local transcription works without transmitting audio.
- Cloud setup clearly states which provider receives audio.
- Microphone and Accessibility permission denial does not crash the app.
- Global shortcut starts and stops recording exactly once.
- A successful dictation restores the previous clipboard contents.
- Downloading, selecting, and deleting each local model works in the sandbox.
- Imported audio is accessed only through a user-selected file URL.
- GitHub update controls and custom command controls are absent.
- Test on Apple Silicon and the oldest supported macOS version.

## App Review notes

Explain:

1. Microphone access records the phrase selected by the user.
2. Accessibility access inserts the transcription into the currently focused text field.
3. Recording always has a visible waveform/status indication.
4. In local mode, audio and transcripts remain on the Mac.
5. Cloud mode is opt-in and sends audio only to the provider chosen and configured by the user.
6. Downloaded speech models are non-executable model data consumed by the transcription engine already included in the reviewed app.
