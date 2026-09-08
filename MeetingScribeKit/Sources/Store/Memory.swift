import Foundation

// Память проекта (фаза 4, SPEC.md §3.6): решения, задачи, вопросы и акты импорта follow-up.
// Записи привязаны к проекту и (обычно) к встрече-источнику, но переживают удаление встречи: строка
// «[дата] решили…» в контексте проекта должна оставаться, даже если запись встречи удалили с диска.
// Хранятся в `library.sqlite` (ADR-007) и попадают в полнотекстовый индекс `memory_index`.

/// Решение проекта, принятое на встрече (SPEC.md §3.6). Источник — импорт follow-up.
public struct DecisionRecord: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var projectID: UUID
  /// Встреча-источник; `nil` — решение добавлено вручную или встреча удалена из библиотеки.
  public var meetingID: UUID?
  /// Импорт, из которого пришла запись.
  public var followupID: UUID?
  public var text: String
  /// Таймкод реплики-источника, с от начала записи.
  public var timestamp: Double?
  /// Дата встречи-источника на момент импорта: строка «[дата]» в контексте проекта живёт и после
  /// удаления встречи.
  public var meetingDate: Date?
  public var createdAt: Date
  /// Порядок внутри одного импорта — модель возвращает решения списком, и порядок несёт смысл.
  public var order: Int

  public init(
    id: UUID = UUID(),
    projectID: UUID,
    meetingID: UUID? = nil,
    followupID: UUID? = nil,
    text: String,
    timestamp: Double? = nil,
    meetingDate: Date? = nil,
    createdAt: Date = Date(),
    order: Int = 0
  ) {
    self.id = id
    self.projectID = projectID
    self.meetingID = meetingID
    self.followupID = followupID
    self.text = text
    self.timestamp = timestamp
    self.meetingDate = meetingDate
    self.createdAt = createdAt
    self.order = order
  }
}

/// Состояние задачи: открыта или выполнена.
public enum ActionStatus: String, Codable, Sendable, CaseIterable {
  case open
  case done

  public var title: String {
    switch self {
    case .open: String(localized: "Открыта")
    case .done: String(localized: "Выполнена")
    }
  }
}

/// Задача проекта с ответственным и сроком (SPEC.md §3.6).
public struct ActionItemRecord: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var projectID: UUID
  public var meetingID: UUID?
  public var followupID: UUID?
  public var text: String
  /// Ответственный так, как его назвала модель.
  public var owner: String?
  /// Ответственный, сопоставленный с человеком из «Люди».
  public var ownerPersonID: UUID?
  /// Срок — день ISO 8601 `YYYY-MM-DD`, без времени и зоны (день, а не момент).
  public var due: String?
  /// Сырой срок, если разобрать в день не вышло («до пятницы»).
  public var dueText: String?
  public var status: ActionStatus
  public var meetingDate: Date?
  public var createdAt: Date
  public var completedAt: Date?
  public var order: Int

  public init(
    id: UUID = UUID(),
    projectID: UUID,
    meetingID: UUID? = nil,
    followupID: UUID? = nil,
    text: String,
    owner: String? = nil,
    ownerPersonID: UUID? = nil,
    due: String? = nil,
    dueText: String? = nil,
    status: ActionStatus = .open,
    meetingDate: Date? = nil,
    createdAt: Date = Date(),
    completedAt: Date? = nil,
    order: Int = 0
  ) {
    self.id = id
    self.projectID = projectID
    self.meetingID = meetingID
    self.followupID = followupID
    self.text = text
    self.owner = owner
    self.ownerPersonID = ownerPersonID
    self.due = due
    self.dueText = dueText
    self.status = status
    self.meetingDate = meetingDate
    self.createdAt = createdAt
    self.completedAt = completedAt
    self.order = order
  }

  public var isOpen: Bool { status == .open }

  /// Срок для показа: разобранный день, иначе сырой текст.
  public var dueTitle: String? { due ?? dueText }
}

