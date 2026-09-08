import AppKit
import Core
import Engines
import Export
import Foundation
import Ingest
import ModelDownload
import OCR
import Observation
import Pipeline
import Store
import SwiftUI
import UserNotifications

/// Выбор в боковой панели (DESIGN.md §2): проект раскрывается во встречи, внизу «Все встречи» и «Люди».
nonisolated public enum SidebarSelection: Hashable, Sendable {
  case allMeetings
  case people
  case meeting(UUID)

  public var meetingID: UUID? {
    if case .meeting(let id) = self { return id }
    return nil
  }
}

/// Вкладки инспектора (DESIGN.md §2, §4).
nonisolated public enum InspectorTab: String, CaseIterable, Hashable, Sendable {
  case speakers
  case details
  case projectContext

  public var title: String {
    switch self {
    case .speakers: String(localized: "Спикеры")
    case .details: String(localized: "Сведения")
    case .projectContext: String(localized: "Контекст проекта")
    }
  }
}

/// Вкладки окна настроек (DESIGN.md §5).
nonisolated public enum SettingsTab: String, CaseIterable, Hashable, Sendable {
  case general
  case engines
  case languages
  case people
  case followup
  case diagnostics

  public var title: String {
    switch self {
    case .general: String(localized: "Общие")
    case .engines: String(localized: "Движки и модели")
    case .languages: String(localized: "Языки")
    case .people: String(localized: "Люди и голоса")
    case .followup: "Follow-up"
    case .diagnostics: String(localized: "Диагностика")
    }
  }
}

/// Справка из меню Help (DESIGN.md §6).
nonisolated public enum HelpTopic: String, Identifiable, Hashable, Sendable {
  case guide
  case zoomTracks

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .guide: String(localized: "Руководство")
    case .zoomTracks: String(localized: "Как включить раздельные дорожки в Zoom")
    }
  }
}

/// Проект для новой встречи в диалоге импорта.
nonisolated public enum ProjectChoice: Hashable, Sendable {
  case none
  case existing(UUID)
  case new
}

/// Параметры диалога импорта (DESIGN.md §5): файлы, проект, число участников, язык, режим.
nonisolated public struct ImportRequest: Identifiable, Hashable, Sendable {
  /// Один файл к импорту: длительность подтягивается пробой контейнера, `problem` — почему файл не годится.
  /// `recording` — папка записи Zoom, если файл лежит в ней (видео для OCR, chat.txt, раздельные дорожки);
  /// `useSeparateTracks` — обрабатывать по дорожкам `Audio Record/` (SPEC.md §2 п. 7), если они есть.
  public struct Item: Identifiable, Hashable, Sendable {
    public var url: URL
    /// Что пользователь выбрал или перетащил — папка записи или сам файл: на него создаётся закладка доступа
    /// для песочницы хоста (`SourceBookmarkStore`), чтобы дорожки и chat.txt рядом оставались доступны.
    public var accessRoot: URL
    public var duration: Double?
    public var problem: String?
    public var recording: ZoomRecording?
    public var useSeparateTracks: Bool

    public var id: URL { url }

    public init(
      url: URL, duration: Double? = nil, problem: String? = nil, recording: ZoomRecording? = nil,
      useSeparateTracks: Bool = true, accessRoot: URL? = nil
    ) {
      self.url = url
      self.accessRoot = accessRoot ?? url
      self.duration = duration
      self.problem = problem
      self.recording = recording
      self.useSeparateTracks = useSeparateTracks
    }

    public var name: String { url.lastPathComponent }

    /// Дорожки, которые уйдут в обработку.
    public var tracks: [ZoomRecording.Track] {
      guard useSeparateTracks, let recording else { return [] }
      return recording.tracks
    }

    /// Видео для распознавания подписей: сам файл, если это видео, иначе `video*.mp4` из папки записи.
    public var videoURL: URL? {
      Self.videoExtensions.contains(url.pathExtension.lowercased()) ? url : recording?.videoURL
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
  }

  public var id = UUID()
  public var items: [Item]
  public var project: ProjectChoice
  public var newProjectName: String
  /// Подсказывать ли диаризатору число участников.
  public var usesExpectedSpeakers: Bool
  public var expectedSpeakers: Int
  public var language: LanguageChoice
  public var engines: EngineSelection

  public init(
    items: [Item],
    project: ProjectChoice = .none,
    newProjectName: String = "",
    usesExpectedSpeakers: Bool = false,
    expectedSpeakers: Int = 4,
    language: LanguageChoice = .auto,
    engines: EngineSelection = .accurate
  ) {
    self.items = items
    self.project = project
    self.newProjectName = newProjectName
    self.usesExpectedSpeakers = usesExpectedSpeakers
    self.expectedSpeakers = expectedSpeakers
    self.language = language
    self.engines = engines
  }

  /// Файлы, которые можно обработать (без ошибок пробы).
  public var usableItems: [Item] { items.filter { $0.problem == nil } }
}

/// Запрос на сохранение файла через `.fileExporter`.
nonisolated public struct ExportRequest: Identifiable, Hashable, Sendable {
  public var id = UUID()
  public var document: TranscriptDocument
  public var format: ExportFormat
  public var defaultFilename: String

  public init(document: TranscriptDocument, format: ExportFormat, defaultFilename: String) {
    self.document = document
    self.format = format
    self.defaultFilename = defaultFilename
  }
}

/// Сообщение пользователю: что случилось и что сделать (DESIGN.md §1). Подтверждения удаления несут
/// идентификатор объекта — действие выполняется моделью, а не замыканием в значении.
nonisolated public struct AppAlert: Identifiable, Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case message
    case confirmDeleteMeeting(UUID)
    case confirmDeleteProject(UUID)
    /// Фаза 3: удалить человека из «Люди» (профиль голоса), имена в встречах остаются.
    case confirmDeletePerson(UUID)
    /// Фаза 3: спикер привязан к человеку, а имя изменено — переименовать человека во всех встречах
    /// или создать нового только для этой.
    case confirmRenamePerson(personID: UUID, newName: String, meetingID: UUID, speakerID: Int)
    /// Фаза 3: объединить двух спикеров встречи (реплики `source` перейдут к `target`).
    case confirmMergeSpeakers(source: Int, target: Int, meetingID: UUID)
    /// Файл собран (отчёт о проблеме, самопроверка) — предложение показать его в Finder.
    case revealFile(URL)
  }

  public var id = UUID()
  public var title: String
  public var message: String?
  public var kind: Kind

  public init(title: String, message: String? = nil, kind: Kind = .message) {
    self.title = title
    self.message = message
    self.kind = kind
  }
}

/// Корневая модель приложения: библиотека встреч, выбор, импорт, экспорт, транскрипт открытой встречи.
/// Живёт в `App` (одна на процесс), окна и команды меню читают её через `@Bindable`/параметры.
@Observable
public final class AppModel {
  public let settings: AppSettings
  public let store: LibraryStore
  public let engines: any EngineProviding
  /// Хранилище моделей: пути только через него (CLAUDE.md).
  public let modelStore: ModelStore
  /// Загрузчик моделей: боевой `ModelDownloader` или сценарный для UI-тестов.
  public let downloader: any ModelDownloading
  public let coordinator: ProcessingCoordinator
  /// Закладки доступа к исходникам записей — для песочницы хоста (ADR-010, SPEC.md §3.1).
  public let sourceBookmarks: SourceBookmarkStore
  /// Заголовок окна, пока встреча не выбрана; хост (ADR-010) подставляет свой («Встречи»).
  public var windowTitle = "MeetingScribe"
  public let playback = PlaybackController()
  /// Скачивание моделей (онбординг и настройки): состояние переживает закрытие окон.
  public let modelDownloads = ModelDownloadController()
  /// Первый запуск (SPEC.md §2 п. 8): шаги живут в контроллере, sheet можно закрыть и открыть снова.
  public let onboarding: OnboardingController
  /// Самопроверка на встроенном сэмпле (SPEC.md §3.8) — онбординг и вкладка «Диагностика».
  public let selfTest = SelfTestController()
  /// Распознавание подписей на видео (фаза 3): одно сканирование за раз, состояние живёт в модели.
  public let nameScan = NameScanController()
  /// Встреча, к которой относится итог последнего сканирования.
  public internal(set) var nameScanSummaryMeetingID: UUID?

