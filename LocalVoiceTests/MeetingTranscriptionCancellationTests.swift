import Foundation
import Testing
@testable import LocalVoice

struct MeetingTranscriptionCancellationTests {
    @MainActor
    @Test func processingDrainPrecedesQueuedSpeakerAnalysis() async {
        let probe = MeetingHeavyWorkProbe()
        let manager = MeetingTranscriptionManager(
            speakerAnalysisOperation: { sourceURL, _ in
                await probe.run(label: "speaker:\(sourceURL.lastPathComponent)")
                return .init(
                    segments: [
                        MeetingSpeakerSegment(
                            speakerID: sourceURL.deletingPathExtension().lastPathComponent,
                            startTime: 0,
                            endTime: 1
                        )
                    ],
                    duration: 1
                )
            },
            processingOperation: { sourceURL in
                await probe.run(label: "processing:\(sourceURL.lastPathComponent)")
                return MeetingTranscript(
                    sourceFilename: sourceURL.lastPathComponent,
                    duration: 1,
                    turns: [],
                    speakerNames: [:],
                    insights: MeetingInsights()
                )
            }
        )
        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = WhisperModelFile(
            name: "ggml-test",
            url: modelsDirectory.appendingPathComponent("ggml-test.bin"),
            coreMLEncoderURL: nil
        )
        let modelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let firstURL = URL(fileURLWithPath: "/tmp/first-meeting.m4a")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement-meeting.m4a")

        manager.start(
            sourceURL: firstURL,
            whisperModel: model,
            language: "auto",
            expectedSpeakerCount: nil,
            anchors: [],
            whisperModelManager: modelManager
        )
        #expect(await probe.waitForStarts(1))
        #expect(manager.isProcessing)

        manager.reset()
        #expect(manager.isProcessing, "Cancellation must remain busy while native work drains")

        manager.analyzeSpeakers(
            sourceURL: replacementURL,
            expectedSpeakerCount: nil
        )
        var snapshot = await probe.snapshot()
        #expect(snapshot.starts == ["processing:first-meeting.m4a"])
        #expect(snapshot.maximumActive == 1)

        await probe.releaseNext()
        #expect(await probe.waitForStarts(2))

        snapshot = await probe.snapshot()
        #expect(snapshot.starts == [
            "processing:first-meeting.m4a",
            "speaker:replacement-meeting.m4a",
        ])
        #expect(snapshot.active == 1)
        #expect(snapshot.maximumActive == 1)
        #expect(!manager.isProcessing)
        #expect(manager.isAnalyzingSpeakers, "The drained stale job must not clear the replacement's busy state")
        #expect(manager.transcript == nil)

        await probe.releaseNext()
        #expect(await waitForSpeakerAnalysisToFinish(manager))
        #expect(manager.speakerSegments.map(\.speakerID) == ["replacement-meeting"])
    }

    @MainActor
    @Test func resetQueuesLatestPreviewWithoutOverlappingFluidAudioWork() async {
        let probe = MeetingHeavyWorkProbe()
        let manager = MeetingTranscriptionManager(
            speakerAnalysisOperation: { sourceURL, _ in
                await probe.run(label: sourceURL.lastPathComponent)
                return .init(
                    segments: [
                        MeetingSpeakerSegment(
                            speakerID: sourceURL.deletingPathExtension().lastPathComponent,
                            startTime: 0,
                            endTime: 1
                        )
                    ],
                    duration: 1
                )
            }
        )
        let firstURL = URL(fileURLWithPath: "/tmp/old-preview.m4a")
        let newestURL = URL(fileURLWithPath: "/tmp/new-preview.m4a")

        manager.analyzeSpeakers(sourceURL: firstURL, expectedSpeakerCount: nil)
        #expect(await probe.waitForStarts(1))

        manager.reset()
        #expect(manager.isAnalyzingSpeakers)
        manager.analyzeSpeakers(sourceURL: newestURL, expectedSpeakerCount: 3)

        await probe.releaseNext()
        #expect(await probe.waitForStarts(2))

        var snapshot = await probe.snapshot()
        #expect(snapshot.starts == ["old-preview.m4a", "new-preview.m4a"])
        #expect(snapshot.active == 1)
        #expect(snapshot.maximumActive == 1)
        #expect(manager.isAnalyzingSpeakers)
        #expect(manager.speakerSegments.isEmpty)

        await probe.releaseNext()
        #expect(await waitForSpeakerAnalysisToFinish(manager))

        snapshot = await probe.snapshot()
        #expect(snapshot.active == 0)
        #expect(snapshot.maximumActive == 1)
        #expect(manager.speakerSegments.map(\.speakerID) == ["new-preview"])
        #expect(manager.speakerAnalysisStage == .ready(speakerCount: 1))
    }

    @MainActor
    private func waitForSpeakerAnalysisToFinish(
        _ manager: MeetingTranscriptionManager
    ) async -> Bool {
        for _ in 0..<400 {
            if !manager.isAnalyzingSpeakers { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}

private actor MeetingHeavyWorkProbe {
    struct Snapshot: Sendable {
        let starts: [String]
        let active: Int
        let maximumActive: Int
    }

    private var starts: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(label: String) async {
        starts.append(label)
        active += 1
        maximumActive = max(maximumActive, active)

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }

        active -= 1
    }

    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func snapshot() -> Snapshot {
        Snapshot(starts: starts, active: active, maximumActive: maximumActive)
    }

    func waitForStarts(_ count: Int) async -> Bool {
        for _ in 0..<400 {
            if starts.count >= count { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}
