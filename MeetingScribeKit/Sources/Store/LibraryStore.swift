import Core
import Export
import Foundation
import GRDB

/// Ошибки библиотеки встреч: что случилось и что сделать (docs/DESIGN.md §1).
public enum LibraryStoreError: Error, LocalizedError, Hashable, Sendable {
  case cannotCreateDirectory(URL, reason: String)
  case readFailed(URL, reason: String)
  case writeFailed(URL, reason: String)
  /// База библиотеки не открылась или ответила ошибкой на запрос.
  case databaseFailed(URL, reason: String)
  /// Поиск не выполнился (запрос сформирован хранилищем, поэтому это всегда сбой базы, не синтаксис).
  case searchFailed(query: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .cannotCreateDirectory(let url, let reason):
      String(localized: "Не удалось создать папку библиотеки \(url.path): \(reason).")
    case .readFailed(let url, let reason):
      String(
        localized:
          "Не удалось прочитать \(url.lastPathComponent): \(reason). Приложение начинает с пустой библиотеки, прежний файл сохранён рядом для восстановления."
      )
    case .writeFailed(let url, let reason):
      String(
        localized:
          "Не удалось сохранить \(url.lastPathComponent): \(reason). Проверьте место на диске и права на папку \(url.deletingLastPathComponent().path)."
      )
    case .databaseFailed(let url, let reason):
      String(
        localized:
          "База библиотеки \(url.lastPathComponent) недоступна: \(reason). Закройте второй экземпляр приложения и проверьте права на папку \(url.deletingLastPathComponent().path)."
      )
    case .searchFailed(let query, let reason):
      String(
        localized:
          "Поиск «\(query)» не выполнился: \(reason). Попробуйте повторить запрос; если не помогает, перезапустите приложение."
      )
    }
  }
}

