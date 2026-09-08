import Core
import Foundation
import Pipeline
import Store

/// «Собрать отчёт о проблеме» (SPEC.md §3.8 — «лог без аудио»): один JSON, который можно приложить
/// к письму. Внутри — машина, версия, настройки, состояние моделей, последняя самопроверка, статусы
/// встреч и журнал приложения.
///
/// Приватность: ни аудио, ни текста реплик, ни названий встреч и проектов, ни имён людей, ни адреса
/// локальной модели. От встреч остаются только идентификатор, статус, стадия ошибки и длительность;
/// от журнала — сообщения `AppLog`, куда по правилу модуля не пишут распознанный текст.
/// Тип не `Codable` (модуль изолирован на главном акторе): JSON собирается словарём через
/// `JSONSerialization`, как в `DiagnosticsReport`.
nonisolated public struct ProblemReport: Sendable {
  /// Одна модель: что на диске и что говорит манифест (модели из старых кэшей манифеста не имеют).
  public struct ModelEntry: Hashable, Sendable {
    public var id: ModelID
    public var isPresent: Bool
    public var sizeBytes: UInt64?
    public var revision: String?
    public var downloadedAt: Date?
    public var downloaderVersion: String?

    public init(
      id: ModelID, isPresent: Bool, sizeBytes: UInt64? = nil, revision: String? = nil,
      downloadedAt: Date? = nil, downloaderVersion: String? = nil
    ) {
      self.id = id
      self.isPresent = isPresent
      self.sizeBytes = sizeBytes
      self.revision = revision
      self.downloadedAt = downloadedAt
      self.downloaderVersion = downloaderVersion
    }

    /// Откуда модель: скачана приложением (есть манифест), перенесена из старого кэша или отсутствует.
    public var source: String {
      guard isPresent else { return "нет" }
      return revision == nil ? "из старого кэша" : "скачана приложением"
    }
  }

  /// Встреча без единого пользовательского слова: только идентификатор, статус и числа.
  public struct MeetingEntry: Hashable, Sendable {
    public var id: UUID
    public var status: String
    /// Стадия, на которой встреча упала (для `failed`).
    public var failedStage: String?
    public var durationSeconds: Double?
    public var utteranceCount: Int?
    public var speakerCount: Int?
    public var isMultiTrack: Bool

    public init(
      id: UUID, status: String, failedStage: String? = nil, durationSeconds: Double? = nil,
      utteranceCount: Int? = nil, speakerCount: Int? = nil, isMultiTrack: Bool = false
    ) {
      self.id = id
      self.status = status
      self.failedStage = failedStage
      self.durationSeconds = durationSeconds
      self.utteranceCount = utteranceCount
      self.speakerCount = speakerCount
      self.isMultiTrack = isMultiTrack
    }

    /// Запись библиотеки → строка отчёта: название, проект и имена спикеров не переносятся.
    public init(record: MeetingRecord) {
      var stage: String?
      if case .failed(let failedStage, _) = record.status { stage = failedStage?.rawValue }
      self.init(
        id: record.id,
        status: Self.name(record.status),
        failedStage: stage,
        durationSeconds: record.duration,
        utteranceCount: record.utteranceCount,
        speakerCount: record.speakerCount,
        isMultiTrack: record.isMultiTrack)
    }

    /// Статус без сообщения об ошибке: в тексте ошибки может быть путь к файлу пользователя.
    static func name(_ status: MeetingStatus) -> String {
      switch status {
      case .imported: "imported"
      case .queued: "queued"
      case .processing: "processing"
      case .ready: "ready"
      case .cancelled: "cancelled"
      case .failed: "failed"
      case .interrupted: "interrupted"
      }
    }
  }

  /// Настройки без личных данных: адрес локальной модели и папки не переносятся.
  public struct SettingsSnapshot: Hashable, Sendable {
    public var engines: EngineSelection
    public var defaultLanguage: String
    public var meetingLanguages: [String]
    public var expectedSpeakers: Int?
    public var voiceAutoThreshold: Double
    public var voiceSuggestThreshold: Double
    public var flags: [String: Bool]

    public init(
      engines: EngineSelection, defaultLanguage: String, meetingLanguages: [String],
      expectedSpeakers: Int?, voiceAutoThreshold: Double, voiceSuggestThreshold: Double,
      flags: [String: Bool]
    ) {
      self.engines = engines
      self.defaultLanguage = defaultLanguage
      self.meetingLanguages = meetingLanguages
      self.expectedSpeakers = expectedSpeakers
      self.voiceAutoThreshold = voiceAutoThreshold
      self.voiceSuggestThreshold = voiceSuggestThreshold
      self.flags = flags
    }

    @MainActor public init(settings: AppSettings) {
      self.init(
        engines: settings.engines,
        defaultLanguage: settings.defaultLanguage.rawValue,
        meetingLanguages: settings.meetingLanguageCodes,
        expectedSpeakers: settings.defaultExpectedSpeakers,
        voiceAutoThreshold: settings.voiceAutoThreshold,
        voiceSuggestThreshold: settings.voiceSuggestThreshold,
        flags: [
          "tenthsInTimecodes": settings.tenthsInTimecodes,
          "markOverlap": settings.markOverlap,
          "notifyOnCompletion": settings.notifyOnCompletion,
          "includeProjectContext": settings.includeProjectContext,
          // Адрес и модель не переносятся: у локального сервера может быть имя машины пользователя.
          "localLLMEnabled": settings.localLLMEnabled,
          "onboardingCompleted": settings.onboardingCompleted,
        ])
    }
  }

  public var generatedAt: Date
  public var appVersion: String
  public var system: SystemInfo
  public var settings: SettingsSnapshot
  public var models: [ModelEntry]
  public var modelsRoot: String
  public var selfTest: SelfTestReport?
  public var meetings: [MeetingEntry]
  public var projectCount: Int
  public var peopleCount: Int
  public var log: [AppLog.Entry]
  /// Почему журнал пуст (`OSLogStore` может быть недоступен) — иначе непонятно, что случилось.
  public var logProblem: String?
  public var memory: ProcessMemory.Snapshot?

  public init(
    generatedAt: Date = Date(),
    appVersion: String = MeetingScribeUIInfo.version,
    system: SystemInfo,
    settings: SettingsSnapshot,
    models: [ModelEntry],
    modelsRoot: String,
    selfTest: SelfTestReport? = nil,
    meetings: [MeetingEntry] = [],
    projectCount: Int = 0,
    peopleCount: Int = 0,
    log: [AppLog.Entry] = [],
    logProblem: String? = nil,
    memory: ProcessMemory.Snapshot? = nil
  ) {
    self.generatedAt = generatedAt
    self.appVersion = appVersion
    self.system = system
    self.settings = settings
    self.models = models
    self.modelsRoot = modelsRoot
    self.selfTest = selfTest
    self.meetings = meetings
    self.projectCount = projectCount
    self.peopleCount = peopleCount
    self.log = log
    self.logProblem = logProblem
    self.memory = memory ?? ProcessMemory.snapshot()
  }

  /// `problem-report-20260905-181233.json`.
  public var fileName: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "problem-report-\(formatter.string(from: generatedAt)).json"
  }

  public func json() throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  var object: [String: Any] {
    var report: [String: Any] = [
      "generatedAt": Self.timestamp.format(generatedAt),
      "app": appVersion,
      "system": systemObject,
      "settings": settingsObject,
      "models": ["root": modelsRoot, "items": models.map(modelObject)],
      "library": [
        "meetings": meetings.map(meetingObject),
        "projectCount": projectCount,
        "peopleCount": peopleCount,
      ],
      "log": log.map { entry -> [String: Any] in
        [
          "date": Self.timestamp.format(entry.date),
          "category": entry.category,
          "level": entry.level,
          "message": entry.message,
        ]
      },
    ]
    report["logProblem"] = logProblem
    if let selfTest { report["selfTest"] = selfTestObject(selfTest) }
    if let memory {
      report["memory"] = [
        "footprintBytes": memory.footprintBytes,
        "footprint": ProcessMemory.format(memory.footprintBytes),
        "peakResidentBytes": memory.peakResidentBytes,
        "peakResident": ProcessMemory.format(memory.peakResidentBytes),
      ]
    }
    return report
  }

  private var systemObject: [String: Any] {
    var object: [String: Any] = [
      "architecture": system.architecture,
      "isAppleSilicon": system.isAppleSilicon,
      "hasNeuralEngine": system.hasNeuralEngine,
      "physicalMemoryBytes": system.physicalMemoryBytes,
      "physicalMemory": ProcessMemory.format(system.physicalMemoryBytes),
      "activeProcessorCount": system.activeProcessorCount,
      "osVersion": system.osVersion,
    ]
    object["chip"] = system.chip
    object["model"] = system.modelIdentifier
    object["osBuild"] = system.osBuild
    object["gpu"] = system.gpuName
    return object
  }

  private var settingsObject: [String: Any] {
    var object: [String: Any] = [
      "asr": settings.engines.asr.rawValue,
      "whisperModel": settings.engines.whisperModel.rawValue,
      "engines": settings.engines.title,
      "defaultLanguage": settings.defaultLanguage,
      "meetingLanguages": settings.meetingLanguages,
      "voiceAutoThreshold": settings.voiceAutoThreshold,
      "voiceSuggestThreshold": settings.voiceSuggestThreshold,
      "flags": settings.flags,
    ]
    object["diarizer"] = settings.engines.diarizer?.rawValue
    object["expectedSpeakers"] = settings.expectedSpeakers
    return object
  }

  private func modelObject(_ entry: ModelEntry) -> [String: Any] {
    var object: [String: Any] = [
      "id": entry.id.rawValue,
      "repo": entry.id.hubRepo,
      "isPresent": entry.isPresent,
      "source": entry.source,
    ]
    object["sizeBytes"] = entry.sizeBytes
    object["revision"] = entry.revision
    object["downloadedAt"] = entry.downloadedAt.map(Self.timestamp.format)
    object["downloaderVersion"] = entry.downloaderVersion
    return object
  }

  private func meetingObject(_ entry: MeetingEntry) -> [String: Any] {
    var object: [String: Any] = [
      "id": entry.id.uuidString,
      "status": entry.status,
      "isMultiTrack": entry.isMultiTrack,
    ]
    object["failedStage"] = entry.failedStage
    object["durationSeconds"] = entry.durationSeconds.map { round($0 * 100) / 100 }
    object["utteranceCount"] = entry.utteranceCount
    object["speakerCount"] = entry.speakerCount
    return object
  }

  private func selfTestObject(_ report: SelfTestReport) -> [String: Any] {
    var object: [String: Any] = [
      "startedAt": Self.timestamp.format(report.startedAt),
      "totalSeconds": round(report.totalSeconds * 100) / 100,
      "passed": report.passed,
      "speakerCount": report.speakerCount,
      "utteranceCount": report.utteranceCount,
      "languages": report.languages,
      "foundKeywords": report.foundKeywords,
      "missingKeywords": report.missingKeywords,
      "engines": report.enginesTitle,
      "problems": report.problems,
      "stages": report.timings.map { timing -> [String: Any] in
        var stage: [String: Any] = [
          "stage": timing.stage.rawValue, "seconds": round(timing.seconds * 100) / 100,
        ]
        stage["audioSeconds"] = timing.audioSeconds.map { round($0 * 100) / 100 }
        return stage
      },
    ]
    // Предпросмотр реплик — это текст встроенного сэмпла, а не встречи пользователя: в отчёт не идёт.
    object["previewLineCount"] = report.preview.count
    object["peakMemoryBytes"] = report.peakMemoryBytes
    return object
  }

  private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}
