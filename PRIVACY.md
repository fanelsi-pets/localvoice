# Local Voice privacy model

Local Voice uses local transcription by default. It also offers an explicit opt-in Gemini mode.

## Enforcement layers

1. `LocalVoice.entitlements` and `LocalVoice.local.entitlements` enable the macOS App Sandbox. Client networking is enabled only for the optional Gemini integration; server networking remains disabled.
2. `LocalOnlyNetworkBlocker` rejects URL Loading System requests whose scheme is HTTP, HTTPS, WS, or WSS unless the destination host is exactly `generativelanguage.googleapis.com`.
3. `CloudProviderRegistry` exposes Gemini only. Groq and other remote providers are unavailable.
4. CloudKit is disabled for every SwiftData store.
5. The app has no licensing, announcement, telemetry, or automatic-update services.

## Gemini mode

When Gemini is selected, recorded audio and the transcription instruction are sent to the Google Gemini Developer API. The API key is stored in the macOS Keychain. Local Voice uses `gemini-2.5-flash-lite`, Google's smallest stable cost-efficient multimodal model. Do not select Gemini when the recording must remain entirely on-device.

## Data locations

Application data is stored in the user's Application Support container. Audio retention and transcript retention can be configured inside the app. Export operations only write to locations explicitly selected by the user.

## Verification

After building, inspect the signed app:

```sh
codesign -d --entitlements :- ~/Downloads/LocalVoice.app
```

The output should show `com.apple.security.app-sandbox = true`, `com.apple.security.network.client = true`, and no network server key. For an additional runtime check, monitor the process while exercising local and Gemini transcription.