  public internal(set) var library: Library = .empty
  /// Ошибка чтения индекса — показывается в интерфейсе, приложение продолжает с пустой библиотекой.
  public private(set) var libraryLoadError: String?

  /// Выбор в боковой панели.
  public var selection: SidebarSelection? {
    didSet { if selection != oldValue { selectionChanged() } }
  }
  /// Открытая встреча (`nil` — выбран раздел «Все встречи»/«Люди» или ничего).
  public private(set) var selectedMeetingID: UUID?
  /// Сырые транскрипты по встречам; для показа и экспорта — `displayTranscript(for:)`.
  public internal(set) var transcripts: [UUID: Transcript] = [:]

  public var searchText: String = "" {
    didSet { if searchText != oldValue { searchTextChanged() } }
  }
  /// Где ищем: по репликам открытой встречи или по всей библиотеке (SPEC.md §2 п. 6).
  public var searchScope: SearchScope = .library {
    didSet { if searchScope != oldValue { searchScopeChanged() } }
  }
  /// Результаты поиска по библиотеке (реплики, решения, задачи, вопросы).
  public internal(set) var libraryResults: [LibrarySearchResult] = []
  /// Запрос к базе ещё выполняется (миллисекунды — подпись, а не индикатор).
  public internal(set) var isSearchingLibrary = false
  /// Фильтр по спикеру в шапке встречи; `nil` — все спикеры.
  public var speakerFilter: Int? {
    didSet { if speakerFilter != oldValue { refreshRows() } }
  }
  /// Готовые строки открытой встречи с учётом поиска и фильтра.
  public private(set) var displayRows: [TranscriptRow] = []
  /// Выбранная реплика в списке.
  public var selectedRowID: Int?
  /// Реплика, к которой нужно проскроллить (⌘G и переход из поиска).
  public internal(set) var scrollTarget: Int?
  /// Переход к таймкоду, отложенный до появления строк (транскрипт грузится асинхронно).
  public internal(set) var pendingTimecode: Double?
  /// Переход к реплике по номеру, отложенный до появления строк (переход из поиска по библиотеке).
  public internal(set) var pendingScrollIndex: Int?

  public var isInspectorPresented = false
  public var inspectorTab: InspectorTab = .speakers
  public var columnVisibility: NavigationSplitViewVisibility = .all
  public var settingsTab: SettingsTab = .general
  public var expandedProjects: Set<UUID> = []
  public var isUnfiledExpanded = true

  /// Диалог «Новый проект» (кнопка в боковой панели и ⌘N).
  public var isCreatingProject = false
  public var newProjectName = ""

  public var pendingImport: ImportRequest?
  public var isFileImporterPresented = false
  public var exportRequest: ExportRequest?
  public var alert: AppAlert?
  public var presentedHelp: HelpTopic?
  public var isGoToTimecodePresented = false
  /// Встреча, для которой открыт диалог «Импорт follow-up» (`nil` — диалог закрыт).
  public var followupImportMeetingID: UUID?
  /// Открыть диалог сразу в режиме генерации локальной моделью.
  public var followupStartsGeneration = false
  /// Проект, чья история follow-up открыта (`nil` — окно закрыто); `followupHistorySelectedID` —
  /// какой follow-up показать первым.
  public var followupHistoryProjectID: UUID?
  public var followupHistorySelectedID: UUID?
  /// Выбор папки для vault Obsidian; `pendingVaultScope` — что именно экспортируем.
  public var isVaultFolderPickerPresented = false
  public internal(set) var pendingVaultScope: VaultScope?
  /// Генерация follow-up локальной моделью: состояние живёт в модели, диалог можно закрыть и открыть.
  public let followupGeneration = FollowupGenerationController()
  /// Прогресс экспорта vault: полоса «N из M заметок», пульс и отмена (SPEC.md §3.7).
  public let vaultExport = VaultExportController()
  /// «Переназначить спикера…» ⌘⇧S для выбранной реплики (фаза 3).
  public var reassignRow: TranscriptRow?
  /// Импорт и экспорт профилей людей (Settings → Люди и голоса): панели живут на окне настроек,
  /// чтобы работать и при закрытом главном окне.
  public var isPeopleImporterPresented = false
  public var peopleExportRequest: ExportRequest?

  /// Обновления приложения: Sparkle у самостоятельного MeetingScribe (таргет `MeetingScribeSparkle`, ADR-009),
  /// `NoUpdater` у хоста, который встраивает ядро как функцию (ADR-010) — тогда пункт меню и секция скрыты.
  public let updater: any UpdaterProviding
  /// Последний собранный отчёт о проблеме — кнопка «Показать в Finder».
  public private(set) var problemReportURL: URL?
  public private(set) var isCollectingProblemReport = false
  /// Итог «Проверить файлы» на вкладке «Диагностика».
  public private(set) var modelVerificationText: String?
  public private(set) var isVerifyingModels = false
  /// Доля проверки файлов моделей 0…1 (по байтам, монотонно) и строка состояния.
  public private(set) var modelVerificationFraction: Double = 0
  public private(set) var modelVerificationStatus: String?
  @ObservationIgnored private var verifyTask: Task<Void, Never>?

  /// «Найти имена на видео» доступно, когда у открытой встречи есть видео и транскрипт.
  public var canScanVideoForNames: Bool {
    guard let record = selectedMeeting, record.videoURL != nil else { return false }
    return transcripts[record.id] != nil && !nameScan.isScanning
  }
  /// Счётчик запросов фокуса в поле поиска (⌘F): окно реагирует на изменение значения.
  public private(set) var searchFocusRequests = 0

  @ObservationIgnored private var hasBootstrapped = false
  @ObservationIgnored private var librarySaveTask: Task<Void, Never>?
  /// Сколько сохранений библиотеки ещё не дошло до диска (`hasPendingLibrarySave`).
  @ObservationIgnored private var pendingLibrarySaves = 0
  /// Текущий запрос к поиску по библиотеке: следующий ввод отменяет предыдущий (debounce).
  @ObservationIgnored var librarySearchTask: Task<Void, Never>?
  /// Цепочки записи транскриптов по встречам (правки реплик и спикеров идут часто).
  @ObservationIgnored var transcriptSaveTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var didRequestNotificationAuthorization = false

  public init(
    settings: AppSettings,
    store: LibraryStore,
    engines: any EngineProviding,
    modelStore: ModelStore = .standard(),
    downloader: (any ModelDownloading)? = nil,
    updater: (any UpdaterProviding)? = nil
  ) {
    self.updater = updater ?? NoUpdater()
    self.settings = settings
    self.store = store
    self.engines = engines
    self.modelStore = modelStore
    self.downloader = downloader ?? ScriptedModelDownloader(store: modelStore)
    self.onboarding = OnboardingController(settings: settings, modelStore: modelStore)
    let sourceBookmarks = SourceBookmarkStore(
      directory: store.directory.appending(path: "bookmarks", directoryHint: .isDirectory))
    self.sourceBookmarks = sourceBookmarks
    self.coordinator = ProcessingCoordinator(
      engines: engines, store: store, settings: settings, sourceBookmarks: sourceBookmarks)
    coordinator.onUpdate = { [weak self] update in
      self?.handle(update)
    }
  }

