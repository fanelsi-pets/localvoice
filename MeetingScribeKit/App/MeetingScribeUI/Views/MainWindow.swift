import Core
import Store
import SwiftUI
import UniformTypeIdentifiers

/// Содержимое главного окна: `NavigationSplitView` — боковая панель проектов и встреч, экран встречи,
/// инспектор (DESIGN.md §2–§3b). Перетаскивание файлов работает на всём окне.
struct MainWindow: View {
  @Bindable var model: AppModel
  @State private var isDropTargeted = false
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    splitView
      .frame(minWidth: 900, minHeight: 560)
      .searchable(
        text: $model.searchText, placement: .toolbar, prompt: model.searchScope.prompt
      )
      .searchScopes($model.searchScope, activation: .onSearchPresentation) {
        ForEach(SearchScope.allCases, id: \.self) { scope in
          Text(scope.title).tag(scope)
        }
      }
      .searchFocused($isSearchFocused)
      .onChange(of: model.searchFocusRequests) { _, _ in isSearchFocused = true }
      .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
        DropSupport.handle(providers, model: model)
      }
      .task { await model.bootstrap() }
      // Модальные сцены и панели файлов вынесены в модификаторы: одно выражение с ними целиком
      // компилятор проверяет типами непозволительно долго.
      .modifier(MainWindowSheets(model: model))
      .modifier(MainWindowAlert(model: model))
      .modifier(MainWindowFilePanels(model: model))
  }

  private var splitView: some View {
    NavigationSplitView(columnVisibility: $model.columnVisibility) {
      SidebarView(model: model)
        // `max` держит разделитель в окне; `min` 290 — ширина, при которой «Импорт…» с подписью,
        // «Новый проект» и переключатель панели ещё помещаются в тулбаре секции (иначе уходят в «»»).
        .navigationSplitViewColumnWidth(min: 290, ideal: 300, max: 420)
    } detail: {
      MeetingContentView(model: model)
        // Колонка встречи берёт предложенную ширину, а не минимум содержимого: иначе split view при
        // перетаскивании разделителя не сжимает колонку, а выходит за окно (сайдбар обрезан слева,
        // транскрипт — справа). Явного минимума у колонки нет намеренно: при открытом инспекторе он
        // складывался с шириной инспектора (480 + 320 > окно − сайдбар), NSSplitView во время
        // перетаскивания соблюдал сумму минимумов и снова выходил за окно; в 1.0.1 это кончалось
        // падением AppKit в раскладке (EXC_BAD_ACCESS в NSSplitView mouseDown).
        .frame(minWidth: 0, maxWidth: .infinity)
        .navigationTitle(model.selectedMeeting?.title ?? model.windowTitle)
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $model.isInspectorPresented) {
          InspectorView(model: model)
            .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbar { toolbarContent }
    }
  }

  private var subtitle: String {
    guard let record = model.selectedMeeting else { return "" }
    return "\(meetingDateText(record.date)) · \(durationText(record.duration))"
  }

  // «Импорт…» — в тулбаре боковой панели (`SidebarView`): действие над библиотекой, а не над встречей.
  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    ToolbarItem {
      processButton
    }
    ToolbarItem {
      if let progress = model.toolbarProgress, !progress.isFinished {
        ProcessingToolbarStatus(model: model, progress: progress)
      }
    }
    ToolbarItem {
      // Скачивание моделей продолжается при свёрнутом онбординге (SPEC.md §3.7 п. 8, 10).
      if model.modelDownloads.isActive, !model.onboarding.isPresented {
        ModelDownloadStatus(model: model)
      }
    }
    ToolbarItem(placement: .primaryAction) {
      exportMenu
    }
    ToolbarItem(placement: .primaryAction) {
      Button("Инспектор", systemImage: "sidebar.trailing") {
        model.isInspectorPresented.toggle()
      }
      .help("Показать или скрыть инспектор")
      .accessibilityIdentifier("inspector.toggle")
    }
    // Индикатор «Обработка на этом Mac» в тулбаре читался как ещё одна кнопка рядом с инспектором —
    // он остаётся в пустом состоянии окна и в диалоге follow-up, где у него есть подпись.
  }

  @ViewBuilder private var processButton: some View {
    if let record = model.selectedMeeting {
      if record.status.isActive {
        Button("Отменить", systemImage: "xmark.circle") { model.cancel(record.id) }
          .help("Отменить обработку встречи")
          .accessibilityIdentifier("process.button")
      } else {
        Button(
          record.status == .ready
            ? String(localized: "Повторить обработку") : String(localized: "Обработать"),
          systemImage: "play.fill"
        ) {
          model.process(record.id)
        }
        .help("Запустить обработку встречи")
        .accessibilityIdentifier("process.button")
      }
    }
  }

  private var exportMenu: some View {
    Menu {
      Group {
        Button("Скопировать TranscribeFull") { model.copyTranscribeFull() }
          .accessibilityIdentifier("export.copy")
        Button("Сохранить .md…") { model.saveMarkdown() }
          .accessibilityIdentifier("export.saveMarkdown")
        Button("Сохранить SRT…") { model.saveSRT() }
          .accessibilityIdentifier("export.saveSRT")
        Button("Сохранить JSON…") { model.saveJSON() }
          .accessibilityIdentifier("export.saveJSON")
      }
      .disabled(!model.canExport)
      Divider()
      // Vault собирается по проекту или по всей библиотеке — он доступен и без открытой встречи.
      Button("Vault для Obsidian…") { model.beginVaultExport(scope: model.vaultScope) }
        .disabled(!model.canExportVault(model.vaultScope) || model.vaultExport.isExporting)
        .accessibilityIdentifier("export.vault")
    } label: {
      Label("Экспорт", systemImage: "square.and.arrow.up")
    }
    .disabled(!model.canExport && !model.canExportVault(model.vaultScope))
    .help("Скопировать или сохранить транскрипт, собрать vault для Obsidian")
    .accessibilityIdentifier("export.menu")
  }
}