/// Состояние вопроса: открыт или получен ответ.
public enum QuestionStatus: String, Codable, Sendable, CaseIterable {
  case open
  case answered

  public var title: String {
    switch self {
    case .open: String(localized: "Открыт")
    case .answered: String(localized: "Отвечен")
    }
  }
}

/// Открытый вопрос проекта (SPEC.md §3.6).
public struct QuestionRecord: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var projectID: UUID
  public var meetingID: UUID?
  public var followupID: UUID?
  public var text: String
  public var status: QuestionStatus
  public var meetingDate: Date?
  public var createdAt: Date
  public var answeredAt: Date?
  public var order: Int

  public init(
    id: UUID = UUID(),
    projectID: UUID,
    meetingID: UUID? = nil,
    followupID: UUID? = nil,
    text: String,
    status: QuestionStatus = .open,
    meetingDate: Date? = nil,
    createdAt: Date = Date(),
    answeredAt: Date? = nil,
    order: Int = 0
  ) {
    self.id = id
    self.projectID = projectID
    self.meetingID = meetingID
    self.followupID = followupID
    self.text = text
    self.status = status
    self.meetingDate = meetingDate
    self.createdAt = createdAt
    self.answeredAt = answeredAt
    self.order = order
  }

  public var isOpen: Bool { status == .open }
}

/// Откуда пришёл follow-up: вставлен пользователем или сгенерирован локальной моделью (SPEC.md §3.6).
public enum FollowupSource: String, Codable, Sendable {
  case pasted
  case localLLM
  /// Провайдер приложения-хоста (ADR-010: LocalVoice — Gemini).
  case hostModel

  public var title: String {
    switch self {
    case .pasted: String(localized: "Вставлен вручную")
    case .localLLM: String(localized: "Локальная модель")
    case .hostModel: String(localized: "Модель приложения-хоста")
    }
  }
}

/// Акт импорта follow-up: чей ответ, к какой встрече, что распознано. Хранит сырой текст, чтобы
/// разбор можно было повторить другим парсером, не прося ответ модели заново.
public struct FollowupRecord: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var projectID: UUID
  public var meetingID: UUID
  public var importedAt: Date
  public var source: FollowupSource
  /// Как разобрали ответ: `jsonBlock` (блок ```meeting-followup```) или `markdownSections`.
  public var method: String?
  public var summary: String?
  public var rawText: String?

  public init(
    id: UUID = UUID(),
    projectID: UUID,
    meetingID: UUID,
    importedAt: Date = Date(),
    source: FollowupSource = .pasted,
    method: String? = nil,
    summary: String? = nil,
    rawText: String? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.meetingID = meetingID
    self.importedAt = importedAt
    self.source = source
    self.method = method
    self.summary = summary
    self.rawText = rawText
  }
}

// MARK: - Память проекта в библиотеке

extension Library {
  /// Решения проекта по возрастанию: дата встречи (без неё — дата записи), затем `createdAt`, затем
  /// порядок внутри импорта. Так «Контекст проекта» в экспорте читается хронологически.
  public func decisions(in projectID: UUID) -> [DecisionRecord] {
    decisions.filter { $0.projectID == projectID }.sorted(by: Self.chronologically)
  }

  public func actionItems(in projectID: UUID) -> [ActionItemRecord] {
    actionItems.filter { $0.projectID == projectID }.sorted(by: Self.chronologically)
  }

  /// Невыполненные задачи проекта — раздел «Открытые задачи» экспорта.
  public func openActionItems(in projectID: UUID) -> [ActionItemRecord] {
    actionItems(in: projectID).filter(\.isOpen)
  }

  public func questions(in projectID: UUID) -> [QuestionRecord] {
    questions.filter { $0.projectID == projectID }.sorted(by: Self.chronologically)
  }

  public func openQuestions(in projectID: UUID) -> [QuestionRecord] {
    questions(in: projectID).filter(\.isOpen)
  }

