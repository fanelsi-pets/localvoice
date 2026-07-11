# Local Voice

Local Voice is a native macOS voice-to-text application with local transcription by default and an optional Gemini transcription mode.

The interface and core transcription workflow are derived from [VoiceInk](https://github.com/Beingpax/VoiceInk). This fork keeps the familiar native macOS experience while removing cloud services, license activation, announcements, automatic updates, and CloudKit sync.

## Privacy modes

- Local Whisper transcription keeps recordings and transcripts on this Mac.
- Gemini is opt-in: audio is sent to `generativelanguage.googleapis.com` only after the user selects Gemini and supplies an API key.
- An in-process allowlist blocks HTTP, HTTPS, WS, and WSS requests to every other host.
- Only local Whisper, FluidAudio, or supported on-device Apple models appear in the model registry.
- Groq and all cloud providers other than Gemini are not registered.
- Dictionary, history, statistics, audio, and settings use local storage only.
- License activation, remote announcements, and Sparkle updates are disabled.

See [PRIVACY.md](PRIVACY.md) for the auditable implementation details.

## Models

Local Voice does not download a model at runtime because that would require network access. Import a compatible Whisper model from disk, or place it in the app's local model directory before launching. Model files can be obtained separately and transferred to the Mac using any method you trust.

## Build

Requirements: macOS 14.4+, full Xcode, Git, and Swift.

```sh
make local
```

The command builds `whisper.xcframework` as a development dependency and produces `~/Downloads/LocalVoice.app`. Network access used by Git/Xcode during source dependency resolution is a build-time action; the resulting app remains sandboxed without network permissions.

## License and attribution

Local Voice is distributed under GNU GPL v3, matching the upstream VoiceInk license. Copyright in upstream code remains with its respective authors. The Local Voice name and supplied application icon identify this fork and do not imply endorsement by the VoiceInk authors.
