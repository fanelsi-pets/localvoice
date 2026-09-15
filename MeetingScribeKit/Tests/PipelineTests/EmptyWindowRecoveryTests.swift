import Core
import Foundation
import Testing

@testable import Pipeline

/// Второй проход по пустым окнам (`EmptyWindowRecovery`) на фейковом движке: ни моделей, ни сети.

/// Движок со сценарием ответов: каждый `transcribe` отдаёт следующий заготовленный список сегментов
/// и запоминает параметры вызова.
actor ScriptedAsr: AsrEngine {
  nonisolated let descriptor = EngineDescriptor(name: "scripted")
  private var responses: [[Segment]]
  private(set) var calls: [AsrOptions] = []
  private(set) var sliceDurations: [Double] = []

  init(responses: [[Segment]]) {
    self.responses = responses
  }

  func prepare(progress: ProgressSink?) async throws {}

  func detectLanguage(_ audio: PCMAudio) async throws -> LanguageDetection {
    LanguageDetection(language: .ru, probabilities: [.ru: 1])
  }

  func transcribe(
    _ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?, discovered: SegmentSink?
  ) async throws -> [Segment] {
    calls.append(options)
    sliceDurations.append(audio.duration)
    guard !responses.isEmpty else { return [] }
    let result = responses.removeFirst()
    discovered?(result)
    return result
  }

  func transcribeFile(_ url: URL, options: AsrOptions, progress: ProgressSink?) async throws
    -> [Segment]
  {
    throw EngineError.inferenceFailed("not supported")
  }
}

private func word(_ start: Double, _ end: Double, _ text: String) -> Word {
  Word(start: start, end: end, text: text, probability: 0.9)
}

private func segment(_ start: Double, _ end: Double, _ text: String, words: [Word] = []) -> Segment
{
  Segment(start: start, end: end, text: text, language: .ru, words: words)
}

/// Минута тишины: содержимое не важно, движок фейковый.
private let audio = PCMAudio(samples: [Float](repeating: 0, count: 60 * PCMAudio.sampleRate))

@Suite("Второй проход по пустым окнам")
struct EmptyWindowRecoveryTests {
  @Test("Пустое окно на речи пересчитывается с языком региона, запасом в секунду и без клипов")
  func emptyWindowIsRedecoded() async throws {
    let empty = segment(10, 20, "")
    let engine = ScriptedAsr(responses: [
      [
        segment(
          9.2, 20.8, "хвост соседа середина окна голова",
          words: [
            word(9.2, 9.8, " хвост"), word(9.8, 10.4, " соседа"),  // середина 9.5 и 10.1 → первое вне окна
            word(12, 13, " середина"), word(14, 15, " окна"), word(19.6, 20.8, " голова"),  // 20.2 — вне окна
          ])
      ]
    ])
    let result = try await EmptyWindowRecovery.recover(
      segments: [segment(0, 10, "до"), empty, segment(20, 30, "после")],
      audio: audio, turns: [Turn(start: 11.5, end: 15.5, speakerID: 1)],
      languageAt: { _ in .uk }, wordTimestamps: true, engine: engine)

    let calls = await engine.calls
    #expect(calls.count == 1)
    #expect(calls.first?.language == .uk)
    #expect(calls.first?.clips.isEmpty == true)
    #expect(calls.first.map { abs($0.timeOffset - 9) < 1e-9 } == true)
    #expect(await engine.sliceDurations.first.map { abs($0 - 12) < 1e-6 } == true)

    #expect(result.recovered.count == 1)
    #expect(result.recovered.first?.segments == 1)
    #expect(result.recovered.first?.attempts == 1)
    #expect(result.recovered.first?.language == .uk)
    #expect(result.segments.map(\.text) == ["до", "соседа середина окна", "после"])
    let recovered = result.segments[1]
    #expect(recovered.words.map(\.text) == [" соседа", " середина", " окна"])
    #expect(recovered.start >= 10 && recovered.end <= 20)
    #expect(!result.segments.contains(where: EmptyWindowRecovery.isEmpty))
  }

  @Test("Пустое окно без речи по диаризации и короткое окно не трогаются")
  func windowsWithoutSpeechOrTooShortAreKept() async throws {
    let engine = ScriptedAsr(responses: [[segment(5, 6, "не должно вызываться")]])
    let segments = [
      segment(0, 4, "a"), segment(4, 5.5, ""), segment(10, 20, ""), segment(20, 30, "b"),
    ]
    let result = try await EmptyWindowRecovery.recover(
      segments: segments, audio: audio, turns: [Turn(start: 0, end: 4, speakerID: 1)],
      languageAt: { _ in .ru }, wordTimestamps: true, engine: engine)
    #expect(await engine.calls.isEmpty)
    #expect(result.recovered.isEmpty)
    #expect(result.segments == segments)
  }