  /// Follow-up проекта по времени сохранения; хронологию по встречам строит приложение — оно знает
  /// даты встреч (`AppModel.followupTimeline`).
  public func followups(in projectID: UUID) -> [FollowupRecord] {
    followups.filter { $0.projectID == projectID }
      .sorted { ($0.importedAt, $0.id.uuidString) < ($1.importedAt, $1.id.uuidString) }
  }

  /// Импорты follow-up встречи, старые сверху.
  public func followups(for meetingID: UUID) -> [FollowupRecord] {
    followups.filter { $0.meetingID == meetingID }
      .sorted { ($0.importedAt, $0.id.uuidString) < ($1.importedAt, $1.id.uuidString) }
  }

  public func decision(id: UUID) -> DecisionRecord? { decisions.first { $0.id == id } }
  public func actionItem(id: UUID) -> ActionItemRecord? { actionItems.first { $0.id == id } }
  public func question(id: UUID) -> QuestionRecord? { questions.first { $0.id == id } }
  public func followup(id: UUID) -> FollowupRecord? { followups.first { $0.id == id } }

  public mutating func upsert(_ decision: DecisionRecord) {
    if let index = decisions.firstIndex(where: { $0.id == decision.id }) {
      decisions[index] = decision
    } else {
      decisions.append(decision)
    }
  }

  public mutating func upsert(_ item: ActionItemRecord) {
    if let index = actionItems.firstIndex(where: { $0.id == item.id }) {
      actionItems[index] = item
    } else {
      actionItems.append(item)
    }
  }

  public mutating func upsert(_ question: QuestionRecord) {
    if let index = questions.firstIndex(where: { $0.id == question.id }) {
      questions[index] = question
    } else {
      questions.append(question)
    }
  }

  public mutating func upsert(_ followup: FollowupRecord) {
    if let index = followups.firstIndex(where: { $0.id == followup.id }) {
      followups[index] = followup
    } else {
      followups.append(followup)
    }
  }

  public mutating func removeDecision(id: UUID) { decisions.removeAll { $0.id == id } }
  public mutating func removeActionItem(id: UUID) { actionItems.removeAll { $0.id == id } }
  public mutating func removeQuestion(id: UUID) { questions.removeAll { $0.id == id } }

  /// Убирает акт импорта; сами решения, задачи и вопросы остаются (после импорта они живут своей жизнью).
  public mutating func removeFollowup(id: UUID) { followups.removeAll { $0.id == id } }

  /// Отменяет импорт целиком: акт и всё, что он принёс.
  public mutating func removeImport(followupID: UUID) {
    followups.removeAll { $0.id == followupID }
    decisions.removeAll { $0.followupID == followupID }
    actionItems.removeAll { $0.followupID == followupID }
    questions.removeAll { $0.followupID == followupID }
  }

  /// Память проекта: всё, что относится к проекту, включая акты импорта.
  mutating func removeMemory(projectID: UUID) {
    decisions.removeAll { $0.projectID == projectID }
    actionItems.removeAll { $0.projectID == projectID }
    questions.removeAll { $0.projectID == projectID }
    followups.removeAll { $0.projectID == projectID }
  }

  static func chronologically(_ lhs: some MemoryRecord, _ rhs: some MemoryRecord) -> Bool {
    let left = lhs.meetingDate ?? lhs.createdAt
    let right = rhs.meetingDate ?? rhs.createdAt
    if left != right { return left < right }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    if lhs.order != rhs.order { return lhs.order < rhs.order }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

/// Общая часть записей памяти: сортировка и индексация одинаковы для решений, задач и вопросов.
public protocol MemoryRecord: Identifiable, Hashable, Sendable where ID == UUID {
  var projectID: UUID { get }
  var meetingID: UUID? { get }
  var text: String { get }
  var meetingDate: Date? { get }
  var createdAt: Date { get }
  var order: Int { get }
}

extension DecisionRecord: MemoryRecord {}
extension ActionItemRecord: MemoryRecord {}
extension QuestionRecord: MemoryRecord {}
