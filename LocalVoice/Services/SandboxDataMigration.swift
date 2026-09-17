import Foundation
import OSLog

/// Перенос данных из песочницы в домашнюю библиотеку.
///
/// До версии 4.3.0 сборка для раздачи работала в App Sandbox, и всё лежало в контейнере
/// `~/Library/Containers/app.localvoice.LocalVoice/Data`: история диктовок и словарь (SwiftData),
/// встречи с их моделями, локальные модели Whisper, записи, настройки и горячие клавиши. Песочницу
/// выключили ради доступа к файлам в любой папке — и те же вызовы `FileManager.urls(for:)` и
/// `UserDefaults.standard` стали указывать уже в домашнюю библиотеку. Без переноса пользователь после
/// обновления увидел бы пустое приложение.
///
/// Контейнер после переноса остаётся на месте: если что-то пойдёт не так, данные можно достать оттуда
/// руками. Перенос выполняется один раз и записывает об этом флаг.
enum SandboxDataMigration {
    private static let completedKey = "didMigrateFromSandboxContainer"
    private static let bundleFolder = "app.localvoice.LocalVoice"
    private static let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "SandboxMigration")

    /// Папка прежнего контейнера — её путь показывается в отчёте о проблеме.
    static var legacyContainer: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/\(bundleFolder)/Data", isDirectory: true)
    }

    /// Зовётся первой строкой `LocalVoiceApp.init` — до регистрации умолчаний, до SwiftData и до встреч.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        // В сэндбоксовой сборке (если такая когда-нибудь понадобится для App Store) переносить нечего:
        // `NSHomeDirectory()` там сам указывает в контейнер.
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else { return }
        guard !defaults.bool(forKey: completedKey) else { return }

        let library = legacyContainer.appendingPathComponent("Library", isDirectory: true)
        guard FileManager.default.fileExists(atPath: library.path) else {
            // Контейнера нет — чистая установка; больше не проверяем.
            defaults.set(true, forKey: completedKey)
            return
        }

        let files = migrateApplicationSupport(from: library)
        let settings = migratePreferences(from: library, into: defaults)
        defaults.set(true, forKey: completedKey)
        logger.notice(
            "📦 Перенос из контейнера: элементов \(files, privacy: .public), настроек \(settings, privacy: .public)"
        )
    }

    /// История, словарь, встречи, модели и записи: переносим по одному элементу, чужого не перетираем.
    private static func migrateApplicationSupport(from library: URL) -> Int {
        let fileManager = FileManager.default
        let source = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleFolder, isDirectory: true)
        let target = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleFolder, isDirectory: true)

        guard let items = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            logger.info("📦 В контейнере нет данных приложения — переносить нечего")
            return 0
        }
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)

        var moved = 0
        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            // Если такой файл уже появился в новой папке, он новее переносимого: оставляем его.
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                // Тот же том — переименование мгновенно даже для гигабайтов моделей.
                try fileManager.moveItem(at: item, to: destination)
                moved += 1
            } catch {
                do {
                    try fileManager.copyItem(at: item, to: destination)
                    moved += 1
                } catch {
                    logger.error(
                        "📦 Не перенеслось «\(item.lastPathComponent, privacy: .public)»: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return moved
    }

    /// Настройки: сам плист копировать нельзя — им владеет cfprefsd. Читаем значения и кладём в новый
    /// домен только те ключи, которых там ещё нет.
    private static func migratePreferences(from library: URL, into defaults: UserDefaults) -> Int {
        let plist = library
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleFolder).plist")
        guard let stored = NSDictionary(contentsOf: plist) as? [String: Any] else { return 0 }

        var applied = 0
        for (key, value) in stored where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            applied += 1
        }
        return applied
    }
}
