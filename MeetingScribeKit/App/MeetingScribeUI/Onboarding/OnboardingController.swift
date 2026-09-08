import Core
import Engines
import Foundation
import Observation

/// Шаги первого запуска (SPEC.md §2 п. 8, DESIGN.md §5).
nonisolated public enum OnboardingStep: String, CaseIterable, Hashable, Sendable, Identifiable {
  case welcome
  case languages
  case models
  case selfTest
  case done

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .welcome: String(localized: "Проверка компьютера")
    case .languages: String(localized: "Языки встреч")
    case .models: String(localized: "Модели распознавания")
    case .selfTest: String(localized: "Проверка на сэмпле")
    case .done: String(localized: "Всё готово")
    }
  }

  public var subtitle: String {
    switch self {
    case .welcome:
      String(
        localized:
          "MeetingScribe расшифровывает встречи на этом Mac: записи никуда не отправляются.")
    case .languages:
      String(
        localized:
          "Выберите языки, на которых говорят на ваших встречах, и режим обработки по умолчанию.")
    case .models:
      String(localized: "Модели скачиваются один раз с Hugging Face и лежат в папке приложения.")
    case .selfTest:
      String(
        localized:
          "Около 30 секунд встроенной записи пройдут весь путь: аудио → голоса → язык → текст.")
    case .done:
      String(localized: "Перетащите папку записи Zoom в окно — обработка начнётся сразу.")
    }
  }
}

/// Режим обработки по умолчанию (DESIGN.md §5 п. 2): «точный» — WhisperKit с моделью из умолчания хоста
/// (`AppSettings.accurateSelection`: turbo у MeetingScribe, large-v3 у LocalVoice), «быстрый» — Parakeet.
nonisolated public enum ProcessingMode: String, CaseIterable, Hashable, Sendable, Identifiable {
  case accurate
  case fast

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .accurate: String(localized: "Точный")
    case .fast: String(localized: "Быстрый")
    }
  }

  /// Пояснение к режиму; `accurate` — выбор движков «точного» режима (модель зависит от хоста).
  public func detail(accurate: EngineSelection) -> String {
    switch self {
    case .accurate:
      String(localized: "\(accurate.title): лучшее качество на русском и украинском")
    case .fast: String(localized: "Parakeet TDT v3: в разы быстрее, слабее на смешанной речи")
    }
  }

  public var selection: EngineSelection {
    switch self {
    case .accurate: .accurate
    case .fast: .fast
    }
  }
}

/// Онбординг первого запуска: пять шагов, состояние переживает закрытие sheet (Help → «Первый запуск…»
/// открывает его на том же месте). Скачивание и самопроверка живут в своих контроллерах `AppModel` —
/// шаг моделей можно свернуть, загрузка продолжится (SPEC.md §3.7 п. 8, 10).
@Observable
public final class OnboardingController {
  public let settings: AppSettings
  public let modelStore: ModelStore

  /// Sheet показан.
  public var isPresented = false
  public private(set) var step: OnboardingStep = .welcome
  /// Проверка железа (пункты с вердиктами); до первого `refresh()` — пусто.
  public private(set) var hardware = HardwareCheck(items: [])
  public private(set) var systemInfo: SystemInfo?
  /// Состояние моделей на диске в порядке `requiredModels`.
  public private(set) var modelStatuses: [ModelStatus] = []
  public private(set) var missingModels: [ModelID] = []
  /// Сколько ещё качать, байт.
  public private(set) var missingBytes: Int64 = 0
  public private(set) var availableDiskBytes: Int64?
  /// Нашлись папки старых кэшей (`~/Documents/huggingface`, FluidAudio) — можно перенести без сети.
  public private(set) var hasLegacyCache = false
  public private(set) var legacyImportText: String?
  public private(set) var isImportingLegacyCache = false
  public private(set) var isRefreshing = false

