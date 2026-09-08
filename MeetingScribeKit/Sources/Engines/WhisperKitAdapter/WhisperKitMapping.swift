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

  /// Клипы `AsrOptions.clips` в `clipTimestamps` WhisperKit: пары секунд «начало, конец».
  /// Проверено (WhisperKit 1.1.0): `VADAudioChunker.chunkAll` строит чанки внутри `prepareSeekClips`,
  /// смещения чанков применяются к сегментам и словам; клип короче `windowPadding` = 1 с пропускается.
  static func clipTimestamps(_ clips: [ClosedRange<Double>]) -> [Float] {
    clips
      .filter { $0.upperBound > $0.lowerBound }
      .sorted { $0.lowerBound < $1.lowerBound }
      .flatMap { [Float($0.lowerBound), Float($0.upperBound)] }
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
  static func decodingOptions(
    language: Language, wordTimestamps: Bool, clips: [ClosedRange<Double>] = []
  ) -> DecodingOptions {
    DecodingOptions(
      task: .transcribe,
      language: language.code,
      usePrefillPrompt: true,
      detectLanguage: false,
      skipSpecialTokens: true,
      withoutTimestamps: false,
      wordTimestamps: wordTimestamps,
      clipTimestamps: clipTimestamps(clips),
      chunkingStrategy: .vad
    )
  }
}
