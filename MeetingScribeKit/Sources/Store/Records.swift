import Core
import Foundation
import Voices

// Записи библиотеки встреч (фазы 2–3). Хранятся в `library.sqlite` через `LibraryStore` (фаза 4, ADR-007);
// транскрипты остаются файлами `meetings/<id>/transcript.json`. `Library` — снимок индекса в памяти:
// он же читается из старого `library.json` при миграции и он же экспортируется как JSON.

/// Проект — группа встреч в sidebar (SPEC.md §2 п. 6). Контекст проекта (решения, задачи) — фаза 4.
public struct ProjectRecord: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var name: String
  public var createdAt: Date

  public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
  }
}

/// Состояние встречи в библиотеке (DESIGN.md §3b «Состояния и их вид»).
public enum MeetingStatus: Hashable, Codable, Sendable {
  /// Импортирована, обработка не запускалась.
  case imported
  case queued
  case processing
  case ready
  /// Отменена пользователем; частичный транскрипт может быть сохранён.
  case cancelled
  /// Ошибка на стадии (`nil` — стадия неизвестна) с понятной причиной.
  case failed(stage: Stage?, message: String)
  /// Приложение закрылось во время обработки или ожидания в очереди — при загрузке библиотеки
  /// активные статусы демотируются сюда.
  case interrupted

  /// Обработка идёт или ждёт очереди.
  public var isActive: Bool {
    switch self {
    case .queued, .processing: true
    default: false
    }
  }

  /// Текст статус-бейджа.
  public var title: String {
    switch self {
    case .imported: String(localized: "Не обработано")
    case .queued: String(localized: "В очереди")
    case .processing: String(localized: "Обрабатывается")
    case .ready: String(localized: "Готово")
    case .cancelled: String(localized: "Отменено")
    case .failed: String(localized: "Ошибка")
    case .interrupted: String(localized: "Прервано")
    }
  }
}

