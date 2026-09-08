import Core
import Foundation
import Observation

/// Состояние обработки одной встречи для тулбара, строки sidebar и карточки (SPEC.md §3.7 п. 8).
/// Один объект на встречу: Observation отслеживает чтение свойств по объекту, поэтому тик раз в секунду
/// перерисовывает только те вью, что читают этот объект. Поля присваиваются только при изменении —
/// Observation не сравнивает значения, и неизменившийся снимок не должен трогать интерфейс.
@Observable
public final class MeetingProgressModel {
  /// Сколько строк ленты держим: трёхчасовая запись даёт ~2500 сегментов, карточке нужны последние.
  public static let feedLimit = 200

  public let meetingID: UUID
  public let includesDiarization: Bool

  public private(set) var snapshot: ProgressSnapshot = .idle
  public private(set) var percent = 0
  public private(set) var barValue: Double = 0
  public private(set) var isModelDownload = false
  public private(set) var line1 = ""
  public private(set) var line2 = ""
  public private(set) var healthText: String?
  public private(set) var showsStuckAction = false
  public private(set) var stageChecks: [StageCheck] = []
  public private(set) var feed: [FeedLine] = []
  /// Позиция в очереди (1 — следующая); `nil` — обработка идёт или не запланирована.
  public private(set) var queuePosition: Int?
  public private(set) var isFinished = false
  public private(set) var isCancelled = false
  public private(set) var failure: String?
  public private(set) var speakerLanguages: [Int: Language] = [:]

  @ObservationIgnored private var turns: [Turn] = []
  @ObservationIgnored private var nextFeedID = 0
  /// Достигнутые значения полосы и процента: монотонность обеспечивает `ProgressReporter`, но модель
  /// не должна её ломать, если снимок пришёл не по порядку или репортёра подменили (превью, тесты).
  @ObservationIgnored private var barFloor: Double = 0
  @ObservationIgnored private var percentFloor = 0

  public init(meetingID: UUID, includesDiarization: Bool = true) {
    self.meetingID = meetingID
    self.includesDiarization = includesDiarization
    stageChecks = ProgressPresentation.stageChecks(.idle, includesDiarization: includesDiarization)
  }

  /// Применяет снимок репортёра: производные поля пересчитываются и присваиваются только при изменении.
  /// Полоса и процент не уменьшаются (SPEC.md §3.7 п. 3), кроме перехода между двумя разными полосами:
  /// подготовка моделей идёт вне взвешенного плана (SPEC.md §3.7 п. 10) и показывается своей полосой по
  /// доле стадии, поэтому «модели 90 %» → «обработка 1 %» — не откат, а смена полосы.
  public func apply(_ snapshot: ProgressSnapshot) {
    if self.snapshot != snapshot { self.snapshot = snapshot }
    let modelDownload = snapshot.stage == .modelDownload && !snapshot.isFinished
    let bar = ProgressPresentation.barValue(snapshot)
    let value = ProgressPresentation.percent(snapshot)
    if modelDownload == isModelDownload {
      barFloor = max(barFloor, bar)
      percentFloor = max(percentFloor, value)
    } else {
      barFloor = bar
      percentFloor = value
    }
    assign(&percent, percentFloor)
    assign(&barValue, barFloor)
    assign(&isModelDownload, modelDownload)
    assign(&line1, ProgressPresentation.line1(snapshot))
    assign(&line2, ProgressPresentation.line2(snapshot))
    assign(&healthText, ProgressPresentation.health(snapshot))
    assign(&showsStuckAction, ProgressPresentation.showsStuckAction(snapshot))
    assign(
      &stageChecks,
      ProgressPresentation.stageChecks(snapshot, includesDiarization: includesDiarization))
    assign(&isFinished, snapshot.isFinished)
    assign(&isCancelled, snapshot.isCancelled)
    assign(&failure, snapshot.failure)
  }

  /// Заголовок для тулбара и карточки: пока встреча ждёт очереди и снимков ещё не было — «В очереди · N».
  public var headline: String {
    if let queuePosition, barValue == 0, snapshot.stage == nil {
      return String(localized: "В очереди · \(queuePosition)")
    }
    return line1.isEmpty ? String(localized: "Подготовка") : line1
  }

  public func setQueuePosition(_ position: Int?) {
    assign(&queuePosition, position)
  }

  /// Короткая подпись для строки в sidebar: «47 %», у подготовки моделей — «модели 30 %».
  /// Считается по проценту модели, а не по сырому снимку, — в sidebar, тулбаре и на карточке
  /// пользователь видит одно и то же число (SPEC.md §3.7 п. 8).
  public var sidebarCaption: String {
    isModelDownload ? String(localized: "модели \(percent) %") : "\(percent) %"
  }

  /// Результат диаризации — чтобы строки ленты получали спикера по перекрытию с turn'ами.
  public func setDiarization(_ result: DiarizationResult) {
    turns = result.turns
    if !feed.isEmpty {
      feed = feed.map { line in
        var copy = line
        copy.speakerID = speaker(at: line.start)
        return copy
      }
    }
  }

  public func setLanguages(_ languages: [SpeakerLanguage]) {
    let mapped = Dictionary(languages.map { ($0.speakerID, $0.language) }) { first, _ in first }
    assign(&speakerLanguages, mapped)
  }

  /// Добавляет сегменты из ленты `discovered` (по времени внутри пачки), держит последние `feedLimit`.
  public func appendFeed(_ segments: [Segment]) {
    let lines = segments.sorted { $0.start < $1.start }.compactMap { segment -> FeedLine? in
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      defer { nextFeedID += 1 }
      return FeedLine(
        id: nextFeedID, start: segment.start, text: text, language: segment.language,
        speakerID: speaker(at: segment.start))
    }
    guard !lines.isEmpty else { return }
    var updated = feed + lines
    if updated.count > Self.feedLimit { updated.removeFirst(updated.count - Self.feedLimit) }
    feed = updated
  }

  // MARK: - Внутреннее

  private func speaker(at time: Double) -> Int? {
    turns.first { $0.start <= time && time < $0.end }?.speakerID
      ?? turns.min { abs($0.start - time) < abs($1.start - time) }
      .flatMap { abs($0.start - time) <= 1 ? $0.speakerID : nil }
  }

  private func assign<T: Equatable>(_ storage: inout T, _ value: T) {
    if storage != value { storage = value }
  }
}
