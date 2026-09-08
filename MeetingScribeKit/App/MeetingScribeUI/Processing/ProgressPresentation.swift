import Core
import Export
import Foundation

/// Состояние одной стадии для списка на карточке встречи (DESIGN.md §3b).
nonisolated public struct StageCheck: Hashable, Identifiable, Sendable {
  public enum State: Hashable, Sendable {
    case pending
    case active
    case done
    case skipped
  }

  public var stage: Stage
  public var state: State
  /// Фактическое время завершённой стадии, с.
  public var seconds: Double?

  public var id: Stage { stage }

  public init(stage: Stage, state: State, seconds: Double? = nil) {
    self.stage = stage
    self.state = state
    self.seconds = seconds
  }
}

/// Строка ленты уже распознанных реплик на карточке встречи. Лента — признак живости, не предпросмотр:
/// сегменты приходят до фильтра галлюцинаций и сшивки (ADR-003), часть исчезнет или склеится.
nonisolated public struct FeedLine: Hashable, Identifiable, Sendable {
  public var id: Int
  public var start: Double
  public var text: String
  public var language: Language?
  /// Спикер по перекрытию с turn'ами диаризации; `nil`, пока диаризация не пришла.
  public var speakerID: Int?

  public init(id: Int, start: Double, text: String, language: Language?, speakerID: Int?) {
    self.id = id
    self.start = start
    self.text = text
    self.language = language
    self.speakerID = speakerID
  }
}

/// Чистые функции «снимок прогресса → текст и числа для интерфейса» (SPEC.md §3.7, DESIGN.md §3b).
/// Не изолированы на главном акторе: их зовут вью-модели и тесты.
nonisolated public enum ProgressPresentation {
  /// Порядок стадий на карточке.
  public static let stageOrder: [Stage] = [
    .modelDownload, .decoding, .diarization, .languageDetection, .transcription, .fusion, .export,
  ]

  /// Процент для подписи: у подготовки моделей — доля стадии (общая доля там всегда 0, SPEC.md §3.7 п. 10).
  public static func percent(_ snapshot: ProgressSnapshot) -> Int {
    if snapshot.isFinished, !snapshot.isCancelled, snapshot.failure == nil { return 100 }
    if snapshot.stage == .modelDownload {
      return Int((min(max(snapshot.stageFraction, 0), 1) * 100).rounded(.down))
    }
    return snapshot.percent
  }

  /// Значение полосы 0…1. Пока идёт подготовка моделей — отдельная определённая полоса по доле стадии,
  /// иначе общая доля; полоса никогда не откатывается (за монотонность отвечает `ProgressReporter`).
  public static func barValue(_ snapshot: ProgressSnapshot) -> Double {
    if snapshot.isFinished, !snapshot.isCancelled, snapshot.failure == nil { return 1 }
    if snapshot.stage == .modelDownload { return min(max(snapshot.stageFraction, 0), 1) }
    return min(max(snapshot.overallFraction, 0), 1)
  }

  /// Строка 1: «Распознавание речи · 47 % · осталось около 4 минут».
  public static func line1(_ snapshot: ProgressSnapshot) -> String {
    if snapshot.isCancelled { return String(localized: "Отменено") }
    if let failure = snapshot.failure { return String(localized: "Ошибка · \(failure)") }
    if snapshot.isFinished {
      return String(localized: "Готово за \(elapsed(snapshot.elapsedSeconds))")
    }
    guard let stage = snapshot.stage else { return String(localized: "Подготовка") }
    var parts = [stage.title]
    if stage == .modelDownload {
      if let completed = snapshot.bytesCompleted, let total = snapshot.bytesTotal, total > 0 {
        parts.append(String(localized: "\(completed / 1_048_576) / \(total / 1_048_576) МБ"))
      } else if snapshot.stageFraction > 0 {
        parts.append("\(percent(snapshot)) %")
      }
    } else {
      parts.append("\(percent(snapshot)) %")
      if let remaining = snapshot.remainingDescription {
        parts.append(String(localized: "осталось \(remaining)"))
      }
    }
    return parts.joined(separator: " · ")
  }

  /// Строка 2 — пульс: «00:38:12 · …надо посчитать юнит-экономику». Фраза усечена по числу символов
  /// с начала (важнее свежий хвост), окончательное усечение по ширине делает вью.
  public static func line2(_ snapshot: ProgressSnapshot, maxPulseLength: Int = 90) -> String {
    let pulse = snapshot.pulse?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var parts: [String] = []
    if let timecode = snapshot.timecode, snapshot.stage != .modelDownload {
      parts.append(Timecode.hhmmss(timecode))
    }
    if !pulse.isEmpty {
      parts.append(
        pulse.count > maxPulseLength ? "…" + String(pulse.suffix(maxPulseLength)) : pulse)
    }
    if parts.isEmpty, let stage = snapshot.stage, !snapshot.isFinished {
      return String(localized: "\(stage.title) · прошло \(elapsed(snapshot.elapsedSeconds))")
    }
    return parts.joined(separator: " · ")
  }

  /// Подпись сторожа (SPEC.md §3.7 п. 6): `nil`, пока события идут.
  public static func health(_ snapshot: ProgressSnapshot) -> String? {
    guard !snapshot.isFinished else { return nil }
    switch snapshot.health {
    case .normal:
      return nil
    case .slow(let seconds):
      return String(localized: "Стадия идёт дольше обычного · прошло \(elapsed(seconds))")
    case .stuck(let seconds):
      return String(localized: "Похоже, зависло · нет событий \(elapsed(seconds))")
    }
  }

  /// Нужна кнопка «Отменить и собрать отчёт» (3 минуты без событий).
  public static func showsStuckAction(_ snapshot: ProgressSnapshot) -> Bool {
    if case .stuck = snapshot.health, !snapshot.isFinished { return true }
    return false
  }

  /// Короткая подпись для строки в sidebar: «47 %», у подготовки моделей — «модели 30 %».
  public static func sidebarCaption(_ snapshot: ProgressSnapshot) -> String {
    if snapshot.stage == .modelDownload {
      return String(localized: "модели \(percent(snapshot)) %")
    }
    return "\(percent(snapshot)) %"
  }

  /// Список стадий с состояниями: завершённые — с фактическим временем, текущая выделена.
  public static func stageChecks(_ snapshot: ProgressSnapshot, includesDiarization: Bool)
    -> [StageCheck]
  {
    stageOrder.compactMap { stage in
      if stage == .diarization, !includesDiarization {
        return StageCheck(stage: stage, state: .skipped)
      }
      if let seconds = snapshot.completedStages[stage] {
        return StageCheck(stage: stage, state: .done, seconds: seconds)
      }
      if snapshot.isFinished, !snapshot.isCancelled, snapshot.failure == nil {
        return StageCheck(stage: stage, state: .done, seconds: nil)
      }
      if snapshot.stage == stage, !snapshot.isFinished {
        return StageCheck(stage: stage, state: .active)
      }
      return StageCheck(stage: stage, state: .pending)
    }
  }

  /// «1:20», «1:02:03» — прошедшее время.
  public static func elapsed(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
    return String(format: "%d:%02d", minutes, rest)
  }

  /// «4.2 с» / «1 мин 12 с» — фактическое время стадии в списке.
  public static func stageDuration(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: "%.1f с", seconds) }
    return Timecode.humanDuration(seconds)
  }
}
