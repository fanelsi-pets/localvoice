// swift-tools-version: 6.2
// MeetingScribe core (product `MeetingScribeKit`) vendored into Local Voice — see README.md in this folder.
// Kept identical to the upstream package except for what Local Voice does not use: the Sparkle updater target,
// the command-line tool and the test targets.

import PackageDescription

let package = Package(
  name: "MeetingScribe",
  defaultLocalization: "ru",
  platforms: [.macOS(.v15)],
  products: [
    .library(
      name: "MeetingScribeKit",
      targets: [
        "Core", "Ingest", "Engines", "Pipeline", "Export", "Voices", "OCR", "Store", "LocalLLM",
        "ModelDownload", "MeetingScribeUI",
      ]
    )
  ],
  dependencies: [
    // WhisperKit + SpeakerKit (MIT), pinned exactly (upstream ADR-002).
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    // Parakeet TDT v3 + offline VBx diarization (Apache-2.0); one version for the whole Local Voice graph.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    // SQLite with FTS5 for the meeting library and search (MIT); links the system libsqlite3.
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
  ],
  targets: [
    // Wrapper around mach_task_self(): the global `mach_task_self_` is not concurrency-safe in Swift 6.
    .target(name: "CMach", path: "Sources/CMach"),

    // Data models, engine protocols, progress, errors, ModelStore, fusion.
    .target(name: "Core", dependencies: ["CMach"]),

    // Streaming decode through AVAssetReader → mono 16 kHz Float32.
    .target(name: "Ingest", dependencies: ["Core"]),

    // Engine adapters: one engine = one module.
    .target(
      name: "WhisperKitAdapter",
      dependencies: ["Core", .product(name: "WhisperKit", package: "argmax-oss-swift")],
      path: "Sources/Engines/WhisperKitAdapter"
    ),
    .target(
      name: "SpeakerKitAdapter",
      dependencies: ["Core", .product(name: "SpeakerKit", package: "argmax-oss-swift")],
      path: "Sources/Engines/SpeakerKitAdapter"
    ),
    .target(
      name: "ParakeetAdapter",
      dependencies: ["Core", .product(name: "FluidAudio", package: "FluidAudio")],
      path: "Sources/Engines/ParakeetAdapter"
    ),
    .target(
      name: "FluidAudioAdapter",
      dependencies: ["Core", .product(name: "FluidAudio", package: "FluidAudio")],
      path: "Sources/Engines/FluidAudioAdapter"
    ),
    // Registry: the only place that knows every adapter, plus the engine providers for the app.
    .target(
      name: "Engines",
      dependencies: [
        "Core", "Ingest", "WhisperKitAdapter", "SpeakerKitAdapter", "ParakeetAdapter",
        "FluidAudioAdapter",
      ],
      path: "Sources/Engines/Registry"
    ),

    .target(name: "Export", dependencies: ["Core"]),
    // Voice profiles: centroids, cosine matching, profile updates.
    .target(name: "Voices", dependencies: ["Core"]),
    // Participant captions on video frames: AVAssetImageGenerator + Vision RecognizeTextRequest.
    .target(name: "OCR", dependencies: ["Core"]),

    // Meeting library: SQLite `library.sqlite` (GRDB, FTS5) — projects, meetings, people, decisions, tasks,
    // questions, follow-ups, utterance index; transcripts live in `meetings/<id>/transcript.json`.
    .target(
      name: "Store",
      dependencies: ["Core", "Export", "Voices", .product(name: "GRDB", package: "GRDB.swift")]),

    // Optional local language model through an OpenAI-compatible endpoint (off by default).
    .target(name: "LocalLLM", dependencies: ["Core"]),

    // Model downloads from Hugging Face: bytes, resume, checksums, manifests.
    .target(name: "ModelDownload", dependencies: ["Core"]),

    // The processing pipeline: engines come through the Core protocols, writes no files itself.
    .target(name: "Pipeline", dependencies: ["Core", "Ingest", "Export", "Voices"]),

    // The interface: SwiftUI views and view models, isolated to the main actor by default.
    .target(
      name: "MeetingScribeUI",
      dependencies: [
        "Core", "Ingest", "Engines", "Pipeline", "Export", "Store", "Voices", "OCR", "LocalLLM",
        "ModelDownload",
      ],
      path: "App/MeetingScribeUI",
      // Built-in self-test sample (28 s, two synthesized voices) and its manifest.
      resources: [.process("Resources")],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
  ]
)
