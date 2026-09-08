import Core
import Export
import LocalLLM
import SwiftUI

/// Окно настроек (DESIGN.md §5): Общие, Движки и модели, Языки, Диагностика.
struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    TabView(selection: $model.settingsTab) {
      GeneralSettings(model: model, settings: model.settings)
        .tabItem { Label(SettingsTab.general.title, systemImage: "gearshape") }
        .tag(SettingsTab.general)
      EngineSettings(model: model, settings: model.settings)
        .tabItem { Label(SettingsTab.engines.title, systemImage: "cpu") }
        .tag(SettingsTab.engines)
      LanguageSettings(model: model, settings: model.settings)
        .tabItem { Label(SettingsTab.languages.title, systemImage: "character.bubble") }
        .tag(SettingsTab.languages)
      PeopleSettings(model: model, settings: model.settings)
        .tabItem { Label(SettingsTab.people.title, systemImage: "person.wave.2") }
        .tag(SettingsTab.people)
      FollowupSettings(settings: model.settings, generatorTitle: model.followupGenerator?.title)
        .tabItem { Label(SettingsTab.followup.title, systemImage: "arrow.uturn.forward") }
        .tag(SettingsTab.followup)
      DiagnosticsSettings(model: model)
        .tabItem { Label(SettingsTab.diagnostics.title, systemImage: "stethoscope") }
        .tag(SettingsTab.diagnostics)
    }
    .frame(minWidth: 520, minHeight: 380)
  }
}

/// Общие: папка данных, уведомления, оформление таймкодов.
struct GeneralSettings: View {
  @Bindable var model: AppModel
  /// Настройки биндятся напрямую: `settings` — константа модели, через неё запись не проходит.
  @Bindable var settings: AppSettings