  /// Ответ на запрос выхода из приложения — для делегата самостоятельного MeetingScribe и делегата хоста
  /// (ADR-010): выход во время обработки теряет результат стадии, поэтому спрашивается подтверждение
  /// стандартным алертом; незаписанные изменения библиотеки задерживают выход на `librarySaveGrace`
  /// (`.terminateLater` — ответ придёт через `sender.reply(toApplicationShouldTerminate:)`).
  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if coordinator.hasPendingWork {
      let alert = NSAlert()
      alert.messageText = String(localized: "Идёт обработка встречи")
      alert.informativeText =
        String(
          localized:
            "Если выйти сейчас, обработка прервётся и её придётся повторить. Продолжить выход?")
      alert.alertStyle = .warning
      alert.addButton(withTitle: String(localized: "Выйти"))
      alert.addButton(withTitle: String(localized: "Отмена"))
      guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    }
    guard hasPendingLibrarySave else { return .terminateNow }
    Task {
      await waitForPendingLibrarySave(timeout: Self.librarySaveGrace)
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Сколько ждать записи библиотеки перед выходом: диск может быть занят, но зависать нельзя.
  public static let librarySaveGrace: Duration = .seconds(3)

  /// Боевая сборка: стандартная папка библиотеки (или `MEETINGSCRIBE_LIBRARY_DIR`); сценарные движки
  /// и сценарный загрузчик моделей — только по launch-аргументу `-MSFakeEngines YES` в DEBUG
  /// (`AppSettings.useFakeEngines`). Хост (ADR-010) задаёт свои папки библиотеки и моделей и свой апдейтер;
  /// без апдейтера — `NoUpdater`.
  public static func live(
    libraryDirectory: URL? = nil,
    modelsRoot: URL? = nil,
    defaultEngines: EngineSelection = .accurate,
    updater: ((AppSettings) -> any UpdaterProviding)? = nil
  ) -> AppModel {
    let settings = AppSettings(defaultEngines: defaultEngines)
    let store = LibraryStore(directory: libraryDirectory ?? LibraryStore.standardDirectory())
    let modelStore = modelsRoot.map(ModelStore.init(root:)) ?? ModelStore.standard()
    let engines: any EngineProviding =
      settings.useFakeEngines ? ScriptedEngines() : ProductionEngines(modelStore: modelStore)
    let downloader: any ModelDownloading =
      settings.useFakeEngines
      ? ScriptedModelDownloader(store: modelStore)
      : ModelDownloader(store: modelStore, downloaderVersion: MeetingScribeUIInfo.version)
    return AppModel(
      settings: settings, store: store, engines: engines, modelStore: modelStore,
      downloader: downloader, updater: updater?(settings))
  }

  /// Загрузка библиотеки при старте (активные статусы уже демотированы в `interrupted` хранилищем).
  public func bootstrap() async {
    guard !hasBootstrapped else { return }
    hasBootstrapped = true
    do {
      library = try await store.load()
    } catch {
      libraryLoadError = error.localizedDescription
      alert = AppAlert(
        title: String(localized: "Библиотека не открылась"), message: error.localizedDescription)
      library = .empty
    }
    expandedProjects = Set(library.projects.map(\.id))
    if let launchFile = settings.importFileAtLaunch {
      importURLs([launchFile])
    }
    // Первый запуск: онбординг открывается сам, пока не пройден и не пропущен (SPEC.md §2 п. 8).
    onboarding.presentIfNeeded()
  }

  // MARK: - Выбор

  public func select(_ selection: SidebarSelection?) {
    self.selection = selection
  }

  public func selectMeeting(_ id: UUID) {
    selection = .meeting(id)
  }

  /// Открытая запись встречи.
  public var selectedMeeting: MeetingRecord? {
    selectedMeetingID.flatMap { library.meeting(id: $0) }
  }

  /// Прогресс открытой встречи (для тулбара и карточки).
  public var selectedProgress: MeetingProgressModel? {
    selectedMeetingID.flatMap { coordinator.progress(for: $0) }
  }

  /// Прогресс, который показывает тулбар: открытая встреча, иначе та, что обрабатывается сейчас.
  public var toolbarProgress: MeetingProgressModel? {
    if let progress = selectedProgress, !progress.isFinished { return progress }
    return coordinator.activeMeetingID.flatMap { coordinator.progress(for: $0) }
  }

  /// Встреча, к которой относится прогресс в тулбаре.
  public var toolbarProgressMeeting: MeetingRecord? {
    toolbarProgress.flatMap { library.meeting(id: $0.meetingID) }
  }

  private func selectionChanged() {
    let meetingID = selection?.meetingID
    // Встреча — ищем по её репликам, разделы библиотеки — по всей библиотеке (SPEC.md §2 п. 6).
    searchScope = meetingID == nil ? .library : .meeting
    guard meetingID != selectedMeetingID else { return }
    selectedMeetingID = meetingID
    searchText = ""
    speakerFilter = nil
    selectedRowID = nil
    scrollTarget = nil
    pendingTimecode = nil
    pendingScrollIndex = nil
    playback.unload()
    guard let meetingID, let record = library.meeting(id: meetingID) else {
      displayRows = []
      return
    }
    playback.load(record: record, cachedAudio: cachedAudioURL(for: meetingID)) {
      [sourceBookmarks] in sourceBookmarks.access(for: meetingID)
    }
    if transcripts[meetingID] == nil, record.hasTranscript {
      loadTranscript(for: meetingID)
    }
    refreshRows()
  }

  func cachedAudioURL(for id: UUID) -> URL {
    store.meetingDirectory(for: id).appending(path: AudioDecoder.outputFileName)
  }

  private func loadTranscript(for id: UUID) {
    Task { [weak self] in
      guard let self else { return }
      do {
        if let transcript = try await store.loadTranscript(for: id) {
          transcripts[id] = transcript
          if id == selectedMeetingID { refreshRows() }
        }
      } catch {
        alert = AppAlert(
          title: String(localized: "Транскрипт не открылся"), message: error.localizedDescription)
      }
    }
  }

  // MARK: - Транскрипт и строки

  /// Транскрипт для показа и экспорта: имена спикеров пользователя и актуальные сведения о встрече.
  public func displayTranscript(for id: UUID) -> Transcript? {
    transcripts[id].map { projected($0, record: library.meeting(id: id)) }
  }

  /// Та же проекция для транскрипта, прочитанного мимо кэша (экспорт vault по всей библиотеке).
  public func projected(_ transcript: Transcript, record: MeetingRecord?) -> Transcript {
    guard let record else { return transcript }
    return Self.projected(transcript, record: record, projectName: projectName(for: record))
  }

  /// Проекция без модели: значения на входе, значение на выходе — её делает и работник vault
  /// вне главного актора.
  nonisolated public static func projected(
    _ transcript: Transcript, record: MeetingRecord, projectName: String?
  ) -> Transcript {
    var display = transcript.applyingSpeakerNames(record.speakerNames)
    let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
    display.meeting = MeetingInfo(
      title: title.isEmpty ? transcript.meeting.title : title,
      date: record.date ?? transcript.meeting.date,
      project: projectName ?? transcript.meeting.project)
    return display
  }

  /// Строки списка для встречи с текущими поиском и фильтром.
  public func rows(for id: UUID) -> [TranscriptRow] {
    guard let transcript = displayTranscript(for: id) else { return [] }
    return TranscriptRow.rows(
      from: transcript, search: searchText, speakerFilter: speakerFilter)
  }

  /// Спикеры открытой встречи с применёнными именами.
  public func speakers(for id: UUID) -> [SpeakerStats] {
    (displayTranscript(for: id)?.speakers ?? []).sorted {
      ($0.speakerID ?? Int.max) < ($1.speakerID ?? Int.max)
    }
  }

  /// До трёх самых длинных реплик спикера — образцы для прослушивания в инспекторе.
  public func samples(forSpeaker speakerID: Int?, meetingID: UUID, limit: Int = 3) -> [Utterance] {
    guard let transcript = transcripts[meetingID] else { return [] }
    return
      transcript.utterances
      .filter { $0.speakerID == speakerID }
      .sorted { $0.duration > $1.duration }
      .prefix(limit)
      .sorted { $0.start < $1.start }
  }

  func refreshRows() {
    guard let id = selectedMeetingID else {
      displayRows = []
      return
    }
    displayRows = rows(for: id)
    if let selectedRowID, !displayRows.contains(where: { $0.id == selectedRowID }) {
      self.selectedRowID = nil
    }
    applyPendingNavigation()
  }

  /// Переход, запрошенный до загрузки транскрипта (запись памяти, результат поиска), выполняется,
  /// как только транскрипт прочитан: до этого строк нет и ждать нечего.
  private func applyPendingNavigation() {
    guard let meetingID = selectedMeetingID, transcripts[meetingID] != nil else { return }
    if let index = pendingScrollIndex {
      let fallback = pendingTimecode
      // Снимаем ожидание до правок фильтра: они перезапустят `refreshRows`.
      pendingScrollIndex = nil
      pendingTimecode = nil
      if revealRow(index) {
        selectedRowID = index
        scrollTarget = index
        return
      }
      // Реплики в транскрипте нет (индекс из устаревшего поиска) — переход по времени.
      if let fallback { goToTimecode(fallback) }
      return
    }
    guard !displayRows.isEmpty else { return }
    if let seconds = pendingTimecode {
      pendingTimecode = nil
      goToTimecode(seconds)
    }
  }

  /// Показывает реплику `index` в списке, снимая фильтры, которые её прячут. Поиск по библиотеке
  /// ищет префиксы слов через AND, а фильтр реплик — подстроку целиком: запрос «когда решили X»
  /// находит реплику в выдаче, но в открытой встрече не оставил бы ни одной строки, и переход
  /// упёрся бы в «Ничего не найдено». Возвращает `false`, если реплики в транскрипте нет.
  @discardableResult
  func revealRow(_ index: Int) -> Bool {
    if displayRows.contains(where: { $0.id == index }) { return true }
    if !searchText.isEmpty { searchText = "" }
    if displayRows.contains(where: { $0.id == index }) { return true }
    if speakerFilter != nil { speakerFilter = nil }
    return displayRows.contains(where: { $0.id == index })
  }

  /// Правка текста реплики (двойной клик по строке).
  public func updateUtteranceText(meetingID: UUID, index: Int, text: String) {
    guard var transcript = transcripts[meetingID], transcript.utterances.indices.contains(index)
    else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != transcript.utterances[index].text else { return }
    transcript.utterances[index].text = trimmed
    commitTranscript(transcript, for: meetingID)
  }

  /// Переход к таймкоду (⌘G): ближайшая реплика, начавшаяся не позже указанного времени.
  public func goToTimecode(_ seconds: Double) {
    guard !displayRows.isEmpty else { return }
    let target =
      displayRows.last { $0.start <= seconds }
      ?? displayRows.min { abs($0.start - seconds) < abs($1.start - seconds) }
    guard let target else { return }
    selectedRowID = target.id
    scrollTarget = target.id
  }

  /// ⌘⇧S — переназначить спикера выбранной реплики.
  public func beginReassigningSelectedRow() {
    guard let id = selectedRowID, let row = displayRows.first(where: { $0.id == id }) else {
      return
    }
    reassignRow = row
  }

  /// ⌘F — курсор в поле поиска.
  public func focusSearch() {
    searchFocusRequests += 1
  }

  /// Сбрасывает запрос на прокрутку после того, как список её выполнил.
  public func clearScrollTarget() {
    scrollTarget = nil
  }

  /// Играет фрагмент реплики.
  public func play(row: TranscriptRow) {
    playback.play(from: row.start, to: row.end)
  }

  /// Реплика с таймкодом для буфера обмена: `[00:12:34] Имя: текст`.
  public func copyRow(_ row: TranscriptRow, to pasteboard: NSPasteboard = .general) {
    let line =
      "\(Timecode.bracketed(row.start, tenths: settings.tenthsInTimecodes)) "
      + "\(row.speakerName): \(row.text)"
    write(line, toPasteboard: pasteboard)
  }

  // MARK: - Импорт

  /// Медиафайлы, которые приложение предлагает импортировать из папки.
  nonisolated public static let supportedExtensions: Set<String> = [
    "mp4", "mov", "m4v", "m4a", "mp3", "wav", "aif", "aiff", "caf", "flac", "aac",
  ]

  /// Показывает диалог импорта для файлов и папок: папка записи Zoom → общий трек `audio*.m4a`,
  /// иначе `video*.mp4`, иначе поддерживаемые медиафайлы внутри (skill zoom-import). Для каждого файла
  /// ищется папка записи Zoom — видео для OCR, chat.txt и раздельные дорожки (фаза 3).
  public func importURLs(_ urls: [URL]) {
    let located = Self.mediaFilesWithRoots(in: urls)
    let files = located.map(\.file)
    guard !files.isEmpty else {
      alert = AppAlert(
        title: String(localized: "Нечего импортировать"),
        message:
          String(
            localized:
              "В выбранном нет записи Zoom. Перетащите папку записи целиком или файл audio*.m4a / video*.mp4."
          )
      )
      return
    }
    let request = ImportRequest(
      items: located.map { entry in
        ImportRequest.Item(
          url: entry.file, recording: ZoomRecording.locate(entry.file), accessRoot: entry.root)
      },
      project: currentProjectChoice,
      usesExpectedSpeakers: settings.defaultExpectedSpeakers != nil,
      expectedSpeakers: settings.defaultExpectedSpeakers ?? 4,
      language: settings.defaultLanguage,
      engines: settings.engines)
    pendingImport = request
    probeDurations(files, requestID: request.id)
  }

  /// Проект по умолчанию для новой встречи — проект открытой встречи.
  private var currentProjectChoice: ProjectChoice {
    if let projectID = selectedMeeting?.projectID { return .existing(projectID) }
    return .none
  }

  /// Длительности файлов: заголовок контейнера читается вне главного потока, диалог обновляется по мере готовности.
  private func probeDurations(_ files: [URL], requestID: UUID) {
    let decoder = engines.decoder()
    Task { [weak self] in
      for file in files {
        var duration: Double?
        var problem: String?
        do {
          duration = try await decoder.probe(file).duration
        } catch {
          problem = error.localizedDescription
        }
        guard let self, pendingImport?.id == requestID else { return }
        if let index = pendingImport?.items.firstIndex(where: { $0.url == file }) {
          pendingImport?.items[index].duration = duration
          pendingImport?.items[index].problem = problem
        }
      }
    }
  }

  /// Создаёт записи встреч, ставит их в очередь и открывает первую.
  public func confirmImport(_ request: ImportRequest) {
    pendingImport = nil
    let projectID = resolveProject(request)
    let projectName = projectID.flatMap { library.project(id: $0)?.name }
    var firstID: UUID?
    for item in request.usableItems {
      let info = MeetingInfo.inferred(from: item.url)
      let title =
        info.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? item.url.deletingPathExtension().lastPathComponent
      let tracks = item.tracks
      let record = MeetingRecord(
        projectID: projectID,
        title: title,
        date: info.date,
        sourceURL: item.url,
        duration: item.duration,
        // По дорожкам число участников известно точно — подсказка диаризатору не нужна.
        expectedSpeakers: tracks.isEmpty && request.usesExpectedSpeakers
          ? request.expectedSpeakers : nil,
        language: request.language,
        engines: request.engines,
        status: .imported,
        trackURLs: tracks.map(\.url),
        videoURL: item.videoURL,
        chatURL: item.recording?.chatURL)
      library.upsert(record)
      // Песочница хоста: доступ к перетащенному или выбранному элементу переживает перезапуск только
      // через закладку (ADR-010); без песочницы закладка безвредна.
      sourceBookmarks.save(item.accessRoot, for: record.id)
      if firstID == nil { firstID = record.id }
      coordinator.enqueue(record, projectName: projectName)
    }
    saveLibrary()
    requestNotificationAuthorizationIfNeeded()
    if let firstID { selectMeeting(firstID) }
  }

  private func resolveProject(_ request: ImportRequest) -> UUID? {
    switch request.project {
    case .none:
      return nil
    case .existing(let id):
      return id
    case .new:
      let name = request.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }
      return createProject(named: name)
    }
  }

