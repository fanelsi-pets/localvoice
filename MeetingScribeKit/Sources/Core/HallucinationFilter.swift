import Foundation

/// Фильтр галлюцинаций Whisper на паузах (SPEC.md §3.2, ADR-002/003). Правила — по тексту и по эффективной
/// длительности: `noSpeechProb`/`avgLogprob`/`compressionRatio` у WhisperKit оконные (одинаковы у всех сегментов
/// 30-секундного окна), а `noSpeechProb` в WhisperKit 1.1.0 вообще всегда 0 (`TextDecoder.swift:817`,
/// «TODO: implement no speech prob») — правило `noSpeech` здесь работает только с движками, которые её считают.
public enum HallucinationFilter {
  public struct Options: Hashable, Sendable {
    /// Отрезок короче с тремя и более словами — мусор (короткие «Да.», «Ну, да.» остаются).
    public var minimumDuration: Double
    /// Букв и цифр в секунду; быстрее — невозможная речь («Продолжение следует…» за 0.02 с).
    public var maxCharactersPerSecond: Double
    /// Собственный zlib-коэффициент сжатия текста сегмента, выше — зацикливание. Кириллица в UTF-8 сжимается
    /// лучше латиницы: плотные реплики 1:25:38 доходят до 2.4, петли — 18–29, поэтому порог 3.0.
    public var compressionRatioThreshold: Double
    /// Столько одинаковых сегментов подряд допустимо; следующие отбрасываются.
    public var maxConsecutiveRepeats: Int
    /// `noSpeechProb` выше — отбрасывать, но только сегменты не длиннее двух слов.
    public var hardNoSpeechThreshold: Double
    /// Синтетические титры Whisper (сравниваются после нормализации, допускается небольшое обрамление).
    public var knownPhrases: [String]
    /// Бытовые фразы из титров («Спасибо за просмотр»): отбрасываются только при точном совпадении —
    /// «Спасибо за просмотр презентации» на встрече говорят всерьёз.
    public var exactPhrases: [String]
    /// Дальше этого расстояния от любого turn'а сегмент помечается «нет речи по диаризации» (не удаляется).
    public var speechEvidenceDistance: Double

    public init(
      minimumDuration: Double = 0.3,
      maxCharactersPerSecond: Double = 80,
      compressionRatioThreshold: Double = 3.0,
      maxConsecutiveRepeats: Int = 2,
      hardNoSpeechThreshold: Double = 0.9,
      knownPhrases: [String] = Options.defaultKnownPhrases,
      exactPhrases: [String] = Options.defaultExactPhrases,
      speechEvidenceDistance: Double = 1.0
    ) {
      self.minimumDuration = minimumDuration
      self.maxCharactersPerSecond = maxCharactersPerSecond
      self.compressionRatioThreshold = compressionRatioThreshold
      self.maxConsecutiveRepeats = maxConsecutiveRepeats
      self.hardNoSpeechThreshold = hardNoSpeechThreshold
      self.knownPhrases = knownPhrases
      self.exactPhrases = exactPhrases
      self.speechEvidenceDistance = speechEvidenceDistance
    }

    /// Титры из обучающих субтитров, которые Whisper выдаёт на тишине (ru/uk/en) и которые в живой речи не встречаются.
    public static let defaultKnownPhrases: [String] = [
      "Продолжение следует",
      "Субтитры сделал DimaTorzok",
      "Субтитры делал DimaTorzok",
      "Субтитры создавал DimaTorzok",
      "Редактор субтитров А.Семкин",
      "Корректор А.Егорова",
      "Субтитры подготовлены",
      "Субтитри створені спільнотою Amara.org",
      "Subtitles by the Amara.org community",
    ]

    /// Прощания из титров, которые могут прозвучать и на встрече, — только точное совпадение.
    public static let defaultExactPhrases: [String] = [
      "Спасибо за просмотр",
      "Подписывайтесь на канал",
      "Дякую за перегляд",
      "Підписуйтесь на канал",
      "Thanks for watching",
      "Thank you for watching",
      "Please subscribe",
    ]
  }

