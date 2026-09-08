import Core
import Foundation
import LocalLLM
import Observation
import Voices

/// Настройки приложения (UserDefaults) и параметры запуска. Ключи стабильны: UI-тест передаёт их
/// launch-аргументами `-Ключ значение` (домен аргументов UserDefaults) и переменными окружения.
@Observable
public final class AppSettings {
  public enum Key {
    public static let engines = "engines"
    public static let defaultExpectedSpeakers = "defaultExpectedSpeakers"
    public static let defaultLanguage = "defaultLanguage"
    public static let tenthsInTimecodes = "tenthsInTimecodes"
    public static let markOverlap = "markOverlap"
    public static let notifyOnCompletion = "notifyOnCompletion"
    public static let showLanguageBadges = "showLanguageBadges"
    public static let showOverlapMarkers = "showOverlapMarkers"
    /// Пороги сопоставления голосов (SPEC.md §3.4): автоприсвоение и предложение.
    public static let voiceAutoThreshold = "voiceAutoThreshold"
    public static let voiceSuggestThreshold = "voiceSuggestThreshold"
    /// Фаза 4: контекст проекта в шапке TranscribeFull (SPEC.md §3.6).
    public static let includeProjectContext = "includeProjectContext"
    /// Локальная модель для генерации follow-up: по умолчанию выключена (SPEC.md §3.6).
    public static let localLLMEnabled = "localLLMEnabled"
    public static let localLLMBaseURL = "localLLMBaseURL"
    public static let localLLMModel = "localLLMModel"
    /// Фаза 5: онбординг первого запуска пройден или пропущен (SPEC.md §2 п. 8).
    public static let onboardingCompleted = "onboardingCompleted"
    /// Языки встреч (коды ISO-639-1) — кандидаты маршрутизатора языков (SPEC.md §3.2).
    public static let meetingLanguages = "meetingLanguages"
    /// Проверять новые версии на GitHub (SPEC.md §3.8): по умолчанию выключено.
    /// Launch-аргумент `-MSFakeEngines YES` (только DEBUG): сценарные движки вместо реальных.
    public static let fakeEngines = "MSFakeEngines"
    /// Launch-аргумент `-MSImportFile <путь>`: предложить файл к импорту при запуске.
    public static let importFile = "MSImportFile"
  }

  public enum EnvironmentKey {
    /// Папка для «Сохранить» без диалога (только DEBUG) — заглушка для UI-теста.
    public static let exportDirectory = "MEETINGSCRIBE_EXPORT_DIR"
    /// Отдельный домен настроек (только DEBUG): UI-тест не трогает настройки пользователя.
    public static let defaultsSuite = "MEETINGSCRIBE_DEFAULTS_SUITE"
  }

  /// Языки встреч по умолчанию (SPEC.md §1: русский, украинский, английские термины).
  public static let defaultMeetingLanguages: [Language] = [.ru, .uk, .en]

  @ObservationIgnored private let defaults: UserDefaults

