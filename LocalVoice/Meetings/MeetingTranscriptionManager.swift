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
        case transcribing
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
            case .transcribing: return 0.60
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

    private var processingTask: Task<Void, Never>?
    private var speakerAnalysisTask: Task<Void, Never>?
    private var speakerAnalysisID = UUID()
    private var cachedAnalysisKey: SpeakerAnalysisKey?
    private var cachedSpeakerSegments: [MeetingSpeakerSegment] = []
    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "MeetingTranscription")

    private struct SpeakerAnalysisKey: Equatable {
        let sourcePath: String
        let expectedSpeakerCount: Int?
    }

    func analyzeSpeakers(sourceURL: URL, expectedSpeakerCount: Int?, force: Bool = false) {
        guard !isProcessing else { return }

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
            } catch is CancellationError {
                guard self.speakerAnalysisID == analysisID else { return }
                self.speakerAnalysisStage = .idle
                self.isAnalyzingSpeakers = false
            } catch {
                guard self.speakerAnalysisID == analysisID else { return }
                self.logger.error("Meeting speaker analysis failed: \(error, privacy: .public)")
                self.speakerAnalysisStage = .failed(error.localizedDescription)
                self.isAnalyzingSpeakers = false
            }
        }
    }

    func start(
        sourceURL: URL,
        whisperModel: WhisperModelFile,
        language: String,
        expectedSpeakerCount: Int?,
        anchors: [MeetingSpeakerAnchor],
        whisperModelManager: WhisperModelManager,
        insightConfiguration: MeetingInsightAnalysisConfiguration? = nil,
        aiService: AIService? = nil
    ) {
        guard !isProcessing else { return }
        stopSpeakerAnalysis(clearResults: false)
        isProcessing = true
        transcript = nil
        insightsWarning = nil
        stage = .preparingAudio

        processingTask = Task { [weak self, weak whisperModelManager] in
            guard let self, let whisperModelManager else { return }
            do {
                let result = try await self.process(
                    sourceURL: sourceURL,
                    whisperModel: whisperModel,
                    language: language,
                    expectedSpeakerCount: expectedSpeakerCount,
                    anchors: anchors,
                    whisperModelManager: whisperModelManager,
                    insightConfiguration: insightConfiguration,
                    aiService: aiService
                )
                try Task.checkCancellation()
                self.transcript = result
                self.stage = .completed
                self.isProcessing = false
                try MeetingTranscriptStore.save(result)
            } catch is CancellationError {
                self.stage = .idle
                self.isProcessing = false
            } catch {
                self.logger.error("Meeting transcription failed: \(error, privacy: .public)")
                self.stage = .failed(error.localizedDescription)
                self.isProcessing = false
            }
        }
    }

    func cancel() {
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
    }

    func cancelSpeakerAnalysis() {
        stopSpeakerAnalysis(clearResults: false)
    }

    private func process(
        sourceURL: URL,
        whisperModel: WhisperModelFile,
        language: String,
        expectedSpeakerCount: Int?,
        anchors: [MeetingSpeakerAnchor],
        whisperModelManager: WhisperModelManager,
        insightConfiguration: MeetingInsightAnalysisConfiguration?,
        aiService: AIService?
    ) async throws -> MeetingTranscript {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoice-meeting-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        stage = .preparingAudio
        let samples = try await Task.detached(priority: .userInitiated) {
            let processor = AudioProcessor()
            let samples = try await processor.processAudioToSamples(sourceURL)
            try processor.saveSamplesAsWav(samples: samples, to: temporaryURL)
            return samples
        }.value
        try Task.checkCancellation()

        let duration = Double(samples.count) / AudioProcessor.AudioFormat.targetSampleRate
        let normalizedCount = normalizedSpeakerCount(expectedSpeakerCount)
        let key = analysisKey(sourceURL: sourceURL, expectedSpeakerCount: normalizedCount)
        let speakerSegments: [MeetingSpeakerSegment]

        if cachedAnalysisKey == key {
            speakerSegments = cachedSpeakerSegments
        } else {
            stage = .preparingDiarizationModels
            let diarizer = OfflineDiarizerManager(config: diarizerConfig(expectedSpeakerCount: normalizedCount))
            try await diarizer.prepareModels(directory: MeetingTranscriptStore.diarizationModelsDirectory)
            try Task.checkCancellation()

            stage = .diarizing(progress: 0)
            let diarization = try await diarizer.process(temporaryURL) { [weak self] processed, total in
                Task { @MainActor in
                    guard let self, self.isProcessing else { return }
                    self.stage = .diarizing(progress: total > 0 ? Double(processed) / Double(total) : 0)
                }
            }
            try Task.checkCancellation()
            speakerSegments = diarization.segments.map {
                MeetingSpeakerSegment(
                    speakerID: $0.speakerId,
                    startTime: TimeInterval($0.startTimeSeconds),
                    endTime: TimeInterval($0.endTimeSeconds)
                )
            }
        }

        stage = .transcribing
        let context: WhisperContext
        let usesSharedContext: Bool
        if whisperModelManager.loadedWhisperModel?.name == whisperModel.name,
            let loadedContext = whisperModelManager.whisperContext
        {
            context = loadedContext
            usesSharedContext = true
        } else {
            context = try await WhisperContext.createContext(path: whisperModel.url.path)
            usesSharedContext = false
        }

        await context.setLanguage(language)
        await context.setPrompt(UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? "")
        let transcriptionSucceeded = await context.fullTranscribe(samples: samples)
        guard transcriptionSucceeded else {
            if !usesSharedContext { await context.releaseResources() }
            throw LocalVoiceEngineError.whisperCoreFailed
        }
        let timedSegments = await context.getTimedSegments()
        if !usesSharedContext { await context.releaseResources() }
        try Task.checkCancellation()

        stage = .assembling
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

        stage = .analyzingInsights
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
            logger.error("Meeting AI insight analysis failed: \(error, privacy: .public)")
            insightsWarning = "AI-анализ итогов не сработал. Сохранены локальные итоги по правилам."
            return offlineTranscript
        }
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

        let duration = try await Task.detached(priority: .userInitiated) {
            let processor = AudioProcessor()
            let samples = try await processor.processAudioToSamples(sourceURL)
            try processor.saveSamplesAsWav(samples: samples, to: temporaryURL)
            return Double(samples.count) / AudioProcessor.AudioFormat.targetSampleRate
        }.value
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
        SpeakerAnalysisKey(
            sourcePath: sourceURL.standardizedFileURL.path,
            expectedSpeakerCount: expectedSpeakerCount
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

    static func save(_ transcript: MeetingTranscript) throws {
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
    }
}