/// Модальные сцены главного окна (DESIGN.md §5): импорт, переход к таймкоду, спикеры, справка, follow-up.
private struct MainWindowSheets: ViewModifier {
  @Bindable var model: AppModel

  func body(content: Content) -> some View {
    content
      .sheet(item: $model.pendingImport) { request in
        ImportSheet(model: model, request: request)
      }
      .sheet(isPresented: $model.isGoToTimecodePresented) {
        GoToTimecodeSheet(model: model)
      }
      .sheet(item: $model.reassignRow) { row in
        if let meetingID = model.selectedMeetingID {
          ReassignSpeakerSheet(model: model, meetingID: meetingID, row: row)
        }
      }
      .sheet(item: $model.presentedHelp) { topic in
        HelpSheet(topic: topic)
      }
      .sheet(isPresented: followupImportBinding) {
        if let meetingID = model.followupImportMeetingID {
          FollowupImportSheet(model: model, meetingID: meetingID)
        }
      }
      .sheet(isPresented: followupHistoryBinding) {
        if let projectID = model.followupHistoryProjectID {
          FollowupHistorySheet(model: model, projectID: projectID)
        }
      }
      // Экспорт vault по всей библиотеке — это секунды работы: полоса, пульс и отмена вместо
      // замороженного окна (SPEC.md §3.7).
      .sheet(isPresented: vaultExportBinding) {
        VaultExportSheet(model: model)
      }
      // Первый запуск (SPEC.md §2 п. 8): открывается сам, пока онбординг не пройден; закрытие sheet
      // не отменяет скачивание моделей — оно продолжается со статусом в тулбаре.
      .sheet(isPresented: onboardingBinding) {
        OnboardingSheet(model: model)
      }
  }

  /// Онбординг живёт в своём контроллере (`let` в модели), поэтому связывание — через замыкания.
  private var onboardingBinding: Binding<Bool> {
    Binding(
      get: { model.onboarding.isPresented },
      set: { model.onboarding.isPresented = $0 })
  }

  /// Панель прогресса открыта, пока идёт экспорт; закрытие панели отменяет его.
  private var vaultExportBinding: Binding<Bool> {
    Binding(
      get: { model.vaultExport.isExporting },
      set: { if !$0 { model.vaultExport.cancel() } })
  }