  /// Файлы для импорта: сам файл, для папки — общий трек Zoom, иначе видео, иначе медиа внутри.
  nonisolated static func mediaFiles(in urls: [URL], fileManager: FileManager = .default) -> [URL] {
    mediaFilesWithRoots(in: urls, fileManager: fileManager).map(\.file)
  }

  /// Файлы для импорта вместе с корнем, который выбрал пользователь (папка записи или сам файл): на корень
  /// создаётся закладка доступа для песочницы хоста (ADR-010).
  nonisolated static func mediaFilesWithRoots(in urls: [URL], fileManager: FileManager = .default)
    -> [(file: URL, root: URL)]
  {
    var result: [(file: URL, root: URL)] = []
    for url in urls {
      var isDirectory: ObjCBool = false
      guard
        fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
      else { continue }
      if isDirectory.boolValue {
        result.append(
          contentsOf: mediaFiles(inFolder: url, fileManager: fileManager).map { ($0, url) })
      } else {
        result.append((url, url))
      }
    }
    var seen = Set<URL>()
    return result.filter { seen.insert($0.file.standardizedFileURL).inserted }
  }

  nonisolated static func mediaFiles(inFolder folder: URL, fileManager: FileManager) -> [URL] {
    let entries =
      (try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    let files =
      entries
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    func matching(prefix: String, ext: String) -> [URL] {
      files.filter {
        $0.lastPathComponent.lowercased().hasPrefix(prefix)
          && $0.pathExtension.lowercased() == ext
      }
    }
    // Общий трек Zoom легче видео и содержит ту же дорожку (skill zoom-import).
    let audio = matching(prefix: "audio", ext: "m4a")
    if !audio.isEmpty { return audio }
    let video = matching(prefix: "video", ext: "mp4")
    if !video.isEmpty { return video }
    return files.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
  }

  // MARK: - Обработка

  /// Можно ли запустить обработку встречи (первый прогон или повтор).
  public func canProcess(_ record: MeetingRecord) -> Bool {
    switch record.status {
    case .imported, .cancelled, .failed, .interrupted, .ready: true
    case .queued, .processing: false
    }
  }

  /// «Обработать» / «Повторить обработку».
  public func process(_ id: UUID) {
    guard let record = library.meeting(id: id), canProcess(record) else { return }
    coordinator.enqueue(record, projectName: projectName(for: record))
    requestNotificationAuthorizationIfNeeded()
  }

  public func cancel(_ id: UUID) {
    coordinator.cancel(id)
  }

  /// «Отменить и собрать отчёт» — сторож зависания (SPEC.md §3.7 п. 6).
  public func cancelAndCollectReport(_ id: UUID) {
    Task { [weak self] in
      guard let self else { return }
      let url = await coordinator.cancelAndCollectReport(id)
      if let url {
        alert = AppAlert(
          title: String(localized: "Отчёт сохранён"), message: url.path(percentEncoded: false))
      }
    }
  }

  // MARK: - Встречи и проекты

  public func rename(meeting id: UUID, to title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var record = library.meeting(id: id), record.title != trimmed else {
      return
    }
    record.title = trimmed
    library.upsert(record)
    saveLibrary()
    if id == selectedMeetingID { refreshRows() }
  }

  public func move(meeting id: UUID, toProject projectID: UUID?) {
    guard var record = library.meeting(id: id), record.projectID != projectID else { return }
    record.projectID = projectID
    library.upsert(record)
    saveLibrary()
    if let projectID { expandedProjects.insert(projectID) }
    if id == selectedMeetingID { refreshRows() }
  }

  /// Спрашивает подтверждение: удаляются данные приложения, исходный файл пользователя остаётся.
  public func requestDelete(meeting id: UUID) {
    guard let record = library.meeting(id: id) else { return }
    alert = AppAlert(
      title: String(localized: "Удалить встречу «\(record.title)»?"),
      message: String(
        localized: "Транскрипт и кэш аудио будут удалены. Исходный файл записи останется на месте."),
      kind: .confirmDeleteMeeting(id))
  }

  public func delete(meeting id: UUID) {
    let wasActive = coordinator.activeMeetingID == id
    // Прогон отменяется и забывается: его итоги не сохраняются и не воскрешают запись.
    coordinator.forget(id)
    library.removeMeeting(id: id)
    sourceBookmarks.remove(for: id)
    transcripts.removeValue(forKey: id)
    if selectedMeetingID == id { selection = nil }
    saveLibrary()
    Task { [weak self] in
      guard let self else { return }
      // Папка кэша стирается после того, как отменённый прогон её отпустил (отмена — до 2 с).
      if wasActive { await waitUntilInactive(id) }
      do {
        try await store.deleteMeetingData(for: id)
      } catch {
        alert = AppAlert(
          title: String(localized: "Файлы встречи не удалились"),
          message: error.localizedDescription)
      }
    }
  }

  private func waitUntilInactive(_ id: UUID) async {
    for _ in 0..<50 where coordinator.activeMeetingID == id {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Открывает диалог создания проекта (⌘N и кнопка в боковой панели).
  public func beginCreatingProject() {
    newProjectName = ""
    isCreatingProject = true
  }

  @discardableResult
  public func createProject(named name: String) -> UUID? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let project = ProjectRecord(name: trimmed)
    library.upsert(project)
    expandedProjects.insert(project.id)
    saveLibrary()
    return project.id
  }

  public func renameProject(_ id: UUID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var project = library.project(id: id), project.name != trimmed else {
      return
    }
    project.name = trimmed
    library.upsert(project)
    saveLibrary()
  }

  public func requestDelete(project id: UUID) {
    guard let project = library.project(id: id) else { return }
    alert = AppAlert(
      title: String(localized: "Удалить проект «\(project.name)»?"),
      message:
        String(
          localized:
            "Решения, задачи и вопросы проекта будут удалены; встречи останутся в библиотеке без проекта."
        ),
      kind: .confirmDeleteProject(id))
  }

  public func deleteProject(_ id: UUID) {
    library.removeProject(id: id)
    expandedProjects.remove(id)
    saveLibrary()
  }

  public func projectName(for record: MeetingRecord) -> String? {
    record.projectID.flatMap { library.project(id: $0)?.name }
  }

  /// Показать файл записи в Finder.
  public func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  public func revealMeetingSource(_ id: UUID) {
    guard let record = library.meeting(id: id) else { return }
    revealInFinder(record.sourceURL)
  }

  // MARK: - Экспорт

  /// Markdown `TranscribeFull` открытой или указанной встречи — один рендер для копирования и сохранения.
  public func renderMarkdown(for id: UUID) -> String? {
    guard let transcript = displayTranscript(for: id) else { return nil }
    let record = library.meeting(id: id)
    return TranscribeFullExporter.render(
      transcript,
      options: TranscribeFullOptions(
        tenths: settings.tenthsInTimecodes,
        markOverlap: settings.markOverlap,
        projectContext: settings.includeProjectContext ? projectContext(for: id) : nil,
        processedAt: record?.processedAt,
        timeZone: Self.contextTimeZone))
  }

  public func renderSRT(for id: UUID) -> String? {
    displayTranscript(for: id).map { SRTExporter.render($0) }
  }

  public func renderJSON(for id: UUID) -> String? {
    guard let transcript = displayTranscript(for: id),
      let data = try? TranscriptJSON.encode(transcript)
    else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  public func render(_ format: ExportFormat, for id: UUID) -> String? {
    switch format {
    case .markdown: renderMarkdown(for: id)
    case .srt: renderSRT(for: id)
    case .json: renderJSON(for: id)
    }
  }

  /// Имя файла экспорта: `TranscribeFull_<дата встречи>.<ext>`.
  public func fileName(_ format: ExportFormat, for id: UUID) -> String? {
    guard let transcript = displayTranscript(for: id) else { return nil }
    let markdownName = TranscribeFullExporter.fileName(for: transcript)
    guard format != .markdown else { return markdownName }
    return (markdownName as NSString).deletingPathExtension + "." + format.fileExtension
  }

  /// Есть ли что экспортировать у открытой встречи.
  public var canExport: Bool {
    selectedMeetingID.flatMap { transcripts[$0] } != nil
  }

  /// «Скопировать TranscribeFull» (⌘⇧C). Буфер передаётся параметром: тесты не трогают буфер пользователя.
  public func copyTranscribeFull(to pasteboard: NSPasteboard = .general) {
    guard let id = selectedMeetingID, let text = renderMarkdown(for: id) else { return }
    write(text, toPasteboard: pasteboard)
  }

  public func saveMarkdown() { save(.markdown) }
  public func saveSRT() { save(.srt) }
  public func saveJSON() { save(.json) }

  /// Сохранение: в тестовом режиме (`MEETINGSCRIBE_EXPORT_DIR`) — сразу файлом, иначе через `.fileExporter`.
  public func save(_ format: ExportFormat) {
    guard let id = selectedMeetingID, let text = render(format, for: id),
      let name = fileName(format, for: id)
    else { return }
    if let directory = settings.exportDirectoryOverride {
      let url = directory.appending(path: name)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        alert = AppAlert(
          title: String(localized: "Сохранено"), message: url.path(percentEncoded: false))
      } catch {
        alert = AppAlert(
          title: String(localized: "Файл не сохранился"), message: error.localizedDescription)
      }
      return
    }
    exportRequest = ExportRequest(
      document: TranscriptDocument(text: text, format: format),
      format: format,
      defaultFilename: name)
  }

  /// Итог диалога сохранения.
  public func finishExport(_ result: Result<URL, any Error>) {
    exportRequest = nil
    if case .failure(let error) = result {
      alert = AppAlert(
        title: String(localized: "Файл не сохранился"), message: error.localizedDescription)
    }
  }

  private func write(_ text: String, toPasteboard pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  // MARK: - Обновления обработки

  private func handle(_ update: ProcessingUpdate) {
    switch update {
    case .recordChanged(let record):
      // Координатор владеет только полями обработки: название, проект, имена спикеров и параметры
      // пользователь мог поменять за время прогона — они остаются. Удалённая встреча не воскресает.
      guard var current = library.meeting(id: record.id) else { return }
      current.status = record.status
      current.processedAt = record.processedAt
      current.processingSeconds = record.processingSeconds
      current.utteranceCount = record.utteranceCount
      current.speakerCount = record.speakerCount
      current.duration = record.duration ?? current.duration
      current.hasTranscript = record.hasTranscript
      current.isPartialTranscript = record.isPartialTranscript
      library.upsert(current)
      saveLibrary()
      if record.id == selectedMeetingID, playback.meetingID == nil {
        playback.load(record: current, cachedAudio: cachedAudioURL(for: record.id)) {
          [sourceBookmarks] in sourceBookmarks.access(for: record.id)
        }
      }
    case .transcriptReady(let meetingID, let transcript, _):
      guard library.meeting(id: meetingID) != nil else { return }
      transcripts[meetingID] = transcript
      if meetingID == selectedMeetingID { refreshRows() }
      // Имена спикеров (фаза 3): дорожки Zoom, голосовые профили, подсказки; строки обновляются внутри.
      applyAutomaticNaming(meetingID: meetingID)
    case .finished(let record, let success):
      guard library.meeting(id: record.id) != nil else { return }
      notifyIfNeeded(record, success: success)
    }
  }

  /// Записи индекса идут по цепочке: две задачи к актору могли бы прийти в обратном порядке,
  /// и старый снимок затёр бы новый.
  func saveLibrary() {
    let snapshot = library
    let previous = librarySaveTask
    pendingLibrarySaves += 1
    librarySaveTask = Task { [weak self] in
      _ = await previous?.result
      do {
        try await self?.store.save(snapshot)
      } catch {
        self?.alert = AppAlert(
          title: String(localized: "Библиотека не сохранилась"), message: error.localizedDescription
        )
      }
      self?.pendingLibrarySaves -= 1
    }
  }

  /// Есть ли незаписанные изменения библиотеки: делегат приложения откладывает выход, пока цепочка
  /// сохранения не закончилась (иначе последнее действие пользователя пропало бы).
  public var hasPendingLibrarySave: Bool { pendingLibrarySaves > 0 }

  /// Ждёт конца цепочки сохранения, но не дольше `timeout`: выход из приложения не должен зависать
  /// из-за недоступного диска.
  public func waitForPendingLibrarySave(timeout: Duration = .seconds(3)) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while hasPendingLibrarySave, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  // MARK: - Модели, самопроверка и отчёты (фаза 5)

  /// Модели, нужные текущему выбору движков (SPEC.md §3.8).
  public var requiredModels: [ModelID] {
    EngineFactory.requiredModels(
      asr: settings.engines.asr, whisperModel: settings.engines.whisperModel,
      diarizer: settings.engines.diarizer)
  }

  /// «Скачать» в онбординге и «Скачать недостающие» в настройках. Пустой список — качать нечего.
  public func startModelDownload(_ models: [ModelID]? = nil) {
    let list = models ?? onboarding.missingModels
    guard !list.isEmpty else { return }
    modelDownloads.start(models: list, downloader: downloader)
  }

  /// Пересчитывает недостающие модели и ставит их в очередь (кнопка в настройках).
  public func downloadMissingModels() async {
    await onboarding.refresh()
    startModelDownload()
  }

  /// «Запустить проверку» (онбординг и вкладка «Диагностика»): встроенный сэмпл через боевой пайплайн.
  public func startSelfTest() {
    guard !selfTest.isRunning else { return }
    do {
      let sample = try SelfTestSampleResource.load()
      selfTest.start(
        engines: engines, selection: settings.engines, sample: sample,
        cacheDirectory: selfTestCacheDirectory, store: store)
    } catch {
      selfTest.fail(error.localizedDescription)
    }
  }

  /// Рабочая папка прогона самопроверки (декодированное аудио сэмпла).
  public var selfTestCacheDirectory: URL {
    store.diagnosticsDirectory.appending(path: "selftest", directoryHint: .isDirectory)
  }

  /// Читает последний отчёт самопроверки с диска — вкладка «Диагностика» показывает итог и после
  /// перезапуска приложения.
  public func loadLastSelfTestReport() async {
    guard selfTest.report == nil, !selfTest.isRunning else { return }
    let directory = store.diagnosticsDirectory
    let found = await Task.detached { () -> (SelfTestReport, URL)? in
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)) ?? []
      let reports = files.filter {
        $0.lastPathComponent.hasPrefix("selftest-") && $0.pathExtension == "json"
      }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
      for url in reports {
        if let data = try? Data(contentsOf: url),
          let report = try? SelfTestController.decode(data)
        {
          return (report, url)
        }
      }
      return nil
    }.value
    if let found, selfTest.report == nil, !selfTest.isRunning {
      selfTest.show(found.0, url: found.1)
    }
  }

  /// «Проверить файлы» на вкладке «Диагностика»: проверка моделей по манифесту без сети.
  /// «Проверить файлы»: sha256 по манифестам — секунды на модель размером с Whisper, поэтому полоса,
  /// статус с байтами и «Остановить» (SPEC.md §3.7). События загрузчика идут через `AsyncStream`
  /// с потребителем на главном акторе (ADR-005).
  public func verifyModels() {
    guard !isVerifyingModels else { return }
    isVerifyingModels = true
    modelVerificationText = nil
    modelVerificationFraction = 0
    modelVerificationStatus = String(localized: "Проверяю файлы моделей…")
    let models = requiredModels
    let downloader = self.downloader
    let (events, continuation) = AsyncStream.makeStream(
      of: ModelDownloadProgress.self, bufferingPolicy: .bufferingNewest(64))
    let total = Double(max(models.count, 1))
    verifyTask = Task { [weak self] in
      let consumer = Task { [weak self] in
        for await event in events {
          guard let self else { return }
          let index = Double(models.firstIndex(of: event.model) ?? 0)
          let fraction = min((index + event.fraction) / total, 1)
          self.modelVerificationFraction = max(self.modelVerificationFraction, fraction)
          self.modelVerificationStatus = String(
            localized:
              "\(event.model.title) · \(ByteText.progress(event.bytesCompleted, of: event.bytesTotal))"
          )
        }
      }
      var lines: [String] = []
      for model in models {
        if Task.isCancelled { break }
        do {
          let verification = try await downloader.verify(
            model, progress: { continuation.yield($0) })
          if verification.isValid {
            lines.append(
              String(localized: "\(model.title): файлы на месте")
                + (verification.hasManifest
                  ? "" : String(localized: " (модель из старого кэша, манифеста нет)")))
          } else {
            let missing = (verification.missing + verification.corrupted).prefix(3)
              .joined(separator: ", ")
            lines.append(
              String(
                localized: "\(model.title): не хватает файлов (\(missing)) — скачайте модель заново"
              ))
          }
        } catch is CancellationError {
          lines.append(String(localized: "Проверка остановлена"))
          break
        } catch ModelDownloadError.cancelled {
          lines.append(String(localized: "Проверка остановлена"))
          break
        } catch {
          lines.append("\(model.title): \(error.localizedDescription)")
        }
      }
      continuation.finish()
      await consumer.value
      self?.modelVerificationText = lines.joined(separator: "\n")
      self?.modelVerificationStatus = nil
      self?.modelVerificationFraction = 1
      self?.isVerifyingModels = false
      self?.verifyTask = nil
    }
  }

  /// «Остановить» проверку: задача отменяется, уже проверенные модели остаются в итоге.
  public func cancelModelVerification() {
    guard isVerifyingModels else { return }
    modelVerificationStatus = String(localized: "Останавливаю…")
    verifyTask?.cancel()
  }

  /// «Собрать отчёт о проблеме» (SPEC.md §3.8): JSON без аудио, текста реплик и названий встреч.
  public func collectProblemReport() {
    guard !isCollectingProblemReport else { return }
    isCollectingProblemReport = true
    let settingsSnapshot = ProblemReport.SettingsSnapshot(settings: settings)
    let meetings = library.meetings.map(ProblemReport.MeetingEntry.init(record:))
    let projectCount = library.projects.count
    let peopleCount = library.people.count
    let selfTestReport = selfTest.report
    let modelStore = self.modelStore
    Task { [weak self] in
      let report = await Task.detached { () -> ProblemReport in
        var log: [AppLog.Entry] = []
        var logProblem: String?
        do {
          log = try AppLog.recentEntries()
        } catch {
          logProblem = error.localizedDescription
        }
        let statuses = modelStore.status()
        let models = statuses.map { status -> ProblemReport.ModelEntry in
          let manifest = modelStore.manifest(for: status.id)
          return ProblemReport.ModelEntry(
            id: status.id,
            isPresent: status.isPresent,
            sizeBytes: status.sizeBytes,
            revision: manifest?.shortRevision,
            downloadedAt: manifest?.downloadedAt,
            downloaderVersion: manifest?.downloaderVersion)
        }
        return ProblemReport(
          system: .current(),
          settings: settingsSnapshot,
          models: models,
          modelsRoot: NSString(string: modelStore.root.path(percentEncoded: false))
            .abbreviatingWithTildeInPath,
          selfTest: selfTestReport,
          meetings: meetings,
          projectCount: projectCount,
          peopleCount: peopleCount,
          log: log,
          logProblem: logProblem)
      }.value
      guard let self else { return }
      do {
        let url = try await store.writeDiagnostics(report.json(), fileName: report.fileName)
        problemReportURL = url
        alert = AppAlert(
          title: String(localized: "Отчёт о проблеме собран"),
          message:
            String(
              localized:
                "\(url.path(percentEncoded: false))\n\nВ файле нет аудио, текста реплик и названий встреч."
            ),
          kind: .revealFile(url))
      } catch {
        alert = AppAlert(
          title: String(localized: "Отчёт не сохранился"), message: error.localizedDescription)
      }
      isCollectingProblemReport = false
    }
  }

  /// Открывает страницу в браузере (страница выпуска, справка).
  public func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  // MARK: - Уведомления

  /// Разрешение спрашивается при первой обработке, а не на старте: до этого уведомлять не о чем.
  private func requestNotificationAuthorizationIfNeeded() {
    guard canUseNotifications, !didRequestNotificationAuthorization else { return }
    didRequestNotificationAuthorization = true
    Task {
      _ = try? await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .sound])
    }
  }

  private func notifyIfNeeded(_ record: MeetingRecord, success: Bool) {
    guard canUseNotifications, let app = NSApp, !app.isActive else { return }
    let content = UNMutableNotificationContent()
    content.title =
      success ? String(localized: "Встреча обработана") : String(localized: "Обработка не удалась")
    content.body = record.title
    let request = UNNotificationRequest(
      identifier: record.id.uuidString, content: content, trigger: nil)
    Task {
      try? await UNUserNotificationCenter.current().add(request)
    }
  }

  /// Уведомления доступны только настоящему приложению с bundle id: под `swift test` и в fake-режиме — нет.
  private var canUseNotifications: Bool {
    settings.notifyOnCompletion && !settings.useFakeEngines && Bundle.main.bundleIdentifier != nil
      && NSApp != nil
  }
}

