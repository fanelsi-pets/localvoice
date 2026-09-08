import Core
import Foundation
import OCR
import Observation
import Store

/// «Найти имена на видео» (SPEC.md §3.4 п. d): необязательный источник подсказок. Сканирование идёт в фоне
/// со своим определённым прогрессом по времени видео (операция дольше 2 с — SPEC.md §3.7) и отменой;
/// итог — список подписей и голоса за спикеров — попадает в `Transcript.nameHints`, откуда инспектор
/// показывает подсказки и предложения. Живёт в `AppModel`, а не во вью: окно можно закрыть.
@Observable
public final class NameScanController {
  public private(set) var activeMeetingID: UUID?
  /// Доля 0…1 по времени видео.
  public private(set) var fraction: Double = 0
  public private(set) var pulse = ""
  public private(set) var elapsedSeconds: Double = 0
  /// Таймкод обрабатываемого места видео.
  public private(set) var timecode: Double?
  /// «осталось около N минут» — по фактической скорости, после 15 с работы или 10 % (SPEC.md §3.7 п. 5).
  public private(set) var remainingText: String?
  /// Сторож: «дольше обычного» / «похоже, зависло» (SPEC.md §3.7 п. 6).
  public private(set) var healthText: String?
  public private(set) var errorText: String?
  /// Итог последнего сканирования для подписи в инспекторе.
  public private(set) var summary: String?

  @ObservationIgnored private var task: Task<Void, Never>?

  /// Открытый доступ к видео по закладке (песочница хоста, ADR-010) — на время сканирования.
  @ObservationIgnored private var sourceAccess: SourceAccess?

  public init() {}

  public var isScanning: Bool { activeMeetingID != nil }

  public func isScanning(_ meetingID: UUID) -> Bool { activeMeetingID == meetingID }

  /// Запускает сканирование видео встречи. `hints` — имена для нечёткого сопоставления подписей
  /// (люди, chat.txt); `completion` получает подсказки с голосованием по репликам.
  public func start(
    meetingID: UUID, videoURL: URL, utterances: [Utterance], hints: [String],
    sourceAccess: () -> SourceAccess? = { nil },
    completion: @escaping (OCRReport, [NameHint]) -> Void
  ) {
    guard !isScanning else { return }
    activeMeetingID = meetingID
    self.sourceAccess = sourceAccess()
    fraction = 0
    pulse = String(localized: "Извлечение кадров")
    elapsedSeconds = 0
    errorText = nil
    summary = nil
    let reporter = ProgressReporter()
    var options = OCROptions()
    options.nameHints = hints
    let scanner = VideoNameScanner(videoURL: videoURL, options: options)
    let heartbeat = reporter.startHeartbeat()
    task = Task { [weak self] in
      defer { heartbeat.cancel() }
      let consumer = Task { [weak self] in
        for await snapshot in reporter.makeStream() {
          guard let self else { return }
          let fraction = min(max(snapshot.stageFraction, 0), 1)
          self.fraction = fraction
          if let pulse = snapshot.pulse { self.pulse = pulse }
          self.elapsedSeconds = snapshot.elapsedSeconds
          self.timecode = snapshot.timecode
          self.remainingText = Self.remaining(elapsed: snapshot.elapsedSeconds, fraction: fraction)
          self.healthText = ProgressPresentation.health(snapshot)
        }
      }
      do {
        let report = try await scanner.scan(progress: reporter.sink)
        reporter.finish()
        await consumer.value
        let hints = NameVoting.hints(from: report, utterances: utterances)
        self?.summary = Self.summary(for: report, hints: hints)
        self?.fraction = 1
        self?.remainingText = nil
        self?.healthText = nil
        completion(report, hints)
      } catch is CancellationError {
        reporter.cancel()
        await consumer.value
        self?.summary = String(localized: "Сканирование отменено")
      } catch {
        reporter.fail(error.localizedDescription)
        await consumer.value
        self?.errorText = error.localizedDescription
      }
      self?.sourceAccess?.end()
      self?.sourceAccess = nil
      self?.activeMeetingID = nil
    }
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }

  /// Прогноз по фактической скорости прохода: показывается после 15 с или 10 % (SPEC.md §3.7 п. 5).
  static func remaining(elapsed: Double, fraction: Double) -> String? {
    guard fraction > 0.001,
      elapsed >= ProgressReporter.estimateAfterSeconds
        || fraction >= ProgressReporter.estimateAfterFraction
    else { return nil }
    return String(localized: "осталось ")
      + ProgressPhrasing.remaining(elapsed * (1 - fraction) / fraction)
  }

  static func summary(for report: OCRReport, hints: [NameHint]) -> String {
    let names = report.roster.map(\.name)
    let voted = hints.filter { $0.speakerID != nil }.count
    var parts: [String] = []
    parts.append(
      names.isEmpty
        ? String(localized: "подписей на видео не найдено")
        : String(localized: "подписей: \(names.count) (\(names.prefix(6).joined(separator: ", ")))")
    )
    if !report.spans.isEmpty {
      parts.append(
        String(
          localized:
            "активный спикер виден \(Int(report.spans.reduce(0) { $0 + ($1.end - $1.start) })) с, предложений спикерам: \(voted)"
        ))
    } else {
      parts.append(
        String(localized: "активный спикер в записи не выделен — имена только как подсказки"))
    }
    parts.append(
      String(localized: "кадров: \(report.framesSampled), \(Int(report.elapsedSeconds)) с"))
    return parts.joined(separator: " · ")
  }
}