  /// Движки по умолчанию для новых встреч (диалог импорта предлагает их).
  /// Умолчание движков, пока пользователь ничего не выбирал: у самостоятельного MeetingScribe — `.accurate`
  /// (ADR-002), хост задаёт своё (LocalVoice — large-v3 + SpeakerKit, ADR-010). Записанный выбор важнее.
  public let defaultEngines: EngineSelection
  /// «Точный» режим для онбординга и переключателя режимов: умолчание хоста, если это WhisperKit.
  public var accurateSelection: EngineSelection {
    defaultEngines.asr == .whisperkit ? defaultEngines : .accurate
  }
  public var engines: EngineSelection {
    didSet { store(engines, forKey: Key.engines) }
  }
  /// Ожидаемое число участников по умолчанию; `nil` — не подсказывать диаризатору.
  public var defaultExpectedSpeakers: Int? {
    didSet { storeOptional(defaultExpectedSpeakers, forKey: Key.defaultExpectedSpeakers) }
  }
  public var defaultLanguage: LanguageChoice {
    didSet { defaults.set(defaultLanguage.rawValue, forKey: Key.defaultLanguage) }
  }
  /// Таймкоды с десятыми долями в TranscribeFull.
  public var tenthsInTimecodes: Bool {
    didSet { defaults.set(tenthsInTimecodes, forKey: Key.tenthsInTimecodes) }
  }
  /// Помечать наложения речи в TranscribeFull.
  public var markOverlap: Bool {
    didSet { defaults.set(markOverlap, forKey: Key.markOverlap) }
  }
  /// Системное уведомление по окончании обработки, если приложение неактивно (SPEC.md §3.7 п. 9).
  public var notifyOnCompletion: Bool {
    didSet { defaults.set(notifyOnCompletion, forKey: Key.notifyOnCompletion) }
  }
  /// View → «Показать языки».
  public var showLanguageBadges: Bool {
    didSet { defaults.set(showLanguageBadges, forKey: Key.showLanguageBadges) }
  }
  /// View → «Показать наложения».
  public var showOverlapMarkers: Bool {
    didSet { defaults.set(showOverlapMarkers, forKey: Key.showOverlapMarkers) }
  }
  /// Порог автоприсвоения имени по голосу (cosine), SPEC.md §3.4: 0.70 по умолчанию.
  public var voiceAutoThreshold: Double {
    didSet { defaults.set(voiceAutoThreshold, forKey: Key.voiceAutoThreshold) }
  }
  /// Порог предложения с подтверждением: 0.55 по умолчанию.
  public var voiceSuggestThreshold: Double {
    didSet { defaults.set(voiceSuggestThreshold, forKey: Key.voiceSuggestThreshold) }
  }
  /// Включать секцию «Контекст проекта» в TranscribeFull (SPEC.md §3.6). По умолчанию включено:
  /// ради этой секции и существует память проекта.
  public var includeProjectContext: Bool {
    didSet { defaults.set(includeProjectContext, forKey: Key.includeProjectContext) }
  }
  /// Генерировать follow-up локальной моделью (SPEC.md §3.6: «по умолчанию выключено»).
  public var localLLMEnabled: Bool {
    didSet { defaults.set(localLLMEnabled, forKey: Key.localLLMEnabled) }
  }
  /// Адрес OpenAI-совместимого сервера на этой машине.
  public var localLLMBaseURL: String {
    didSet { defaults.set(localLLMBaseURL, forKey: Key.localLLMBaseURL) }
  }
  /// Идентификатор модели у сервера (`id` из `/v1/models`).
  public var localLLMModel: String {
    didSet { defaults.set(localLLMModel, forKey: Key.localLLMModel) }
  }
  /// Онбординг первого запуска пройден (или пропущен): sheet больше не показывается сам.
  public var onboardingCompleted: Bool {
    didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
  }
  /// Языки встреч кодами, в порядке показа; хотя бы один (интерфейс не даёт снять последний).
  public var meetingLanguageCodes: [String] {
    didSet { defaults.set(meetingLanguageCodes, forKey: Key.meetingLanguages) }
  }

  /// Языки встреч типизированно: `LanguageRouter` получает их как кандидатов (`orderedMeetingLanguages`).
  public var meetingLanguages: Set<Language> {
    get { Set(meetingLanguageCodes.map { Language(code: $0) }) }
    set {
      let ordered = Self.defaultMeetingLanguages.filter(newValue.contains)
      let extra = newValue.subtracting(ordered).map(\.code).sorted()
      meetingLanguageCodes = ordered.map(\.code) + extra
    }
  }

  /// Кандидаты для маршрутизатора языков в порядке ru → uk → en; пустой выбор — все три языка,
  /// иначе распознавание осталось бы вовсе без кандидатов.
  public var orderedMeetingLanguages: [Language] {
    let languages = meetingLanguageCodes.map { Language(code: $0) }.filter(\.isKnown)
    return languages.isEmpty ? Self.defaultMeetingLanguages : languages
  }

