import Core
import Darwin
import Foundation

/// Отчёт «Отменить и собрать отчёт» (SPEC.md §3.7 п. 6, DESIGN.md §3b): состояние зависшего прогона, которое
/// можно приложить к письму, — стадии и время, доли прогресса, метрики живости, память, железо и ОС.
///
/// Приватность: в отчёт не попадают ни аудио, ни текст реплик. Пульс — это последняя распознанная фраза,
/// поэтому в отчёте от него остаётся только длина; из ленты — только число сегментов.
/// Тип не `Codable` (модуль изолирован на главном акторе, а `JSONDecoder` зовёт `init(from:)` из любого
/// контекста): JSON собирается словарём через `JSONSerialization`.
nonisolated public struct DiagnosticsReport: Sendable {
  /// Версия приложения: `MeetingScribeUIInfo.version` от координатора, иначе версия бандла.
  public static let bundleVersion =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

  public var appVersion: String
  public var generatedAt: Date
  public var meetingID: UUID
  public var meetingTitle: String
  public var durationSeconds: Double?
  public var engines: EngineSelection
  public var snapshot: ProgressSnapshot
  public var stages: [StageCheck]
  /// Сколько сегментов пришло в ленту к моменту отчёта.
  public var feedSegmentCount: Int
  public var queuePosition: Int?
  public var isActive: Bool
  public var memory: ProcessMemory.Snapshot?

  public init(
    appVersion: String = DiagnosticsReport.bundleVersion,
    generatedAt: Date = Date(),
    meetingID: UUID,
    meetingTitle: String,
    durationSeconds: Double? = nil,
    engines: EngineSelection,
    snapshot: ProgressSnapshot,
    stages: [StageCheck] = [],
    feedSegmentCount: Int = 0,
    queuePosition: Int? = nil,
    isActive: Bool = false,
    memory: ProcessMemory.Snapshot? = nil
  ) {
    self.appVersion = appVersion
    self.generatedAt = generatedAt
    self.meetingID = meetingID
    self.meetingTitle = meetingTitle
    self.durationSeconds = durationSeconds
    self.engines = engines
    self.snapshot = snapshot
    self.stages = stages
    self.feedSegmentCount = feedSegmentCount
    self.queuePosition = queuePosition
    self.isActive = isActive
    self.memory = memory
  }

  /// `diagnostics-20260904-181233-<uuid>.json` — сортируется по времени и не перетирает прошлые отчёты.
  public var fileName: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "diagnostics-\(formatter.string(from: generatedAt))-\(meetingID.uuidString).json"
  }

  /// JSON отчёта. Бросает, если словарь нельзя сериализовать (значения — только числа, строки и словари).
  public func json() throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  var object: [String: Any] {
    var meeting: [String: Any] = [
      "id": meetingID.uuidString,
      "title": meetingTitle,
      "isActive": isActive,
    ]
    meeting["durationSeconds"] = durationSeconds.map { round($0 * 100) / 100 }
    meeting["queuePosition"] = queuePosition

    var engineInfo: [String: Any] = [
      "asr": engines.asr.rawValue,
      "title": engines.title,
      "asrRate": engines.asrRate,
    ]
    engineInfo["whisperModel"] = engines.whisperModel.rawValue
    engineInfo["diarizer"] = engines.diarizer?.rawValue

    var progress: [String: Any] = [
      "stage": snapshot.stage?.rawValue ?? "—",
      "stageFraction": rounded(snapshot.stageFraction),
      "overallFraction": rounded(snapshot.overallFraction),
      "percent": ProgressPresentation.percent(snapshot),
      "elapsedSeconds": rounded(snapshot.elapsedSeconds),
      "engineEventGapSeconds": rounded(snapshot.engineEventGapSeconds),
      "maxEngineEventGapSeconds": rounded(snapshot.maxEngineEventGapSeconds),
      "health": health,
      "isFinished": snapshot.isFinished,
      "isCancelled": snapshot.isCancelled,
      // Пульс — распознанная фраза: в отчёт идёт только её длина.
      "pulseLength": snapshot.pulse?.count ?? 0,
    ]
    progress["timecode"] = snapshot.timecode.map(rounded)
    progress["estimatedRemainingSeconds"] = snapshot.estimatedRemainingSeconds.map(rounded)
    progress["processedAudioSeconds"] = snapshot.processedAudioSeconds.map(rounded)
    progress["totalAudioSeconds"] = snapshot.totalAudioSeconds.map(rounded)
    progress["failure"] = snapshot.failure

    var report: [String: Any] = [
      "generatedAt": Self.timestamp.format(generatedAt),
      "app": appVersion,
      "meeting": meeting,
      "engines": engineInfo,
      "progress": progress,
      "stages": stages.map { stage -> [String: Any] in
        var item: [String: Any] = ["stage": stage.stage.rawValue, "state": Self.name(stage.state)]
        item["seconds"] = stage.seconds.map(rounded)
        return item
      },
      "feedSegmentCount": feedSegmentCount,
      "system": Self.system,
    ]
    if let memory {
      report["memory"] = [
        "footprintBytes": memory.footprintBytes,
        "peakResidentBytes": memory.peakResidentBytes,
        "footprint": ProcessMemory.format(memory.footprintBytes),
        "peakResident": ProcessMemory.format(memory.peakResidentBytes),
      ]
    }
    return report
  }

  private var health: [String: Any] {
    switch snapshot.health {
    case .normal: ["state": "normal"]
    case .slow(let seconds): ["state": "slow", "sinceSeconds": rounded(seconds)]
    case .stuck(let seconds): ["state": "stuck", "sinceSeconds": rounded(seconds)]
    }
  }

  private func rounded(_ value: Double) -> Double {
    (value * 1000).rounded() / 1000
  }

  private static func name(_ state: StageCheck.State) -> String {
    switch state {
    case .pending: "pending"
    case .active: "active"
    case .done: "done"
    case .skipped: "skipped"
    }
  }

  private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

  /// «Apple M5 Pro» — чип для отчёта и вкладки Settings → Диагностика.
  public static var chip: String? { sysctl("machdep.cpu.brand_string") }

  /// «Mac17,8» — идентификатор модели.
  public static var modelIdentifier: String? { sysctl("hw.model") }

  /// Железо и ОС: по ним видно, ANE это или нет и совпадает ли конфигурация с замерами в docs/BENCH.
  private static var system: [String: Any] {
    var system: [String: Any] = [
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
      "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
    ]
    system["chip"] = chip
    system["model"] = modelIdentifier
    return system
  }

  private static func sysctl(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }
}
