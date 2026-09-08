import Core
import Export
import Ingest
import Store
import SwiftUI

/// Диалог импорта (DESIGN.md §5): файлы, проект, ожидаемое число участников, язык, режим.
struct ImportSheet: View {
  @Bindable var model: AppModel
  @State private var draft: ImportRequest

  init(model: AppModel, request: ImportRequest) {
    self.model = model
    _draft = State(initialValue: request)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Импорт записи").font(.title3)
      Form {
        Section("Файлы") {
          ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Label(item.name, systemImage: "waveform")
                  .lineLimit(1)
                Spacer()
                if let problem = item.problem {
                  Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(problem)
                } else if let duration = item.duration {
                  Text(durationText(duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                } else {
                  // Проба заголовка контейнера занимает доли секунды — крутилка здесь допустима.
                  ProgressView().controlSize(.small)
                }
              }
              if let recording = item.recording, recording.hasSeparateTracks {
                Toggle(
                  "Раздельные дорожки участников: \(recording.tracks.count)",
                  isOn: tracksBinding(for: item.url)
                )
                .accessibilityIdentifier("import.tracks")
                Text(trackNames(recording))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
          }
        }
        Section {
          Picker("Проект", selection: $draft.project) {
            Text("Без проекта").tag(ProjectChoice.none)
            ForEach(model.library.projects) { project in
              Text(project.name).tag(ProjectChoice.existing(project.id))
            }
            Text("Новый проект…").tag(ProjectChoice.new)
          }
          .accessibilityIdentifier("import.project")
          if draft.project == .new {
            TextField("Название проекта", text: $draft.newProjectName)
              .accessibilityIdentifier("import.newProject")
          }
          Toggle("Подсказать число участников", isOn: $draft.usesExpectedSpeakers)
          if draft.usesExpectedSpeakers {
            Stepper(
              "Участников: \(draft.expectedSpeakers)", value: $draft.expectedSpeakers, in: 2...12
            )
            .accessibilityIdentifier("import.expectedSpeakers")
            .accessibilityValue("\(draft.expectedSpeakers)")
          }
          Picker("Язык", selection: $draft.language) {
            ForEach(LanguageChoice.allCases, id: \.self) { choice in
              Text(choice.title).tag(choice)
            }
          }
          .accessibilityIdentifier("import.language")
          Picker("Режим", selection: modeBinding) {
            Text("Точный (WhisperKit)").tag(AsrEngineID.whisperkit)
            Text("Быстрый (Parakeet)").tag(AsrEngineID.parakeet)
          }
          .accessibilityIdentifier("import.mode")
          Text("Модель WhisperKit и диаризатор выбираются в настройках: \(draft.engines.title).")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      HStack {
        LocalProcessingBadge()
        Spacer()
        Button("Отмена", role: .cancel) { model.pendingImport = nil }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("import.cancel")
        Button("Обработать") { confirm() }
          .keyboardShortcut(.defaultAction)
          .disabled(usableCount == 0)
          .accessibilityIdentifier("import.process")
      }
    }
    .padding()
    .frame(minWidth: 460, minHeight: 380)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("import.sheet")
  }

  /// Файлы берём из модели: длительности дозаполняются пробой уже после показа диалога.
  private var items: [ImportRequest.Item] {
    model.pendingImport?.id == draft.id ? (model.pendingImport?.items ?? draft.items) : draft.items
  }

  private var usableCount: Int {
    items.filter { $0.problem == nil }.count
  }

  /// Переключатель дорожек хранится в модели вместе с файлами: длительности дозаполняются туда же.
  private func tracksBinding(for url: URL) -> Binding<Bool> {
    Binding(
      get: { items.first { $0.url == url }?.useSeparateTracks ?? true },
      set: { value in
        if model.pendingImport?.id == draft.id,
          let index = model.pendingImport?.items.firstIndex(where: { $0.url == url })
        {
          model.pendingImport?.items[index].useSeparateTracks = value
        }
        if let index = draft.items.firstIndex(where: { $0.url == url }) {
          draft.items[index].useSeparateTracks = value
        }
      })
  }

  private func trackNames(_ recording: ZoomRecording) -> String {
    let names = recording.tracks.map { $0.participantName ?? $0.rawName }
    return String(localized: "Имена из файлов: ") + names.joined(separator: ", ")
      + String(localized: ". Диаризация не нужна, имена подставятся автоматически.")
  }

  private var modeBinding: Binding<AsrEngineID> {
    Binding(
      get: { draft.engines.asr },
      set: { asr in
        draft.engines.asr = asr
        if asr == .parakeet { draft.language = .auto }
      })
  }

  private func confirm() {
    var request = draft
    request.items = items
    model.confirmImport(request)
  }
}