/// Встреча в библиотеке: источник, параметры обработки, статус и сводка для sidebar.
/// Имена спикеров живут здесь, а не в транскрипте: транскрипт — неизменяемый результат прогона,
/// имена применяются проекцией `Transcript.applyingSpeakerNames` при показе и экспорте.
public struct MeetingRecord: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var projectID: UUID?
  public var title: String
  /// Дата и время встречи (не обработки).
  public var date: Date?
  public var sourceURL: URL
  /// Длительность записи, с: из заголовка контейнера при импорте, уточняется после обработки.
  public var duration: Double?
  public var expectedSpeakers: Int?
  public var language: LanguageChoice
  public var engines: EngineSelection
  public var status: MeetingStatus
  public var createdAt: Date
  public var processedAt: Date?
  /// Фактическое время последней обработки, с.
  public var processingSeconds: Double?
  public var utteranceCount: Int?
  public var speakerCount: Int?
  /// Сопоставления спикеров с именами и людьми (фаза 3, SPEC.md §3.4); имена фазы 2 читаются как
  /// подтверждённые пользователем.
  public var speakerAssignments: [Int: SpeakerAssignment]
  /// Раздельные дорожки участников Zoom (`Audio Record/`); пусто — обрабатывается `sourceURL` целиком.
  public var trackURLs: [URL]
  /// Видеофайл записи для распознавания подписей (сам `sourceURL`, если это видео, либо `video*.mp4` рядом).
  public var videoURL: URL?
  /// `chat.txt` записи — подсказки имён.
  public var chatURL: URL?
  /// На диске есть `transcript.json` (полный или частичный после отмены).
  public var hasTranscript: Bool
  /// Транскрипт частичный — собран из ленты при отмене.
  public var isPartialTranscript: Bool

  public init(
    id: UUID = UUID(),
    projectID: UUID? = nil,
    title: String,
    date: Date? = nil,
    sourceURL: URL,
    duration: Double? = nil,
    expectedSpeakers: Int? = nil,
    language: LanguageChoice = .auto,
    engines: EngineSelection = .accurate,
    status: MeetingStatus = .imported,
    createdAt: Date = Date(),
    processedAt: Date? = nil,
    processingSeconds: Double? = nil,
    utteranceCount: Int? = nil,
    speakerCount: Int? = nil,
    speakerNames: [Int: String] = [:],
    speakerAssignments: [Int: SpeakerAssignment] = [:],
    trackURLs: [URL] = [],
    videoURL: URL? = nil,
    chatURL: URL? = nil,
    hasTranscript: Bool = false,
    isPartialTranscript: Bool = false
  ) {
    self.id = id
    self.projectID = projectID
    self.title = title
    self.date = date
    self.sourceURL = sourceURL
    self.duration = duration
    self.expectedSpeakers = expectedSpeakers
    self.language = language
    self.engines = engines
    self.status = status
    self.createdAt = createdAt
    self.processedAt = processedAt
    self.processingSeconds = processingSeconds
    self.utteranceCount = utteranceCount
    self.speakerCount = speakerCount
    var assignments = speakerAssignments
    for (speakerID, name) in speakerNames where assignments[speakerID] == nil {
      assignments[speakerID] = .user(name)
    }
    self.speakerAssignments = assignments
    self.trackURLs = trackURLs
    self.videoURL = videoURL
    self.chatURL = chatURL
    self.hasTranscript = hasTranscript
    self.isPartialTranscript = isPartialTranscript
  }

  /// Применённые имена спикеров (заданные, подтверждённые или присвоенные автоматически) по номеру спикера —
  /// проекция для `Transcript.applyingSpeakerNames`. Запись — через `speakerAssignments`.
  public var speakerNames: [Int: String] {
    get {
      Dictionary(
        uniqueKeysWithValues: speakerAssignments.compactMap { key, value in
          value.trimmedName.map { (key, $0) }
        })
    }
    set {
      // Запись через проекцию — действие пользователя: имя подтверждено, автоматика его не перепишет.
      for (speakerID, name) in newValue {
        var assignment = speakerAssignments[speakerID] ?? SpeakerAssignment()
        if assignment.name != name || assignment.source != .user {
          assignment.name = name
          assignment.source = .user
          assignment.isConfirmed = true
        }
        speakerAssignments[speakerID] = assignment
      }
      for speakerID in speakerAssignments.keys where newValue[speakerID] == nil {
        speakerAssignments[speakerID]?.name = nil
        speakerAssignments[speakerID]?.isConfirmed = false
      }
    }
  }

  /// Запись обработана по раздельным дорожкам Zoom (SPEC.md §2 п. 7).
  public var isMultiTrack: Bool { !trackURLs.isEmpty }

  // MARK: - Codable

  // Словари с целочисленными ключами кодируются объектами со строковыми ключами: `JSONEncoder` превращает
  // `[Int: …]` в плоский массив, и library.json перестаёт читаться руками. Необязательные поля — с умолчаниями,
  // чтобы старые файлы открывались после добавления полей.
  enum CodingKeys: String, CodingKey {
    case id, projectID, title, date, sourceURL, duration, expectedSpeakers, language, engines,
      status
    case createdAt, processedAt, processingSeconds, utteranceCount, speakerCount, speakerNames
    case speakerAssignments, trackURLs, videoURL, chatURL
    case hasTranscript, isPartialTranscript
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
    title = try container.decode(String.self, forKey: .title)
    date = try container.decodeIfPresent(Date.self, forKey: .date)
    sourceURL = try container.decode(URL.self, forKey: .sourceURL)
    duration = try container.decodeIfPresent(Double.self, forKey: .duration)
    expectedSpeakers = try container.decodeIfPresent(Int.self, forKey: .expectedSpeakers)
    language = try container.decodeIfPresent(LanguageChoice.self, forKey: .language) ?? .auto
    engines = try container.decodeIfPresent(EngineSelection.self, forKey: .engines) ?? .accurate
    status = try container.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .imported
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    processedAt = try container.decodeIfPresent(Date.self, forKey: .processedAt)
    processingSeconds = try container.decodeIfPresent(Double.self, forKey: .processingSeconds)
    utteranceCount = try container.decodeIfPresent(Int.self, forKey: .utteranceCount)
    speakerCount = try container.decodeIfPresent(Int.self, forKey: .speakerCount)
    // Фаза 2 хранила только имена: они читаются как подтверждённые пользователем сопоставления.
    var assignments = try SpeakerAssignment.decodeMap(from: container)
    let names = try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
    for (key, name) in names {
      guard let speakerID = Int(key), assignments[speakerID] == nil else { continue }
      assignments[speakerID] = .user(name)
    }
    speakerAssignments = assignments
    trackURLs = try container.decodeIfPresent([URL].self, forKey: .trackURLs) ?? []
    videoURL = try container.decodeIfPresent(URL.self, forKey: .videoURL)
    chatURL = try container.decodeIfPresent(URL.self, forKey: .chatURL)
    hasTranscript = try container.decodeIfPresent(Bool.self, forKey: .hasTranscript) ?? false
    isPartialTranscript =
      try container.decodeIfPresent(Bool.self, forKey: .isPartialTranscript) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(projectID, forKey: .projectID)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(date, forKey: .date)
    try container.encode(sourceURL, forKey: .sourceURL)
    try container.encodeIfPresent(duration, forKey: .duration)
    try container.encodeIfPresent(expectedSpeakers, forKey: .expectedSpeakers)
    try container.encode(language, forKey: .language)
    try container.encode(engines, forKey: .engines)
    try container.encode(status, forKey: .status)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(processedAt, forKey: .processedAt)
    try container.encodeIfPresent(processingSeconds, forKey: .processingSeconds)
    try container.encodeIfPresent(utteranceCount, forKey: .utteranceCount)
    try container.encodeIfPresent(speakerCount, forKey: .speakerCount)
    try SpeakerAssignment.encodeMap(speakerAssignments, into: &container)
    if !trackURLs.isEmpty { try container.encode(trackURLs, forKey: .trackURLs) }
    try container.encodeIfPresent(videoURL, forKey: .videoURL)
    try container.encodeIfPresent(chatURL, forKey: .chatURL)
    try container.encode(hasTranscript, forKey: .hasTranscript)
    try container.encode(isPartialTranscript, forKey: .isPartialTranscript)
  }
}