/// Хранилище библиотеки: `library.sqlite` — индекс и полнотекстовый поиск (GRDB, FTS5; ADR-007),
/// `meetings/<id>/` — транскрипт и кэш аудио `audio16k.wav` (SPEC.md §3.1), `Diagnostics/` — отчёты
/// «Отменить и собрать отчёт». Корень — `~/Library/Application Support/MeetingScribe` (модели лежат рядом
/// в `Models`, см. `ModelStore`), переопределяется переменной `MEETINGSCRIBE_LIBRARY_DIR` (UI-тесты).
///
/// В памяти библиотека остаётся значением `Library`: `load()` собирает его из таблиц, `save(_:)` пишет
/// разницу с последним сохранённым снимком одной транзакцией. Индекс `library.json` фазы 3 переносится
/// в SQLite при первой загрузке и откладывается как `library-migrated-<время>.json`.
public actor LibraryStore {
  public static let environmentVariable = "MEETINGSCRIBE_LIBRARY_DIR"
  public static let applicationSupportSubpath = "MeetingScribe"
  public static let indexFileName = "library.sqlite"
  /// Индекс фаз 2–3; читается один раз при миграции.
  public static let legacyIndexFileName = "library.json"
  /// База, в которую идёт перенос: становится `library.sqlite` только после коммита.
  public static let migrationFileName = "library-migrating.sqlite"
  public static let meetingsFolderName = "meetings"
  public static let diagnosticsFolderName = "Diagnostics"
  public static let transcriptFileName = "transcript.json"

  public nonisolated let directory: URL

  /// Открытая база (WAL): создаётся при первом обращении, живёт до конца сессии.
  private var pool: DatabasePool?
  /// Последний записанный снимок — основа для разницы в `save(_:)`.
  private var lastSaved: Library?
  /// Снимок собран внутри чужой операции (перенос `library.json` случился в `save`/`search`), и
  /// вызывающий его не видел: первое сохранение поверх такого снимка ничего не удаляет.
  private var snapshotIsUnseen = false
  /// Строки индекса, пропущенные при последней загрузке: одна нечитаемая запись не откладывает базу.
  public private(set) var lastLoadWarnings: [String] = []

  public init(directory: URL) {
    self.directory = directory.standardizedFileURL
  }

  /// Стандартная папка: переменная окружения либо Application Support.
  public static func standardDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    if let override = environment[environmentVariable], !override.isEmpty {
      return URL(
        fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
    }
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    return base.appending(path: applicationSupportSubpath, directoryHint: .isDirectory)
  }

  // MARK: - Пути

  public nonisolated var databaseURL: URL { directory.appending(path: Self.indexFileName) }

  public nonisolated var legacyIndexURL: URL {
    directory.appending(path: Self.legacyIndexFileName)
  }

  public nonisolated var meetingsDirectory: URL {
    directory.appending(path: Self.meetingsFolderName, directoryHint: .isDirectory)
  }

  public nonisolated var diagnosticsDirectory: URL {
    directory.appending(path: Self.diagnosticsFolderName, directoryHint: .isDirectory)
  }

  /// Папка встречи: транскрипт и кэш `audio16k.wav` (та же папка передаётся пайплайну как `cacheDirectory`).
  public nonisolated func meetingDirectory(for id: UUID) -> URL {
    meetingsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
  }

  public nonisolated func transcriptURL(for id: UUID) -> URL {
    meetingDirectory(for: id).appending(path: Self.transcriptFileName)
  }

  // MARK: - Индекс

  /// Читает библиотеку целиком; пустая база — пустая библиотека. Активные статусы демотируются
  /// в `interrupted` (обработчика после перезапуска нет). Нечитаемые строки пропускаются, их список
  /// остаётся в `lastLoadWarnings`.
  public func load() throws -> Library {
    try loadStored(unseen: false).demotingInterrupted()
  }

  /// Чтение с запоминанием снимка — основа и для `load()`, и для операций, заставших неперенесённый
  /// `library.json`. `unseen` помечает снимок, о котором вызывающий не знает (см. `snapshotIsUnseen`).
  @discardableResult
  private func loadStored(unseen: Bool) throws -> Library {
    let pool = try openDatabase(migratingLegacyIndex: true)
    let stored: LibraryDatabase.LibraryRead
    do {
      stored = try pool.read { try LibraryDatabase.read($0) }
    } catch {
      // База открылась, но данные не читаются — обращаемся с ней как с битым индексом.
      try setAsideDatabase(error)
    }
    lastLoadWarnings = stored.warnings
    lastSaved = stored.library
    snapshotIsUnseen = unseen
    return stored.library
  }

  /// Сохраняет разницу с последним снимком одной транзакцией; без предшествующего `load()` —
  /// полная синхронизация (upsert всех записей, удаление отсутствующих).
  ///
  /// Запрос к базе — синхронный намеренно: `await` внутри актора пустил бы сюда второе сохранение,
  /// и снимок `lastSaved` разошёлся бы с содержимым базы. Транзакции короткие (локальный SQLite).
  public func save(_ library: Library) throws {
    let pool = try database()
    let previous = lastSaved
    // Записи, перенесённые из `library.json` по ходу этого же вызова, вызывающему не принадлежат:
    // их можно дополнять, но не удалять, иначе перенос стёрся бы под ноль.
    let deletingMissing = !snapshotIsUnseen
    do {
      try pool.write { db in
        try LibraryDatabase.write(
          library, previous: previous, deletingMissing: deletingMissing, in: db)
      }
    } catch {
      throw LibraryStoreError.writeFailed(databaseURL, reason: error.localizedDescription)
    }
    if deletingMissing {
      lastSaved = library
    } else {
      // В базе осталось больше, чем передал вызывающий: снимок обязан совпадать с её содержимым.
      lastSaved = (try? pool.read { try LibraryDatabase.read($0).library }) ?? library
      snapshotIsUnseen = false
    }
  }

  // MARK: - Транскрипты

  /// Пишет `transcript.json` и переиндексирует реплики встречи для поиска (SPEC.md §3.6).
  public func saveTranscript(_ transcript: Transcript, for id: UUID) throws {
    try ensureDirectory(meetingDirectory(for: id))
    let url = transcriptURL(for: id)
    do {
      try TranscriptJSON.write(transcript, to: url)
    } catch {
      throw LibraryStoreError.writeFailed(url, reason: error.localizedDescription)
    }
    let pool = try database()
    let utterances = transcript.utterances
    do {
      try pool.write { db in
        try LibraryDatabase.indexUtterances(utterances, meetingID: id, in: db)
      }
    } catch {
      throw LibraryStoreError.writeFailed(databaseURL, reason: error.localizedDescription)
    }
  }

  /// `nil` — транскрипта нет.
  public func loadTranscript(for id: UUID) throws -> Transcript? {
    let url = transcriptURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return nil
    }
    do {
      return try TranscriptJSON.decode(Data(contentsOf: url))
    } catch {
      throw LibraryStoreError.readFailed(url, reason: error.localizedDescription)
    }
  }

  /// Стирает папку встречи (транскрипт и кэш аудио) и её реплики из поискового индекса.
  /// Исходную запись пользователя не трогает.
  ///
  /// Порядок важен: сначала папка, потом индекс. Иначе неудачное удаление папки оставило бы
  /// транскрипт на диске, но уже без реплик в поиске.
  public func deleteMeetingData(for id: UUID) throws {
    let pool = try database()
    let url = meetingDirectory(for: id)
    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        throw LibraryStoreError.writeFailed(url, reason: error.localizedDescription)
      }
    }
    do {
      try pool.write { db in
        try LibraryDatabase.removeUtterances(meetingID: id, in: db)
      }
    } catch {
      throw LibraryStoreError.writeFailed(databaseURL, reason: error.localizedDescription)
    }
  }

  // MARK: - Диагностика

  /// Пишет текстовый отчёт (без аудио) в `Diagnostics/` и возвращает его путь.
  public func writeDiagnostics(_ text: String, fileName: String) throws -> URL {
    try ensureDirectory(diagnosticsDirectory)
    let url = diagnosticsDirectory.appending(path: fileName)
    do {
      try Data(text.utf8).write(to: url, options: .atomic)
    } catch {
      throw LibraryStoreError.writeFailed(url, reason: error.localizedDescription)
    }
    return url
  }

  // MARK: - База

  /// Открытая база для точечных операций (`save`, транскрипты, поиск). Миграция `library.json` живёт
  /// в загрузке: запусти её отсюда — и первое же `save` посчитало бы разницу с пустой библиотекой и
  /// стёрло перенесённые записи. Поэтому при неперенесённом индексе сначала идёт внутреннее чтение,
  /// и операция считает разницу относительно перенесённого.
  func database() throws -> DatabasePool {
    if let pool { return pool }
    if hasLegacyIndex {
      try loadStored(unseen: true)
      if let pool { return pool }
    }
    return try openDatabase(migratingLegacyIndex: false)
  }

  /// Рядом лежит индекс фаз 2–3.
  private var hasLegacyIndex: Bool {
    FileManager.default.fileExists(atPath: legacyIndexURL.path(percentEncoded: false))
  }

  private func openDatabase(migratingLegacyIndex: Bool) throws -> DatabasePool {
    if let pool { return pool }
    try ensureDirectory(directory)
    if migratingLegacyIndex { try migrateLegacyIndexIfNeeded() }
    let opened = try openPool()
    pool = opened
    return opened
  }

  private func openPool() throws -> DatabasePool {
    do {
      let opened = try DatabasePool(
        path: databaseURL.path(percentEncoded: false), configuration: Self.configuration())
      try LibraryDatabase.migrator().migrate(opened)
      // Версия данных пишется после миграций схемы, а не внутри одной из них: `user_version` должен
      // называть текущую версию, а не ту, при которой файл создали.
      try opened.writeWithoutTransaction { db in
        let stored = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard stored != LibraryDatabase.userVersion else { return }
        try db.execute(sql: "PRAGMA user_version = \(LibraryDatabase.userVersion)")
      }
      return opened
    } catch {
      // Файл есть, но это не база (или схема не накатилась) — откладываем и начинаем с пустой.
      guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
        throw LibraryStoreError.databaseFailed(databaseURL, reason: error.localizedDescription)
      }
      try setAsideDatabase(error)
    }
  }

  private static func configuration(label: String = "MeetingScribe.library") -> Configuration {
    var configuration = Configuration()
    configuration.label = label
    // Внутри процесса записи и так сериализованы, но второй экземпляр приложения (или UI-тест рядом
    // с ним) не должен получать «база занята» мгновенно: ждём вместо ошибки.
    configuration.busyMode = .timeout(5)
    return configuration
  }

  /// Откладывает нечитаемую базу (вместе с `-wal`/`-shm`) и сообщает об этом пользователю.
  private func setAsideDatabase(_ error: any Error) throws -> Never {
    pool = nil
    lastSaved = nil
    snapshotIsUnseen = false
    lastLoadWarnings = []
    let manager = FileManager.default
    let backup = availableURL(name: Self.timestampedName("library-broken"), extension: "sqlite")
    let path = databaseURL.path(percentEncoded: false)
    let moved: Bool
    do {
      try manager.moveItem(at: databaseURL, to: backup)
      moved = true
    } catch {
      moved = false
    }
    if moved {
      for suffix in ["-wal", "-shm"] {
        let sidecar = URL(fileURLWithPath: path + suffix)
        guard manager.fileExists(atPath: sidecar.path) else { continue }
        try? manager.moveItem(
          at: sidecar, to: URL(fileURLWithPath: backup.path(percentEncoded: false) + suffix))
      }
    }
    let fate =
      moved
      ? String(localized: "файл переименован в \(backup.lastPathComponent)")
      : String(
        localized:
          "переименовать файл не удалось — уберите \(databaseURL.lastPathComponent) вручную")
    throw LibraryStoreError.readFailed(
      databaseURL, reason: "\(error.localizedDescription); \(fate)")
  }

  // MARK: - Перенос индекса фазы 3

  /// Переносит индекс фаз 2–3 в SQLite: записи, затем реплики всех обработанных встреч.
  /// Битый `library.json` откладывается, как и раньше.
  ///
  /// Перенос идёт во временный файл и становится `library.sqlite` только после коммита: прерванная
  /// миграция не оставляет пустую базу, из-за которой перенос никогда бы не повторился, а `library.json`
  /// переименовывается последним.
  private func migrateLegacyIndexIfNeeded() throws {
    let manager = FileManager.default
    let legacy = legacyIndexURL
    guard manager.fileExists(atPath: legacy.path(percentEncoded: false)) else { return }
    // База уже есть: поверх непустой не переносим (индекс фазы 4 главнее), пустую заменяем — это
    // остаток прерванного переноса.
    if manager.fileExists(atPath: databaseURL.path(percentEncoded: false)),
      try !existingDatabaseIsEmpty()
    {
      return
    }

    let library: Library
    do {
      library = try Self.decoder().decode(Library.self, from: Data(contentsOf: legacy))
    } catch {
      let backup = availableURL(name: Self.timestampedName("library-broken"), extension: "json")
      let moved = (try? manager.moveItem(at: legacy, to: backup)) != nil
      let fate =
        moved
        ? String(localized: "файл переименован в \(backup.lastPathComponent)")
        : String(
          localized: "переименовать файл не удалось — уберите \(legacy.lastPathComponent) вручную")
      throw LibraryStoreError.readFailed(legacy, reason: "\(error.localizedDescription); \(fate)")
    }

    try writeMigratedDatabase(library)
    try? manager.moveItem(
      at: legacy,
      to: availableURL(name: Self.timestampedName("library-migrated"), extension: "json"))
  }

  /// Пустая ли лежащая рядом база (остаток прерванного переноса). Соединение закрывается сразу:
  /// файл будет заменён перенесённым.
  private func existingDatabaseIsEmpty() throws -> Bool {
    let opened = try openPool()
    defer { try? opened.close() }
    return (try? opened.read { try LibraryDatabase.isEmpty($0) }) ?? false
  }

  /// Пишет перенесённую библиотеку во временную базу и переименовывает её в `library.sqlite`.
  private func writeMigratedDatabase(_ library: Library) throws {
    let manager = FileManager.default
    let temporary = directory.appending(path: Self.migrationFileName)
    removeDatabaseFiles(at: temporary)
    do {
      let opened = try DatabasePool(
        path: temporary.path(percentEncoded: false),
        configuration: Self.configuration(label: "MeetingScribe.library.migration"))
      try LibraryDatabase.migrator().migrate(opened)
      try opened.write { db in
        try LibraryDatabase.write(library, previous: nil, in: db)
        for meeting in library.meetings where meeting.hasTranscript {
          // Одна нечитаемая встреча не должна ронять миграцию всей библиотеки.
          guard let data = try? Data(contentsOf: transcriptURL(for: meeting.id)),
            let transcript = try? TranscriptJSON.decode(data)
          else { continue }
          try LibraryDatabase.indexUtterances(
            transcript.utterances, meetingID: meeting.id, in: db)
        }
      }
      // Файл должен быть самодостаточным до переименования: WAL сливается в него, соединения закрыты.
      try opened.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
      }
      try opened.close()
    } catch {
      removeDatabaseFiles(at: temporary)
      throw LibraryStoreError.writeFailed(databaseURL, reason: error.localizedDescription)
    }
    do {
      removeDatabaseFiles(at: databaseURL)
      try manager.moveItem(at: temporary, to: databaseURL)
    } catch {
      removeDatabaseFiles(at: temporary)
      throw LibraryStoreError.writeFailed(databaseURL, reason: error.localizedDescription)
    }
  }

  /// Удаляет файл базы вместе с `-wal`/`-shm`.
  private func removeDatabaseFiles(at url: URL) {
    let manager = FileManager.default
    let path = url.path(percentEncoded: false)
    for suffix in ["", "-wal", "-shm"] {
      try? manager.removeItem(at: URL(fileURLWithPath: path + suffix))
    }
  }

  // MARK: - Внутреннее

  private func ensureDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw LibraryStoreError.cannotCreateDirectory(url, reason: error.localizedDescription)
    }
  }

  private static func timestampedName(_ prefix: String) -> String {
    "\(prefix)-\(Int(Date().timeIntervalSince1970))"
  }

  /// Свободное имя рядом с занятым: `library-broken-1757000000.sqlite`, затем `…-2`, `…-3`.
  /// Два сбоя в одну секунду не должны терять файл и называть в ошибке чужое имя.
  private func availableURL(name: String, extension pathExtension: String) -> URL {
    let manager = FileManager.default
    var candidate = directory.appending(path: "\(name).\(pathExtension)")
    var index = 2
    while manager.fileExists(atPath: candidate.path(percentEncoded: false)) {
      candidate = directory.appending(path: "\(name)-\(index).\(pathExtension)")
      index += 1
    }
    return candidate
  }

  /// Даты — ISO 8601 с долями секунды (иначе round-trip теряет миллисекунды и записи перестают быть равными).
  /// Кодировщик остаётся публичным: им читается старый `library.json` и им же экспортируются профили людей.
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(Self.dateFormat.format(date))
    }
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      if let date = (try? Self.dateFormat.parse(text)) ?? (try? Self.wholeSecondFormat.parse(text))
      {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: String(localized: "не дата ISO 8601: \(text)"))
    }
    return decoder
  }

  private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let wholeSecondFormat = Date.ISO8601FormatStyle()
}
