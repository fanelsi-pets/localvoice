import Core
import Export
import Store
import SwiftUI

/// Боковая панель (DESIGN.md §2): проекты со встречами, внизу «Все встречи» и «Люди». Строка проекта
/// раскрывается кликом по названию, а не только по треугольнику. В тулбаре секции — действия над
/// библиотекой: «Импорт…» и «Новый проект». В строке обрабатываемой встречи — тонкая определённая
/// полоса и процент (SPEC.md §3.7 п. 8).
struct SidebarView: View {
  @Bindable var model: AppModel
  @State private var renamingProject: ProjectRecord?
  @State private var projectDraftName = ""
  @State private var renamingMeeting: MeetingRecord?
  @State private var meetingDraftTitle = ""

  var body: some View {
    List(selection: $model.selection) {
      Section("Проекты") {
        ForEach(sortedProjects) { project in
          DisclosureGroup(isExpanded: expansion(of: project.id)) {
            meetingRows(model.library.meetings(in: project.id))
          } label: {
            DisclosureRowLabel(
              title: project.name, systemImage: "folder", isExpanded: expansion(of: project.id)
            )
            .accessibilityIdentifier("project.row.\(project.id.uuidString)")
            .contextMenu {
              Button("Переименовать…") {
                projectDraftName = project.name
                renamingProject = project
              }
              Button("Удалить…", role: .destructive) {
                model.requestDelete(project: project.id)
              }
            }
          }
        }
        if !model.library.meetings(in: nil).isEmpty {
          DisclosureGroup(isExpanded: $model.isUnfiledExpanded) {
            meetingRows(model.library.meetings(in: nil))
          } label: {
            DisclosureRowLabel(
              title: String(localized: "Без проекта"), systemImage: "tray",
              isExpanded: $model.isUnfiledExpanded
            )
            .accessibilityIdentifier("project.row.unfiled")
          }
        }
      }
      Section {
        Label("Все встречи", systemImage: "list.bullet.rectangle")
          .tag(SidebarSelection.allMeetings)
        Label("Люди", systemImage: "person.2")
          .tag(SidebarSelection.people)
      }
    }
    .accessibilityIdentifier("sidebar.list")
    .toolbar {
      // Импорт — действие над библиотекой, поэтому живёт в секции боковой панели рядом с «Новый проект»,
      // а не рядом с названием открытой встречи; подпись видна всегда, без неё иконку принимали за
      // «скачать». Второй путь — File → Импортировать… (⌘O) и перетаскивание файлов в окно.
      ToolbarItem {
        Button {
          model.isFileImporterPresented = true
        } label: {
          Label("Импорт…", systemImage: "square.and.arrow.down")
        }
        .labelStyle(.titleAndIcon)
        .help("Импортировать запись Zoom или папку записи")
        .accessibilityIdentifier("import.button")
      }
      ToolbarItem {
        Button("Новый проект", systemImage: "folder.badge.plus") {
          model.beginCreatingProject()
        }
        .accessibilityIdentifier("project.new")
      }
    }
    .alert("Новый проект", isPresented: $model.isCreatingProject) {
      TextField("Название", text: $model.newProjectName)
      Button("Создать") { model.createProject(named: model.newProjectName) }
      Button("Отмена", role: .cancel) {}
    }
    .alert("Переименовать проект", isPresented: renamingProjectBinding) {
      TextField("Название", text: $projectDraftName)
      Button("Сохранить") {
        if let project = renamingProject { model.renameProject(project.id, to: projectDraftName) }
        renamingProject = nil
      }
      Button("Отмена", role: .cancel) { renamingProject = nil }
    }
    .alert("Переименовать встречу", isPresented: renamingMeetingBinding) {
      TextField("Название", text: $meetingDraftTitle)
      Button("Сохранить") {
        if let meeting = renamingMeeting {
          model.rename(meeting: meeting.id, to: meetingDraftTitle)
        }
        renamingMeeting = nil
      }
      Button("Отмена", role: .cancel) { renamingMeeting = nil }
    }
  }

  private var sortedProjects: [ProjectRecord] {
    model.library.projects.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
  }

  @ViewBuilder private func meetingRows(_ records: [MeetingRecord]) -> some View {
    ForEach(records) { record in
      MeetingSidebarRow(model: model, record: record)
        .accessibilityIdentifier("sidebar.meeting.\(record.id.uuidString)")
        .tag(SidebarSelection.meeting(record.id))
        .contextMenu {
          Button("Переименовать…") {
            meetingDraftTitle = record.title
            renamingMeeting = record
          }
          Menu("Переместить в проект") {
            Button("Без проекта") { model.move(meeting: record.id, toProject: nil) }
            ForEach(sortedProjects) { project in
              Button(project.name) { model.move(meeting: record.id, toProject: project.id) }
            }
          }
          Button(
            record.status == .ready
              ? String(localized: "Повторить обработку") : String(localized: "Обработать")
          ) {
            model.process(record.id)
          }
          .disabled(!model.canProcess(record))
          Button("Показать в Finder") { model.revealInFinder(record.sourceURL) }
          Divider()
          Button("Удалить…", role: .destructive) { model.requestDelete(meeting: record.id) }
        }
    }
  }

  private func expansion(of projectID: UUID) -> Binding<Bool> {
    Binding(
      get: { model.expandedProjects.contains(projectID) },
      set: { isExpanded in
        if isExpanded {
          model.expandedProjects.insert(projectID)
        } else {
          model.expandedProjects.remove(projectID)
        }
      })
  }

  private var renamingProjectBinding: Binding<Bool> {
    Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })
  }

  private var renamingMeetingBinding: Binding<Bool> {
    Binding(get: { renamingMeeting != nil }, set: { if !$0 { renamingMeeting = nil } })
  }
}

/// Заголовок группы в боковой панели: кликабельна вся строка, а не только треугольник (как в Finder
/// и Mail); раскрытие переключается тем же binding, что и у `DisclosureGroup`.
private struct DisclosureRowLabel: View {
  let title: String
  let systemImage: String
  @Binding var isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      if reduceMotion {
        isExpanded.toggle()
      } else {
        withAnimation { isExpanded.toggle() }
      }
    } label: {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Строка встречи: название, дата и длительность, бейдж статуса; во время обработки — полоса и подпись.
struct MeetingSidebarRow: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(record.title)
        .lineLimit(1)
      HStack(spacing: 6) {
        Text(shortDate)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(durationText(record.duration))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Spacer()
        StatusBadge(status: record.status)
      }
      if let progress = model.coordinator.progress(for: record.id), record.status.isActive {
        ProgressView(value: progress.barValue)
          .progressViewStyle(.linear)
          .controlSize(.small)
          .animation(reduceMotion ? nil : .default, value: progress.barValue)
          .accessibilityLabel("Прогресс обработки")
          .accessibilityValue("\(progress.percent) %")
        Text(caption(for: progress))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  /// Название, дата, статус и — во время обработки — процент: VoiceOver слышит прогресс, не открывая встречу.
  private var accessibilityDescription: String {
    var parts = [record.title, shortDate, record.status.title]
    if record.status.isActive, let progress = model.coordinator.progress(for: record.id) {
      parts.append(caption(for: progress))
    }
    return parts.joined(separator: ", ")
  }

  private var shortDate: String {
    guard let date = record.date ?? Optional(record.createdAt) else { return "—" }
    return date.formatted(.dateTime.day().month(.abbreviated).year())
  }

  private func caption(for progress: MeetingProgressModel) -> String {
    if let position = progress.queuePosition {
      return String(localized: "В очереди · \(position)")
    }
    return progress.sidebarCaption
  }
}
