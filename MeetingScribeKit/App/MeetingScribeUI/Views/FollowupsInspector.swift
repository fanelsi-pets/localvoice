import Core
import Store
import SwiftUI

/// Inspector «Follow-up» (DESIGN.md §2, SPEC.md §3.6): follow-up проекта по хронологии встреч и кнопки
/// создать, вставить и открыть историю. Клик по строке открывает follow-up целиком в истории.
struct FollowupsInspector: View {
  @Bindable var model: AppModel
  let record: MeetingRecord

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
  }

  // MARK: - Встреча без проекта

  private var noProject: some View {
    ContentUnavailableView {
      Label("Встреча без проекта", systemImage: "folder.badge.questionmark")
    } description: {
      Text("Follow-up хранятся в проекте: он собирает follow-up всех своих встреч в одну историю.")
    } actions: {
      Menu("Переместить в проект") {
        ForEach(sortedProjects) { project in
          Button(project.name) { model.move(meeting: record.id, toProject: project.id) }
        }
        Divider()
        Button("Новый проект…") { model.beginCreatingProject() }
      }
      .fixedSize()
      .accessibilityIdentifier("context.moveToProject")
    }
  }

  // MARK: - Follow-up проекта

  @ViewBuilder private func content(project: ProjectRecord) -> some View {
    let timeline = model.followupTimeline(projectID: project.id)
    List {
      Section {
        header(project: project)
        buttons(projectID: project.id)
      }
      if timeline.isEmpty {
        Section {
          Text(
            "Follow-up этого проекта пока нет. Создайте его моделью или вставьте ответ модели на TranscribeFull — он сохранится здесь."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Section("Follow-up (\(timeline.count))") {
          ForEach(Array(timeline.enumerated()), id: \.element.id) { index, entry in
            followupRow(entry, position: index, projectID: project.id)
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
        .lineLimit(2)
      Text("\(count) встреч в проекте")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  /// Кнопки столбиком: инспектор узкий, и в один ряд длинные подписи не помещаются.
  private func buttons(projectID: UUID) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let generator = model.activeFollowupGenerator {
        Button("Создать follow-up", systemImage: "sparkles") {
          model.beginFollowupImport(meetingID: record.id, generate: true)
        }
        .disabled(!generator.isAvailable)
        .help(
          generator.unavailableReason
            ?? String(localized: "Отправить транскрипт модели и сохранить её ответ")
        )
        .accessibilityIdentifier("followup.generate.inspector")
      }
      Button("Вставить ответ модели…", systemImage: "doc.on.clipboard") {
        model.beginFollowupImport(meetingID: record.id)
      }
      .help("Вставить ответ модели на TranscribeFull и сохранить его в истории проекта")
      .accessibilityIdentifier("followup.import")
      Button("История follow-up…", systemImage: "clock.arrow.circlepath") {
        model.beginFollowupHistory(projectID: projectID)
      }
      .help("Follow-up встреч проекта по датам, целиком")
      .accessibilityIdentifier("followup.history")
    }
    .labelStyle(.titleOnly)
    .padding(.vertical, 2)
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
        Text(entry.meetingTitle)
          .lineLimit(2)
        Text(followupSubtitle(entry))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if entry.meetingID == record.id {
          Text("эта встреча")
            .font(.caption)
            .foregroundStyle(.tint)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("context.followup.\(position)")
  }

  /// «14 авг 2026 · follow-up от 15 авг».
  private func followupSubtitle(_ entry: FollowupTimelineEntry) -> String {
    var parts: [String] = []
    if let date = entry.meetingDate {
      parts.append(date.formatted(.dateTime.day().month(.abbreviated).year()))
    }
    let imported = entry.followup.importedAt.formatted(.dateTime.day().month(.abbreviated))
    parts.append(String(localized: "follow-up от \(imported)"))
    return parts.joined(separator: " · ")
  }

  private var sortedProjects: [ProjectRecord] {
    model.library.projects.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
  }
}