/// Индекс библиотеки: проекты, встречи, люди (голосовые профили, фаза 3) и память проекта — решения,
/// задачи, вопросы, импорты follow-up (фаза 4). Порядок записей — порядок добавления; интерфейс сортирует сам.
public struct Library: Hashable, Codable, Sendable {
  /// 2 — фаза 3: `people`, сопоставления спикеров в записях встреч; 3 — фаза 4: память проекта в SQLite.
  /// Файлы версий 1 и 2 читаются (недостающие поля — пустые).
  public static let currentSchemaVersion = 3

  public var schemaVersion: Int
  public var projects: [ProjectRecord]
  public var meetings: [MeetingRecord]
  public var people: [PersonRecord]
  /// Память проекта (SPEC.md §3.6): решения, задачи и вопросы переживают удаление встречи-источника.
  public var decisions: [DecisionRecord]
  public var actionItems: [ActionItemRecord]
  public var questions: [QuestionRecord]
  public var followups: [FollowupRecord]

  public init(
    projects: [ProjectRecord] = [],
    meetings: [MeetingRecord] = [],
    people: [PersonRecord] = [],
    decisions: [DecisionRecord] = [],
    actionItems: [ActionItemRecord] = [],
    questions: [QuestionRecord] = [],
    followups: [FollowupRecord] = []
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.projects = projects
    self.meetings = meetings
    self.people = people
    self.decisions = decisions
    self.actionItems = actionItems
    self.questions = questions
    self.followups = followups
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Миграция выполняется прямо при чтении (имена → сопоставления), поэтому в памяти — текущая версия.
    _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
    schemaVersion = Self.currentSchemaVersion
    projects = try container.decodeIfPresent([ProjectRecord].self, forKey: .projects) ?? []
    meetings = try container.decodeIfPresent([MeetingRecord].self, forKey: .meetings) ?? []
    people = try container.decodeIfPresent([PersonRecord].self, forKey: .people) ?? []
    decisions = try container.decodeIfPresent([DecisionRecord].self, forKey: .decisions) ?? []
    actionItems = try container.decodeIfPresent([ActionItemRecord].self, forKey: .actionItems) ?? []
    questions = try container.decodeIfPresent([QuestionRecord].self, forKey: .questions) ?? []
    followups = try container.decodeIfPresent([FollowupRecord].self, forKey: .followups) ?? []
  }

  public static let empty = Library()

  public func meeting(id: UUID) -> MeetingRecord? {
    meetings.first { $0.id == id }
  }

