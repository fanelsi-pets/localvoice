# Local Voice

Local Voice is a native macOS dictation app built around private on-device transcription with optional Gemini and OpenAI providers.

## Features

- Meetings: transcribe Zoom recordings on this Mac — speaker separation, per-speaker language (Russian, Ukrainian, English), names, project memory and Markdown/SRT export (the MeetingScribe core).
- Bundled Whisper Base model for offline transcription.
- Optional downloadable Whisper models, including Medium and Large variants.
- Optional Gemini and OpenAI transcription and text enhancement.
- Ukrainian, Russian, and English interface and dictation languages.
- Global recording shortcuts and a dynamic menu-bar control.
- Local transcript history, dictionary, audio-device settings, and custom modes.
- API keys stored in the macOS Keychain.

## Privacy

- Local Whisper keeps audio and transcripts on this Mac.
- Cloud providers are disabled until the user explicitly adds an API key and selects a cloud model.
- Network access is restricted to the configured Gemini and OpenAI API hosts.
- Local Voice does not operate an intermediary server.

See [PRIVACY.md](PRIVACY.md) for implementation details.

## Build

Requirements: macOS 15+ on Apple Silicon, Xcode 26, Git, CMake, and Swift. The Meetings core is the `MeetingScribeKit`
Swift package referenced from `../Транскрибация` (see `THIRD_PARTY_NOTICES.md`).

```sh
make local
```

The Xcode project also supports an ad-hoc signed Debug build without an Apple Developer account.

## License

Local Voice is distributed under GNU GPL v3. Third-party copyright and dependency notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