/// Одна модель в очереди скачивания: байты сначала ожидаемые (`downloadSpec`), после листинга — точные.
nonisolated public struct ModelDownloadItem: Identifiable, Hashable, Sendable {
  public var id: ModelID
  public var totalBytes: Int64
  public var completedBytes: Int64
  /// Байты уточнены листингом репозитория, а не взяты из оценки.
  public var isExact: Bool
  public var isFinished: Bool

  public init(
    id: ModelID, totalBytes: Int64, completedBytes: Int64 = 0, isExact: Bool = false,
    isFinished: Bool = false
  ) {
    self.id = id
    self.totalBytes = totalBytes
    self.completedBytes = completedBytes
    self.isExact = isExact
    self.isFinished = isFinished
  }

  public var title: String { id.title }

  public var fraction: Double {
    guard totalBytes > 0 else { return isFinished ? 1 : 0 }
    return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
  }

  /// «412 МБ из 1,64 ГБ» — для строки модели в списке.
  public var sizeText: String { ByteText.progress(completedBytes, of: totalBytes) }
}

/// Скачивание моделей (SPEC.md §3.7 п. 10, §3.8): очередь моделей, байтовый прогресс, пауза с докачкой.
/// Живёт в модели, а не во вью: окно настроек и sheet онбординга можно закрыть, загрузка продолжится.
/// События приходят с рабочих потоков загрузчика и разбираются одной задачей на главном акторе
/// через `AsyncStream` (ADR-005) — без `Task { @MainActor }` на каждое событие.
@Observable
public final class ModelDownloadController {
  /// Идёт загрузка прямо сейчас.
  public private(set) var isDownloading = false
  /// Пауза: очередь и докачанное сохранены, «Продолжить» возобновляет с того же места.
  public private(set) var isPaused = false
  public private(set) var models: [ModelDownloadItem] = []
  public private(set) var currentModel: ModelID?
  public private(set) var bytesCompleted: Int64 = 0
  public private(set) var bytesTotal: Int64 = 0
  /// Доля 0…1 по байтам всех моделей; не откатывается при уточнении объёма (SPEC.md §3.7 п. 3).
  public private(set) var fraction: Double = 0
  /// «Whisper large-v3 turbo · 412 МБ из 1,64 ГБ · 35 МБ/с · осталось около минуты».
  public private(set) var statusText = ""
  public private(set) var errorText: String?
  public private(set) var finishedText: String?
  /// Модель, на которой загрузка остановилась с ошибкой (кнопка «Повторить» начнёт с неё).
  public private(set) var failedModel: ModelID?
  public private(set) var bytesPerSecond: Double?