  public func project(id: UUID) -> ProjectRecord? {
    projects.first { $0.id == id }
  }

  public func person(id: UUID) -> PersonRecord? {
    people.first { $0.id == id }
  }

  /// Человек по имени (без учёта регистра и пробелов по краям).
  public func person(named name: String) -> PersonRecord? {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return people.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
  }

  /// Люди по имени, для списка «Люди» и автодополнения.
  public var peopleByName: [PersonRecord] {
    people.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
  }

  /// Встречи, где человек сопоставлен спикеру.
  public func meetings(with personID: UUID) -> [MeetingRecord] {
    meetings.filter { $0.speakerAssignments.values.contains { $0.personID == personID } }
      .sorted(by: Self.newestFirst)
  }

  /// Встречи проекта (`nil` — без проекта), новые сверху: по дате встречи, затем по дате добавления.
  public func meetings(in projectID: UUID?) -> [MeetingRecord] {
    meetings.filter { $0.projectID == projectID }.sorted(by: Self.newestFirst)
  }

  /// Все встречи, новые сверху.
  public var meetingsNewestFirst: [MeetingRecord] {
    meetings.sorted(by: Self.newestFirst)
  }

  public static func newestFirst(_ lhs: MeetingRecord, _ rhs: MeetingRecord) -> Bool {
    let left = lhs.date ?? lhs.createdAt
    let right = rhs.date ?? rhs.createdAt
    if left != right { return left > right }
    return lhs.createdAt > rhs.createdAt
  }

  /// Добавляет встречу или заменяет запись с тем же `id`.
  public mutating func upsert(_ meeting: MeetingRecord) {
    if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
      meetings[index] = meeting
    } else {
      meetings.append(meeting)
    }
  }

  public mutating func upsert(_ project: ProjectRecord) {
    if let index = projects.firstIndex(where: { $0.id == project.id }) {
      projects[index] = project
    } else {
      projects.append(project)
    }
  }

  public mutating func upsert(_ person: PersonRecord) {
    if let index = people.firstIndex(where: { $0.id == person.id }) {
      people[index] = person
    } else {
      people.append(person)
    }
  }

  /// Удаляет встречу и её образцы голоса. Память проекта не трогается: решение, принятое на встрече,
  /// остаётся в контексте проекта вместе с датой встречи (SPEC.md §3.6).
  public mutating func removeMeeting(id: UUID) {
    meetings.removeAll { $0.id == id }
    for index in people.indices {
      people[index].removeSamples(meetingID: id)
    }
  }

  /// Кандидаты сопоставления в пространстве эмбеддингов (люди с отпечатками этого движка).
  public func voiceCandidates(space: String) -> [VoiceCandidate] {
    people.compactMap { $0.candidate(space: space) }
  }

  /// Удаляет человека; сопоставления в встречах теряют ссылку на него, имена остаются.
  public mutating func removePerson(id: UUID) {
    people.removeAll { $0.id == id }
    for meetingIndex in meetings.indices {
      for speakerID in meetings[meetingIndex].speakerAssignments.keys {
        if meetings[meetingIndex].speakerAssignments[speakerID]?.personID == id {
          meetings[meetingIndex].speakerAssignments[speakerID]?.personID = nil
        }
        if meetings[meetingIndex].speakerAssignments[speakerID]?.suggestion?.personID == id {
          meetings[meetingIndex].speakerAssignments[speakerID]?.suggestion = nil
        }
      }
    }
  }

  /// Удаляет проект; его встречи остаются в библиотеке без проекта, а память проекта (решения, задачи,
  /// вопросы, импорты) уходит вместе с ним — она осмысленна только внутри проекта.
  public mutating func removeProject(id: UUID) {
    projects.removeAll { $0.id == id }
    for index in meetings.indices where meetings[index].projectID == id {
      meetings[index].projectID = nil
    }
    removeMemory(projectID: id)
  }

  /// Активные статусы после перезапуска приложения означают прерванную обработку: обработчика уже нет,
  /// а строка «Обрабатывается» с живой полосой без задачи вводила бы в заблуждение.
  public func demotingInterrupted() -> Library {
    var copy = self
    for index in copy.meetings.indices where copy.meetings[index].status.isActive {
      copy.meetings[index].status = .interrupted
    }
    return copy
  }
}
