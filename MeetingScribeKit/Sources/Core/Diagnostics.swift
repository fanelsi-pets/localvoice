import Foundation

// Типы результатов маршрутизации языка и фильтра галлюцинаций. Файл — общий контракт модулей
// LanguageRouter, HallucinationFilter, Pipeline и Export: меняется только вместе со всеми ними.

/// Язык спикера по итогам маршрутизации — «язык выбирается по спикеру» (SPEC.md §3.2, ADR-002/003).
public struct SpeakerLanguage: Hashable, Codable, Sendable {
  public enum Method: String, Codable, Sendable {
    /// Уверенное определение по пробе речи спикера.
    case detected
    /// Вероятности неоднозначны — выбрано сравнением декодирования пробы с каждым кандидатом.
    case decodedComparison
    /// Речи спикера мало или уверенности нет — язык по умолчанию (доминирующий язык записи).
    case fallback
    /// Задан пользователем (`--language ru`).
    case forced
    /// Движок не принимает язык на вход (Parakeet).
    case unsupported
  }

  public var speakerID: Int
  public var language: Language
  /// Уверенность 0…1 после ренормализации по языкам-кандидатам.
  public var confidence: Double
  /// Сколько секунд речи спикера легло в пробу.
  public var probeSeconds: Double
  public var method: Method

  public init(
    speakerID: Int, language: Language, confidence: Double, probeSeconds: Double, method: Method
  ) {
    self.speakerID = speakerID
    self.language = language
    self.confidence = confidence
    self.probeSeconds = probeSeconds
    self.method = method
  }
}

/// Непрерывный отрезок записи одного языка — единица распознавания (клип одного вызова ASR).
/// Регионы разбивают `[0, длительность]` без пересечений и без дыр.
public struct LanguageRegion: Hashable, Codable, Sendable {
  public var start: Double
  public var end: Double
  /// `nil` — язык не выбирается (движок без языкового входа или диаризации нет и язык не определён).
  public var language: Language?
  /// Спикеры, чьи turn'ы легли в регион, по первому появлению.
  public var speakerIDs: [Int]

  public init(start: Double, end: Double, language: Language?, speakerIDs: [Int] = []) {
    self.start = start
    self.end = end
    self.language = language
    self.speakerIDs = speakerIDs
  }

  public var duration: Double { end - start }

  /// Интервал для `AsrOptions.clips`.
  public var range: ClosedRange<Double> { start...max(start, end) }
}

/// Почему сегмент распознавания отброшен фильтром галлюцинаций.
public enum DropReason: String, Codable, Sendable, CaseIterable, Hashable {
  /// Пустой текст после очистки.
  case empty
  /// Известная фраза-титр («Продолжение следует…», «Субтитры сделал DimaTorzok»).
  case knownPhrase
  /// Зацикливание: сильно сжимаемый текст или многократный повтор n-граммы внутри сегмента.
  case loop
  /// Невозможная скорость речи (символов в секунду).
  case implausibleRate
  /// Несколько слов в отрезке короче минимальной длительности.
  case tooShort
  /// Очень высокая вероятность отсутствия речи у короткого сегмента.
  case noSpeech
  /// Тот же текст, что у предыдущих сегментов, сверх допустимого числа повторов подряд.
  case repeated

  public var title: String {
    switch self {
    case .empty: String(localized: "пустой текст")
    case .knownPhrase: String(localized: "фраза-титр")
    case .loop: String(localized: "зацикливание")
    case .implausibleRate: String(localized: "невозможная скорость речи")
    case .tooShort: String(localized: "слишком короткий")
    case .noSpeech: String(localized: "нет речи")
    case .repeated: String(localized: "повтор")
    }
  }
}

/// Отброшенный сегмент с причиной — для диагностики и отчёта.
public struct DroppedSegment: Hashable, Codable, Sendable {
  public var segment: Segment
  public var reason: DropReason

  public init(segment: Segment, reason: DropReason) {
    self.segment = segment
    self.reason = reason
  }
}

/// Диагностика обработки, сохраняемая вместе с транскриптом.
public struct TranscriptDiagnostics: Hashable, Codable, Sendable {
  public var dropped: [DroppedSegment]
  public var regions: [LanguageRegion]
  /// Сегменты, у которых по диаризации нет речи. Только пометка: SPEC.md §3.3 запрещает терять реплики.
  public var noSpeechEvidence: [Segment]

  public init(
    dropped: [DroppedSegment] = [], regions: [LanguageRegion] = [], noSpeechEvidence: [Segment] = []
  ) {
    self.dropped = dropped
    self.regions = regions
    self.noSpeechEvidence = noSpeechEvidence
  }

  public static let empty = TranscriptDiagnostics()
}