  /// Почему загрузка остановилась: пауза и отмена приходят как `cancelled` от загрузчика.
  private enum Stop {
    case none
    case paused
    case cancelled
  }

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var downloader: (any ModelDownloading)?
  @ObservationIgnored private var queue: [ModelID] = []
  @ObservationIgnored private var stop: Stop = .none
  @ObservationIgnored private var startedAt: Date?
  @ObservationIgnored private var fractionFloor: Double = 0

  public init() {}

  /// Загрузка идёт или стоит на паузе — панель прогресса остаётся на месте.
  public var isActive: Bool { isDownloading || isPaused }

  /// Ставит модели в очередь и начинает загрузку. Повторный вызов во время загрузки игнорируется.
  public func start(models: [ModelID], downloader: any ModelDownloading) {
    guard !isDownloading, !models.isEmpty else { return }
    self.downloader = downloader
    queue = models
    self.models = models.map {
      ModelDownloadItem(id: $0, totalBytes: $0.downloadSpec.approximateBytes)
    }
    fractionFloor = 0
    fraction = 0
    bytesCompleted = 0
    bytesTotal = self.models.reduce(0) { $0 + $1.totalBytes }
    bytesPerSecond = nil
    currentModel = models.first
    statusText = String(localized: "Подготовка загрузки")
    run()
  }

