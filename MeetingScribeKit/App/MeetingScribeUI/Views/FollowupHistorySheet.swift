import Core
import Export
import Store
import SwiftUI

/// История follow-up проекта (SPEC.md §3.6, DESIGN.md §5): слева — follow-up по хронологии встреч,
/// справа — выбранный целиком: резюме, разобранные пункты и полный текст ответа модели. Так follow-up
/// прошлой и текущей встречи лежат рядом и сравниваются по датам и названиям.
struct FollowupHistorySheet: View {
  @Bindable var model: AppModel
  let projectID: UUID
  @State private var selectedID: UUID?
  @State private var deleting: FollowupTimelineEntry?

  var body: some View {
    let entries = model.followupTimeline(projectID: projectID)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("История follow-up").font(.title3)
        if let project = model.library.project(id: projectID) {
          Text(project.name).foregroundStyle(.secondary)
        }
        Spacer()
        Text("Записей: \(entries.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if entries.isEmpty {
        ContentUnavailableView {
          Label("Follow-up пока нет", systemImage: "text.badge.checkmark")
        } description: {
          Text(
            "Вставьте ответ модели на TranscribeFull через меню «Follow-up» в шапке встречи — текст сохранится здесь целиком."
          )
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          List(selection: $selectedID) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
              row(entry, position: index).tag(entry.id)
            }
          }
          .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
          .accessibilityIdentifier("followupHistory.list")
          detail(entries: entries)
        }
      }
      footer(entries: entries)
    }
    .padding()
    .frame(minWidth: 880, minHeight: 560)
    .onAppear { selectedID = model.followupHistorySelectedID ?? defaultSelection(entries) }
    // Удалённая запись не должна оставаться «выбранной»: показываем соседнюю.
    .onChange(of: entries.map(\.id)) { _, ids in
      if let selectedID, !ids.contains(selectedID) { self.selectedID = defaultSelection(entries) }
    }
    .alert(
      "Удалить follow-up?", isPresented: deletingBinding, presenting: deleting
    ) { entry in
      Button("Удалить", role: .destructive) { model.removeFollowupImport(entry.id) }
      Button("Отмена", role: .cancel) {}
    } message: { entry in
      Text(
        "Follow-up встречи «\(entry.meetingTitle)» удалится вместе с решениями, задачами и вопросами, добавленными из него."
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("followupHistory.sheet")
  }

  // MARK: - Список

  private func row(_ entry: FollowupTimelineEntry, position: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(entry.meetingTitle).lineLimit(1)
      Text(dateLine(entry))
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(entry.countsText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("followupHistory.row.\(position)")
  }

  /// «14 авг 2026 · follow-up от 15 авг».
  private func dateLine(_ entry: FollowupTimelineEntry) -> String {
    var parts: [String] = []
    if let date = entry.meetingDate {
      parts.append(date.formatted(.dateTime.day().month(.abbreviated).year()))
    }
    let imported = entry.followup.importedAt.formatted(.dateTime.day().month(.abbreviated))
    parts.append(String(localized: "follow-up от \(imported)"))
    return parts.joined(separator: " · ")
  }

  // MARK: - Выбранный follow-up

  @ViewBuilder private func detail(entries: [FollowupTimelineEntry]) -> some View {
    if let entry = entries.first(where: { $0.id == selectedID }) {
      let decisions = model.library.decisions.filter { $0.followupID == entry.id }
      let actions = model.library.actionItems.filter { $0.followupID == entry.id }
      let questions = model.library.questions.filter { $0.followupID == entry.id }
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          Text(entry.meetingTitle).font(.headline)
          // Части уже локализованы и отформатированы — склейка не должна стать ключом каталога.
          Text(
            [
              meetingDateText(entry.meetingDate),
              String(localized: "сохранён \(meetingDateText(entry.followup.importedAt))"),
              entry.followup.source.title,
            ].joined(separator: " · ")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if let summary = entry.followup.summary, !summary.isEmpty {
            section("Резюме") { Text(summary) }
          }
          if !decisions.isEmpty {
            section("Решения") {
              ForEach(decisions) { decision in
                Text(
                  decision.timestamp.map { "\(decision.text) (\(Timecode.hhmmss($0)))" }
                    ?? decision.text)
              }
            }
          }
          if !actions.isEmpty {
            section("Задачи") {
              ForEach(actions) { item in
                Label {
                  Text(actionLine(item)).strikethrough(!item.isOpen)
                } icon: {
                  Image(systemName: item.isOpen ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(item.isOpen ? Color.secondary : Color.green)
                }
              }
            }
          }
          if !questions.isEmpty {
            section("Вопросы") {
              ForEach(questions) { question in
                Text(question.text).strikethrough(!question.isOpen)
              }
            }
          }
          if let raw = entry.followup.rawText, !raw.isEmpty {
            section("Текст ответа") {
              Text(raw)
                .font(.callout)
                .textSelection(.enabled)
                .accessibilityIdentifier("followupHistory.text")
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }
      .accessibilityIdentifier("followupHistory.detail")
    } else {
      ContentUnavailableView("Выберите follow-up", systemImage: "text.badge.checkmark")
    }
  }

  private func section<Content: View>(
    _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline.weight(.semibold))
      content()
    }
  }

  /// «Прислать смету — Иван, до 2026-09-10».
  private func actionLine(_ item: ActionItemRecord) -> String {
    var tail: [String] = []
    if let owner = item.owner { tail.append(owner) }
    if let due = item.dueTitle { tail.append(String(localized: "до \(due)")) }
    return tail.isEmpty ? item.text : "\(item.text) — \(tail.joined(separator: ", "))"
  }

  // MARK: - Футер

  private func footer(entries: [FollowupTimelineEntry]) -> some View {
    let entry = entries.first { $0.id == selectedID }
    return HStack {
      if let entry {
        Button("Перейти к встрече") {
          model.selectMeeting(entry.meetingID)
          close()
        }
        .disabled(model.library.meeting(id: entry.meetingID) == nil)
        Button("Скопировать текст") {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(entry.followup.rawText ?? "", forType: .string)
        }
        .disabled(entry.followup.rawText?.isEmpty ?? true)
        Button("Удалить follow-up…", role: .destructive) { deleting = entry }
          .accessibilityIdentifier("followupHistory.delete")
      }
      Spacer()
      Button("Закрыть") { close() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("followupHistory.close")
    }
  }

  // MARK: - Вспомогательное

  /// Первым показываем последний follow-up открытой встречи, иначе последний в проекте: прошлый
  /// стоит прямо над ним.
  private func defaultSelection(_ entries: [FollowupTimelineEntry]) -> UUID? {
    if let meetingID = model.selectedMeetingID,
      let own = entries.last(where: { $0.meetingID == meetingID })
    {
      return own.id
    }
    return entries.last?.id
  }

  private var deletingBinding: Binding<Bool> {
    Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
  }

  private func close() {
    model.followupHistoryProjectID = nil
    model.followupHistorySelectedID = nil
  }
}
