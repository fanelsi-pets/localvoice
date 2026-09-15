import Core
import Foundation
import Testing
import WhisperKit

@testable import WhisperKitAdapter

/// Тесты адаптера WhisperKit: только чистые функции и конфигурация путей.
/// Ни один тест не создаёт `WhisperKit`, не грузит модели и не ходит в сеть — реальный инференс живёт в SmokeTests.

// MARK: - Вспомогательное

private func makeSegment(
  start: Float,
  end: Float,
  text: String,
  words: [WordTiming]? = nil,
  noSpeechProb: Float = 0.125,
  avgLogprob: Float = -0.25,
  compressionRatio: Float = 1.5
) -> TranscriptionSegment {
  TranscriptionSegment(
    start: start,
    end: end,
    text: text,
    avgLogprob: avgLogprob,
    compressionRatio: compressionRatio,
    noSpeechProb: noSpeechProb,
    words: words
  )
}

private func makeResult(language: String, segments: [TranscriptionSegment]) -> TranscriptionResult {
  TranscriptionResult(
    text: segments.map(\.text).joined(),
    segments: segments,
    language: language,
    timings: TranscriptionTimings()
  )
}

private func withTemporaryStore(models: [ModelID] = [], _ body: (ModelStore) -> Void) {
  let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "meetingscribe-engine-tests-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ModelStore(root: root)
  for model in models {
    let directory = store.directory(for: model)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for entry in model.requiredEntries {
      FileManager.default.createFile(
        atPath: directory.appending(path: entry).path, contents: Data("stub".utf8))
    }
  }
  body(store)
}

// MARK: - Маппинг

@Suite("WhisperKit: маппинг результатов")
struct WhisperKitMappingTests {
  @Test("Сегмент и слова получают смещение и метрики")
  func segmentWithOffset() {
    let words = [
      WordTiming(word: " Привет", tokens: [1], start: 0.5, end: 0.75, probability: 0.875),
      WordTiming(word: " мир", tokens: [2], start: 0.75, end: 1.5, probability: 0.5),
    ]
    let source = makeSegment(start: 0.5, end: 1.5, text: " Привет мир", words: words)

    let mapped = WhisperKitMapping.segment(source, offset: 120, language: .ru)

    #expect(mapped.start == 120.5)
    #expect(mapped.end == 121.5)
    #expect(mapped.text == "Привет мир")
    #expect(mapped.language == .ru)
    #expect(mapped.noSpeechProb == 0.125)
    #expect(mapped.avgLogprob == -0.25)
    #expect(mapped.compressionRatio == 1.5)
    #expect(mapped.words.count == 2)
    // Ведущий пробел сохраняется: по нему Fuser склеивает реплику.
    #expect(mapped.words[0].text == " Привет")
    #expect(mapped.words[0].start == 120.5)
    #expect(mapped.words[0].end == 120.75)
    #expect(mapped.words[0].probability == 0.875)
    #expect(mapped.words[1].end == 121.5)
  }

  @Test("Сегменты всех окон сортируются по началу, язык берётся из результата")
  func segmentsSorted() {
    let results = [
      makeResult(
        language: "ru",
        segments: [makeSegment(start: 10, end: 12, text: "второй")]),
      makeResult(
        language: "uk",
        segments: [
          makeSegment(start: 0, end: 2, text: "первый"),
          makeSegment(start: 20, end: 22, text: "третий"),
        ]),
    ]

    let mapped = WhisperKitMapping.segments(results, offset: 1)

    #expect(mapped.map(\.text) == ["первый", "второй", "третий"])
    #expect(mapped.map(\.start) == [1, 11, 21])
    #expect(mapped.map(\.language) == [.uk, .ru, .uk])
  }

  @Test("Пустые сегменты не выбрасываются: фильтр галлюцинаций — фаза 1")
  func emptySegmentsKept() {
    let results = [
      makeResult(
        language: "ru",
        segments: [
          makeSegment(start: 0, end: 0.02, text: " "),
          makeSegment(start: 1, end: 2, text: "текст"),
        ])
    ]

    #expect(WhisperKitMapping.segments(results).count == 2)
  }

