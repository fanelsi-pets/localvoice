import AppKit
import Core
import Export
import Store
import SwiftUI

/// «Follow-up из ответа модели» (DESIGN.md §5, SPEC.md §3.6): вставленный или сгенерированный локально
/// ответ модели сохраняется в историю проекта целиком, парсер разбирает решения, задачи и вопросы,
/// пользователь отмечает и правит пункты, и они уходят в память проекта.
struct FollowupImportSheet: View {
  @Bindable var model: AppModel
  let meetingID: UUID

  @State private var text = ""
  @State private var parsed = ParsedFollowup()
  @State private var decisions: [DraftItem] = []
  @State private var actions: [DraftItem] = []
  @State private var questions: [DraftItem] = []
  @State private var source: FollowupSource = .pasted
  @State private var projectChoice: ProjectChoice = .none
  @State private var newProjectName = ""
  @State private var isExporting = false

  /// Один пункт предпросмотра: включён ли он и что именно запишется.
  private struct DraftItem: Identifiable, Hashable {
    var id: Int
    var isOn = true
    var text: String
    var owner = ""
    var due = ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Follow-up из ответа модели").font(.title3)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(
        "Вставьте ответ Claude на TranscribeFull целиком: текст сохранится в истории проекта, а решения, задачи и вопросы будут распознаны и добавлены в его память."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Form {
        if record?.projectID == nil { projectSection }
        answerSection
        previewSections
      }
      .formStyle(.grouped)
      footer
    }
    .padding()
    .frame(minWidth: 560, minHeight: 520)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("followup.sheet")
    .fileExporter(
      isPresented: $isExporting,
      document: TranscriptDocument(text: text, contentType: ExportFormat.markdown.contentType),
      contentType: ExportFormat.markdown.contentType,
      defaultFilename: exportFileName
    ) { _ in }
    .onAppear {
      if model.followupStartsGeneration {
        model.followupStartsGeneration = false
        model.startFollowupGeneration(meetingID: meetingID)
      }
    }
    // Во время генерации показываем растущий ответ, но не разбираем его на каждой дельте:
    // разбор чинит JSON и пробует markdown — на незакрытом блоке это лишняя работа главного актора.
    .onChange(of: model.followupGeneration.text) { _, generated in
      guard !generated.isEmpty else { return }
      source = generatedSource
      text = generated
    }
    .onChange(of: model.followupGeneration.finishedText) { _, finished in
      guard let finished, !finished.isEmpty else { return }
      source = generatedSource
      text = finished
      reparse()
    }
  }

  /// Чей ответ: провайдера хоста или локальной модели (для истории follow-up).
  private var generatedSource: FollowupSource {
    model.followupGenerator != nil ? .hostModel : .localLLM
  }

  private var followupLanguage: Binding<FollowupLanguage> {
    Binding(
      get: { model.settings.followupLanguage },
      set: { model.settings.followupLanguage = $0 })
  }

  /// `[YYYY-MM-DD]_[Проект]_follow-up_имена_и_поручения.md` — формат из инструкции генерации.
  private var exportFileName: String {
    FollowupGenerationPrompt.fileName(
      date: record?.date ?? record?.createdAt,
      project: record.flatMap { model.projectName(for: $0) },
      language: model.settings.followupLanguage)
  }

  private func copyText() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  // MARK: - Проект

  @ViewBuilder private var projectSection: some View {
    Section("Проект") {
      Picker("Проект", selection: $projectChoice) {
        Text("Не выбран").tag(ProjectChoice.none)
        ForEach(sortedProjects) { project in
          Text(project.name).tag(ProjectChoice.existing(project.id))
        }
        Text("Новый проект").tag(ProjectChoice.new)
      }
      .accessibilityIdentifier("followup.project")
      if projectChoice == .new {
        TextField("Название проекта", text: $newProjectName)
          .accessibilityIdentifier("followup.newProjectName")
      }
      Text("Решения и задачи хранятся в проекте: встреча переедет в выбранный проект.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Ответ модели

  @ViewBuilder private var answerSection: some View {
    Section("Ответ модели") {
      TextEditor(text: $text)
        .font(.body.monospaced())
        // Длинный ответ прокручивается внутри поля: предпросмотр и футер остаются под рукой.
        .frame(minHeight: 120, maxHeight: 360)
        .onChange(of: text) { _, _ in
          // Ручной ввод и вставка; ответ модели разбирается по окончании генерации.
          guard !model.followupGeneration.isRunning else { return }
          reparse()
        }
        .accessibilityLabel("Ответ модели на TranscribeFull")
        .accessibilityIdentifier("followup.text")
      HStack {
        // Стандартная кнопка вставки: системного запроса «Разрешить вставку» она не вызывает
        // и сама выключается, когда в буфере нет текста.
        PasteButton(payloadType: String.self) { strings in
          guard let pasted = strings.first(where: { !$0.isEmpty }) else { return }
          source = .pasted
          text = pasted
        }
        .accessibilityIdentifier("followup.paste")
        .accessibilityLabel("Вставить ответ модели из буфера обмена")
        Button("Очистить") {
          text = ""
          reparse()
        }
        .disabled(text.isEmpty)
        if let generator = model.activeFollowupGenerator {
          if model.followupGeneration.isRunning {
            Button("Отменить", role: .cancel) {
              model.followupGeneration.cancel()
              // Отмена — не окончание: разбираем то, что модель успела прислать.
              reparse()
            }
            .accessibilityIdentifier("followup.cancelGeneration")
          } else {
            Picker("Язык follow-up", selection: followupLanguage) {
              ForEach(FollowupLanguage.allCases, id: \.self) { language in
                Text(language.title).tag(language)
              }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("followup.language")
            Button("Сгенерировать (\(generator.title))") {
              model.startFollowupGeneration(meetingID: meetingID)
            }
            .disabled(!generator.isAvailable)
            .help(
              generator.unavailableReason
                ?? String(localized: "Отправить транскрипт модели и разобрать её ответ")
            )
            .accessibilityIdentifier("followup.generate")
          }
        }
      }
      if !text.isEmpty, !model.followupGeneration.isRunning {
        HStack {
          Button("Скопировать follow-up") { copyText() }
            .accessibilityIdentifier("followup.copy")
          Button("Сохранить .md…") { isExporting = true }
            .accessibilityIdentifier("followup.save")
        }
      }
      if model.followupGeneration.isRunning {
        // Признаки живости вместо неопределённой полосы (SPEC.md §3.7 п. 4): текст растёт на глазах.
        Text(model.followupGeneration.statusText)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("followup.generationStatus")
      }
      if let error = model.followupGeneration.errorText {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("followup.generationError")
      }
      Text("Кнопка «Вставить» берёт текст из буфера; можно и просто нажать ⌘V в поле выше.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Label(methodTitle, systemImage: methodImage)
        .font(.callout)
        .foregroundStyle(parsed.isEmpty ? Color.secondary : Color.primary)
        .accessibilityIdentifier("followup.method")
      ForEach(parsed.warnings, id: \.self) { warning in
        Text(warning)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Предпросмотр

  @ViewBuilder private var previewSections: some View {
    if !decisions.isEmpty {
      Section("Решения (\(decisions.filter(\.isOn).count) из \(decisions.count))") {
        ForEach($decisions) { $item in
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              include($item, label: String(localized: "Добавить решение"))
              TextField("Решение", text: $item.text)
                .accessibilityIdentifier("followup.decision.\(item.id)")
            }
            if let timestamp = parsed.decisions[safe: item.id]?.timestamp {
              Text("Таймкод \(Timecode.hhmmss(timestamp))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    if !actions.isEmpty {
      Section("Задачи (\(actions.filter(\.isOn).count) из \(actions.count))") {
        ForEach($actions) { $item in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              include($item, label: String(localized: "Добавить задачу"))
              TextField("Задача", text: $item.text)
                .accessibilityIdentifier("followup.action.\(item.id)")
            }
            HStack {
              TextField("Ответственный", text: $item.owner)
                .accessibilityIdentifier("followup.action.owner.\(item.id)")
              ownerMenu(for: $item)
              TextField("Срок (ГГГГ-ММ-ДД)", text: $item.due)
                .accessibilityIdentifier("followup.action.due.\(item.id)")
            }
            .font(.callout)
          }
        }
      }
    }
    if !questions.isEmpty {
      Section("Вопросы (\(questions.filter(\.isOn).count) из \(questions.count))") {
        ForEach($questions) { $item in
          HStack {
            include($item, label: String(localized: "Добавить вопрос"))
            TextField("Вопрос", text: $item.text)
              .accessibilityIdentifier("followup.question.\(item.id)")
          }
        }
      }
    }
    if let summary = parsed.summary, !summary.isEmpty {
      Section("Резюме") {
        Text(summary)
          .font(.callout)
          .textSelection(.enabled)
          .accessibilityIdentifier("followup.summary")
      }
    }
  }

  /// Флажок «взять пункт»: отдельный контрол рядом с полем — иначе клик по тексту переключал бы галочку.
  private func include(_ item: Binding<DraftItem>, label: String) -> some View {
    Toggle(label, isOn: item.isOn)
      .toggleStyle(.checkbox)
      .labelsHidden()
      .accessibilityLabel("\(label): \(item.wrappedValue.text)")
  }

  private func ownerMenu(for item: Binding<DraftItem>) -> some View {
    Menu {
      ForEach(ownerSuggestions, id: \.self) { name in
        Button(name) { item.wrappedValue.owner = name }
      }
    } label: {
      Label("Подсказки", systemImage: "person.crop.circle")
    }
    .labelStyle(.iconOnly)
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(ownerSuggestions.isEmpty)
    .help("Люди библиотеки и спикеры этой встречи")
  }

  // MARK: - Футер

  private var footer: some View {
    HStack {
      LocalProcessingBadge()
      Spacer()
      Button("Отмена", role: .cancel) { close() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("followup.cancel")
      Button("Сохранить в проект") { add() }
        .keyboardShortcut(.defaultAction)
        .disabled(!hasText || !hasProject)
        .accessibilityIdentifier("followup.add")
    }
  }

  // MARK: - Действия

  private func reparse() {
    let result = FollowupParser.parse(text)
    parsed = result
    decisions = result.decisions.enumerated().map {
      DraftItem(id: $0.offset, text: $0.element.text)
    }
    actions = result.actions.enumerated().map {
      DraftItem(
        id: $0.offset, text: $0.element.text, owner: $0.element.owner ?? "",
        due: $0.element.due ?? $0.element.dueText ?? "")
    }
    questions = result.questions.enumerated().map {
      DraftItem(id: $0.offset, text: $0.element.text)
    }
  }

  private func add() {
    guard resolveProject() else { return }
    model.finishFollowupImport(
      parsed, meetingID: meetingID, source: source, rawText: text, include: selection)
    model.followupGeneration.reset()
  }

  private func close() {
    model.followupImportMeetingID = nil
    model.followupStartsGeneration = false
    model.followupGeneration.reset()
  }

  /// Переносит встречу в выбранный проект (или создаёт новый); `false` — проекта нет.
  private func resolveProject() -> Bool {
    if record?.projectID != nil { return true }
    switch projectChoice {
    case .none:
      return false
    case .existing(let id):
      model.move(meeting: meetingID, toProject: id)
      return true
    case .new:
      guard let id = model.createProject(named: newProjectName) else { return false }
      model.move(meeting: meetingID, toProject: id)
      return true
    }
  }

  // MARK: - Данные

  private var record: MeetingRecord? { model.library.meeting(id: meetingID) }

  private var subtitle: String {
    guard let record else { return String(localized: "Встреча не найдена") }
    var parts = [record.title, meetingDateText(record.date)]
    if let project = model.projectName(for: record) { parts.append(project) }
    return parts.joined(separator: " · ")
  }

  private var sortedProjects: [ProjectRecord] {
    model.library.projects.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
  }

  /// Сохранять есть что, когда вставлен текст: даже без распознанных пунктов он идёт в историю.
  private var hasText: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasProject: Bool {
    if record?.projectID != nil { return true }
    switch projectChoice {
    case .none: return false
    case .existing: return true
    case .new: return !newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var ownerSuggestions: [String] {
    var names = model.library.peopleByName.map(\.name)
    if let record { names += record.speakerNames.values }
    var seen: Set<String> = []
    return
      names
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
      .sorted { $0.localizedCompare($1) == .orderedAscending }
  }

  private var selection: FollowupSelection {
    FollowupSelection(
      decisions: decisions.filter(\.isOn).compactMap { item in
        AppModel.cleaned(item.text).map { FollowupSelection.Item(index: item.id, text: $0) }
      },
      actions: actions.filter(\.isOn).compactMap { item in
        AppModel.cleaned(item.text).map {
          FollowupSelection.Item(
            index: item.id, text: $0, owner: AppModel.cleaned(item.owner),
            due: AppModel.cleaned(item.due))
        }
      },
      questions: questions.filter(\.isOn).compactMap { item in
        AppModel.cleaned(item.text).map { FollowupSelection.Item(index: item.id, text: $0) }
      })
  }

  private var methodTitle: String {
    switch parsed.method {
    case .jsonBlock: String(localized: "Найден блок meeting-followup")
    case .markdownSections: String(localized: "Разобраны секции Markdown")
    case .none:
      String(localized: "Решения, задачи и вопросы не распознаны — сохранится только текст")
    }
  }

  private var methodImage: String {
    switch parsed.method {
    case .jsonBlock: "curlybraces"
    case .markdownSections: "text.badge.checkmark"
    case .none: "questionmark.circle"
    }
  }
}

extension Array {
  /// Элемент по индексу или `nil` — предпросмотр смотрит в разбор по номеру пункта.
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
