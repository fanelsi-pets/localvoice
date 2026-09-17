import Foundation

/// Слово облачного распознавания: таймкоды от начала переданного куска аудио.
public struct RemoteWord: Hashable, Sendable {
  public var text: String
  public var start: Double
  public var end: Double
  /// Метка спикера провайдера (`spk_1`), если его просили о диаризации. Ядро её не использует: спикеров
  /// даёт локальный диаризатор, иначе рассыпались бы голосовые профили и сшивка между кусками (ADR-006).
  public var speaker: String?

  public init(text: String, start: Double, end: Double, speaker: String? = nil) {
    self.text = text
    self.start = start
    self.end = end
    self.speaker = speaker
  }
}

/// Готовность облачного провайдера: ключ на месте или причина, понятная пользователю.
public struct RemoteTranscriberAvailability: Hashable, Sendable {
  public var isAvailable: Bool
  public var reason: String?

  public init(isAvailable: Bool, reason: String? = nil) {
    self.isAvailable = isAvailable
    self.reason = reason
  }

  public static let available = RemoteTranscriberAvailability(isAvailable: true)
}

/// Облачное распознавание силами приложения-хоста (ADR-010, как `FollowupGenerating`): ключ, протокол и сеть
/// живут в хосте, ядро только режет запись на куски и просит распознать файл. Реализация в LocalVoice —
/// Gemini 3.5 Transcribe (`GeminiMeetingTranscriber`).
public protocol RemoteTranscribing: Sendable {
  /// Название для карточки встречи и настроек: «Gemini 3.5 Transcribe».
  var title: String { get }
  /// Идентификатор модели для `EngineDescriptor.model`: `gemini-3.5-transcribe`.
  var model: String { get }
  /// Предел длительности одного запроса, с. У Gemini со словными таймкодами — 30 минут
  /// (ai.google.dev/gemini-api/docs/transcribe, прочитано 16.09.2026).
  var maximumClipSeconds: Double { get }

  /// Есть ли ключ и можно ли слать запросы. Ядро зовёт это в `prepare`, до первого куска.
  func availability() async -> RemoteTranscriberAvailability

  /// Распознаёт один файл (ядро держит его длительность в пределах `maximumClipSeconds`) и возвращает слова
  /// с таймкодами от его начала. `language` — `nil`: язык определяет сам провайдер (смешанная речь встречи).
  /// `duration` — длительность куска в секундах: провайдеру она нужна, если таймкодов в ответе не оказалось.
  func transcribe(clip url: URL, mimeType: String, duration: Double, language: Language?)
    async throws -> [RemoteWord]
}

/// Ошибка провайдера в терминах, понятных ядру: текст показываем как есть (это ответ сервиса), а
/// `isRetryable` отличает временный отказ (429, 5xx, таймаут) от окончательного (нет ключа, отказ модели).
public struct RemoteTranscriptionError: Error, LocalizedError, Hashable, Sendable {
  public var message: String
  public var isRetryable: Bool

  public init(message: String, isRetryable: Bool) {
    self.message = message
    self.isRetryable = isRetryable
  }

  public var errorDescription: String? { message }
}
