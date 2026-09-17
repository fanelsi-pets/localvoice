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
          Picker("Обработка", selection: placeBinding) {
            ForEach(availablePlaces) { place in
              Text(place.title).tag(place)
            }
          }
          .accessibilityIdentifier("import.mode")
          Text(placeNote)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      HStack {
        ProcessingPlaceBadge(isCloud: draft.engines.asr.isCloud)
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

  /// Облако предлагается только там, где хост дал провайдера (ADR-010): в самостоятельном ядре его нет.
  private var availablePlaces: [ProcessingPlace] {
    model.cloudEngine == nil ? [.local] : ProcessingPlace.allCases
  }

  private var placeBinding: Binding<ProcessingPlace> {
    Binding(
      get: { draft.engines.asr.isCloud ? .cloud : .local },
      set: { place in
        switch place {
        case .cloud:
          guard let cloud = model.cloudEngine else { return }
          draft.engines.asr = cloud
        case .local:
          draft.engines = model.settings.localEngines
        }
        // Ни Parakeet, ни облако не принимают язык на вход: он определяется по самой речи.
        if draft.engines.asr != .whisperkit { draft.language = .auto }
      })
  }

  private var placeNote: String {
    guard !draft.engines.asr.isCloud else { return Self.cloudNote(for: draft.engines.asr) }
    return String(
      localized:
        "Распознавание и голоса — на этом Mac: \(draft.engines.title). Движок и модель меняются в настройках."
    )
  }

  private func confirm() {
    var request = draft
    request.items = items
    model.confirmImport(request)
  }
}

extension ImportSheet {
  /// Куда уходит аудио в облачном режиме — подпись под выбором места обработки.
  static func cloudNote(for engine: AsrEngineID) -> String {
    switch engine {
    case .azure:
      String(
        localized:
          "Аудио встречи уходит в Microsoft Azure по вашему ключу: распознаёт MAI-Transcribe-2, по условиям Azure отправленное аудио не сохраняется. Голоса, имена и память проекта остаются на этом Mac."
      )
    case .gemini:
      String(
        localized:
          "Аудио встречи уходит в Google по вашему ключу: распознаёт gemini-3.5-transcribe. Голоса и имена остаются на этом Mac."
      )
    case .whisperkit, .parakeet: ""
    }
  }
}