  public struct Report: Hashable, Sendable {
    public var kept: [Segment]
    public var dropped: [DroppedSegment]
    /// Сегменты без речи по диаризации — только пометка (SPEC.md §3.3: без потери реплик).
    public var noSpeechEvidence: [Segment]

    public init(kept: [Segment], dropped: [DroppedSegment] = [], noSpeechEvidence: [Segment] = []) {
      self.kept = kept
      self.dropped = dropped
      self.noSpeechEvidence = noSpeechEvidence
    }
  }

  /// Сколько раз подряд одна n-грамма слов должна повториться, чтобы считаться зацикливанием.
  static let loopRepeats = 4
  /// Максимальная длина повторяющейся n-граммы слов.
  static let loopMaxOrder = 3
  /// Короче этого zlib не сжимает вовсе (заголовок больше выигрыша) — коэффициент считаем равным 1.
  static let minimumCompressedBytes = 40

  /// Порядок правил: пустой текст → фраза-титр → зацикливание → невозможная скорость / слишком короткий →
  /// noSpeech → повторы (считаются по уже оставленным сегментам). `turns` — только для пометки «нет речи».
  public static func filter(
    _ segments: [Segment], turns: [Turn]? = nil, options: Options = Options()
  ) -> Report {
    let ordered = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    let phrases = options.knownPhrases.map(normalize).filter { !$0.isEmpty }
    let exact = Set(options.exactPhrases.map(normalize).filter { !$0.isEmpty })
    let speechTurns = turns ?? []
    var kept: [Segment] = []
    var dropped: [DroppedSegment] = []
    var noSpeechEvidence: [Segment] = []
    /// Нормализованный текст последнего оставленного сегмента и число таких подряд.
    var previousKept: String?
    var repeats = 0

    for segment in ordered {
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalized = normalize(segment.text)
      if let reason = reason(
        for: segment, text: text, normalized: normalized, phrases: phrases, exact: exact,
        options: options)
      {
        dropped.append(DroppedSegment(segment: segment, reason: reason))
        continue
      }
      // Повтор считается по оставленным сегментам: «Ну шо, окей.» дважды — норма, третий подряд — галлюцинация.
      if normalized == previousKept {
        guard repeats + 1 <= options.maxConsecutiveRepeats else {
          dropped.append(DroppedSegment(segment: segment, reason: .repeated))
          continue
        }
        repeats += 1
      } else {
        previousKept = normalized
        repeats = 1
      }
      kept.append(segment)
      // Речи по диаризации нет — реплику не теряем, только помечаем (SPEC.md §3.3).
      if !speechTurns.isEmpty,
        !hasSpeechEvidence(segment, turns: speechTurns, distance: options.speechEvidenceDistance)
      {
        noSpeechEvidence.append(segment)
      }
    }
    return Report(kept: kept, dropped: dropped, noSpeechEvidence: noSpeechEvidence)
  }

  /// Первое сработавшее правило (кроме повторов — они считаются по оставленным сегментам).
  private static func reason(
    for segment: Segment, text: String, normalized: String, phrases: [String],
    exact: Set<String>, options: Options
  ) -> DropReason? {
    if text.isEmpty || normalized.isEmpty { return .empty }
    if exact.contains(normalized)
      || phrases.contains(where: { matchesKnownPhrase(normalized, phrase: $0) })
    {
      return .knownPhrase
    }
    if isLooping(text: text, normalized: normalized, options: options) { return .loop }

    let duration = effectiveDuration(segment)
    // Текст без длительности — тоже невозможная скорость: сегмент возник на пустом месте.
    guard duration > 0 else { return .implausibleRate }
    // Считаются только буквы и цифры: «То есть...» за 0.15 с — быстрая, но живая речь, многоточие не в счёт.
    let characters = text.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
    if Double(characters) / duration > options.maxCharactersPerSecond { return .implausibleRate }

    let words = wordCount(segment)
    // Два слова («Ну, да.», «То есть») укладываются в 0.3 с живой речью; три — уже нет.
    if duration < options.minimumDuration, words >= 3 { return .tooShort }
    if let noSpeechProb = segment.noSpeechProb, noSpeechProb > options.hardNoSpeechThreshold,
      words <= 2
    {
      return .noSpeech
    }
    return nil
  }

