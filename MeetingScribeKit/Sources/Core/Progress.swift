import Foundation

/// Стадии обработки записи (SPEC.md §2 п. 1, §3.7).
public enum Stage: String, Codable, Sendable, CaseIterable, Hashable {
  case modelDownload
  case decoding
  case diarization
  case languageDetection
  case transcription
  case fusion
  case export
  /// Распознавание подписей на видео (фаза 3, SPEC.md §3.4 п. d): необязательная стадия вне пайплайна,
  /// со своим прогрессом по времени видео.
  case nameRecognition

  /// Название стадии для строки состояния.
  public var title: String {
    switch self {
    case .modelDownload: String(localized: "Подготовка моделей")
    case .decoding: String(localized: "Подготовка аудио")
    case .diarization: String(localized: "Разделение по голосам")
    case .languageDetection: String(localized: "Определение языка")
    case .transcription: String(localized: "Распознавание речи")
    case .fusion: String(localized: "Сшивка")
    case .export: String(localized: "Экспорт")
    case .nameRecognition: String(localized: "Распознавание подписей")
    }
  }
}

/// Событие прогресса от движка или стадии. Единица измерения — секунды обработанного аудио (SPEC.md §3.7 п. 1);
/// доля стадии — для стадий, где секунды неприменимы (кластеризация, скачивание).
public struct ProgressEvent: Hashable, Sendable {
  public var stage: Stage
  /// Заполненность стадии 0…1, если известна.
  public var fractionOfStage: Double?
  public var processedAudioSeconds: Double?
  public var totalAudioSeconds: Double?
  /// Таймкод обрабатываемого места записи (для пульса).
  public var timecode: Double?
  /// Последняя распознанная фраза или иной признак живости.
  public var pulse: String?
  public var bytesCompleted: Int64?
  public var bytesTotal: Int64?
  public var timestamp: Date

  public init(
    stage: Stage,
    fractionOfStage: Double? = nil,
    processedAudioSeconds: Double? = nil,
    totalAudioSeconds: Double? = nil,
    timecode: Double? = nil,
    pulse: String? = nil,
    bytesCompleted: Int64? = nil,
    bytesTotal: Int64? = nil,
    timestamp: Date = Date()
  ) {
    self.stage = stage
    self.fractionOfStage = fractionOfStage
    self.processedAudioSeconds = processedAudioSeconds
    self.totalAudioSeconds = totalAudioSeconds
    self.timecode = timecode
    self.pulse = pulse
    self.bytesCompleted = bytesCompleted
    self.bytesTotal = bytesTotal
    self.timestamp = timestamp
  }

  /// Доля выполнения стадии: явная, либо вычисленная из секунд аудио или байтов.
  public var estimatedFraction: Double? {
    if let fractionOfStage { return min(max(fractionOfStage, 0), 1) }
    if let processedAudioSeconds, let totalAudioSeconds, totalAudioSeconds > 0 {
      return min(max(processedAudioSeconds / totalAudioSeconds, 0), 1)
    }
    if let bytesCompleted, let bytesTotal, bytesTotal > 0 {
      return min(max(Double(bytesCompleted) / Double(bytesTotal), 0), 1)
    }
    return nil
  }

  public static func fraction(_ stage: Stage, _ fraction: Double, pulse: String? = nil)
    -> ProgressEvent
  {
    ProgressEvent(stage: stage, fractionOfStage: fraction, pulse: pulse)
  }

  public static func audio(
    _ stage: Stage,
    processed: Double,
    total: Double,
    timecode: Double? = nil,
    pulse: String? = nil
  ) -> ProgressEvent {
    ProgressEvent(
      stage: stage,
      processedAudioSeconds: processed,
      totalAudioSeconds: total,
      timecode: timecode ?? processed,
      pulse: pulse
    )
  }
}

/// Приёмник событий прогресса. Вызывается с произвольного потока: обновление интерфейса — только через главный актор.
public typealias ProgressSink = @Sendable (ProgressEvent) -> Void

/// Пульс для операций без собственного прогресса (загрузка и компиляция моделей CoreML занимает до минут):
/// событие в начале, затем «стадия жива» раз в `interval`, событие с долей 1 по завершении (SPEC.md §3.7 п. 4).
public enum ProgressHeartbeat {
  public static func run<T>(
    stage: Stage,
    pulse: String,
    interval: Duration = .seconds(1),
    sink: ProgressSink?,
    body: () async throws -> T
  ) async rethrows -> T {
    guard let sink else { return try await body() }
    let started = ContinuousClock.now
    sink(ProgressEvent(stage: stage, fractionOfStage: 0, pulse: pulse))
    let heartbeat = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { break }
        let elapsed = (ContinuousClock.now - started).components.seconds
        sink(ProgressEvent(stage: stage, pulse: String(localized: "\(pulse) · \(elapsed) с")))
      }
    }
    defer { heartbeat.cancel() }
    let result = try await body()
    sink(ProgressEvent(stage: stage, fractionOfStage: 1, pulse: pulse))
    return result
  }
}
