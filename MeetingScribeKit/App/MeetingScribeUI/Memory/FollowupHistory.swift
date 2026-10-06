import Core
import Export
import Foundation
import Store

/// Строка истории follow-up проекта: запись с названием и датой встречи.
nonisolated public struct FollowupTimelineEntry: Identifiable, Hashable, Sendable {
  public var followup: FollowupRecord
  public var meetingTitle: String
  /// Дата встречи (без неё — дата сохранения записи); `nil` — встреча удалена.
  public var meetingDate: Date?

  public init(followup: FollowupRecord, meetingTitle: String, meetingDate: Date?) {
    self.followup = followup
    self.meetingTitle = meetingTitle
    self.meetingDate = meetingDate
  }

  public var id: UUID { followup.id }
  public var meetingID: UUID { followup.meetingID }
}

/// История follow-up проекта (SPEC.md §3.6): сгенерированный или вставленный follow-up сохраняется
/// к встрече целиком — без разбора на решения, задачи и вопросы. Всё пишется в тот же снимок
/// `library` и сохраняется обычным `saveLibrary()` (`LibraryStore` пишет разницу).
extension AppModel {

  /// Часовой пояс дат экспорта (TranscribeFull, заметки Obsidian).
  nonisolated public static let contextTimeZone: TimeZone = .current

  // MARK: - Сохранение follow-up

  /// Открывает диалог follow-up для встречи (⌘⇧I и кнопки в инспекторе); `generate` — сразу
  /// запустить генерацию.
  public func beginFollowupImport(meetingID: UUID, generate: Bool = false) {
    followupStartsGeneration = generate
    followupImportMeetingID = meetingID
  }

  /// Встреча, для которой можно открыть follow-up: открытая, с транскриптом.
  public var canImportFollowup: Bool {
    guard let id = selectedMeetingID else { return false }
    return transcripts[id] != nil || library.meeting(id: id)?.hasTranscript == true
  }

  /// Сохраняет текст follow-up в историю проекта встречи. Тот же текст у той же встречи повторно
  /// не записывается. `nil` — встречи нет, она вне проекта (об этом сообщает `alert`) или текст пуст.
  @discardableResult
  public func saveFollowup(_ text: String, meetingID: UUID, source: FollowupSource = .pasted)
    -> FollowupRecord?
  {
    guard let record = library.meeting(id: meetingID), let text = Self.cleaned(text) else {
      return nil
    }
    guard let projectID = record.projectID else {
      alert = AppAlert(
        title: String(localized: "Встреча не в проекте"),
        message: String(
          localized:
            "Follow-up хранятся в истории проекта. Выберите проект в диалоге follow-up или переместите встречу в проект из боковой панели."
        ))
      return nil
    }
    if let existing = library.followups(for: meetingID).first(where: {
      Self.cleaned($0.rawText) == text
    }) {
      return existing
    }
    let followup = FollowupRecord(
      projectID: projectID, meetingID: meetingID, source: source, rawText: text)
    library.upsert(followup)
    saveLibrary()
    return followup
  }

  /// Сохранение из диалога: запись, закрытие диалога и история проекта на этом follow-up.
  @discardableResult
  public func finishFollowup(_ text: String, meetingID: UUID, source: FollowupSource = .pasted)
    -> FollowupRecord?
  {
    guard let followup = saveFollowup(text, meetingID: meetingID, source: source) else {
      return nil
    }
    followupImportMeetingID = nil
    followupStartsGeneration = false
    if selectedMeetingID != meetingID { selectMeeting(meetingID) }
    inspectorTab = .followups
    isInspectorPresented = true
    return followup
  }

  // MARK: - История follow-up

  /// Follow-up проекта по хронологии встреч: дата встречи, затем время сохранения. Так follow-up
  /// прошлой и текущей встречи стоят рядом и сравниваются по датам и названиям.
  public func followupTimeline(projectID: UUID) -> [FollowupTimelineEntry] {
    library.followups(in: projectID)
      .map { followup in
        let meeting = library.meeting(id: followup.meetingID)
        return FollowupTimelineEntry(
          followup: followup,
          meetingTitle: meeting?.title ?? String(localized: "встреча удалена"),
          meetingDate: meeting.map { $0.date ?? $0.createdAt })
      }
      .sorted { lhs, rhs in
        (lhs.meetingDate ?? lhs.followup.importedAt, lhs.followup.importedAt, lhs.id.uuidString)
          < (rhs.meetingDate ?? rhs.followup.importedAt, rhs.followup.importedAt, rhs.id.uuidString)
      }
  }

  /// Открывает историю follow-up проекта; `followupID` — какую запись показать первой.
  public func beginFollowupHistory(projectID: UUID, selecting followupID: UUID? = nil) {
    followupHistorySelectedID = followupID
    followupHistoryProjectID = projectID
  }

  /// История доступна, когда открытая встреча лежит в проекте.
  public var canShowFollowupHistory: Bool {
    selectedMeeting?.projectID != nil
  }

  public func removeFollowup(_ followupID: UUID) {
    library.removeFollowup(id: followupID)
    saveLibrary()
  }

  // MARK: - Общее

  /// Текст без пробелов по краям; пустой — `nil`.
  static func cleaned(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return text
  }
}