  /// Фраза-титр целиком или с небольшим обрамлением («Продолжение следует... Продолжение следует»).
  private static func matchesKnownPhrase(_ normalized: String, phrase: String) -> Bool {
    if normalized == phrase { return true }
    return normalized.contains(phrase) && normalized.count <= 2 * phrase.count
  }

  /// Зацикливание: сильно сжимаемый текст или n-грамма слов, повторённая подряд `loopRepeats` раз.
  private static func isLooping(text: String, normalized: String, options: Options) -> Bool {
    if compressionRatio(of: text) > options.compressionRatioThreshold { return true }
    return hasRepeatedNGram(normalized.split(separator: " ").map(String.init))
  }

  /// Есть ли n-грамма (n = 1…`loopMaxOrder`), идущая подряд `loopRepeats` раз и больше, — но только если
  /// повтор занимает большую часть сегмента (`loopCoverage` слов при `loopMinimumWords` и больше) либо тянется
  /// `loopHardRepeats` раз. Живая речь тоже повторяет слова («пу-пу-пу-пу-пу, если тут…», «да-да-да-да»),
  /// а галлюцинация-петля состоит из повтора почти целиком — на 1:25:38 первое правило срезало 25 с речи.
  static func hasRepeatedNGram(_ words: [String]) -> Bool {
    guard words.count >= loopRepeats else { return false }
    for order in 1...loopMaxOrder where words.count >= order * loopRepeats {
      for start in 0...(words.count - order * loopRepeats) {
        let gram = Array(words[start..<(start + order)])
        var repeats = 1
        var next = start + order
        while next + order <= words.count, Array(words[next..<(next + order)]) == gram {
          repeats += 1
          next += order
        }
        if repeats >= loopHardRepeats { return true }
        if repeats >= loopRepeats, words.count >= loopMinimumWords,
          Double(repeats * order) / Double(words.count) >= loopCoverage
        {
          return true
        }
      }
    }
    return false
  }

  /// Столько повторов подряд — петля независимо от остального текста.
  static let loopHardRepeats = 8
  /// Доля слов сегмента, которую должен занимать повтор из `loopRepeats` n-грамм.
  static let loopCoverage = 0.7
  /// Короче этого повтор из четырёх n-грамм не считается: «да да да да» — живая речь.
  static let loopMinimumWords = 8

  /// Слова сегмента: из ASR, иначе разбиение текста по пробелам.
  static func wordCount(_ segment: Segment) -> Int {
    segment.words.isEmpty
      ? segment.text.split(whereSeparator: \.isWhitespace).count : segment.words.count
  }

  /// Есть ли рядом речь по диаризации: пересечение с turn'ом или расстояние до ближайшего не больше `distance`.
  static func hasSpeechEvidence(_ segment: Segment, turns: [Turn], distance: Double) -> Bool {
    turns.contains { turn in
      if turn.overlap(from: segment.start, to: segment.end) > 0 { return true }
      return max(turn.start - segment.end, segment.start - turn.end) <= distance
    }
  }

  /// Нижний регистр, без пунктуации и лишних пробелов — для сравнения повторов и фраз.
  static func normalize(_ text: String) -> String {
    text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
  }

  /// Коэффициент сжатия текста (zlib): длина UTF-8 / длина сжатого. Короткие тексты zlib не сжимает — 1.
  static func compressionRatio(of text: String) -> Double {
    let data = Data(text.utf8)
    guard data.count >= minimumCompressedBytes,
      let compressed = try? (data as NSData).compressed(using: .zlib),
      compressed.length > 0
    else { return 1 }
    return Double(data.count) / Double(compressed.length)
  }

  /// Эффективная длительность: сегмент или размах его слов — что больше (тайминги последнего сегмента окна
  /// бывают битые, DTW-слова надёжнее).
  static func effectiveDuration(_ segment: Segment) -> Double {
    guard let first = segment.words.map(\.start).min(), let last = segment.words.map(\.end).max()
    else { return segment.duration }
    return max(segment.duration, last - first)
  }
}