  /// Диалог «Follow-up из ответа модели» открыт для встречи `followupImportMeetingID`.
  private var followupImportBinding: Binding<Bool> {
    Binding(
      get: { model.followupImportMeetingID != nil },
      set: { if !$0 { model.followupImportMeetingID = nil } })
  }

  /// История follow-up открыта для проекта `followupHistoryProjectID`.
  private var followupHistoryBinding: Binding<Bool> {
    Binding(
      get: { model.followupHistoryProjectID != nil },
      set: {
        if !$0 {
          model.followupHistoryProjectID = nil
          model.followupHistorySelectedID = nil
        }
      })
  }
}

/// Сообщения и подтверждения (DESIGN.md §1): действие выполняет модель по идентификатору из значения.
private struct MainWindowAlert: ViewModifier {
  @Bindable var model: AppModel

  func body(content: Content) -> some View {
    content.alert(
      model.alert?.title ?? "",
      isPresented: Binding(
        get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
      presenting: model.alert
    ) { alert in
      buttons(for: alert)
    } message: { alert in
      if let message = alert.message { Text(message) }
    }
  }

  @ViewBuilder private func buttons(for alert: AppAlert) -> some View {
    switch alert.kind {
    case .message:
      Button("ОК", role: .cancel) {}
    case .confirmDeleteMeeting(let id):
      Button("Удалить", role: .destructive) { model.delete(meeting: id) }
      Button("Отмена", role: .cancel) {}
    case .confirmDeleteProject(let id):
      Button("Удалить", role: .destructive) { model.deleteProject(id) }
      Button("Отмена", role: .cancel) {}
    case .confirmDeletePerson(let id):
      Button("Удалить", role: .destructive) { model.deletePerson(id) }
      Button("Отмена", role: .cancel) {}
    case .confirmRenamePerson(let personID, let newName, let meetingID, let speakerID):
      Button("Переименовать везде") {
        model.renamePersonEverywhereAndConfirm(
          personID: personID, newName: newName, meetingID: meetingID, speakerID: speakerID)
      }
      Button("Это другой человек") {
        model.markAsNewPerson(speakerID, meetingID: meetingID, name: newName)
      }
      Button("Отмена", role: .cancel) {}
    case .confirmMergeSpeakers(let source, let target, let meetingID):
      Button("Объединить", role: .destructive) {
        model.mergeSpeakers(source, into: target, meetingID: meetingID)
      }
      Button("Отмена", role: .cancel) {}
    case .revealFile(let url):
      Button("Показать в Finder") { model.revealInFinder(url) }
      Button("ОК", role: .cancel) {}
    }
  }
}

/// Панели файлов: импорт записей, папка vault для Obsidian, сохранение транскрипта.
private struct MainWindowFilePanels: ViewModifier {
  @Bindable var model: AppModel

  func body(content: Content) -> some View {
    content
      .fileImporter(
        isPresented: $model.isFileImporterPresented,
        allowedContentTypes: [.audiovisualContent, .folder],
        allowsMultipleSelection: true
      ) { result in
        switch result {
        case .success(let urls):
          model.importURLs(urls)
        case .failure(let error):
          model.alert = AppAlert(
            title: String(localized: "Файл не открылся"), message: error.localizedDescription)
        }
      }
      .fileImporter(
        isPresented: $model.isVaultFolderPickerPresented,
        allowedContentTypes: [.folder]
      ) { result in
        model.finishVaultFolderSelection(result.map { $0 })
      }
      // Панель могла закрыться и без колбэка: область экспорта не должна пережить её.
      .onChange(of: model.isVaultFolderPickerPresented) { _, presented in
        if !presented { model.forgetPendingVaultScope() }
      }
      .fileExporter(
        isPresented: Binding(
          get: { model.exportRequest != nil }, set: { if !$0 { model.exportRequest = nil } }),
        document: model.exportRequest?.document ?? TranscriptDocument(text: "", format: .markdown),
        contentType: model.exportRequest?.format.contentType ?? ExportFormat.markdown.contentType,
        defaultFilename: model.exportRequest?.defaultFilename
      ) { result in
        model.finishExport(result.map { $0 })
      }
  }
}
