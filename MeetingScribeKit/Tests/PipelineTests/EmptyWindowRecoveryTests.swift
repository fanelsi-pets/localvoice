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
      audio: audio, turns: [Turn(start: 11, end: 18, speakerID: 1)],
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
        RecoveredWindow(start: 10, end: 20, language: nil, attempts: 2, segments: 0)
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
