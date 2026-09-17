# Local Voice privacy model

Local Voice uses local transcription by default for dictation. It also offers explicit opt-in cloud modes: Gemini
for dictation, and Microsoft Azure for meeting transcription (see **Meetings**).

## Enforcement layers

1. `LocalVoice.entitlements` and `LocalVoice.local.entitlements` enable the macOS App Sandbox. Client networking is enabled only for the optional Gemini integration; server networking remains disabled.
2. `LocalOnlyNetworkBlocker` rejects URL Loading System requests whose scheme is HTTP, HTTPS, WS, or WSS unless the destination host is on a short allow list: the Gemini and OpenAI-compatible endpoints behind the opt-in cloud modes, Azure Speech (`*.api.cognitive.microsoft.com`, `*.cognitiveservices.azure.com`) for meeting transcription, Hugging Face for model downloads, and GitHub for updates.
3. `CloudProviderRegistry` exposes Gemini only. Groq and other remote providers are unavailable.
4. CloudKit is disabled for every SwiftData store.
5. The app has no licensing, announcement, telemetry, or automatic-update services.

## Gemini mode

When Gemini is selected, recorded audio and the transcription instruction are sent to the Google Gemini Developer API. The API key is stored in the macOS Keychain. Local Voice uses `gemini-2.5-flash-lite`, Google's smallest stable cost-efficient multimodal model. Do not select Gemini when the recording must remain entirely on-device.

## Meetings

The Meetings feature (MeetingScribe core) processes Zoom recordings in one of two places, and the choice is yours:

- **On this Mac.** Nothing leaves the device: WhisperKit or Parakeet recognizes the speech on the Neural Engine
  and GPU. The only network use is downloading open-source models from Hugging Face on first use (allowed by
  `LocalOnlyNetworkBlocker`) and, optionally, a local language model at a localhost address you configure.
- **In the Azure cloud** (the default for new installs, and an explicit one-time question for everyone who used
  Meetings before it existed). The recording's audio is uploaded in chunks to Microsoft Azure, where
  MAI-Transcribe-2 returns words with timecodes; under Azure's terms the audio is not retained. The Azure Speech
  key is entered by you on a dedicated screen before the first cloud run, is stored in this Mac's Keychain and is
  used only for transcription. No key is shipped in the app or in this repository.

Whatever recognizes the speech, speaker separation, voice profiles, names, project memory, follow-ups stored in
the library and export always run on this Mac. Recordings you import are read through security-scoped bookmarks
inside the sandbox; exports are written only to files and folders you choose, which is why the entitlements now
include `com.apple.security.files.user-selected.read-write`.

## Data locations

Application data is stored in the user's Application Support container. Audio retention and transcript retention can be configured inside the app. Export operations only write to locations explicitly selected by the user.

## Verification

After building, inspect the signed app:

```sh
codesign -d --entitlements :- ~/Downloads/LocalVoice.app
```

The output should show `com.apple.security.app-sandbox = true`, `com.apple.security.network.client = true`, and no network server key. For an additional runtime check, monitor the process while exercising local and Gemini transcription.
