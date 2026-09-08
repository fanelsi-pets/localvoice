import Core
import Foundation
import Observation
import Pipeline
import Store

/// Самопроверка на встроенном сэмпле (SPEC.md §2 п. 8, §3.8) для онбординга и вкладки «Диагностика».
/// Прогон идёт в `SelfTestRunner` (актор пайплайна), события прогресса приходят с рабочих потоков через
/// `AsyncStream` и разбираются одной задачей на главном акторе (ADR-005). Стадия «Подготовка моделей»
/// показывается своей определённой полосой: первая загрузка Whisper компилирует CoreML до ~100 с,
/// и «крутилка» здесь запрещена (SPEC.md §3.7).
@Observable
public final class SelfTestController {
  public private(set) var isRunning = false
  /// Значение полосы 0…1 (у подготовки моделей — своя шкала по доле стадии).
  public private(set) var barValue: Double = 0
  public private(set) var percent = 0
  public private(set) var isModelPreparation = false
  /// «Распознавание речи · 47 % · осталось около минуты».
  public private(set) var line1 = ""
  /// Пульс: таймкод и последняя распознанная фраза.
  public private(set) var line2 = ""
  public private(set) var stageChecks: [StageCheck] = []
  public private(set) var elapsedSeconds: Double = 0
  /// Итог последнего прогона (в том числе прошлого сеанса приложения — читается из папки диагностики).
  public private(set) var report: SelfTestReport?
  /// Файл отчёта самопроверки в папке диагностики.
  public private(set) var reportURL: URL?
  public private(set) var errorText: String?
  public private(set) var isCancelled = false
  /// Отмена запрошена, задача ещё завершается (компиляция CoreML не прерывается мгновенно).
  public private(set) var isStopping = false

  @ObservationIgnored private var task: Task<Void, Never>?
  /// Монотонность полосы (SPEC.md §3.7 п. 3) внутри одной шкалы.
  @ObservationIgnored private var barFloor: Double = 0
  @ObservationIgnored private var percentFloor = 0

  public init() {}

  public var hasResult: Bool { report != nil || errorText != nil }

  /// Короткий итог для интерфейса: «Всё работает: 2 спикера, 6 реплик, ru/uk, 21 с».
  public var resultText: String? {
    if let errorText { return errorText }
    if isCancelled, report == nil { return String(localized: "Проверка отменена") }
    return report?.summary
  }

  /// Запускает проверку. `cacheDirectory` — рабочая папка прогона (декодированное аудио),
  /// `store` — куда положить отчёт (`Diagnostics/selftest-<дата>.json`).
  public func start(
    engines: any EngineProviding,
    selection: EngineSelection,
    sample: SelfTestSample,
    cacheDirectory: URL,
    store: LibraryStore? = nil
  ) {
    guard !isRunning else { return }
    isRunning = true
    isCancelled = false
    errorText = nil
    report = nil
    reportURL = nil
    barValue = 0
    barFloor = 0
    percent = 0
    percentFloor = 0
    line1 = Stage.modelDownload.title
    line2 = ""
    elapsedSeconds = 0
    stageChecks = ProgressPresentation.stageChecks(
      .idle, includesDiarization: selection.diarizer != nil)

    let reporter = ProgressReporter()
    let heartbeat = reporter.startHeartbeat()
    let runner = SelfTestRunner(engines: engines, selection: selection)
    task = Task { [weak self] in
      defer { heartbeat.cancel() }
      let includesDiarization = selection.diarizer != nil
      let consumer = Task { [weak self] in
        for await snapshot in reporter.makeStream() {
          self?.apply(snapshot, includesDiarization: includesDiarization)
        }
      }
      do {
        let report = try await runner.run(
          sample: sample, cacheDirectory: cacheDirectory, reporter: reporter)
        reporter.finish()
        await consumer.value
        self?.finish(report: report, store: store)
      } catch is CancellationError {
        reporter.cancel()
        await consumer.value
        self?.isCancelled = true
      } catch let error as PipelineError {
        if case .cancelled = error {
          reporter.cancel()
          await consumer.value
          self?.isCancelled = true
        } else {
          reporter.fail(error.localizedDescription)
          await consumer.value
          self?.errorText = error.localizedDescription
        }
      } catch {
        reporter.fail(error.localizedDescription)
        await consumer.value
        self?.errorText = error.localizedDescription
      }
      self?.isRunning = false
      self?.isStopping = false
      self?.task = nil
    }
  }

  public func cancel() {
    guard isRunning, !isStopping else { return }
    isStopping = true
    line1 = String(localized: "Останавливаю…")
    line2 = ""
    task?.cancel()
  }

