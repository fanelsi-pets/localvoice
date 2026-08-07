import AVFoundation
import FluidAudio
import Foundation
import OSLog

@MainActor
final class MeetingTranscriptionManager: ObservableObject {
    enum SpeakerAnalysisStage: Equatable {
        case idle
        case preparingAudio
        case preparingModels
        case diarizing(progress: Double)
        case ready(speakerCount: Int)
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Анализ голосов ещё не запущен"
            case .preparingAudio: return "Подготавливаем дорожку для анализа голосов…"
            case .preparingModels: return "Проверяем локальные модели голосов…"
            case .diarizing: return "Ищем участки с разными голосами…"
            case .ready(let speakerCount): return "Найдено голосов: \(speakerCount)"
            case .failed(let message): return message
            }
        }

        var progress: Double? {
            switch self {
            case .preparingAudio: return 0.08
            case .preparingModels: return 0.18
            case .diarizing(let value): return 0.20 + value * 0.80
            case .ready: return 1
            default: return nil
            }
        }
    }

    enum Stage: Equatable {
        case idle
        case preparingAudio
        case preparingDiarizationModels
        case diarizing(progress: Double)
        case transcribing(progress: Double)
        case assembling
        case analyzingInsights
        case completed
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Готово к запуску"
            case .preparingAudio: return "Подготавливаем аудио…"
            case .preparingDiarizationModels: return "Проверяем модели спикеров…"
            case .diarizing: return "Разделяем спикеров…"
            case .transcribing: return "Распознаём речь…"
            case .assembling: return "Собираем транскрипцию и итоги…"
            case .analyzingInsights: return "Выделяем решения и настоящий follow-up через AI…"
            case .completed: return "Транскрипция готова"
            case .failed(let message): return message
            }
        }

        var progress: Double? {
            switch self {
            case .preparingAudio: return 0.05
            case .preparingDiarizationModels: return 0.12
            case .diarizing(let value): return 0.15 + value * 0.40
            case .transcribing(let value): return 0.58 + min(1, max(0, value)) * 0.35
            case .assembling: return 0.95
            case .analyzingInsights: return 0.98
            case .completed: return 1
            default: return nil
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var transcript: MeetingTranscript?
    @Published private(set) var isProcessing = false
    @Published private(set) var speakerAnalysisStage: SpeakerAnalysisStage = .idle
    @Published private(set) var speakerSegments: [MeetingSpeakerSegment] = []
    @Published private(set) var speakerAnalysisDuration: TimeInterval = 0
    @Published private(set) var isAnalyzingSpeakers = false
    @Published private(set) var insightsWarning: String?
    @Published private(set) var savedTranscriptDirectory: URL?

    private var processingTask: Task<Void, Never>?
    private var processingID = UUID()
    private var whisperControl: WhisperTranscriptionControl?
    private var speakerAnalysisTask: Task<Void, Never>?
    private var speakerAnalysisID = UUID()
    private var cachedAnalysisKey: SpeakerAnalysisKey?
    private var cachedSpeakerSegments: [MeetingSpeakerSegment] = []
    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "MeetingTranscription")

    private struct SpeakerAnalysisKey: Equatable {
        let sourcePath: String
        let expectedSpeakerCount: Int?
        let fileSize: Int64?
        let modificationDate: Date?
    }

    func analyzeSpeakers(sourceURL: URL, expectedSpeakerCount: Int?, force: Bool = false) {
        // Speaker analysis is intentionally single-flight. FluidAudio performs
        // native work internally, so a replacement must not start until the
        // previous task has actually unwound.
        guard !isProcessing, !isAnalyzingSpeakers else { return }

        let normalizedCount = normalizedSpeakerCount(expectedSpeakerCount)
        let key = analysisKey(sourceURL: sourceURL, expectedSpeakerCount: normalizedCount)
        if !force, cachedAnalysisKey == key {
            speakerSegments = cachedSpeakerSegments
            speakerAnalysisStage = .ready(speakerCount: Set(cachedSpeakerSegments.map(\.speakerID)).count)
            isAnalyzingSpeakers = false
            return
        }

        speakerAnalysisTask?.cancel()
        let analysisID = UUID()
        speakerAnalysisID = analysisID
        cachedAnalysisKey = nil
        cachedSpeakerSegments = []
        speakerSegments = []
        speakerAnalysisDuration = 0
        speakerAnalysisStage = .preparingAudio
        isAnalyzingSpeakers = true

        speakerAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.performSpeakerAnalysis(
                    sourceURL: sourceURL,
                    expectedSpeakerCount: normalizedCount,
                    analysisID: analysisID
                )
                try Task.checkCancellation()
                guard self.speakerAnalysisID == analysisID else { return }

                self.cachedAnalysisKey = key
                self.cachedSpeakerSegments = result.segments
                self.speakerSegments = result.segments
                self.speakerAnalysisDuration = result.duration
                self.speakerAnalysisStage = .ready(
                    speakerCount: Set(result.segments.map(\.speakerID)).count
                )
                self.isAnalyzingSpeakers = false
                self.speakerAnalysisTask = nil
            } catch is CancellationError {
                guard self.speakerAnalysisID == analysisID else { return }
                self.speakerAnalysisStage = .idle
                self.isAnalyzingSpeakers = false
                self.speakerAnalysisTask = nil
            } catch {
                guard self.speakerAnalysisID == analysisID else { return }
                self.logger.error("Meeting speaker analysis failed: \(error, privacy: .public)")
                self.speakerAnalysisStage = .failed(error.localizedDescription)
                self.isAnalyzingSpeakers = false
                self.speakerAnalysisTask = nil
            }
        }
    }

    func start(
        sourceURL: URL,
        whisperModel: WhisperModelFile,
        language: String,
        expectedSpeakerCount: Int?,
        anchors: [MeetingSpeakerAnchor],
        whisperModelManager _: WhisperModelManager,
        insightConfiguration: MeetingInsightAnalysisConfiguration? = nil,
        aiService: AIService? = nil
    ) {
        guard !isProcessing, !isAnalyzingSpeakers else { return }
        stopSpeakerAnalysis(clearResults: false)
        let generationID = UUID()
        let control = WhisperTranscriptionControl()
        processingID = generationID
        whisperControl = control
        isProcessing = true
        transcript = nil
        insightsWarning = nil
        savedTranscriptDirectory = nil
        stage = .preparingAudio

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.process(
                    sourceURL: sourceURL,
                    whisperModel: whisperModel,
                    language: language,
                    expectedSpeakerCount: expectedSpeakerCount,
                    anchors: anchors,
                    insightConfiguration: insightConfiguration,
                    aiService: aiService,
                    generationID: generationID,
                    whisperControl: control
                )
                try Task.checkCancellation()
                guard self.processingID == generationID else { return }
                let savedDirectory = try MeetingTranscriptStore.save(result)
                try Task.checkCancellation()
                guard self.processingID == generationID else { return }
                self.transcript = result
                self.savedTranscriptDirectory = savedDirectory
                self.stage = .completed
                self.isProcessing = false
                self.processingTask = nil
                self.whisperControl = nil
            } catch is CancellationError {
                guard self.processingID == generationID else { return }
                self.stage = .idle
                self.isProcessing = false
                self.processingTask = nil
                self.whisperControl = nil
            } catch {
                guard self.processingID == generationID else { return }
                self.logger.error("Meeting transcription failed: \(error, privacy: .public)")
                self.stage = .failed(error.localizedDescription)
                self.isProcessing = false
                self.processingTask = nil
                self.whisperControl = nil
            }
        }
    }

    func cancel() {
        processingID = UUID()
        whisperControl?.cancel()
        whisperControl = nil
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        stage = .idle
    }

    func reset() {
        cancel()
        stopSpeakerAnalysis(clearResults: true)
        transcript = nil
        insightsWarning = nil
        savedTranscriptDirectory = nil
    }

    func cancelSpeakerAnalysis() {
        // Keep the busy flag set until native work has really returned. A quick
        // sidebar round-trip therefore cannot launch an overlapping analysis.
        speakerAnalysisTask?.cancel()
    }

    private func process(
        sourceURL: URL,
        whisperModel: WhisperModelFile,
        language: String,
        expectedSpeakerCount: Int?,
        anchors: [MeetingSpeakerAnchor],
        insightConfiguration: MeetingInsightAnalysisConfiguration?,
        aiService: AIService?,
        generationID: UUID,
        whisperControl: WhisperTranscriptionControl
    ) async throws -> MeetingTranscript {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoice-meeting-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try updateStage(.preparingAudio, generationID: generationID)
        let samples = try await prepareAudio(sourceURL: sourceURL, temporaryURL: temporaryURL)
        try Task.checkCancellation()
        try validateProcessingRun(generationID)

        let duration = Double(samples.count) / AudioProcessor.AudioFormat.targetSampleRate
        let normalizedCount = normalizedSpeakerCount(expectedSpeakerCount)
        let key = analysisKey(sourceURL: sourceURL, expectedSpeakerCount: normalizedCount)
        let speakerSegments: [MeetingSpeakerSegment]

        if cachedAnalysisKey == key {
            speakerSegments = cachedSpeakerSegments
        } else {
            try updateStage(.preparingDiarizationModels, generationID: generationID)
            let diarizer = OfflineDiarizerManager(config: diarizerConfig(expectedSpeakerCount: normalizedCount))
            try await diarizer.prepareModels(directory: MeetingTranscriptStore.diarizationModelsDirectory)
            try Task.checkCancellation()

            try updateStage(.diarizing(progress: 0), generationID: generationID)
            let diarization = try await diarizer.process(temporaryURL) { [weak self] processed, total in
                Task { @MainActor in
                    guard let self,
                        self.processingID == generationID,
                        self.isProcessing
                    else { return }
                    self.stage = .diarizing(progress: total > 0 ? Double(processed) / Double(total) : 0)
                }
            }
            try Task.checkCancellation()
            try validateProcessingRun(generationID)
            speakerSegments = diarization.segments.map {
                MeetingSpeakerSegment(
                    speakerID: $0.speakerId,
                    startTime: TimeInterval($0.startTimeSeconds),
                    endTime: TimeInterval($0.endTimeSeconds)
                )
            }
            try validateProcessingRun(generationID)
            cachedAnalysisKey = key
            cachedSpeakerSegments = speakerSegments
            self.speakerSegments = speakerSegments
            speakerAnalysisDuration = duration
            speakerAnalysisStage = .ready(speakerCount: Set(speakerSegments.map(\.speakerID)).count)
        }

        try updateStage(.transcribing(progress: 0), generationID: generationID)
        let context = try await WhisperContext.createContext(path: whisperModel.url.path)

        await context.setLanguage(language)
        await context.setPrompt(UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? "")
        let transcriptionSucceeded = await context.fullTranscribe(
            samples: samples,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                        self.processingID == generationID,
                        self.isProcessing
                    else { return }
                    self.stage = .transcribing(progress: progress)
                }
            },
            control: whisperControl
        )
        let timedSegments = transcriptionSucceeded ? await context.getTimedSegments() : []
        await context.releaseResources()
        if whisperControl.isCancelled {
            throw CancellationError()
        }
        guard transcriptionSucceeded else {
            throw LocalVoiceEngineError.whisperCoreFailed
        }
        try Task.checkCancellation()
        try validateProcessingRun(generationID)

        try updateStage(.assembling, generationID: generationID)
        let offlineTranscript = MeetingTranscriptBuilder.build(
            sourceFilename: sourceURL.lastPathComponent,
            duration: duration,
            whisperSegments: timedSegments,
            speakerSegments: speakerSegments,
            anchors: anchors
        )

        guard let insightConfiguration, let aiService else {
            return offlineTranscript
        }

        try updateStage(.analyzingInsights, generationID: generationID)
        do {
            let aiInsights = try await MeetingAIInsightAnalyzer.analyze(
                turns: offlineTranscript.turns,
                configuration: insightConfiguration,
                aiService: aiService
            )
            try Task.checkCancellation()

            let fallback = offlineTranscript.insights
            let mergedInsights = MeetingInsights(
                keyPoints: aiInsights.keyPoints.isEmpty ? fallback.keyPoints : aiInsights.keyPoints,
                decisions: aiInsights.decisions.isEmpty ? fallback.decisions : aiInsights.decisions,
                actionItems: aiInsights.actionItems.isEmpty ? fallback.actionItems : aiInsights.actionItems,
                questions: aiInsights.questions.isEmpty ? fallback.questions : aiInsights.questions
            )
            return MeetingTranscript(
                id: offlineTranscript.id,
                sourceFilename: offlineTranscript.sourceFilename,
                createdAt: offlineTranscript.createdAt,
                duration: offlineTranscript.duration,
                turns: offlineTranscript.turns,
                speakerNames: offlineTranscript.speakerNames,
                insights: mergedInsights
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try validateProcessingRun(generationID)
            logger.error("Meeting AI insight analysis failed: \(error, privacy: .public)")
            insightsWarning = "AI-анализ итогов не сработал. Сохранены локальные итоги по правилам."
            return offlineTranscript
        }
    }

    private func validateProcessingRun(_ generationID: UUID) throws {
        guard processingID == generationID, isProcessing else {
            throw CancellationError()
        }
    }

    private func updateStage(_ newStage: Stage, generationID: UUID) throws {
        try validateProcessingRun(generationID)
        stage = newStage
    }

    private func performSpeakerAnalysis(
        sourceURL: URL,
        expectedSpeakerCount: Int?,
        analysisID: UUID
    ) async throws -> (segments: [MeetingSpeakerSegment], duration: TimeInterval) {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoice-speaker-preview-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let samples = try await prepareAudio(sourceURL: sourceURL, temporaryURL: temporaryURL)
        let duration = Double(samples.count) / AudioProcessor.AudioFormat.targetSampleRate
        try Task.checkCancellation()
        guard speakerAnalysisID == analysisID else { throw CancellationError() }

        speakerAnalysisStage = .preparingModels
        let diarizer = OfflineDiarizerManager(config: diarizerConfig(expectedSpeakerCount: expectedSpeakerCount))
        try await diarizer.prepareModels(directory: MeetingTranscriptStore.diarizationModelsDirectory)
        try Task.checkCancellation()
        guard speakerAnalysisID == analysisID else { throw CancellationError() }

        speakerAnalysisStage = .diarizing(progress: 0)
        let diarization = try await diarizer.process(temporaryURL) { [weak self] processed, total in
            Task { @MainActor in
                guard let self,
                    self.speakerAnalysisID == analysisID,
                    self.isAnalyzingSpeakers
                else { return }
                self.speakerAnalysisStage = .diarizing(
                    progress: total > 0 ? Double(processed) / Double(total) : 0
                )
            }
        }
        try Task.checkCancellation()

        let segments = diarization.segments.map {
            MeetingSpeakerSegment(
                speakerID: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds)
            )
        }
        return (segments, duration)
    }

    /// Runs the synchronous parts of media decoding away from the main actor while
    /// still propagating cancellation to the worker. A plain detached task would
    /// otherwise keep decoding a long Zoom recording after the user changes files
    /// or leaves the screen, potentially overlapping a second full decode.
    private func prepareAudio(sourceURL: URL, temporaryURL: URL) async throws -> [Float] {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let processor = AudioProcessor()
            let samples = try await processor.processAudioToSamples(sourceURL)
            try Task.checkCancellation()
            try processor.saveSamplesAsWav(samples: samples, to: temporaryURL)
            try Task.checkCancellation()
            return samples
        }

        return try await withTaskCancellationHandler {
            let samples = try await worker.value
            try Task.checkCancellation()
            return samples
        } onCancel: {
            worker.cancel()
        }
    }

    private func stopSpeakerAnalysis(clearResults: Bool) {
        speakerAnalysisID = UUID()
        speakerAnalysisTask?.cancel()
        speakerAnalysisTask = nil
        isAnalyzingSpeakers = false

        if clearResults {
            speakerAnalysisStage = .idle
            speakerSegments = []
            speakerAnalysisDuration = 0
            cachedAnalysisKey = nil
            cachedSpeakerSegments = []
        } else if cachedAnalysisKey == nil {
            speakerAnalysisStage = .idle
        }
    }

    private func analysisKey(sourceURL: URL, expectedSpeakerCount: Int?) -> SpeakerAnalysisKey {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        return SpeakerAnalysisKey(
            sourcePath: sourceURL.standardizedFileURL.path,
            expectedSpeakerCount: expectedSpeakerCount,
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }

    private func normalizedSpeakerCount(_ count: Int?) -> Int? {
        guard let count, count > 0 else { return nil }
        return count
    }

    private func diarizerConfig(expectedSpeakerCount: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        if let expectedSpeakerCount {
            config.clustering.numSpeakers = expectedSpeakerCount
        }
        return config
    }
}

enum MeetingTranscriptStore {
    private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.localvoice.LocalVoice", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    static var diarizationModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.localvoice.LocalVoice", isDirectory: true)
            .appendingPathComponent("DiarizationModels", isDirectory: true)
    }

    @discardableResult
    static func save(_ transcript: MeetingTranscript) throws -> URL {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let stem = transcript.sourceFilename
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let folder = baseDirectory.appendingPathComponent("\(stem)-\(transcript.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transcript).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try transcript.markdown.write(
            to: folder.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        return folder
    }
}