  /// «Пауза»: задача отменяется, скачанное остаётся на диске (загрузчик докачивает с того же места).
  public func pause() {
    guard isDownloading else { return }
    stop = .paused
    task?.cancel()
    task = nil
    isDownloading = false
    isPaused = true
    bytesPerSecond = nil
    statusText = String(localized: "Пауза · \(ByteText.progress(bytesCompleted, of: bytesTotal))")
  }

  /// «Продолжить»: та же очередь без уже скачанных моделей.
  public func resume() {
    guard isPaused, downloader != nil else { return }
    isPaused = false
    run()
  }

  public func cancel() {
    stop = .cancelled
    task?.cancel()
    task = nil
    isDownloading = false
    isPaused = false
    bytesPerSecond = nil
    currentModel = nil
    statusText = ""
  }

  /// «Повторить» после ошибки: очередь та же, ошибка сбрасывается.
  public func retry() {
    guard !isDownloading, downloader != nil, !queue.isEmpty else { return }
    isPaused = false
    run()
  }

  // MARK: - Внутреннее

  private func run() {
    guard let downloader else { return }
    stop = .none
    isDownloading = true
    errorText = nil
    finishedText = nil
    failedModel = nil
    startedAt = Date()
    let pending = queue.filter { model in
      !(models.first { $0.id == model }?.isFinished ?? false)
    }
    guard !pending.isEmpty else {
      complete(failure: nil)
      return
    }
    let (events, continuation) = AsyncStream.makeStream(
      of: ModelDownloadProgress.self, bufferingPolicy: .bufferingNewest(256))
    task = Task { [weak self] in
      // Потребитель живёт на главном акторе и владеет потоком: переходов между акторами — по одному
      // на порцию событий, а не на каждый байтовый тик.
      let consumer = Task { [weak self] in
        for await event in events { self?.apply(event) }
      }
      var failure: (model: ModelID, error: any Error)?
      for model in pending {
        do {
          _ = try await downloader.download(model, progress: { continuation.yield($0) })
          self?.markFinished(model)
        } catch {
          failure = (model, error)
          break
        }
      }
      continuation.finish()
      await consumer.value
      self?.complete(failure: failure)
    }
  }

