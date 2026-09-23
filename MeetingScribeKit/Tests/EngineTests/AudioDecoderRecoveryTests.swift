import Core
import Foundation
import Testing

@testable import Ingest

/// Пропуск повреждённого участка записи. Политика поиска места, с которого декодер снова читает,
/// проверяется чистой функцией; полный прогон на настоящем битом файле — тест ниже, он включается
/// переменной окружения `MS_DAMAGED_AUDIO` (такие записи в репозиторий не кладём).
@Suite("Декодер: повреждённые участки")
struct AudioDecoderRecoveryTests {
  @Test("Пробы идут по секунде вперёд и не дальше предела пропуска")
  func probesStepForward() {
    let points = AudioDecoder.probeOffsets(after: 100, limit: 600)
    #expect(points.first == 101)
    #expect(points.count == Int(AudioDecoder.maxSkipSeconds))
    #expect(points.last == 100 + AudioDecoder.maxSkipSeconds)
    #expect(points == points.sorted())
  }

  @Test("Пробы не уходят за конец записи")
  func probesStopAtEnd() {
    let points = AudioDecoder.probeOffsets(after: 100, limit: 104)
    #expect(points == [101, 102, 103])
    // У самого конца пробовать нечего.
    #expect(AudioDecoder.probeOffsets(after: 103.8, limit: 104).isEmpty)
  }

  @Test("Без известной длительности предел задаёт только пропуск")
  func probesWithoutDuration() {
    let points = AudioDecoder.probeOffsets(after: 10, limit: 0, step: 5, maxSkip: 20)
    #expect(points == [15, 20, 25, 30])
  }

  @Test("Мусорные значения не дают проб")
  func probesRejectNonsense() {
    #expect(AudioDecoder.probeOffsets(after: -1, limit: 100).isEmpty)
    #expect(AudioDecoder.probeOffsets(after: .nan, limit: 100).isEmpty)
    #expect(AudioDecoder.probeOffsets(after: 10, limit: 100, step: 0).isEmpty)
  }

  /// Настоящая повреждённая запись: `MS_DAMAGED_AUDIO=<путь> swift test --filter Декодер`.
  /// Ожидание — декодируется почти вся запись, а пропуск отражён в `damagedSeconds`.
  @Test(
    "Битый кадр не стоит всей записи",
    .enabled(if: ProcessInfo.processInfo.environment["MS_DAMAGED_AUDIO"] != nil))
  func damagedRecordingIsRecovered() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MS_DAMAGED_AUDIO"])
    let source = URL(fileURLWithPath: path)
    let cache = FileManager.default.temporaryDirectory
      .appendingPathComponent("decode-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cache) }

    let decoded = try await AudioDecoder().decode(source, into: cache, progress: nil)
    let probe = try await AudioDecoder.probe(source)
    #expect(decoded.damagedSeconds > 0)
    // Потеряна доля процента, а не вся встреча.
    #expect(decoded.damagedSeconds < probe.duration * 0.05)
    #expect(abs(decoded.duration - probe.duration) < probe.duration * 0.05)
  }
}
