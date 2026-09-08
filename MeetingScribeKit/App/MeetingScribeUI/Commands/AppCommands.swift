import Store
import SwiftUI

/// Меню-бар (DESIGN.md §6): у каждого действия есть пункт меню и шорткат; недоступные пункты выключены.
struct AppCommands: Commands {
  @Bindable var model: AppModel
  @Environment(\.openSettings) private var openSettings

  var body: some Commands {
    // «Проверить обновления…» — под «О программе», как принято в macOS (Sparkle, ADR-009).
    CommandGroup(after: .appInfo) {
      if model.updater.isAvailable {
        Button("Проверить обновления…") { model.updater.checkForUpdates() }
          .disabled(!model.updater.canCheckForUpdates)
      }
    }

    CommandGroup(replacing: .newItem) {
      Button("Новый проект") { model.beginCreatingProject() }
        .keyboardShortcut("n", modifiers: .command)
      Button("Импортировать…") { model.isFileImporterPresented = true }
        .keyboardShortcut("o", modifiers: .command)
    }

    CommandGroup(after: .newItem) {
      Menu("Экспорт") {
        Group {
          Button("Скопировать TranscribeFull") { model.copyTranscribeFull() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
          Button("Сохранить .md…") { model.saveMarkdown() }
            .keyboardShortcut("e", modifiers: .command)
          Button("Сохранить SRT…") { model.saveSRT() }
          Button("Сохранить JSON…") { model.saveJSON() }
        }
        .disabled(!model.canExport)
        Divider()
        // Vault — по проекту открытой встречи, а при выборе «Все встречи» — по всей библиотеке.
        Button("Vault для Obsidian…") { model.beginVaultExport(scope: model.vaultScope) }
          .keyboardShortcut("e", modifiers: [.command, .shift])
          .disabled(!model.canExportVault(model.vaultScope) || model.vaultExport.isExporting)
      }
      Button("Follow-up: вставить ответ модели…") {
        if let id = model.selectedMeetingID { model.beginFollowupImport(meetingID: id) }
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .disabled(!model.canImportFollowup)
      Button("Follow-up: история проекта…") {
        if let projectID = model.selectedMeeting?.projectID {
          model.beginFollowupHistory(projectID: projectID)
        }
      }
      .disabled(!model.canShowFollowupHistory)
      Button("Показать в Finder") {
        if let id = model.selectedMeetingID { model.revealMeetingSource(id) }
      }
      .disabled(model.selectedMeeting == nil)
      Divider()
    }

    CommandGroup(after: .pasteboard) {
      Button("Найти") { model.focusSearch() }
        .keyboardShortcut("f", modifiers: .command)
      Button("Искать по библиотеке") { model.focusLibrarySearch() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
      Button("Переназначить спикера…") { model.beginReassigningSelectedRow() }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(model.selectedRowID == nil)
    }

    CommandGroup(after: .sidebar) {
      Button(
        isSidebarVisible
          ? String(localized: "Скрыть боковую панель")
          : String(localized: "Показать боковую панель")
      ) {
        model.columnVisibility = isSidebarVisible ? .detailOnly : .all
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      Button(
        model.isInspectorPresented
          ? String(localized: "Скрыть инспектор") : String(localized: "Показать инспектор")
      ) {
        model.isInspectorPresented.toggle()
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      Toggle("Показать языки", isOn: languageBadges)
      Toggle("Показать наложения", isOn: overlapMarkers)
      Divider()
    }

    CommandMenu("Встреча") {
      Button(processTitle) {
        if let id = model.selectedMeetingID { model.process(id) }
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(!canProcess)

      Button("Отменить обработку") {
        if let id = model.selectedMeetingID { model.cancel(id) }
      }
      .keyboardShortcut(".", modifiers: .command)
      .disabled(model.selectedMeeting?.status.isActive != true)

      Divider()

      // Пробел обрабатывает список транскрипта (`onKeyPress`): шорткат меню без модификаторов
      // перехватывал бы пробел в поле поиска и в именах спикеров.
      Button(
        model.playback.isPlaying
          ? String(localized: "Пауза") : String(localized: "Воспроизвести (пробел в транскрипте)")
      ) {
        model.playback.togglePlayPause()
      }
      .disabled(!model.playback.isAvailable)

      Button("Перейти к таймкоду…") { model.isGoToTimecodePresented = true }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(model.displayRows.isEmpty)

      Divider()

      Button("Найти имена на видео") {
        if let id = model.selectedMeetingID { model.scanVideoForNames(meetingID: id) }
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(!model.canScanVideoForNames)
      Button("Показать спикеров в инспекторе") { model.showSpeakersInspector() }
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(model.selectedMeeting == nil)
      Button("Показать сведения в инспекторе") {
        model.inspectorTab = .details
        model.isInspectorPresented = true
      }
      .keyboardShortcut("2", modifiers: [.command, .option])
      .disabled(model.selectedMeeting == nil)
      Button("Показать контекст проекта в инспекторе") {
        model.inspectorTab = .projectContext
        model.isInspectorPresented = true
      }
      .keyboardShortcut("3", modifiers: [.command, .option])
      .disabled(model.selectedMeeting == nil)
    }

    CommandGroup(replacing: .help) {
      Button(HelpTopic.guide.title) { model.presentedHelp = .guide }
      Button(HelpTopic.zoomTracks.title) { model.presentedHelp = .zoomTracks }
      // Онбординг открывается на том шаге, где его закрыли (SPEC.md §2 п. 8).
      Button("Первый запуск…") { model.onboarding.present() }
      Button("Диагностика") {
        model.settingsTab = .diagnostics
        openSettings()
      }
      Button("Показать папку диагностики") {
        model.revealInFinder(model.store.diagnosticsDirectory)
      }
    }
  }

  private var isSidebarVisible: Bool {
    model.columnVisibility != .detailOnly
  }

  private var canProcess: Bool {
    guard let record = model.selectedMeeting else { return false }
    return model.canProcess(record)
  }

  private var processTitle: String {
    switch model.selectedMeeting?.status {
    case .ready?, .cancelled?, .failed?, .interrupted?: String(localized: "Повторить обработку")
    default: String(localized: "Обработать")
    }
  }

  private var languageBadges: Binding<Bool> {
    Binding(
      get: { model.settings.showLanguageBadges },
      set: { model.settings.showLanguageBadges = $0 })
  }

  private var overlapMarkers: Binding<Bool> {
    Binding(
      get: { model.settings.showOverlapMarkers },
      set: { model.settings.showOverlapMarkers = $0 })
  }
}
