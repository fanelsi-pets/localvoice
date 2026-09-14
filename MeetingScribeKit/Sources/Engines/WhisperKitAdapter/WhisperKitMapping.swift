import Core
import Foundation
import WhisperKit

/// Перевод результатов WhisperKit в модели Core и обратно.
/// Только чистые функции: тесты проверяют их без загрузки моделей и без сети.
enum WhisperKitMapping {
  /// Длительность фрагмента, по которому Whisper определяет язык (окно модели).
  static let languageDetectionSeconds: Double = 30

  // MARK: - Текст

  /// Убирает спецтокены вида `<|ru|>`, `<|0.00|>`, `<|endoftext|>`.
  ///
  /// При `skipSpecialTokens: true` их в `segment.text` быть не должно: `SegmentSeeker` декодирует только
  /// токены `< specialTokenBegin` (Text/SegmentSeeker.swift, строки 119–121 и 163–165 в argmax-oss-swift 1.1.0).
  /// Подстраховка стоит дёшево и защищает экспорт от мусора, если умолчания движка изменятся.
  static func cleanText(_ text: String) -> String {
    guard text.contains("<|") else {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var result = ""
    var rest = Substring(text)
    while let open = rest.range(of: "<|") {
      result.append(contentsOf: rest[..<open.lowerBound])
      guard let close = rest[open.upperBound...].range(of: "|>") else {
        rest = rest[rest.endIndex...]
        break
      }
      rest = rest[close.upperBound...]
    }
    result.append(contentsOf: rest)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Сегменты и слова

  /// Слово с абсолютным таймкодом. Текст не трогаем: у Whisper слово несёт ведущий пробел, по нему `Fuser` склеивает реплику.
  static func word(_ timing: WordTiming, offset: Double = 0) -> Word {
    Word(
      start: Double(timing.start) + offset,
      end: Double(timing.end) + offset,
      text: timing.word,
      probability: Double(timing.probability)
    )
  }

  /// Сегмент декодирования с абсолютными таймкодами. Пустые сегменты не выбрасываем: фильтр галлюцинаций — фаза 1.
  static func segment(
    _ segment: TranscriptionSegment, offset: Double = 0, language: Language? = nil
  )
    -> Segment
  {
    Segment(
      start: Double(segment.start) + offset,
      end: Double(segment.end) + offset,
      text: cleanText(segment.text),
      language: language,
      words: (segment.words ?? []).map { word($0, offset: offset) },
      noSpeechProb: Double(segment.noSpeechProb),
      avgLogprob: Double(segment.avgLogprob),
      compressionRatio: Double(segment.compressionRatio)
    )
  }

  /// Собирает сегменты всех окон в один список, отсортированный по времени начала.
  /// Порядок равных начал сохраняется (сортировка по паре «начало, исходный индекс»).
  static func segments(_ results: [TranscriptionResult], offset: Double = 0) -> [Segment] {
    var mapped: [Segment] = []
    mapped.reserveCapacity(results.reduce(0) { $0 + $1.segments.count })
    for result in results {
      let language = Language(code: result.language)
      for item in result.segments {
        mapped.append(segment(item, offset: offset, language: language))
      }
    }
    return sorted(mapped)
  }

  /// Сегменты одного колбэка обнаружения (уже с абсолютными смещениями чанка) с языком вызова.
  static func segments(
    _ segments: [TranscriptionSegment], offset: Double = 0, language: Language?
  ) -> [Segment] {
    sorted(segments.map { segment($0, offset: offset, language: language) })
  }

  private static func sorted(_ segments: [Segment]) -> [Segment] {
    segments
      .enumerated()
      .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
      .map(\.element)
  }

  // MARK: - Клипы

  /// Секунды → индекс сэмпла ровно так, как это делает WhisperKit 1.1.0 (`DecodingOptions.prepareSeekClips`,
  /// Utilities/Extensions+Internal.swift:113): `Int(round(seconds * Float(WhisperKit.sampleRate)))`.
  /// Арифметика Float32 повторена один в один: от неё зависит, попадёт ли граница клипа в буфер.
  /// Функция тотальна: NaN → 0, ±inf и значения вне `Int` → `Int.max`/`Int.min`, трапа `Int(Float)` нет.
  static func whisperKitSampleIndex(_ seconds: Float) -> Int {
    let scaled = seconds * Float(WhisperKit.sampleRate)
    if scaled.isNaN { return 0 }
    if scaled >= 9.0e18 { return .max }
    if scaled <= -9.0e18 { return .min }
    return Int(scaled.rounded())
  }

  /// Граница клипа в секундах Float32, безопасная для буфера из `sampleCount` сэмплов.
  ///
  /// WhisperKit не ограничивает `seekClipEnd` длиной буфера (`prepareSeekClips`) и режет
  /// `audioArray[start..<end]` в `VADAudioChunker.chunkAll` — граница за буфером убивает процесс.
  /// `Float(секунды)` при длине от 2^24 сэмплов (≈17,5 мин) округляется на несколько сэмплов в любую сторону:
  /// крэш LocalVoice 4.1.0 (2026-09-14) — буфер 75 450 341 сэмпл, конец клипа 75 450 344.
  /// Значение прижимается к `[0, длительность]` и опускается по `nextDown`, пока WhisperKit не даст индекс
  /// в пределах буфера (теряется не больше одной единицы Float32, ≤ 16 сэмплов при длине до 4,6 ч).
  static func clampedClipBoundary(_ seconds: Double, sampleCount: Int) -> Float {
    guard seconds.isFinite, sampleCount > 0 else { return 0 }
    let limit = PCMAudio.seconds(forSampleIndex: sampleCount)
    var value = Float(min(max(seconds, 0), limit))
    guard value.isFinite else { return 0 }
    while value > 0, whisperKitSampleIndex(value) > sampleCount {
      value = value.nextDown
    }
    return max(value, 0)
  }

  /// Клипы `AsrOptions.clips` в `clipTimestamps` WhisperKit: пары секунд «начало, конец» по порядку, обе границы
  /// приведены к буферу (`clampedClipBoundary`). Клипы с нечисловыми границами, целиком вне буфера или пустые
  /// после приведения выбрасываются. Если выброшены все, результат пуст — вызывающий не должен превращать
  /// это в «весь файл» (пустой список у WhisperKit означает именно это), см. `WhisperKitEngine.transcribe`.
  /// Проверено (WhisperKit 1.1.0): `VADAudioChunker.chunkAll` строит чанки внутри `prepareSeekClips`,
  /// смещения чанков применяются к сегментам и словам; клип короче `windowPadding` = 1 с пропускается.
  static func clipTimestamps(_ clips: [ClosedRange<Double>], sampleCount: Int) -> [Float] {
    guard sampleCount > 0 else { return [] }
    var result: [Float] = []
    let ordered =
      clips
      .filter { $0.lowerBound.isFinite && $0.upperBound.isFinite }
      .sorted { $0.lowerBound < $1.lowerBound }
    for clip in ordered {
      let start = clampedClipBoundary(clip.lowerBound, sampleCount: sampleCount)
      let end = clampedClipBoundary(clip.upperBound, sampleCount: sampleCount)
      let startIndex = whisperKitSampleIndex(start)
      let endIndex = whisperKitSampleIndex(end)
      guard startIndex < sampleCount, endIndex > startIndex else { continue }
      result.append(contentsOf: [start, end])
    }
    return result
  }

  // MARK: - Язык

  /// Результат `detectLangauge` (опечатка в API WhisperKit) в модель Core.
  ///
  /// `langProbs` из `TextDecoder.detectLanguage` — это log-вероятности (TextDecoder.swift:519), поэтому
  /// значения ≤ 0 переводятся через `exp`; значения в (0, 1] считаются уже вероятностями.
  static func languageDetection(language: String, probabilities: [String: Float])
    -> LanguageDetection
  {
    var mapped: [Language: Double] = [:]
    for (code, value) in probabilities {
      let key = Language(code: code)
      let probability = value <= 0 ? exp(Double(value)) : min(Double(value), 1)
      mapped[key] = max(mapped[key] ?? 0, probability)
    }
    return LanguageDetection(language: Language(code: language), probabilities: mapped)
  }

  /// Параметры декодирования (SPEC.md §3.2). Язык всегда задан явно: умолчание WhisperKit `nil` даёт английский.
  ///
  /// `clipTimestamps` — уже приведённые к буферу пары секунд из `clipTimestamps(_:sampleCount:)`;
  /// пустой список означает «весь файл».
  static func decodingOptions(
    language: Language, wordTimestamps: Bool, clipTimestamps: [Float] = []
  ) -> DecodingOptions {
    DecodingOptions(
      task: .transcribe,
      language: language.code,
      usePrefillPrompt: true,
      detectLanguage: false,
      skipSpecialTokens: true,
      withoutTimestamps: false,
      wordTimestamps: wordTimestamps,
      clipTimestamps: clipTimestamps,
      chunkingStrategy: .vad
    )
  }
}