  var body: some View {
    Form {
      Section("Данные") {
        LabeledContent("Папка библиотеки") {
          HStack {
            Text(model.store.directory.path(percentEncoded: false))
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Button("Показать в Finder") { model.revealInFinder(model.store.directory) }
              .accessibilityIdentifier("settings.revealLibrary")
          }
        }
        Text(
          "Здесь лежат индекс встреч, транскрипты и кэш аудио. Исходные записи остаются на месте."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Поведение") {
        Toggle("Уведомлять о завершении обработки", isOn: $settings.notifyOnCompletion)
        Toggle("Таймкоды с десятыми долями", isOn: $settings.tenthsInTimecodes)
        Toggle("Помечать наложения речи в экспорте", isOn: $settings.markOverlap)
      }
      // Sparkle (ADR-009): секция есть только у сборок с лентой обновлений в Info.plist.
      if model.updater.isAvailable {
        Section("Обновления") {
          Toggle(
            "Проверять обновления автоматически",
            isOn: Binding(
              get: { model.updater.automaticallyChecksForUpdates },
              set: { model.updater.automaticallyChecksForUpdates = $0 })
          )
          .accessibilityIdentifier("settings.updates.automatic")
          Toggle(
            "Скачивать и устанавливать без вопросов",
            isOn: Binding(
              get: { model.updater.automaticallyDownloadsUpdates },
              set: { model.updater.automaticallyDownloadsUpdates = $0 })
          )
          .disabled(!model.updater.automaticallyChecksForUpdates)
          .accessibilityIdentifier("settings.updates.autoInstall")
          HStack {
            Button("Проверить сейчас…") { model.updater.checkForUpdates() }
              .disabled(!model.updater.canCheckForUpdates)
              .accessibilityIdentifier("settings.updates.checkNow")
            if let date = model.updater.lastUpdateCheckDate {
              Text("Последняя проверка: \(date.formatted(.dateTime.day().month().hour().minute()))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Text(
            "Приложение читает ленту обновлений в репозитории проекта на GitHub и скачивает оттуда DMG новой версии; подпись проверяется перед установкой. Данные о системе не отправляются."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// Движки и модели: выбор ASR и диаризатора, состояние моделей на диске, скачивание недостающих.
struct EngineSettings: View {
  @Bindable var model: AppModel
  @Bindable var settings: AppSettings
  @State private var statuses: [ModelStatus] = []

  var body: some View {
    Form {
      Section("Движки") {
        Picker("Распознавание", selection: $settings.engines.asr) {
          ForEach(AsrEngineID.allCases, id: \.self) { engine in
            Text(engine.title).tag(engine)
          }
        }
        Picker("Модель Whisper", selection: $settings.engines.whisperModel) {
          Text("large-v3 turbo (быстрее)").tag(ModelID.whisperLargeV3Turbo)
          Text("large-v3 (точнее)").tag(ModelID.whisperLargeV3)
        }
        .disabled(settings.engines.asr != .whisperkit)
        Picker("Разделение по голосам", selection: $settings.engines.diarizer) {
          Text(DiarizerID.speakerkit.title).tag(DiarizerID?.some(.speakerkit))
          Text(DiarizerID.fluidaudio.title).tag(DiarizerID?.some(.fluidaudio))
          Text("Без диаризации").tag(DiarizerID?.none)
        }
        Toggle("Подсказывать число участников", isOn: expectedSpeakersEnabled)
        // Шаг числа появляется только при включённой подсказке — выключенный контрол ничего не объясняет.
        if settings.defaultExpectedSpeakers != nil {
          Stepper(
            "Участников по умолчанию: \(settings.defaultExpectedSpeakers ?? 4)",
            value: expectedSpeakersValue, in: 2...12
          )
        }
      }
      Section("Модели") {
        ForEach(statuses, id: \.self) { status in
          ModelStatusRow(status: status)
        }
        downloadControls
      }
    }
    .formStyle(.grouped)
    .task { await reloadStatuses() }
    .onChange(of: model.modelDownloads.finishedText) { _, _ in
      Task { await reloadStatuses() }
    }
  }

  /// Скачивание в мегабайтах и процентах с паузой (SPEC.md §3.7 п. 10): та же очередь и тот же
  /// контроллер, что в онбординге, — окно настроек можно закрыть, загрузка продолжится.
  @ViewBuilder private var downloadControls: some View {
    let downloads = model.modelDownloads
    if downloads.isActive {
      ProgressView(value: downloads.fraction) {
        Text("Скачивание моделей")
      } currentValueLabel: {
        Text("\(Int(downloads.fraction * 100)) %").monospacedDigit()
      }
      .progressViewStyle(.linear)
      .accessibilityIdentifier("settings.downloadProgress")
      .accessibilityValue("\(Int(downloads.fraction * 100)) %")
      Text(downloads.statusText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .accessibilityIdentifier("settings.downloadStatus")
      HStack {
        if downloads.isPaused {
          Button("Продолжить") { downloads.resume() }
            .accessibilityIdentifier("settings.downloadResume")
        } else {
          Button("Пауза") { downloads.pause() }
            .accessibilityIdentifier("settings.downloadPause")
        }
        Button("Остановить") { downloads.cancel() }
          .accessibilityIdentifier("settings.downloadCancel")
      }
    } else {
      Button("Скачать недостающие") {
        Task { await model.downloadMissingModels() }
      }
      .accessibilityIdentifier("settings.download")
    }
    if let error = model.modelDownloads.errorText {
      Label(error, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
      Button("Повторить") { model.modelDownloads.retry() }
        .accessibilityIdentifier("settings.downloadRetry")
    } else if let finished = model.modelDownloads.finishedText {
      Label(finished, systemImage: "checkmark.circle")
        .font(.caption)
        .foregroundStyle(.green)
    }
  }

  private func reloadStatuses() async {
    let store = model.modelStore
    statuses = await Task.detached { store.status() }.value
  }

  private var expectedSpeakersEnabled: Binding<Bool> {
    Binding(
      get: { settings.defaultExpectedSpeakers != nil },
      set: { settings.defaultExpectedSpeakers = $0 ? 4 : nil })
  }

  private var expectedSpeakersValue: Binding<Int> {
    Binding(
      get: { settings.defaultExpectedSpeakers ?? 4 },
      set: { settings.defaultExpectedSpeakers = $0 })
  }
}

/// Языки: язык по умолчанию для новых встреч.
struct LanguageSettings: View {
  @Bindable var model: AppModel
  @Bindable var settings: AppSettings

  var body: some View {
    Form {
      Section("Языки встреч") {
        ForEach(AppSettings.defaultMeetingLanguages, id: \.code) { language in
          Toggle(
            OnboardingSheet.languageTitle(language),
            isOn: Binding(
              get: { settings.meetingLanguages.contains(language) },
              set: { model.onboarding.setLanguage(language, enabled: $0) })
          )
          .accessibilityIdentifier("settings.language.\(language.code)")
        }
        Text(
          "Между этими языками распознавание выбирает язык каждого спикера. Лишние языки замедляют определение и добавляют ошибок — оставьте те, на которых действительно говорят."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Язык обработки по умолчанию") {
        Picker("Язык по умолчанию", selection: $settings.defaultLanguage) {
          ForEach(LanguageChoice.allCases, id: \.self) { choice in
            Text(choice.title).tag(choice)
          }
        }
        Text(
          "«Авто, по каждому спикеру» определяет язык отдельно для каждого голоса: русская речь остаётся русской, украинская — украинской, английские термины сохраняются латиницей. Один язык на файл стоит выбирать, только если вся встреча заведомо на одном языке."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

/// Люди и голоса (DESIGN.md §5): пороги сопоставления, экспорт и импорт профилей.
struct PeopleSettings: View {
  @Bindable var model: AppModel
  @Bindable var settings: AppSettings

  var body: some View {
    Form {
      Section("Пороги сопоставления голосов") {
        LabeledContent("Присваивать автоматически от") {
          HStack {
            Slider(value: $settings.voiceAutoThreshold, in: 0.4...0.95, step: 0.01)
            Text(NamingState.percent(settings.voiceAutoThreshold))
              .monospacedDigit()
          }
        }
        LabeledContent("Предлагать с подтверждением от") {
          HStack {
            Slider(value: $settings.voiceSuggestThreshold, in: 0.3...0.9, step: 0.01)
            Text(NamingState.percent(settings.voiceSuggestThreshold))
              .monospacedDigit()
          }
        }
        Text(
          "Сходство голоса с профилем (cosine). По умолчанию 70 % и 55 % (SPEC.md §3.4); если знакомые люди остаются «Неизвестными», понизьте пороги, если путаются — повысьте."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Профили") {
        LabeledContent(
          "Людей с голосом",
          value:
            String(
              localized:
                "\(model.library.people.filter { $0.sampleCount > 0 }.count) из \(model.library.people.count)"
            )
        )
        HStack {
          Button("Экспортировать профили…") { model.savePeopleJSON() }
            .disabled(model.library.people.isEmpty)
          Button("Импортировать профили…") { model.isPeopleImporterPresented = true }
        }
        Text("JSON с людьми и их отпечатками — перенос на другой Mac. Аудио в файле нет.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onChange(of: settings.voiceSuggestThreshold) { _, value in
      if value > settings.voiceAutoThreshold { settings.voiceAutoThreshold = value }
    }
    .onChange(of: settings.voiceAutoThreshold) { _, value in
      if value < settings.voiceSuggestThreshold { settings.voiceSuggestThreshold = value }
    }
    // Панели — на окне настроек: главное окно может быть закрыто (SPEC.md §3.7 п. 8).
    .fileImporter(
      isPresented: $model.isPeopleImporterPresented, allowedContentTypes: [.json]
    ) { result in
      if case .success(let url) = result { model.importPeople(from: url) }
    }
    .fileExporter(
      isPresented: Binding(
        get: { model.peopleExportRequest != nil },
        set: { if !$0 { model.peopleExportRequest = nil } }),
      document: model.peopleExportRequest?.document
        ?? TranscriptDocument(text: "", format: .json),
      contentType: .json,
      defaultFilename: model.peopleExportRequest?.defaultFilename
    ) { result in
      model.peopleExportRequest = nil
      if case .failure(let error) = result {
        model.alert = AppAlert(
          title: String(localized: "Файл не сохранился"), message: error.localizedDescription)
      }
    }
  }
}

/// Follow-up (SPEC.md §3.6): контекст проекта в экспорте и необязательная локальная модель.
struct FollowupSettings: View {
  @Bindable var settings: AppSettings
  /// Название генератора хоста (ADR-010), если он задан, — подпись «Follow-up создаёт: …».
  var generatorTitle: String? = nil
  @State private var models: [LocalLLMModel] = []
  @State private var statusText: String?
  /// Красным красится только настоящая неудача: «список моделей пуст» — это подсказка, а не ошибка.
  @State private var statusIsError = false
  @State private var isLoadingModels = false

  var body: some View {
    Form {
      Section("Экспорт") {
        Toggle("Включать контекст проекта в TranscribeFull", isOn: $settings.includeProjectContext)
        Text(
          "В шапку экспорта добавляются решения, открытые задачи и вопросы предыдущих встреч того же проекта — внешняя модель видит, о чём договорились раньше."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Генерация follow-up") {
        Picker("Язык follow-up", selection: $settings.followupLanguage) {
          ForEach(FollowupLanguage.allCases, id: \.self) { language in
            Text(language.title).tag(language)
          }
        }
        .accessibilityIdentifier("settings.followup.language")
        if let generatorTitle {
          Text("Follow-up создаёт: \(generatorTitle)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Section("Локальная языковая модель (необязательно)") {
        Toggle("Генерировать follow-up локальной моделью", isOn: $settings.localLLMEnabled)
        TextField("Адрес сервера", text: $settings.localLLMBaseURL)
          .disabled(!settings.localLLMEnabled)
          .accessibilityIdentifier("settings.llm.url")
        Menu("Пресет") {
          Button("LM Studio (localhost:1234)") {
            settings.localLLMBaseURL = LocalLLMConfiguration.lmStudioDefaultURL.absoluteString
          }
          Button("Ollama (localhost:11434)") {
            settings.localLLMBaseURL = LocalLLMConfiguration.ollamaDefaultURL.absoluteString
          }
        }
        .disabled(!settings.localLLMEnabled)
        .accessibilityIdentifier("settings.llm.preset")
        TextField("Модель", text: $settings.localLLMModel)
          .disabled(!settings.localLLMEnabled)
          .accessibilityIdentifier("settings.llm.model")
        if !models.isEmpty {
          Picker("Из списка", selection: $settings.localLLMModel) {
            Text("Не выбрана").tag("")
            ForEach(models) { available in
              Text(available.id).tag(available.id)
            }
          }
          .disabled(!settings.localLLMEnabled)
          .accessibilityIdentifier("settings.llm.modelPicker")
        }
        HStack {
          Button("Получить список моделей") { loadModels() }
            .disabled(!settings.localLLMEnabled || isLoadingModels)
            .accessibilityIdentifier("settings.llm.fetchModels")
          if isLoadingModels {
            // Запрос к localhost занимает доли секунды; таймаут — 15 с. Полосы нет: доля неизвестна,
            // а «крутилка» запрещена (SPEC.md §3.7) — состояние показано словами.
            Text("Запрашиваю список…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if let statusText {
          Text(statusText)
            .font(.caption)
            .foregroundStyle(statusIsError ? Color.red : Color.secondary)
            .accessibilityIdentifier("settings.llm.status")
        }
        Text(
          "Транскрипт отправляется только на этот адрес. Разрешены localhost, имена .local и адреса частной сети — облачные адреса отклоняются (SPEC.md §1: вся обработка на этом Mac)."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .accessibilityIdentifier("settings.followup")
  }

  private func loadModels() {
    let address = settings.localLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = AppSettings.serverURL(address) else {
      models = []
      statusIsError = true
      statusText = LocalLLMError.invalidURL(address).localizedDescription
      return
    }
    isLoadingModels = true
    statusText = nil
    statusIsError = false
    Task {
      do {
        let available = try await LocalLLMClient().listModels(baseURL: url)
        models = available
        statusIsError = false
        statusText =
          available.isEmpty
          ? String(
            localized:
              "Сервер ответил, но список моделей пуст: загрузите модель в LM Studio или скачайте её в Ollama."
          )
          : String(localized: "Доступно \(available.count) моделей")
        if settings.localLLMModel.isEmpty, let first = available.first {
          settings.localLLMModel = first.id
        }
      } catch {
        models = []
        statusIsError = true
        statusText = error.localizedDescription
      }
      isLoadingModels = false
    }
  }
}

/// Одна модель в списке настроек: название, состояние на диске, лицензия.
struct ModelStatusRow: View {
  let status: ModelStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(status.id.title)
        Spacer()
        Text(sizeText)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(status.isPresent ? Color.secondary : Color.orange)
      }
      Text(status.id.license)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private var sizeText: String {
    guard status.isPresent else {
      return String(localized: "не скачано · ~\(status.id.approximateSizeMB) МБ")
    }
    guard let bytes = status.sizeBytes else { return String(localized: "скачано") }
    return String(localized: "скачано · \(bytes / 1_048_576) МБ")
  }
}