  @Test(
    "Повторная пустота: вторая попытка с автоопределением языка, при неудаче окно остаётся как было"
  )
  func secondAttemptWithoutLanguageThenGiveUp() async throws {
    let engine = ScriptedAsr(responses: [[], []])
    let empty = segment(10, 20, "")
    let result = try await EmptyWindowRecovery.recover(
      segments: [empty], audio: audio, turns: nil, languageAt: { _ in .ru },
      wordTimestamps: true, engine: engine)
    let calls = await engine.calls
    #expect(calls.map(\.language) == [.ru, nil])
    #expect(
      result.recovered == [
        RecoveredWindow(
          start: 10, end: 20, language: nil, attempts: 2, segments: 0, reason: "empty")
      ])
    #expect(result.segments == [empty])
  }

  @Test("Без диаризации пустые окна тоже пересчитываются; без языка региона — одна попытка")
  func noDiarizationNoLanguage() async throws {
    let engine = ScriptedAsr(responses: [[segment(10.5, 19.5, "текст")]])
    let result = try await EmptyWindowRecovery.recover(
      segments: [segment(10, 20, "")], audio: audio, turns: nil, languageAt: { _ in nil },
      wordTimestamps: false, engine: engine)
    let calls = await engine.calls
    #expect(calls.count == 1)
    #expect(calls.first?.language == nil)
    #expect(result.segments.map(\.text) == ["текст"])
    #expect(result.recovered.first?.language == nil)
    #expect(result.recovered.first?.segments == 1)
  }

  @Test("Предел числа окон и порядок по времени")
  func limitAndOrdering() async throws {
    let engine = ScriptedAsr(responses: [
      [segment(30.5, 39.5, "второе")], [segment(10.5, 19.5, "первое")],
    ])
    let result = try await EmptyWindowRecovery.recover(
      segments: [segment(30, 40, ""), segment(10, 20, ""), segment(50, 55, "")], audio: audio,
      turns: nil,
      languageAt: { _ in .ru }, wordTimestamps: true, engine: engine,
      options: EmptyWindowRecovery.Options(maximumWindows: 2))
    #expect(await engine.calls.count == 2)
    #expect(result.segments.map(\.text) == ["первое", "второе", ""])
    #expect(result.segments.map(\.start) == [10.5, 30.5, 50])
  }

  @Test("Обрезка результата: сегменты без слов берутся по середине, границы прижимаются к окну")
  func trimmingWithoutWords() {
    let trimmed = EmptyWindowRecovery.trimmed(
      [
        segment(8, 11, "сосед"), segment(11, 21, "внутри"), segment(19.5, 22, "хвост"),
        segment(12, 14, ""),
      ],
      to: 10, end: 20)
    #expect(trimmed.map(\.text) == ["внутри"])
    #expect(trimmed.first?.start == 11)
    #expect(trimmed.first?.end == 20)
  }
}

// MARK: - Стадия 2: речь без текста

private func segmentWithMetrics(
  _ start: Double, _ end: Double, _ text: String, words: [Word], logprob: Double, ratio: Double
) -> Segment {
  Segment(
    start: start, end: end, text: text, language: .ru, words: words, avgLogprob: logprob,
    compressionRatio: ratio)
}

@Suite("Второй проход: реплики диаризации без текста")
struct UncoveredSpeechRecoveryTests {
  @Test("Реплика без текста пересчитывается, уже распознанные слова из результата не дублируются")
  func uncoveredTurnIsRedecoded() async throws {
    // Есть текст на 0–10 и 20–30, реплика спикера 2 на 11–19 без текста.
    let existing = [
      segment(0, 10, "до", words: [word(0, 10, " до")]),
      segment(20, 30, "после", words: [word(20, 30, " после")]),
    ]
    let engine = ScriptedAsr(responses: [
      [
        segment(
          9.5, 20.5, "до найдено после",
          words: [
            word(9.5, 10.2, " до"),  // середина 9.85 внутри уже распознанного 0–10 → дубликат
            word(12, 14, " найдено"), word(20.2, 20.5, " после"),  // 20.35 — внутри 20–30 → дубликат
          ])
      ]
    ])
    let result = try await EmptyWindowRecovery.recover(
      segments: existing, audio: audio,
      turns: [
        Turn(start: 0, end: 10, speakerID: 1), Turn(start: 11, end: 19, speakerID: 2),
        Turn(start: 20, end: 30, speakerID: 1),
      ],
      languageAt: { _ in .ru }, wordTimestamps: true, engine: engine)
    let calls = await engine.calls
    #expect(calls.count == 1)
    #expect(calls.first.map { abs($0.timeOffset - 10) < 1e-9 } == true)
    #expect(result.segments.map(\.text) == ["до", "найдено", "после"])
    #expect(result.recovered.count == 1)
    #expect(result.recovered.first?.reason == EmptyWindowRecovery.reasonUncovered)
    #expect(result.recovered.first?.segments == 1)
  }