  /// Показывает ошибку, случившуюся до прогона (нет встроенного сэмпла).
  public func fail(_ text: String) {
    errorText = text
    isRunning = false
  }

  /// Показывает готовый отчёт (например, прочитанный с диска при открытии вкладки «Диагностика»).
  public func show(_ report: SelfTestReport, url: URL? = nil) {
    self.report = report
    reportURL = url
    errorText = nil
    isCancelled = false
    barValue = 1
    percent = 100
    stageChecks = report.timings.map {
      StageCheck(stage: $0.stage, state: .done, seconds: $0.seconds)
    }
    elapsedSeconds = report.totalSeconds
    line1 = report.summary
  }

  /// `selftest-20260905-181233.json` — сортируется по времени и не перетирает прошлые прогоны.
  nonisolated public static func fileName(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "selftest-\(formatter.string(from: date)).json"
  }

  nonisolated public static func encode(_ report: SelfTestReport) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(report), as: UTF8.self)
  }

  nonisolated public static func decode(_ data: Data) throws -> SelfTestReport {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(SelfTestReport.self, from: data)
  }

  // MARK: - Внутреннее

  private func apply(_ snapshot: ProgressSnapshot, includesDiarization: Bool) {
    let modelPreparation = snapshot.stage == .modelDownload && !snapshot.isFinished
    let bar = ProgressPresentation.barValue(snapshot)
    let value = ProgressPresentation.percent(snapshot)
    // Смена шкалы (модели → обработка) — не откат полосы, а новая полоса (ADR-005 п. 8).
    if modelPreparation == isModelPreparation {
      barFloor = max(barFloor, bar)
      percentFloor = max(percentFloor, value)
    } else {
      barFloor = bar
      percentFloor = value
    }
    isModelPreparation = modelPreparation
    barValue = barFloor
    percent = percentFloor
    line1 = ProgressPresentation.line1(snapshot)
    line2 = ProgressPresentation.line2(snapshot)
    elapsedSeconds = snapshot.elapsedSeconds
    stageChecks = ProgressPresentation.stageChecks(
      snapshot, includesDiarization: includesDiarization)
  }

  private func finish(report: SelfTestReport, store: LibraryStore?) {
    self.report = report
    barValue = 1
    percent = 100
    line1 = report.summary
    guard let store else { return }
    let fileName = Self.fileName(for: report.startedAt)
    Task { [weak self] in
      do {
        let text = try Self.encode(report)
        self?.reportURL = try await store.writeDiagnostics(text, fileName: fileName)
      } catch {
        // Отчёт — вспомогательный файл: провал записи не отменяет успешную проверку.
        AppLog.diagnostics.error(
          "не удалось записать отчёт самопроверки: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

/// Встроенный сэмпл самопроверки: 28 секунд, два синтезированных голоса (русский и украинский),
/// лежит в ресурсах модуля интерфейса вместе с манифестом ожиданий (SPEC.md §2 п. 8).
nonisolated public enum SelfTestSampleResource {
  public static let baseName = "selftest-sample"
  /// Имя ресурсного бандла SwiftPM для модуля интерфейса.
  static let bundleName = "MeetingScribe_MeetingScribeUI"

  private final class BundleToken {}

  /// Ресурсный бандл модуля. `Bundle.module` здесь не годится: если бандл не доехал до `.app`,
  /// он падает `fatalError`, а самопроверка обязана показать понятное сообщение, а не уронить окно.
  public static var bundle: Bundle {
    let candidates = [
      // Приложение: MeetingScribe.app/Contents/Resources.
      Bundle.main.resourceURL,
      Bundle.main.bundleURL,
      // `swift test`: бандл лежит рядом с продуктами сборки, а не внутри .xctest.
      Bundle(for: BundleToken.self).resourceURL,
      Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
    ]
    for candidate in candidates {
      let url = candidate?.appending(path: "\(bundleName).bundle")
      if let url, let bundle = Bundle(url: url) { return bundle }
    }
    return Bundle(for: BundleToken.self)
  }

  /// Сэмпл из ресурсов модуля.
  public static func load() throws -> SelfTestSample {
    try load(in: bundle)
  }

  public static func load(in bundle: Bundle) throws -> SelfTestSample {
    guard let audio = bundle.url(forResource: baseName, withExtension: "wav") else {
      throw SelfTestError.sampleMissing(URL(fileURLWithPath: "\(baseName).wav"))
    }
    guard let manifest = bundle.url(forResource: baseName, withExtension: "json") else {
      throw SelfTestError.manifestUnreadable(
        URL(fileURLWithPath: "\(baseName).json"),
        reason: String(localized: "файла нет в приложении"))
    }
    return try SelfTestSample.load(manifest: manifest, audio: audio)
  }
}
