import Core
import Foundation
import Testing
import WhisperKit

@testable import WhisperKitAdapter

/// Границы клипов и чанкер WhisperKit.
///
/// Крэш LocalVoice 4.1.0 (2026-09-14): `VADAudioChunker.chunkAll` упал на `audioArray[start..<end]`, потому что
/// конец последнего языкового клипа, переведённый в Float32, округлился на 3 сэмпла дальше конца буфера
/// (75 450 341 сэмпл → 75 450 344). WhisperKit не ограничивает `seekClipEnd` длиной буфера, поэтому границы
/// приводит адаптер. Ни один тест не грузит модели: чанкер работает на тишине.

/// Длины буферов (сэмплов 16 kHz), на которых наивный перевод `Float(секунды)` выходит за буфер.
private let overshootingSampleCounts = [75_450_341, 17_294_955, 18_254_955, 19_214_955]

/// Сколько сэмплов допустимо потерять на конце клипа при приведении (одна единица Float32 при длине до 4,6 ч).
private let tolerance = 16

@Suite("WhisperKit: границы клипов и буфер")
struct WhisperKitClipClampTests {
  @Test(
    "Предпосылка: Float32-конец клипа, равный длительности буфера, выходит за буфер",
    arguments: overshootingSampleCounts)
  func naiveConversionOvershoots(sampleCount: Int) {
    let naive = WhisperKitMapping.whisperKitSampleIndex(
      Float(PCMAudio.seconds(forSampleIndex: sampleCount)))
    #expect(naive > sampleCount)
  }

  @Test(
    "Приведённая граница не выходит за буфер и теряет не больше одной единицы Float32",
    arguments: overshootingSampleCounts)
  func clampedBoundaryStaysInsideBuffer(sampleCount: Int) {
    let end = WhisperKitMapping.clampedClipBoundary(
      PCMAudio.seconds(forSampleIndex: sampleCount), sampleCount: sampleCount)
    let index = WhisperKitMapping.whisperKitSampleIndex(end)
    #expect(index <= sampleCount)
    #expect(index >= sampleCount - tolerance)
  }

  @Test("Перебор длительностей до 3 ч с дробными хвостами: конец клипа никогда не выходит за буфер")
  func sweepOfDurations() {
    var checked = 0
    var overshoots = 0
    for minutes in 0...180 {
      for extra in stride(from: 0, to: PCMAudio.sampleRate, by: 997) {
        let sampleCount = minutes * 60 * PCMAudio.sampleRate + extra + PCMAudio.sampleRate
        let duration = PCMAudio.seconds(forSampleIndex: sampleCount)
        let clips = WhisperKitMapping.clipTimestamps([0...duration], sampleCount: sampleCount)
        guard clips.count == 2 else {
          Issue.record("клип [0, \(duration)] потерян при \(sampleCount) сэмплах")
          return
        }
        let end = WhisperKitMapping.whisperKitSampleIndex(clips[1])
        if end > sampleCount {
          overshoots += 1
        }
        if end < sampleCount - tolerance {
          Issue.record("конец клипа \(end) слишком далеко от буфера \(sampleCount)")
          return
        }
        checked += 1
      }
    }
    #expect(overshoots == 0)
    #expect(checked > 2_900)
  }

  @Test("Клипы внутри буфера не меняются, вне буфера выбрасываются, границы прижимаются")
  func interiorAndInvalidClips() {
    let sampleCount = 100 * PCMAudio.sampleRate
    #expect(
      WhisperKitMapping.clipTimestamps([1.5...3, 10...20.25], sampleCount: sampleCount)
        == [1.5, 3, 10, 20.25])
    #expect(
      WhisperKitMapping.clipTimestamps([100...105, 200...210], sampleCount: sampleCount).isEmpty)
    #expect(WhisperKitMapping.clipTimestamps([95...105], sampleCount: sampleCount) == [95, 100])
    #expect(WhisperKitMapping.clipTimestamps([(-5)...5], sampleCount: sampleCount) == [0, 5])
    #expect(WhisperKitMapping.clipTimestamps([0...10], sampleCount: 0).isEmpty)
    #expect(WhisperKitMapping.clipTimestamps([0...(.infinity)], sampleCount: sampleCount).isEmpty)
  }

  @Test("Перевод секунд в сэмплы тотален: NaN, бесконечности и огромные значения не роняют процесс")
  func sampleIndexIsTotal() {
    #expect(WhisperKitMapping.whisperKitSampleIndex(.nan) == 0)
    #expect(WhisperKitMapping.whisperKitSampleIndex(.infinity) == .max)
    #expect(WhisperKitMapping.whisperKitSampleIndex(-.infinity) == .min)
    #expect(WhisperKitMapping.whisperKitSampleIndex(.greatestFiniteMagnitude) == .max)
    #expect(WhisperKitMapping.whisperKitSampleIndex(1.5) == 24_000)
    #expect(WhisperKitMapping.clampedClipBoundary(.infinity, sampleCount: 16_000) == 0)
    #expect(WhisperKitMapping.clampedClipBoundary(.nan, sampleCount: 16_000) == 0)
    #expect(WhisperKitMapping.clampedClipBoundary(-1, sampleCount: 16_000) == 0)
    #expect(WhisperKitMapping.clampedClipBoundary(3, sampleCount: 16_000) == 1)
  }

  @Test(
    "Реальный чанкер WhisperKit принимает приведённые клипы на проблемных длинах буфера",
    arguments: [17_294_955, 75_450_341])
  func realChunkerAcceptsClampedClips(sampleCount: Int) async throws {
    let duration = PCMAudio.seconds(forSampleIndex: sampleCount)
    // Два языковых региона, последний кончается ровно на длительности файла — как у упавшей встречи.
    let regions: [ClosedRange<Double>] = [0...(duration / 2), (duration / 2)...duration]
    let clips = WhisperKitMapping.clipTimestamps(regions, sampleCount: sampleCount)
    #expect(clips.count == 4)
    let options = WhisperKitMapping.decodingOptions(
      language: .ru, wordTimestamps: true, clipTimestamps: clips)
    let silence = [Float](repeating: 0, count: sampleCount)
    let chunks = try await VADAudioChunker().chunkAll(
      audioArray: silence, maxChunkLength: 30 * WhisperKit.sampleRate, decodeOptions: options)
    #expect(!chunks.isEmpty)
    for chunk in chunks {
      #expect(chunk.seekOffsetIndex >= 0)
      #expect(chunk.seekOffsetIndex + chunk.audioSamples.count <= sampleCount)
    }
    let covered = chunks.map { $0.seekOffsetIndex + $0.audioSamples.count }.max() ?? 0
    // Хвост короче секунды (`windowPadding`) WhisperKit не режет — это его штатное поведение.
    #expect(covered >= sampleCount - WhisperKit.sampleRate - tolerance)
  }
}
