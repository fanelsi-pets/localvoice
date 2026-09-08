import Foundation

/// Сводка о медиафайле до декодирования: длительность для плана прогресса, проверки и подсказки в интерфейсе.
public struct AudioProbe: Hashable, Sendable {
  public var url: URL
  /// Длительность по контейнеру, с. 0, если контейнер её не сообщает.
  public var duration: Double
  /// Частота дискретизации исходной дорожки, Гц.
  public var sampleRate: Double
  public var channelCount: Int
  public var hasVideo: Bool
  /// Четырёхбуквенный код формата дорожки: «aac », «lpcm», «.mp3».
  public var formatName: String

  public init(
    url: URL,
    duration: Double,
    sampleRate: Double,
    channelCount: Int,
    hasVideo: Bool,
    formatName: String
  ) {
    self.url = url
    self.duration = duration
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.hasVideo = hasVideo
    self.formatName = formatName
  }
}

/// Результат декодирования: WAV mono 16 kHz Float32 в кэше встречи.
public struct DecodedAudio: Hashable, Codable, Sendable {
  public var url: URL
  public var sourceURL: URL
  public var duration: Double
  public var sampleCount: Int
  public var sampleRate: Int

  public init(
    url: URL, sourceURL: URL, duration: Double, sampleCount: Int,
    sampleRate: Int = PCMAudio.sampleRate
  ) {
    self.url = url
    self.sourceURL = sourceURL
    self.duration = duration
    self.sampleCount = sampleCount
    self.sampleRate = sampleRate
  }
}

/// Потоковый декодер (SPEC.md §3.1): файл 0.5–2 GB не загружается в память целиком.
public protocol AudioDecoding: Sendable {
  /// Быстрая справка о файле без декодирования (заголовок контейнера): длительность нужна плану прогресса
  /// до первой стадии (SPEC.md §3.7 п. 1).
  func probe(_ source: URL) async throws -> AudioProbe

  /// Декодирует аудиодорожку `source` в `cacheDirectory/audio16k.wav`. Прогресс — по таймкоду записи.
  func decode(_ source: URL, into cacheDirectory: URL, progress: ProgressSink?) async throws
    -> DecodedAudio

  /// Читает ранее декодированный WAV в память для движков.
  func loadPCM(_ decoded: DecodedAudio) async throws -> PCMAudio
}