  @Test("Спецтокены и таймкодные токены вычищаются из текста")
  func specialTokensRemoved() {
    #expect(WhisperKitMapping.cleanText("<|0.00|> Привет<|1.24|>") == "Привет")
    #expect(
      WhisperKitMapping.cleanText("<|startoftranscript|><|ru|><|transcribe|> текст<|endoftext|>")
        == "текст")
    #expect(WhisperKitMapping.cleanText("  обычный текст  ") == "обычный текст")
    #expect(WhisperKitMapping.cleanText("хвост <|обрезано") == "хвост")
    #expect(WhisperKitMapping.cleanText("") == "")
  }

  @Test("Определение языка: код и вероятности")
  func languageDetection() {
    let detection = WhisperKitMapping.languageDetection(
      language: "uk", probabilities: ["uk": 0.75, "ru": 0.125, "xx": 0.125])

    #expect(detection.language == .uk)
    #expect(detection.probabilities[.uk] == 0.75)
    #expect(detection.probabilities[.ru] == 0.125)
    #expect(detection.probabilities[.other("xx")] == 0.125)
    #expect(detection.confidence == 0.75)
  }

  @Test("Определение языка: log-вероятности WhisperKit переводятся в вероятности")
  func languageDetectionFromLogProbabilities() {
    let detection = WhisperKitMapping.languageDetection(
      language: "ru", probabilities: ["ru": -0.05, "uk": -3.0, "en": -6.0])

    #expect(detection.language == .ru)
    #expect(abs(detection.confidence - exp(-0.05)) < 1e-6)
    #expect(abs((detection.probabilities[.uk] ?? 0) - exp(-3.0)) < 1e-6)
    #expect(detection.confidence > 0.9)
  }

  @Test("Параметры декодирования: язык явный, VAD, пороги по умолчанию")
  func decodingOptions() {
    let options = WhisperKitMapping.decodingOptions(language: .ru, wordTimestamps: true)

    #expect(options.language == "ru")
    #expect(options.task == .transcribe)
    #expect(options.usePrefillPrompt)
    #expect(options.detectLanguage == false)
    #expect(options.skipSpecialTokens)
    #expect(options.withoutTimestamps == false)
    #expect(options.wordTimestamps)
    #expect(options.chunkingStrategy == .vad)
    #expect(options.concurrentWorkerCount == 4)
    #expect(options.noSpeechThreshold == 0.6)
    #expect(options.compressionRatioThreshold == 2.4)
  }
}

// MARK: - Прогресс

@Suite("WhisperKit: накопитель прогресса")
struct WhisperKitProgressTrackerTests {
  @Test("Секунды обработанного аудио не уменьшаются")
  func processedSecondsAreMonotonic() {
    let tracker = WhisperKitProgressTracker(totalAudioSeconds: 100, timeOffset: 10)

    let values = [[4.0, 9.0], [3.0], [12.0], [11.0, 5.0]]
      .compactMap { tracker.event(forSegmentEnds: $0)?.processedAudioSeconds }

    #expect(values == [9, 9, 12, 12])
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
  }

  @Test("Таймкод абсолютный, доля стадии считается от длительности куска")
  func timecodeIncludesOffset() {
    let tracker = WhisperKitProgressTracker(totalAudioSeconds: 60, timeOffset: 300)
    let event = tracker.event(forSegmentEnds: [30])

    #expect(event?.stage == .transcription)
    #expect(event?.processedAudioSeconds == 30)
    #expect(event?.totalAudioSeconds == 60)
    #expect(event?.timecode == 330)
    #expect(event?.estimatedFraction == 0.5)
  }

  @Test("Секунды не выходят за длительность куска, пустой список не даёт события")
  func processedSecondsClamped() {
    let tracker = WhisperKitProgressTracker(totalAudioSeconds: 10)

    #expect(tracker.event(forSegmentEnds: [])?.processedAudioSeconds == nil)
    #expect(tracker.event(forSegmentEnds: [15])?.processedAudioSeconds == 10)
    #expect(tracker.completionEvent().processedAudioSeconds == 10)
  }

