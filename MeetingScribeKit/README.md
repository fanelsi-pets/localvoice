# MeetingScribe core (vendored)

This folder is the MeetingScribe core — the Swift package behind the **Meetings** feature of Local Voice:
streaming decode of Zoom recordings, speaker diarization (SpeakerKit / FluidAudio), speech recognition with a
language per speaker (WhisperKit / Parakeet), speaker names and voice profiles, the meeting library with
full-text search, project memory and follow-up import, Markdown/SRT/JSON export, model downloads with
checksums, and the SwiftUI interface that Local Voice shows in its Meetings window.

Author: Ivan Minin. The upstream package is developed privately; this copy is distributed with Local Voice
under the same license as Local Voice (GNU GPL v3, see `../LICENSE`). Compared with upstream, the Sparkle
updater target, the command-line tool and the test suites are not included — Local Voice does not use them.

Refresh the copy from a local checkout of the upstream repository with `scripts/sync-meetingscribe-kit.sh`
and then re-run `scripts/merge-meetingscribe-strings.py` so the app's string catalog picks up new keys.

Third-party components and their licenses are listed in `../THIRD_PARTY_NOTICES.md` (WhisperKit and
SpeakerKit — MIT; FluidAudio — Apache-2.0; GRDB.swift — MIT; models — MIT and CC BY 4.0).