  /// Настройки клиента локальной модели; `nil` — модель выключена, адрес пуст или не разбирается,
  /// либо не выбрана модель. Проверку «адрес локальный» делает сам клиент (`LocalHostPolicy`).
  public var localLLMConfiguration: LocalLLMConfiguration? {
    guard localLLMEnabled else { return nil }
    let model = localLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty,
      let url = Self.serverURL(localLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return LocalLLMConfiguration(baseURL: url, model: model)
  }

  /// Адрес сервера из строки настроек: только `http`/`https`. Без этой проверки «localhost:1234/v1»
  /// разбирается как URL со схемой «localhost» — запрос ушёл бы в никуда, а кнопка выглядела бы рабочей.
  nonisolated public static func serverURL(_ address: String) -> URL? {
    guard !address.isEmpty, let url = URL(string: address),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host(percentEncoded: false)?.isEmpty == false
    else { return nil }
    return url
  }

  public var voiceThresholds: VoiceThresholds {
    VoiceThresholds(autoAssign: voiceAutoThreshold, suggest: voiceSuggestThreshold)
  }

  /// Сценарные движки вместо реальных — только в DEBUG-сборке по launch-аргументу `-MSFakeEngines YES`.
  public let useFakeEngines: Bool
  /// Файл, который нужно предложить к импорту при запуске (`-MSImportFile`).
  public let importFileAtLaunch: URL?
  /// Папка, куда «Сохранить» пишет без диалога (только DEBUG, `MEETINGSCRIBE_EXPORT_DIR`).
  public let exportDirectoryOverride: URL?

  public init(
    defaults: UserDefaults? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaultEngines: EngineSelection = .accurate
  ) {
    let defaults = defaults ?? Self.makeDefaults(environment: environment)
    self.defaults = defaults
    self.defaultEngines = defaultEngines
    engines = Self.load(EngineSelection.self, forKey: Key.engines, from: defaults) ?? defaultEngines
    // В домене аргументов запуска (`-defaultExpectedSpeakers 6`) значение — строка: `integer(forKey:)` её разбирает.
    defaultExpectedSpeakers =
      defaults.object(forKey: Key.defaultExpectedSpeakers) == nil
      ? nil : defaults.integer(forKey: Key.defaultExpectedSpeakers)
    defaultLanguage =
      defaults.string(forKey: Key.defaultLanguage).flatMap(LanguageChoice.init(rawValue:)) ?? .auto
    tenthsInTimecodes = defaults.bool(forKey: Key.tenthsInTimecodes)
    markOverlap = defaults.bool(forKey: Key.markOverlap)
    // Булевы значения с умолчанием `true`: launch-аргумент `-notifyOnCompletion NO` приходит строкой,
    // которую разбирает `bool(forKey:)`, а не `as? Bool`.
    notifyOnCompletion = Self.bool(forKey: Key.notifyOnCompletion, default: true, in: defaults)
    showLanguageBadges = Self.bool(forKey: Key.showLanguageBadges, default: true, in: defaults)
    showOverlapMarkers = Self.bool(forKey: Key.showOverlapMarkers, default: true, in: defaults)
    let standard = VoiceThresholds.standard
    voiceAutoThreshold = Self.double(
      forKey: Key.voiceAutoThreshold, default: standard.autoAssign, in: defaults)
    voiceSuggestThreshold = Self.double(
      forKey: Key.voiceSuggestThreshold, default: standard.suggest, in: defaults)
    includeProjectContext = Self.bool(
      forKey: Key.includeProjectContext, default: true, in: defaults)
    localLLMEnabled = defaults.bool(forKey: Key.localLLMEnabled)
    localLLMBaseURL =
      defaults.string(forKey: Key.localLLMBaseURL)?.nilIfEmpty
      ?? LocalLLMConfiguration.lmStudioDefaultURL.absoluteString
    localLLMModel = defaults.string(forKey: Key.localLLMModel) ?? ""
    onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
    meetingLanguageCodes = Self.languageCodes(from: defaults)
    #if DEBUG
      importFileAtLaunch = defaults.string(forKey: Key.importFile).map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
      }
      useFakeEngines = defaults.bool(forKey: Key.fakeEngines)
      exportDirectoryOverride = environment[EnvironmentKey.exportDirectory].map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
      }
    #else
      importFileAtLaunch = nil
      useFakeEngines = false
      exportDirectoryOverride = nil
    #endif
  }

  // MARK: - Домен настроек

  /// Где хранить настройки. Обычно — `UserDefaults.standard`; в DEBUG переменная окружения
  /// `MEETINGSCRIBE_DEFAULTS_SUITE` уводит их в отдельный домен, чтобы UI-тест не менял настройки
  /// пользователя и не зависел от них. Значения launch-аргументов (`-ключ значение`) переносятся
  /// в домен регистрации suite: домен аргументов виден и так, но перенос делает поведение явным.
  public static func makeDefaults(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> UserDefaults {
    #if DEBUG
      guard let suite = environment[EnvironmentKey.defaultsSuite]?.nilIfEmpty,
        let defaults = UserDefaults(suiteName: suite)
      else { return .standard }
      defaults.register(
        defaults: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
      return defaults
    #else
      return .standard
    #endif
  }

  // MARK: - Внутреннее

  /// Языки встреч: массив строк, либо строка «ru,uk» (так их удобно передавать launch-аргументом).
  private static func languageCodes(from defaults: UserDefaults) -> [String] {
    let stored: [String]
    if let array = defaults.array(forKey: Key.meetingLanguages) as? [String] {
      stored = array
    } else if let text = defaults.string(forKey: Key.meetingLanguages) {
      stored = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    } else {
      stored = []
    }
    // Языки встреч — только ru/uk/en: остальные коды движки проекта не проверяли (SPEC.md §1).
    let known = defaultMeetingLanguages.map(\.code)
    let codes = Set(stored.map { Language(code: $0).code }.filter(known.contains))
    return codes.isEmpty ? known : known.filter(codes.contains)
  }

  private func store<T: Encodable>(_ value: T, forKey key: String) {
    if let data = try? JSONEncoder().encode(value) {
      defaults.set(data, forKey: key)
    }
  }

  private static func bool(forKey key: String, default fallback: Bool, in defaults: UserDefaults)
    -> Bool
  {
    defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
  }

  private static func double(
    forKey key: String, default fallback: Double, in defaults: UserDefaults
  ) -> Double {
    guard defaults.object(forKey: key) != nil else { return fallback }
    let value = defaults.double(forKey: key)
    return value.isFinite && value > 0 && value <= 1 ? value : fallback
  }

  private func storeOptional(_ value: Int?, forKey key: String) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  private static func load<T: Decodable>(
    _ type: T.Type, forKey key: String, from defaults: UserDefaults
  )
    -> T?
  {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}