  @Test("Пульс из сегментов: текст и таймкод одного сегмента, живость без текста прореживается")
  func pulseFromSegments() {
    let tracker = WhisperKitProgressTracker(
      totalAudioSeconds: 100, timeOffset: 300, livenessInterval: 1)
    let event = tracker.event(for: [
      makeSegment(start: 2, end: 7, text: " распознанная фраза "),
      makeSegment(start: 0, end: 2, text: " раньше "),
    ])
    #expect(event?.pulse == "распознанная фраза")
    #expect(event?.processedAudioSeconds == 7)
    #expect(event?.timecode == 307)

    let liveness = tracker.livenessEvent(now: 0)
    #expect(liveness?.pulse == nil)
    #expect(liveness?.processedAudioSeconds == 7)
    #expect(tracker.livenessEvent(now: 0.5) == nil)
    #expect(tracker.livenessEvent(now: 1.5) != nil)
    #expect(tracker.event(for: [])?.pulse == nil)
  }

  @Test("Клипы превращаются в пары секунд по порядку, вырожденные пропускаются")
  func clipTimestamps() {
    let sampleCount = 100 * PCMAudio.sampleRate
    let clips: [ClosedRange<Double>] = [40...55.5, 0...10, 20...20]
    #expect(WhisperKitMapping.clipTimestamps(clips, sampleCount: sampleCount) == [0, 10, 40, 55.5])
    #expect(WhisperKitMapping.clipTimestamps([], sampleCount: sampleCount).isEmpty)
    let options = WhisperKitMapping.decodingOptions(
      language: .uk, wordTimestamps: true,
      clipTimestamps: WhisperKitMapping.clipTimestamps([1.5...3], sampleCount: sampleCount))
    #expect(options.clipTimestamps == [1.5, 3])
    #expect(options.language == "uk")
    #expect(
      WhisperKitMapping.decodingOptions(language: .ru, wordTimestamps: true).clipTimestamps.isEmpty)
  }

  @Test("Отмена: флаг виден из колбэка")
  func cancellationFlag() {
    let tracker = WhisperKitProgressTracker(totalAudioSeconds: 10)

    #expect(!tracker.isCancelled)
    tracker.cancel()
    #expect(tracker.isCancelled)
  }
}

// MARK: - Пути моделей

@Suite("WhisperKit: конфигурация путей")
struct WhisperKitModelPlanTests {
  @Test("Модель на диске: modelFolder из ModelStore, скачивания нет")
  func modelPresent() {
    withTemporaryStore(models: [.whisperLargeV3Turbo]) { store in
      let plan = WhisperKitEngine.plan(modelStore: store, model: .whisperLargeV3Turbo)

      #expect(plan.needsDownload == false)
      #expect(plan.modelFolder == store.directory(for: .whisperLargeV3Turbo))
      #expect(plan.downloadBase == store.hfBase)
      #expect(plan.tokenizerFolder == store.hfBase)
      #expect(plan.variant == "openai_whisper-large-v3-v20240930_turbo")
      #expect(plan.repo == "argmaxinc/whisperkit-coreml")

      let configuration = WhisperKitEngine.configuration(for: plan, verbose: false)
      #expect(configuration.download == false)
      #expect(configuration.modelFolder == store.directory(for: .whisperLargeV3Turbo).path)
      #expect(configuration.tokenizerFolder == store.hfBase)
      #expect(configuration.downloadBase == store.hfBase)
      #expect(configuration.model == "openai_whisper-large-v3-v20240930_turbo")
      #expect(configuration.load == true)
      #expect(configuration.prewarm == false)
      #expect(configuration.verbose == false)
    }
  }

  @Test("Модели нет: modelFolder пуст, конфигурация разрешает скачивание")
  func modelMissing() {
    withTemporaryStore { store in
      let plan = WhisperKitEngine.plan(modelStore: store, model: .whisperLargeV3)

      #expect(plan.needsDownload)
      #expect(plan.modelFolder == nil)

      let configuration = WhisperKitEngine.configuration(for: plan, verbose: true)
      #expect(configuration.download)
      #expect(configuration.modelFolder == nil)
      #expect(configuration.model == "openai_whisper-large-v3")
      #expect(configuration.verbose)
    }
  }
}
