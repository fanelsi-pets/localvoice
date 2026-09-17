import AVFoundation
import Core
import Engines
import Foundation
import Testing

@testable import RemoteAdapter

/// План кусков и разбор ответа облачного движка (`RemoteAsrEngine`). Сети здесь нет: проверяются чистые
/// функции — как встреча режется на запросы (у Gemini 3.5 Transcribe со словными таймкодами предел 30 минут
/// на запрос) и как слова превращаются в сегменты с абсолютными таймкодами.
@Suite("Облачное распознавание: план кусков и сегменты")
struct RemoteEngineTests {
  /// Аудио с речью (шум) и тишиной: `speech` — интервалы, где есть сигнал.
  private func audio(duration: Double, speech: [ClosedRange<Double>]) -> PCMAudio {
    var samples = [Float](repeating: 0, count: PCMAudio.sampleIndex(forSeconds: duration))
    for range in speech {
      let lower = PCMAudio.sampleIndex(forSeconds: range.lowerBound)
      let upper = min(samples.count, PCMAudio.sampleIndex(forSeconds: range.upperBound))
      guard upper > lower else { continue }
      for index in lower..<upper {
        samples[index] = index.isMultiple(of: 2) ? 0.4 : -0.4
      }
    }
    return PCMAudio(samples: samples)
  }

  @Test("Файл целиком режется на равные куски не длиннее предела и покрывает запись без дыр")
  func wholeFileIsSplitEvenly() {
    let chunks = RemoteChunkPlanner.plan(ranges: [0...7200], limit: 900, silenceLimit: 60)
    #expect(chunks.count == 8)
    #expect(chunks.allSatisfy { $0.duration <= 900.001 })
    #expect(chunks.first?.start == 0)
    #expect(chunks.last?.end == 7200)
    for (previous, next) in zip(chunks, chunks.dropFirst()) {
      #expect(abs(next.start - previous.end) < 0.001)
    }
  }

  @Test("Короткие паузы между клипами склеиваются, длинная пауза разделяет куски")
  func clipsArePacked() {
    let clips: [ClosedRange<Double>] = [0...10, 15...25, 30...40, 600...610]
    let chunks = RemoteChunkPlanner.plan(ranges: clips, limit: 900, silenceLimit: 60)
    #expect(chunks.count == 2)
    #expect(chunks[0].start == 0)
    #expect(chunks[0].end == 40)
    #expect(chunks[1].start == 600)
    #expect(chunks[1].end == 610)
  }

  @Test("Граница между кусками съезжает в тишину, чтобы не разрезать слово")
  func boundaryMovesToSilence() {
    // Речь идёт до 108 с и снова с 112 с: номинальная граница на 100 с должна уехать в паузу.
    let recording = audio(duration: 200, speech: [0...108, 112...200])
    let planned = RemoteChunkPlanner.plan(ranges: [0...200], limit: 100, silenceLimit: 60)
    #expect(planned.count == 2)
    let refined = RemoteChunkPlanner.refine(planned, audio: recording, search: 20, window: 0.5)
    #expect(refined.count == 2)
    let boundary = refined[0].end
    #expect(boundary > 108)
    #expect(boundary < 112)
    #expect(refined[1].start == boundary)
    #expect(refined[0].start == 0)
    #expect(refined[1].end == 200)
  }

  @Test("Границы между разными отрезками остаются на месте")
  func separatedChunksKeepBoundaries() {
    let recording = audio(duration: 700, speech: [0...40, 600...610])
    let planned = RemoteChunkPlanner.plan(
      ranges: [0...40, 600...610], limit: 900, silenceLimit: 60)
    let refined = RemoteChunkPlanner.refine(planned, audio: recording, search: 20, window: 0.5)
    #expect(refined == planned)
  }

  @Test("Слова куска становятся сегментами с абсолютными таймкодами, пауза режет сегмент")
  func wordsBecomeSegments() {
    let words = [
      RemoteWord(text: "Коллеги,", start: 0.2, end: 0.8),
      RemoteWord(text: "начнём", start: 0.9, end: 1.4),
      // Пауза 2 с — следующий сегмент.
      RemoteWord(text: "Добре", start: 3.4, end: 3.9),
    ]
    let segments = RemoteAsrEngine.segments(from: words, offset: 900, language: nil)
    #expect(segments.count == 2)
    #expect(segments[0].text == "Коллеги, начнём")
    #expect(abs(segments[0].start - 900.2) < 0.001)
    #expect(abs(segments[0].end - 901.4) < 0.001)
    #expect(segments[0].words.count == 2)
    #expect(segments[1].text == "Добре")
    #expect(abs(segments[1].start - 903.4) < 0.001)
  }

  @Test("Пустые слова отбрасываются, порядок восстанавливается по времени")
  func wordsAreCleaned() {
    let words = [
      RemoteWord(text: "второе", start: 2, end: 2.5),
      RemoteWord(text: "   ", start: 0.5, end: 0.6),
      RemoteWord(text: "первое", start: 1.4, end: 1.9),
    ]
    let segments = RemoteAsrEngine.segments(from: words, offset: 0, language: .ru)
    #expect(segments.count == 1)
    #expect(segments[0].text == "первое второе")
    #expect(segments[0].language == .ru)
  }

  @Test("Кусок пишется в FLAC 16 kHz моно, длительность сохраняется")
  func clipIsWritten() throws {
    let recording = audio(duration: 3, speech: [0.5...2.5])
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let written = try RemoteAudioClip.write(recording, into: directory, name: "clip-0")
    #expect(written.mimeType == "audio/flac")
    #expect(written.url.pathExtension == "flac")

    let file = try AVAudioFile(forReading: written.url)
    #expect(file.fileFormat.sampleRate == Double(PCMAudio.sampleRate))
    #expect(file.fileFormat.channelCount == 1)
    #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 3) < 0.05)
    let size = try FileManager.default.attributesOfItem(atPath: written.url.path)[.size] as? Int
    #expect((size ?? 0) > 0)
  }
}

private struct FakeRemote: RemoteTranscribing {
  let title = "Fake"
  let model = "fake"
  let maximumClipSeconds: Double = 600
  func availability() async -> RemoteTranscriberAvailability { .available }
  func transcribe(clip url: URL, mimeType: String, duration: Double, language: Language?)
    async throws
    -> [RemoteWord]
  { [] }
}

@Suite("Облачные движки по провайдерам хоста")
struct CloudEngineWiringTests {
  @Test("Облачный движок создаётся только с провайдером хоста для этого движка")
  func cloudEnginesNeedTheirProvider() throws {
    let store = ModelStore(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(
        "cloud-wiring-\(UUID().uuidString)"))
    let azure = try EngineFactory.makeAsr(
      .azure, modelStore: store, remotes: [.azure: FakeRemote()])
    #expect(azure is RemoteAsrEngine)
    #expect(azure.descriptor.name == "Fake")
    #expect(throws: (any Error).self) {
      try EngineFactory.makeAsr(.gemini, modelStore: store, remotes: [.azure: FakeRemote()])
    }
  }

  @Test("Облачные идентификаторы помечены как облако, локальные — нет, качать им нечего")
  func cloudFlags() {
    #expect(AsrEngineID.azure.isCloud && AsrEngineID.gemini.isCloud)
    #expect(!AsrEngineID.whisperkit.isCloud && !AsrEngineID.parakeet.isCloud)
    #expect(EngineFactory.requiredModels(asr: .azure, whisperModel: nil, diarizer: nil).isEmpty)
    #expect(EngineSelection(asr: .azure, diarizer: .speakerkit).title.hasPrefix("MAI-Transcribe-2"))
  }
}