  @Test("Покрытая реплика и короткая реплика не пересчитываются")
  func coveredAndShortTurnsAreSkipped() async throws {
    let engine = ScriptedAsr(responses: [[segment(0, 1, "лишнее")]])
    let existing = [segment(0, 10, "текст", words: [word(1, 9, " текст")])]
    let result = try await EmptyWindowRecovery.recover(
      segments: existing, audio: audio,
      turns: [Turn(start: 0, end: 10, speakerID: 1), Turn(start: 12, end: 13.5, speakerID: 2)],
      languageAt: { _ in .ru }, wordTimestamps: true, engine: engine)
    #expect(await engine.calls.isEmpty)
    #expect(result.recovered.isEmpty)
    #expect(result.segments == existing)
  }

  @Test("Соседние реплики одного спикера сливаются в одно окно, чужая реплика — отдельно")
  func adjacentTurnsMerge() async throws {
    let engine = ScriptedAsr(responses: [
      [segment(11, 24, "одно окно", words: [word(11, 24, " одно окно")])],
      [segment(31, 35, "другое", words: [word(31, 35, " другое")])],
    ])
    let result = try await EmptyWindowRecovery.recover(
      segments: [], audio: audio,
      turns: [
        Turn(start: 10, end: 17, speakerID: 1), Turn(start: 18, end: 25, speakerID: 1),
        Turn(start: 30, end: 36, speakerID: 2),
      ],
      languageAt: { _ in .uk }, wordTimestamps: true, engine: engine)
    let calls = await engine.calls
    #expect(calls.count == 2)
    #expect(calls.map { $0.timeOffset } == [9, 29])
    #expect(
      result.recovered.map { ($0.start, $0.end) }.map { "\($0.0)-\($0.1)" } == [
        "10.0-25.0", "30.0-36.0",
      ])
    #expect(result.segments.map(\.text) == ["одно окно", "другое"])
  }

  @Test("Галлюцинация на шуме отбрасывается: низкая вероятность или зацикленный текст")
  func hallucinationGuard() async throws {
    let engine = ScriptedAsr(responses: [
      [
        segmentWithMetrics(
          11, 18, "шум шум шум", words: [word(11, 18, " шум шум шум")], logprob: -1.8, ratio: 1.0)
      ],
      [
        segmentWithMetrics(
          11, 18, "ла ла ла ла", words: [word(11, 18, " ла ла ла ла")], logprob: -0.3, ratio: 3.1)
      ],
    ])
    let result = try await EmptyWindowRecovery.recover(
      segments: [], audio: audio, turns: [Turn(start: 10, end: 19, speakerID: 1)],
      languageAt: { _ in .ru }, wordTimestamps: true, engine: engine)
    #expect(await engine.calls.count == 2)
    #expect(result.segments.isEmpty)
    #expect(
      result.recovered == [
        RecoveredWindow(
          start: 10, end: 19, language: nil, attempts: 2, segments: 0, reason: "uncovered")
      ])
  }

  @Test(
    "Пустые окна и пропуски речи считаются в одном лимите; стадия 2 учитывает найденное стадией 1")
  func stagesShareTheLimit() async throws {
    let engine = ScriptedAsr(responses: [
      [segment(10.5, 19.5, "найдено", words: [word(10.5, 19.5, " найдено")])]
    ])
    let result = try await EmptyWindowRecovery.recover(
      segments: [segment(10, 20, "")], audio: audio,
      turns: [Turn(start: 10, end: 20, speakerID: 1)],
      languageAt: { _ in .ru }, wordTimestamps: true, engine: engine)
    // Пустое окно восстановлено стадией 1; та же реплика уже покрыта — стадия 2 её не трогает.
    #expect(await engine.calls.count == 1)
    #expect(result.recovered.map(\.reason) == [EmptyWindowRecovery.reasonEmpty])
    #expect(result.segments.map(\.text) == ["найдено"])
  }
}

@Suite("Клипы дорожек для распознавания")
struct TrackClipTests {
  @Test(
    "Паузы до 2,5 с сливаются, короткий клип растягивается до 4 с, далёкие отрезки остаются отдельными"
  )
  func clipsMergeAndExpand() {
    let options = SpeechActivityDetector.Options()
    #expect(options.clipMergeGapSeconds == 2.5)
    #expect(options.clipMinimumSeconds == 4)
    let turns = [
      Turn(start: 10, end: 11, speakerID: 1), Turn(start: 13, end: 14, speakerID: 1),  // пауза 2 с → один клип
      Turn(start: 40, end: 40.8, speakerID: 1),  // короткий → растянется до 4 с
      Turn(start: 60, end: 70, speakerID: 1),
    ]
    let clips = SpeechActivityDetector.clipRanges(
      from: turns, duration: 100, mergeGap: options.clipMergeGapSeconds,
      minimumSeconds: options.clipMinimumSeconds)
    #expect(clips.count == 3)
    #expect(clips[0].lowerBound <= 10 && clips[0].upperBound >= 14)
    #expect(clips[1].upperBound - clips[1].lowerBound >= 4 - 1e-9)
    #expect(clips[2] == 60...70)
    // Старые умолчания дали бы 1-секундные клипы: два отрезка не сливаются при gap 1.
    let legacy = SpeechActivityDetector.clipRanges(
      from: turns, duration: 100, mergeGap: 1.0, minimumSeconds: 1.2)
    #expect(legacy.count == 4)
  }
}