  @ObservationIgnored private let systemInfoProvider: @Sendable () -> SystemInfo
  @ObservationIgnored private let diskBytesProvider: @Sendable (URL) -> Int64?

  /// - Parameters:
  ///   - systemInfo: сведения о машине; подменяются в тестах (провал проверки железа).
  ///   - availableDiskBytes: свободное место на томе моделей.
  public init(
    settings: AppSettings,
    modelStore: ModelStore,
    systemInfo: @escaping @Sendable () -> SystemInfo = { SystemInfo.current() },
    availableDiskBytes: @escaping @Sendable (URL) -> Int64? = {
      SystemInfo.availableDiskBytes(at: $0)
    }
  ) {
    self.settings = settings
    self.modelStore = modelStore
    self.systemInfoProvider = systemInfo
    self.diskBytesProvider = availableDiskBytes
  }

  // MARK: - Показ

  /// Первый запуск: sheet открывается сам, пока онбординг не пройден и не пропущен.
  public func presentIfNeeded() {
    guard !settings.onboardingCompleted else { return }
    isPresented = true
  }

  /// Help → «Первый запуск…»: шаг не сбрасывается — пользователь возвращается туда, где остановился.
  public func present() {
    isPresented = true
  }

  /// «Свернуть» на шаге моделей: sheet закрывается, скачивание продолжается, статус виден в тулбаре.
  public func minimize() {
    isPresented = false
  }

  // MARK: - Шаги

  public var isFirstStep: Bool { step == OnboardingStep.allCases.first }
  public var isLastStep: Bool { step == OnboardingStep.allCases.last }

  /// Можно ли идти дальше: без Apple Silicon и без места на диске — нельзя (но можно закрыть окно);
  /// без языка не из чего выбирать; без моделей не на чем проверять.
  public var canGoNext: Bool {
    switch step {
    case .welcome: hardware.items.isEmpty || hardware.canProceed
    case .languages: !settings.meetingLanguages.isEmpty
    case .models: missingModels.isEmpty
    case .selfTest, .done: true
    }
  }

  /// Почему «Далее» выключена — текст под кнопкой (DESIGN.md §1: что случилось и что сделать).
  public var blockingReason: String? {
    guard !canGoNext else { return nil }
    switch step {
    case .welcome:
      return String(
        localized: "Этот Mac не подходит для локального распознавания — окно можно закрыть.")
    case .languages:
      return String(localized: "Выберите хотя бы один язык встреч.")
    case .models:
      return String(localized: "Скачайте модели: без них распознавание не запустится.")
    case .selfTest, .done:
      return nil
    }
  }

  public func next() {
    guard canGoNext, let index = OnboardingStep.allCases.firstIndex(of: step),
      index + 1 < OnboardingStep.allCases.count
    else { return }
    step = OnboardingStep.allCases[index + 1]
  }

  public func back() {
    guard let index = OnboardingStep.allCases.firstIndex(of: step), index > 0 else { return }
    step = OnboardingStep.allCases[index - 1]
  }

  public func go(to step: OnboardingStep) {
    self.step = step
  }

  /// «Пропустить» и «Начать» одинаково закрывают первый запуск: sheet сам больше не появится.
  public func skip() {
    settings.onboardingCompleted = true
    isPresented = false
  }

  public func finish() {
    settings.onboardingCompleted = true
    isPresented = false
  }

  // MARK: - Языки и режим

  public func isLanguageEnabled(_ language: Language) -> Bool {
    settings.meetingLanguages.contains(language)
  }

  /// Снять последний язык нельзя: распознавание осталось бы без кандидатов.
  public func setLanguage(_ language: Language, enabled: Bool) {
    var languages = settings.meetingLanguages
    if enabled {
      languages.insert(language)
    } else {
      guard languages.count > 1 else { return }
      languages.remove(language)
    }
    settings.meetingLanguages = languages
  }

  public var mode: ProcessingMode {
    get { settings.engines.asr == .parakeet ? .fast : .accurate }
    set {
      guard newValue != mode else { return }
      settings.engines = newValue == .fast ? .fast : settings.accurateSelection
    }
  }

