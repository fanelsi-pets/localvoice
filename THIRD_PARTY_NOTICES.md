# Third-party notices

Local Voice contains and adapts GPL-licensed open-source code. Copyright remains with the respective original contributors.

The project depends on open-source Swift packages including FluidAudio, AXSwift, KeySender, LaunchAtLogin, NetworkImage, Swift Atomics, Swift Markdown UI, and Zip. Their licenses and copyright notices are available in their respective source repositories and resolved package checkouts.

Two audited MIT-licensed dependency snapshots are maintained under the Local Voice GitHub account:

- `localvoice-llmkit` at commit `733b0accd1fa5a02ab327cb81b440524bdb92745`
- `localvoice-selectedtextkit` at commit `6dd60c6d5c405fcaf929450ae08ebe01574d1fc1`

The former MediaRemote adapter dependency was removed. Local Voice does not inspect or control playback in other applications.

Nothing in the Local Voice name, icon, or documentation implies endorsement by those projects or contributors.

## Meetings (MeetingScribe core)

The Meetings feature is the MeetingScribe core (`MeetingScribeKit`, Swift package by Ivan Minin) embedded as a
dependency. It brings these open-source components and models:

- [argmaxinc/argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) 1.1.0 — WhisperKit and SpeakerKit (MIT), with vendored Hub/Tokenizers from swift-transformers (Apache-2.0).
- [groue/GRDB.swift](https://github.com/groue/GRDB.swift) 7.11.1 (MIT) — meeting library and full-text search on the system SQLite.
- [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.6 (Apache-2.0) — shared with dictation.
- Models downloaded on first use of Meetings, never bundled: OpenAI Whisper large-v3 turbo (MIT, CoreML conversion by argmax);
  pyannote speaker-diarization community-1 for SpeakerKit and FluidAudio (CC BY 4.0 — attribution required);
  NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0).

Sparkle is a dependency of the MeetingScribe package but is not linked into Local Voice; updates keep coming through GitHub Releases.
