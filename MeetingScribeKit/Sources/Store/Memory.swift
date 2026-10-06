import Foundation

// История follow-up проекта (SPEC.md §3.6): тексты follow-up, сохранённые к встречам проекта.
// Хранятся в `library.sqlite` (ADR-007). Решения, задачи и вопросы из ответа модели больше не
// выделяются: follow-up — это документ целиком. Таблицы `decisions`, `action_items`, `questions` и
// `memory_index` прежних версий остаются в файле нетронутыми, приложение их не читает и не пишет.

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

/// Follow-up встречи в истории проекта: чей ответ, к какой встрече и сам текст документа.
public struct FollowupRecord: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var projectID: UUID
  public var meetingID: UUID
  public var importedAt: Date
  public var source: FollowupSource
  public var rawText: String?

  public init(
    id: UUID = UUID(),
    projectID: UUID,
    meetingID: UUID,
    importedAt: Date = Date(),
    source: FollowupSource = .pasted,
    rawText: String? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.meetingID = meetingID
    self.importedAt = importedAt
    self.source = source
    self.rawText = rawText
  }
}

// MARK: - История follow-up в библиотеке

extension Library {
  /// Follow-up проекта по времени сохранения; хронологию по встречам строит приложение — оно знает
  /// даты встреч (`AppModel.followupTimeline`).
  public func followups(in projectID: UUID) -> [FollowupRecord] {
    followups.filter { $0.projectID == projectID }
      .sorted { ($0.importedAt, $0.id.uuidString) < ($1.importedAt, $1.id.uuidString) }
  }

  /// Follow-up встречи, старые сверху.
  public func followups(for meetingID: UUID) -> [FollowupRecord] {
    followups.filter { $0.meetingID == meetingID }
      .sorted { ($0.importedAt, $0.id.uuidString) < ($1.importedAt, $1.id.uuidString) }
  }

  public func followup(id: UUID) -> FollowupRecord? { followups.first { $0.id == id } }

  public mutating func upsert(_ followup: FollowupRecord) {
    if let index = followups.firstIndex(where: { $0.id == followup.id }) {
      followups[index] = followup
    } else {
      followups.append(followup)
    }
  }

  public mutating func removeFollowup(id: UUID) { followups.removeAll { $0.id == id } }

  /// История follow-up уходит вместе с проектом: вне проекта она не показывается.
  mutating func removeFollowups(projectID: UUID) {
    followups.removeAll { $0.projectID == projectID }
  }
}
