import AppKit
import Core
import Export
import Store
import SwiftUI

/// «Follow-up» встречи (DESIGN.md §5, SPEC.md §3.6): модель пишет follow-up по транскрипту (или
/// пользователь вставляет ответ внешней модели), документ можно прочитать, поправить, перевести на
/// другой язык, скопировать или сохранить .md — и сохранить в историю проекта целиком.
struct FollowupImportSheet: View {
  @Bindable var model: AppModel
  let meetingID: UUID

  @State private var text = ""
  @State private var mode: Mode = .preview
  @State private var source: FollowupSource = .pasted
  @State private var projectChoice: ProjectChoice = .none
  @State private var newProjectName = ""
  @State private var isExporting = false
  /// Текст и язык до перевода: отмена или ошибка перевода возвращают документ как был.
  @State private var beforeTranslation: (text: String, language: FollowupLanguage)?

  /// Как показан документ: прочитать или править Markdown.
  private enum Mode: Hashable {
    case preview
    case markdown
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if record?.projectID == nil { projectPicker }
      toolbar
      document
      statusLine
      Divider()
      footer
    }
    .padding(20)
    .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity, minHeight: 560, idealHeight: 720)
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
        startGeneration()
      }
    }
    // Растущий ответ модели сразу в документе; Gemini присылает его одним куском.
    .onChange(of: model.followupGeneration.text) { _, generated in
      guard !generated.isEmpty else { return }
      text = FollowupGenerationPrompt.cleanedAnswer(generated)
    }
    .onChange(of: model.followupGeneration.finishedText) { _, finished in
      guard let finished, !finished.isEmpty else { return }
      text = FollowupGenerationPrompt.cleanedAnswer(finished)
      beforeTranslation = nil
    }
    .onChange(of: model.followupGeneration.errorText) { _, error in
      if error != nil { restoreAfterFailedTranslation() }
    }
  }

  // MARK: - Шапка

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Follow-up").font(.title2.weight(.semibold))
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
    }
  }

  private var projectPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Picker("Проект", selection: $projectChoice) {
          Text("Не выбран").tag(ProjectChoice.none)
          ForEach(sortedProjects) { project in
            Text(project.name).tag(ProjectChoice.existing(project.id))
          }
          Text("Новый проект").tag(ProjectChoice.new)
        }
        .frame(maxWidth: 320)
        .accessibilityIdentifier("followup.project")
        if projectChoice == .new {
          TextField("Название проекта", text: $newProjectName)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)
            .accessibilityIdentifier("followup.newProjectName")
        }
      }
      Text("Follow-up хранятся в истории проекта: встреча переедет в выбранный проект.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Панель

  /// Генерация и язык слева, вид документа справа. Подписи короткие, а модель вынесена в подсказку:
  /// длинное «Сгенерировать (Gemini · …)» раздвигало окно шире листа.
  private var toolbar: some View {
    HStack(spacing: 10) {
      if let generator = model.activeFollowupGenerator {
        if model.followupGeneration.isRunning {
          Button("Остановить", role: .cancel) { cancelGeneration() }
            .accessibilityIdentifier("followup.cancelGeneration")
        } else {
          Button(
            hasText ? String(localized: "Создать заново") : String(localized: "Создать follow-up"),
            systemImage: "sparkles"
          ) {
            startGeneration()
          }
          .disabled(!generator.isAvailable)
          .help(generator.unavailableReason ?? String(localized: "Модель: \(generator.title)"))
          .accessibilityIdentifier("followup.generate")
        }
        Picker("Язык", selection: languageBinding) {
          ForEach(FollowupLanguage.allCases, id: \.self) { language in
            Text(language.title).tag(language)
          }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(model.followupGeneration.isRunning || !generator.isAvailable)
        .help(
          hasText
            ? String(localized: "Смена языка переводит этот follow-up")
            : String(localized: "На каком языке писать follow-up"))
        .accessibilityIdentifier("followup.language")
      }
      Spacer(minLength: 12)
      Picker("Вид", selection: $mode) {
        Text("Документ").tag(Mode.preview)
        Text("Markdown").tag(Mode.markdown)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityIdentifier("followup.mode")
    }
    .labelStyle(.titleAndIcon)
  }

  // MARK: - Документ

  @ViewBuilder private var document: some View {
    Group {
      if mode == .markdown {
        TextEditor(text: $text)
          .font(.body.monospaced())
          .scrollContentBackground(.hidden)
          .padding(8)
          .disabled(model.followupGeneration.isRunning)
          .accessibilityLabel("Текст follow-up в Markdown")
          .accessibilityIdentifier("followup.text")
      } else if hasText {
        ScrollView {
          MarkdownDocumentView(markdown: text)
            .padding(16)
        }
        .accessibilityIdentifier("followup.preview")
      } else {
        emptyDocument
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
  }

  @ViewBuilder private var emptyDocument: some View {
    if model.followupGeneration.isRunning {
      // Пока модель пишет, подсказки «создайте или вставьте» сбивают с толку.
      ContentUnavailableView(
        "Модель пишет follow-up…", systemImage: "text.badge.checkmark",
        description: Text("Обычно это занимает до минуты."))
    } else {
      idleDocument
    }
  }

  private var idleDocument: some View {
    ContentUnavailableView {
      Label("Follow-up пока нет", systemImage: "text.badge.checkmark")
    } description: {
      Text(
        model.activeFollowupGenerator == nil
          ? "Вставьте ответ модели на TranscribeFull — он сохранится в истории проекта."
          : "Создайте follow-up моделью или вставьте ответ внешней модели на TranscribeFull."
      )
    } actions: {
      PasteButton(payloadType: String.self) { strings in paste(strings) }
        .accessibilityIdentifier("followup.paste")
    }
  }

  /// Живость генерации и перевода, ошибки — одной строкой под документом.
  @ViewBuilder private var statusLine: some View {
    if model.followupGeneration.isRunning {
      Text(model.followupGeneration.statusText)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("followup.generationStatus")
    } else if let error = model.followupGeneration.errorText {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(3)
        .accessibilityIdentifier("followup.generationError")
    }
  }

  // MARK: - Футер

  private var footer: some View {
    HStack(spacing: 8) {
      if hasText {
        PasteButton(payloadType: String.self) { strings in paste(strings) }
          .labelStyle(.iconOnly)
          .help("Заменить текст ответом модели из буфера обмена")
          .accessibilityIdentifier("followup.paste")
        Button("Скопировать", systemImage: "doc.on.doc") { copyText() }
          .accessibilityIdentifier("followup.copy")
        Button("Сохранить .md…", systemImage: "square.and.arrow.down") { isExporting = true }
          .accessibilityIdentifier("followup.save")
      }
      Spacer(minLength: 12)
      Button("Отмена", role: .cancel) { close() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("followup.cancel")
      Button("Сохранить в проект") { save() }
        .keyboardShortcut(.defaultAction)
        .disabled(!hasText || !hasProject || model.followupGeneration.isRunning)
        .accessibilityIdentifier("followup.add")
    }
    .labelStyle(.titleAndIcon)
  }

  // MARK: - Действия

  private func startGeneration() {
    beforeTranslation = nil
    source = generatedSource
    model.startFollowupGeneration(meetingID: meetingID)
  }

  private func cancelGeneration() {
    model.followupGeneration.cancel()
    // Отменённый перевод не должен оставить документ наполовину на другом языке.
    restoreAfterFailedTranslation()
  }

  /// Смена языка: без текста — язык следующей генерации, с текстом — перевод этого follow-up.
  private var languageBinding: Binding<FollowupLanguage> {
    Binding(
      get: { model.settings.followupLanguage },
      set: { language in
        let previous = model.settings.followupLanguage
        guard language != previous else { return }
        model.settings.followupLanguage = language
        guard hasText, !model.followupGeneration.isRunning else { return }
        beforeTranslation = (text, previous)
        if !model.startFollowupTranslation(text, to: language) {
          restoreAfterFailedTranslation()
        }
      })
  }

  private func restoreAfterFailedTranslation() {
    guard let saved = beforeTranslation else { return }
    beforeTranslation = nil
    text = saved.text
    model.settings.followupLanguage = saved.language
  }

  private func paste(_ strings: [String]) {
    guard let pasted = strings.first(where: { !$0.isEmpty }) else { return }
    source = .pasted
    beforeTranslation = nil
    text = FollowupGenerationPrompt.cleanedAnswer(pasted)
    mode = .preview
  }

  private func copyText() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func save() {
    guard resolveProject() else { return }
    model.finishFollowup(text, meetingID: meetingID, source: source)
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

  /// Чей ответ: провайдера хоста или локальной модели (для истории follow-up).
  private var generatedSource: FollowupSource {
    model.followupGenerator != nil ? .hostModel : .localLLM
  }

  /// `[YYYY-MM-DD]_[Проект]_follow-up_имена_и_поручения.md`.
  private var exportFileName: String {
    FollowupGenerationPrompt.fileName(
      date: record?.date ?? record?.createdAt,
      project: record.flatMap { model.projectName(for: $0) },
      language: model.settings.followupLanguage)
  }

  private var sortedProjects: [ProjectRecord] {
    model.library.projects.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
  }

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
}

extension Array {
  /// Элемент по индексу или `nil`.
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
