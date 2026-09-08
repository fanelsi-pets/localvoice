import Foundation

/// Параметры одного вызова распознавания.
public struct AsrOptions: Hashable, Sendable {
  /// Язык речи. `nil` — движок должен сам определить язык (никогда не полагаться на умолчание библиотеки).
  public var language: Language?
  public var wordTimestamps: Bool
  /// Смещение переданного куска относительно начала записи: таймкоды в результате всегда абсолютные.
  public var timeOffset: Double
  /// Интервалы переданного аудио (секунды от его начала), которые нужно распознать; пусто — целиком.
  /// Так один вызов на язык покрывает все реплики спикеров этого языка без нарезки аудио (ADR-003):
  /// у WhisperKit это `clipTimestamps`, чанки внутри клипов идут параллельно, таймкоды остаются абсолютными.
  /// Интервалы не пересекаются и идут по времени; интервал короче 1 с WhisperKit пропускает целиком.
  public var clips: [ClosedRange<Double>]

  public init(
    language: Language? = nil,
    wordTimestamps: Bool = true,
    timeOffset: Double = 0,
    clips: [ClosedRange<Double>] = []
  ) {
    self.language = language
    self.wordTimestamps = wordTimestamps
    self.timeOffset = timeOffset
    self.clips = clips
  }

  /// Суммарная длительность запрошенных интервалов (или всего аудио, если клипов нет).
  public func requestedSeconds(audioDuration: Double) -> Double {
    clips.isEmpty ? audioDuration : clips.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
  }
}

/// Результат определения языка.
public struct LanguageDetection: Hashable, Sendable {
  public var language: Language
  public var probabilities: [Language: Double]

  public init(language: Language, probabilities: [Language: Double] = [:]) {
    self.language = language
    self.probabilities = probabilities
  }

  public var confidence: Double { probabilities[language] ?? 0 }
}

/// Приёмник готовых сегментов по мере их появления: таймкоды абсолютные, слова уже привязаны.
/// Вызывается с произвольного потока. Нужен для ленты реплик в интерфейсе и для сохранения уже распознанного при отмене.
public typealias SegmentSink = @Sendable ([Segment]) -> Void

/// Движок распознавания речи (SPEC.md §3.2). Реализации — акторы в модулях Engines/*.
public protocol AsrEngine: Sendable {
  var descriptor: EngineDescriptor { get }

  /// Принимает ли движок язык на вход. Если нет (Parakeet), язык по спикеру и клипы по языкам не используются.
  var supportsLanguageSelection: Bool { get }

  /// Скачивает (при необходимости) и загружает модели. Прогресс скачивания — в мегабайтах и процентах.
  func prepare(progress: ProgressSink?) async throws

  /// Определяет язык по первым 30 секундам переданного аудио.
  func detectLanguage(_ audio: PCMAudio) async throws -> LanguageDetection

  /// Распознаёт аудио целиком (или интервалы `options.clips`) со смещением `options.timeOffset`.
  /// Прогресс — секунды обработанного аудио и пульс (таймкод + текст последнего сегмента);
  /// `discovered` получает сегменты по мере появления — при отмене вызов бросает `EngineError.cancelled`,
  /// а уже переданные сегменты остаются у вызывающего.
  func transcribe(
    _ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?, discovered: SegmentSink?
  ) async throws -> [Segment]

  /// Потоковое распознавание файла целиком силами движка (инкрементальная загрузка). По умолчанию не поддерживается.
  func transcribeFile(_ url: URL, options: AsrOptions, progress: ProgressSink?) async throws
    -> [Segment]
}

extension AsrEngine {
  public var supportsLanguageSelection: Bool { true }

  /// Удобная форма без ленты сегментов.
  public func transcribe(_ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?)
    async throws -> [Segment]
  {
    try await transcribe(audio, options: options, progress: progress, discovered: nil)
  }

  public func transcribeFile(_ url: URL, options: AsrOptions, progress: ProgressSink?) async throws
    -> [Segment]
  {
    throw EngineError.unsupported(
      String(
        localized: "\(descriptor.name) не умеет читать файл напрямую; декодируйте через Ingest"))
  }
}
