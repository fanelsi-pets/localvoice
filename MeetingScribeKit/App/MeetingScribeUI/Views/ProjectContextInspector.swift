import Core
import Export
import Store
import SwiftUI

/// Inspector «Контекст проекта» (DESIGN.md §2, SPEC.md §3.6): история follow-up проекта по хронологии,
/// решения, задачи и вопросы. Отсюда же вставляется ответ модели — то, что наполняет этот список.
struct ProjectContextInspector: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  @State private var editing: MemoryEdit?
  @State private var draftText = ""

  var body: some View {
    Group {
      if let projectID = record.projectID, let project = model.library.project(id: projectID) {
        content(project: project)
      } else {
        noProject
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inspector.context")
    .alert("Править запись", isPresented: editingBinding) {
      TextField("Текст", text: $draftText)
      Button("Сохранить") {
        if let editing { model.updateMemory(editing, text: draftText) }
        editing = nil
      }
      Button("Отмена", role: .cancel) { editing = nil }
    }
  }

  // MARK: - Встреча без проекта

  private var noProject: some View {
    ContentUnavailableView {
      Label("Встреча без проекта", systemImage: "folder.badge.questionmark")
    } description: {
      Text(
        "Решения, задачи и вопросы хранятся в проекте: он объединяет встречи и даёт контекст следующим экспортам TranscribeFull."
      )
    } actions: {
      Menu("Переместить в проект") {
        ForEach(sortedProjects) { project in
          Button(project.name) { model.move(meeting: record.id, toProject: project.id) }
        }
        Divider()
        Button("Новый проект…") { model.beginCreatingProject() }
      }
      .accessibilityIdentifier("context.moveToProject")
    }
  }

  // MARK: - Контекст проекта

  @ViewBuilder private func content(project: ProjectRecord) -> some View {
    let decisions = model.library.decisions(in: project.id)
    let actions = model.library.actionItems(in: project.id)
    let questions = model.library.questions(in: project.id)
    let timeline = model.followupTimeline(projectID: project.id)
    // Инспектор показывает всю память проекта, но в шапку экспорта этой встречи идёт только то,
    // что раньше неё: остальное подписано «позже этой встречи».
    let inContext = model.contextItemIDs(forMeeting: record.id)
    if decisions.isEmpty, actions.isEmpty, questions.isEmpty, timeline.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        header(project: project)
        buttons
        ContentUnavailableView {
          Label("Пока пусто", systemImage: "text.quote")
        } description: {
          Text(
            "Вставьте ответ модели на TranscribeFull через «Вставить ответ модели…» — текст сохранится в истории проекта, а решения и задачи попадут в контекст следующих экспортов."
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      List {
        Section {
          header(project: project)
          buttons
        }
        if !timeline.isEmpty {
          Section("Follow-up (\(timeline.count))") {
            ForEach(Array(timeline.enumerated()), id: \.element.id) { index, entry in
              followupRow(entry, position: index, projectID: project.id)
            }
          }
        }
        Section("Решения (\(decisions.count))") {
          ForEach(Array(decisions.enumerated()), id: \.element.id) { index, decision in
            decisionRow(decision, position: index, isLater: !inContext.contains(decision.id))
          }
        }
        Section("Задачи (открытых \(actions.filter(\.isOpen).count) из \(actions.count))") {
          ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
            actionRow(item, position: index, isLater: !inContext.contains(item.id))
          }
        }
        Section("Вопросы (открытых \(questions.filter(\.isOpen).count) из \(questions.count))") {
          ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
            questionRow(question, position: index, isLater: !inContext.contains(question.id))
          }
        }
      }
    }
  }

  private func header(project: ProjectRecord) -> some View {
    let count = model.library.meetings(in: project.id).count
    return VStack(alignment: .leading, spacing: 2) {
      Label(project.name, systemImage: "folder")
        .font(.headline)
      Text("\(count) встреч в проекте")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var buttons: some View {
    HStack {
      Button("Вставить ответ модели…", systemImage: "text.badge.checkmark") {
        model.beginFollowupImport(meetingID: record.id)
      }
      .help(
        "Вставить ответ модели на TranscribeFull: текст сохранится в истории, решения, задачи и вопросы — в памяти проекта"
      )
      .accessibilityIdentifier("followup.import")
      if let projectID = record.projectID {
        Button("История follow-up…", systemImage: "clock.arrow.circlepath") {
          model.beginFollowupHistory(projectID: projectID)
        }
        .help("Follow-up прошлых встреч проекта по датам, целиком")
        .accessibilityIdentifier("followup.history")
      }
      if let generator = model.activeFollowupGenerator {
        Button("Создать follow-up", systemImage: "sparkles") {
          model.beginFollowupImport(meetingID: record.id, generate: true)
        }
        .disabled(!generator.isAvailable)
        .help(
          generator.unavailableReason
            ?? String(localized: "Отправить транскрипт модели и разобрать её ответ")
        )
        .accessibilityIdentifier("followup.generate.inspector")
      }
    }
    .labelStyle(.titleOnly)
  }

  // MARK: - Строки

  /// Follow-up в хронологии проекта: клик открывает историю на этой записи.
  private func followupRow(_ entry: FollowupTimelineEntry, position: Int, projectID: UUID)
    -> some View
  {
    Button {
      model.beginFollowupHistory(projectID: projectID, selecting: entry.id)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.meetingTitle).lineLimit(1)
        Text(followupSubtitle(entry))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("context.followup.\(position)")
  }

  /// «14 авг 2026 · follow-up от 15 авг · 3 решения · 2 задачи».
  private func followupSubtitle(_ entry: FollowupTimelineEntry) -> String {
    var parts: [String] = []
    if let date = entry.meetingDate {
      parts.append(date.formatted(.dateTime.day().month(.abbreviated).year()))
    }
    let imported = entry.followup.importedAt.formatted(.dateTime.day().month(.abbreviated))
    parts.append(String(localized: "follow-up от \(imported)"))
    parts.append(entry.countsText)
    return parts.joined(separator: " · ")
  }

  private func decisionRow(_ decision: DecisionRecord, position: Int, isLater: Bool) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(decision.text)
      HStack(spacing: 6) {
        Text(
          subtitle(meetingID: decision.meetingID, date: decision.meetingDate, isLater: isLater)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let timestamp = decision.timestamp, decision.meetingID != nil {
          Button(Timecode.hhmmss(timestamp)) { model.open(decision: decision.id) }
            .buttonStyle(.link)
            .font(.caption)
            .monospacedDigit()
            .accessibilityLabel("Перейти к реплике \(Timecode.hhmmss(timestamp))")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("context.decision.\(position)")
    .contextMenu {
      Button("Править…") { beginEditing(.decision(decision.id), text: decision.text) }
      Button("Перейти к реплике") { model.open(decision: decision.id) }
        .disabled(decision.timestamp == nil || decision.meetingID == nil)
      Divider()
      Button("Удалить", role: .destructive) { model.deleteDecision(decision.id) }
    }
  }

  private func actionRow(_ item: ActionItemRecord, position: Int, isLater: Bool) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(isOn: doneBinding(item)) {
        Text(item.text)
          .strikethrough(!item.isOpen)
      }
      .toggleStyle(.checkbox)
      .accessibilityLabel("Выполнена: \(item.text)")
      .accessibilityIdentifier("context.action.toggle.\(position)")
      Text(actionSubtitle(item, isLater: isLater))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("context.action.\(position)")
    .contextMenu {
      Button("Править…") { beginEditing(.action(item.id), text: item.text) }
      Button("Перейти к реплике") { model.open(meetingID: item.meetingID, timecode: nil) }
        .disabled(item.meetingID == nil)
      Divider()
      Button("Удалить", role: .destructive) { model.deleteActionItem(item.id) }
    }
  }

  private func questionRow(_ question: QuestionRecord, position: Int, isLater: Bool) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(isOn: answeredBinding(question)) {
        Text(question.text)
          .strikethrough(!question.isOpen)
      }
      .toggleStyle(.checkbox)
      .accessibilityLabel("Отвечено: \(question.text)")
      .accessibilityIdentifier("context.question.toggle.\(position)")
      Text(
        subtitle(meetingID: question.meetingID, date: question.meetingDate, isLater: isLater)
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("context.question.\(position)")
    .contextMenu {
      Button("Править…") { beginEditing(.question(question.id), text: question.text) }
      Divider()
      Button("Удалить", role: .destructive) { model.deleteQuestion(question.id) }
    }
  }

  // MARK: - Вспомогательное

  private var sortedProjects: [ProjectRecord] {
    model.library.projects.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
  }

  /// «14 авг 2026 · Синк по продукту» (+ «эта встреча» или «позже этой встречи»: последняя пометка
  /// говорит, что в контекст экспорта открытой встречи запись не пойдёт).
  private func subtitle(meetingID: UUID?, date: Date?, isLater: Bool) -> String {
    var parts: [String] = []
    if let date { parts.append(date.formatted(.dateTime.day().month(.abbreviated).year())) }
    if let meetingID, let meeting = model.library.meeting(id: meetingID) {
      parts.append(meeting.title)
    } else if meetingID != nil {
      parts.append(String(localized: "встреча удалена"))
    }
    if meetingID == record.id {
      parts.append(String(localized: "эта встреча"))
    } else if isLater {
      parts.append(String(localized: "позже этой встречи"))
    }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
  }

  private func actionSubtitle(_ item: ActionItemRecord, isLater: Bool) -> String {
    var parts: [String] = []
    if let owner = item.owner { parts.append(owner) }
    if let due = item.dueTitle { parts.append(String(localized: "до \(due)")) }
    if parts.isEmpty { parts.append(item.status.title) }
    parts.append(subtitle(meetingID: item.meetingID, date: item.meetingDate, isLater: isLater))
    return parts.joined(separator: " · ")
  }

  private func doneBinding(_ item: ActionItemRecord) -> Binding<Bool> {
    Binding(
      get: { !item.isOpen },
      set: { model.setActionItemDone(item.id, $0) })
  }

  private func answeredBinding(_ question: QuestionRecord) -> Binding<Bool> {
    Binding(
      get: { !question.isOpen },
      set: { model.setQuestionAnswered(question.id, $0) })
  }

  private func beginEditing(_ target: MemoryEdit, text: String) {
    draftText = text
    editing = target
  }

  private var editingBinding: Binding<Bool> {
    Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
  }
}

/// Какая запись памяти правится в диалоге «Править…».
nonisolated enum MemoryEdit: Hashable, Identifiable {
  case decision(UUID)
  case action(UUID)
  case question(UUID)

  var id: UUID {
    switch self {
    case .decision(let id), .action(let id), .question(let id): id
    }
  }
}

extension AppModel {
  /// Правка текста записи памяти из инспектора.
  func updateMemory(_ target: MemoryEdit, text: String) {
    switch target {
    case .decision(let id): updateDecision(id, text: text)
    case .action(let id): updateActionItem(id, text: text)
    case .question(let id): updateQuestion(id, text: text)
    }
  }
}