  /// Движки «точного» режима — умолчание хоста (для подписи в онбординге).
  public var accurateSelection: EngineSelection { settings.accurateSelection }

  // MARK: - Модели

  /// Модели, нужные текущему выбору движков.
  public var requiredModels: [ModelID] {
    EngineFactory.requiredModels(
      asr: settings.engines.asr, whisperModel: settings.engines.whisperModel,
      diarizer: settings.engines.diarizer)
  }

  public var allModelsPresent: Bool { !modelStatuses.isEmpty && missingModels.isEmpty }

  /// Пересчитывает проверку железа и состояние моделей. Файловая система опрашивается вне главного
  /// актора: у скачанной модели `status()` считает размер обходом папки.
  public func refresh() async {
    isRefreshing = true
    defer { isRefreshing = false }
    let store = modelStore
    let required = requiredModels
    let disk = diskBytesProvider
    let snapshot = await Task.detached { () -> Snapshot in
      let statuses = required.map { model -> ModelStatus in
        let url = store.directory(for: model)
        let present = store.isPresent(model)
        return ModelStatus(id: model, url: url, isPresent: present, sizeBytes: nil)
      }
      let missing = statuses.filter { !$0.isPresent }.map(\.id)
      return Snapshot(
        statuses: statuses,
        missing: missing,
        missingBytes: missing.reduce(0) { $0 + $1.downloadSpec.approximateBytes },
        availableBytes: disk(store.root),
        hasLegacyCache: Self.hasLegacyCache())
    }.value

    modelStatuses = snapshot.statuses
    missingModels = snapshot.missing
    missingBytes = snapshot.missingBytes
    availableDiskBytes = snapshot.availableBytes
    hasLegacyCache = snapshot.hasLegacyCache
    let info = systemInfoProvider()
    systemInfo = info
    hardware = HardwareCheck.evaluate(
      info, requiredBytes: snapshot.missingBytes, availableBytes: snapshot.availableBytes)
  }

  /// «Перенести из кэша»: модели, уже скачанные `argmax-cli`/FluidAudio, копируются в хранилище
  /// приложения (на APFS это клоны — секунды и без места).
  public func importFromLegacyCache() async {
    guard !isImportingLegacyCache else { return }
    isImportingLegacyCache = true
    legacyImportText = nil
    let store = modelStore
    let result = await Task.detached { () -> Result<ModelStore.ImportReport, any Error> in
      do {
        return .success(try store.importExisting())
      } catch {
        return .failure(error)
      }
    }.value
    isImportingLegacyCache = false
    switch result {
    case .success(let report):
      if report.imported.isEmpty {
        legacyImportText =
          report.failed.isEmpty
          ? String(
            localized: "В старых кэшах не нашлось нужных моделей — скачайте их кнопкой выше.")
          : String(localized: "Не удалось перенести: \(report.failed.joined(separator: "; "))")
      } else {
        legacyImportText = String(
          localized: "Перенесено из кэша: \(report.imported.joined(separator: ", "))")
      }
    case .failure(let error):
      legacyImportText = error.localizedDescription
    }
    await refresh()
  }

  // MARK: - Внутреннее

  private struct Snapshot: Sendable {
    var statuses: [ModelStatus]
    var missing: [ModelID]
    var missingBytes: Int64
    var availableBytes: Int64?
    var hasLegacyCache: Bool
  }

  /// Есть ли на машине старые кэши моделей (папки `~/Documents/huggingface/models` и FluidAudio).
  nonisolated static func hasLegacyCache(fileManager: FileManager = .default) -> Bool {
    let legacy = ModelStore.LegacyLocations.standard(fileManager: fileManager)
    return [legacy.huggingFaceModels, legacy.fluidAudioModels].contains {
      fileManager.fileExists(atPath: $0.path(percentEncoded: false))
    }
  }
}
