import Core
import Foundation

/// План кусков для облачного распознавания: у провайдера есть предел длительности одного запроса
/// (Gemini 3.5 Transcribe со словными таймкодами — 30 минут), поэтому встреча уезжает кусками.
///
/// Правила: клипы, между которыми меньше `silenceLimit` тишины, склеиваются в один отрезок (иначе на
/// раздельных дорожках Zoom получились бы сотни крошечных запросов); длинный отрезок режется на равные
/// куски не длиннее `limit`; внутренние границы сдвигаются к самому тихому месту поблизости, чтобы слово
/// не разрывалось пополам.
enum RemoteChunkPlanner {
  struct Chunk: Hashable, Sendable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
  }

  static func plan(
    ranges: [ClosedRange<Double>], limit: Double, silenceLimit: Double
  ) -> [Chunk] {
    let sorted =
      ranges
      .filter { $0.upperBound > $0.lowerBound }
      .sorted { $0.lowerBound < $1.lowerBound }
    guard !sorted.isEmpty, limit > 0 else { return [] }

    var spans: [Chunk] = []
    for range in sorted {
      if let last = spans.last, range.lowerBound - last.end < silenceLimit {
        spans[spans.count - 1].end = max(last.end, range.upperBound)
      } else {
        spans.append(Chunk(start: range.lowerBound, end: range.upperBound))
      }
    }

    var chunks: [Chunk] = []
    for span in spans {
      let pieces = max(1, Int((span.duration / limit).rounded(.up)))
      let step = span.duration / Double(pieces)
      for piece in 0..<pieces {
        let start = span.start + Double(piece) * step
        let end = piece == pieces - 1 ? span.end : span.start + Double(piece + 1) * step
        chunks.append(Chunk(start: start, end: end))
      }
    }
    return chunks
  }

  /// Сдвигает границы между соседними кусками одного отрезка к самому тихому окну в пределах `search`.
  /// Границы между разными отрезками (там была длинная пауза) остаются на месте.
  static func refine(
    _ chunks: [Chunk], audio: PCMAudio, search: Double, window: Double
  ) -> [Chunk] {
    guard chunks.count > 1 else { return chunks }
    var result = chunks
    for index in 0..<(result.count - 1) {
      let boundary = result[index].end
      guard abs(result[index + 1].start - boundary) < 0.001 else { continue }
      // Кусок не должен ужаться меньше половины и не должен вырасти за пределы поиска.
      let lower = max(boundary - search, result[index].start + result[index].duration / 2)
      let upper = min(boundary + search, result[index + 1].end - result[index + 1].duration / 2)
      guard upper > lower else { continue }
      let quiet = quietPoint(in: audio, from: lower, to: upper, window: window) ?? boundary
      result[index].end = quiet
      result[index + 1].start = quiet
    }
    return result
  }

  /// Середина самого тихого окна `window` секунд в интервале `[from, to]` по среднему квадрату амплитуды.
  static func quietPoint(in audio: PCMAudio, from: Double, to: Double, window: Double) -> Double? {
    let samples = audio.samples
    let windowSamples = max(1, PCMAudio.sampleIndex(forSeconds: window))
    let lower = max(0, PCMAudio.sampleIndex(forSeconds: from))
    let upper = min(samples.count, PCMAudio.sampleIndex(forSeconds: to))
    guard upper - lower > windowSamples else { return nil }

    let step = max(1, windowSamples / 2)
    var best = (energy: Double.infinity, index: lower)
    var index = lower
    while index + windowSamples <= upper {
      var energy = 0.0
      var sample = index
      // Каждый четвёртый отсчёт: на 16 kHz этого достаточно, чтобы отличить тишину от речи, и вчетверо дешевле.
      while sample < index + windowSamples {
        let value = Double(samples[sample])
        energy += value * value
        sample += 4
      }
      if energy < best.energy { best = (energy, index) }
      index += step
    }
    guard best.energy.isFinite else { return nil }
    return PCMAudio.seconds(forSampleIndex: best.index + windowSamples / 2)
  }
}