  private func apply(_ event: ModelDownloadProgress) {
    if event.phase == .listing {
      // Листинг репозитория: байтов ещё нет, но пользователь должен видеть, что процесс жив.
      currentModel = event.model
      let elapsed = Int(Date().timeIntervalSince(startedAt ?? Date()))
      statusText = String(
        localized: "\(event.model.title) · запрашиваю список файлов · \(elapsed) с")
      return
    }
    currentModel = event.model
    if let index = models.firstIndex(where: { $0.id == event.model }) {
      if event.bytesTotal > 0 {
        models[index].totalBytes = event.bytesTotal
        models[index].isExact = true
      }
      models[index].completedBytes = min(
        max(models[index].completedBytes, event.bytesCompleted), models[index].totalBytes)
      if event.phase == .finished {
        models[index].completedBytes = models[index].totalBytes
        models[index].isFinished = true
      }
    }
    if let speed = event.bytesPerSecond, speed > 0 { bytesPerSecond = speed }
    recompute()
  }

  private func markFinished(_ model: ModelID) {
    guard let index = models.firstIndex(where: { $0.id == model }) else { return }
    models[index].completedBytes = models[index].totalBytes
    models[index].isFinished = true
    recompute()
  }

  private func recompute() {
    bytesTotal = models.reduce(0) { $0 + $1.totalBytes }
    bytesCompleted = min(models.reduce(0) { $0 + $1.completedBytes }, bytesTotal)
    let raw = bytesTotal > 0 ? Double(bytesCompleted) / Double(bytesTotal) : 0
    // Точные байты после листинга могут увеличить общий объём — доля от этого не откатывается.
    fractionFloor = max(fractionFloor, min(max(raw, 0), 1))
    fraction = fractionFloor
    statusText = makeStatusText()
  }

  private func makeStatusText() -> String {
    var parts: [String] = []
    if let currentModel { parts.append(currentModel.title) }
    parts.append(ByteText.progress(bytesCompleted, of: bytesTotal))
    if let speed = ByteText.speed(bytesPerSecond) { parts.append(speed) }
    if let remaining = remainingText() { parts.append(remaining) }
    return parts.joined(separator: " · ")
  }

  /// Прогноз показывается после 5 секунд работы и только при измеренной скорости (SPEC.md §3.7 п. 5).
  private func remainingText() -> String? {
    guard let startedAt, Date().timeIntervalSince(startedAt) >= 5, let speed = bytesPerSecond,
      speed > 0, bytesTotal > bytesCompleted
    else { return nil }
    return String(
      localized:
        "осталось \(ProgressPhrasing.remaining(Double(bytesTotal - bytesCompleted) / speed))")
  }

  private func complete(failure: (model: ModelID, error: any Error)?) {
    isDownloading = false
    bytesPerSecond = nil
    if let failure {
      guard !Self.isCancellation(failure.error) else {
        // Пауза и отмена приходят сюда как отмена загрузчика: состояние уже выставлено.
        if stop == .none { isPaused = true }
        return
      }
      failedModel = failure.model
      errorText = failure.error.localizedDescription
      statusText = String(localized: "Остановлено на модели «\(failure.model.title)»")
      return
    }
    guard stop == .none else { return }
    for index in models.indices {
      models[index].completedBytes = models[index].totalBytes
      models[index].isFinished = true
    }
    recompute()
    fraction = 1
    currentModel = nil
    finishedText = String(localized: "Модели готовы · \(ByteText.short(bytesTotal))")
    statusText = finishedText ?? ""
  }

  nonisolated private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case .cancelled = error as? ModelDownloadError { return true }
    return false
  }
}

extension String {
  /// `nil` вместо пустой строки — чтобы `??` подставлял запасное значение.
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
