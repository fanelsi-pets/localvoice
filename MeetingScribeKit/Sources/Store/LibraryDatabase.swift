import Core
import Foundation
import GRDB
import Voices

// Схема `library.sqlite` и перенос `Library` ↔ SQLite (ADR-007, фаза 4).
//
// Правила схемы:
// - идентификаторы — TEXT (uuidString), даты — REAL `timeIntervalSince1970` (GRDB читает REAL как юлианский
//   день, поэтому конверсия дат здесь ручная и точная);
// - скалярные поля — колонки, сложные (статус с ассоциированными значениями, сопоставления спикеров,
//   образцы голоса) — JSON-текст;
// - внешних ключей нет: записи памяти проекта переживают удаление встречи (SPEC.md §3.6);
// - `position` — порядок записи в массиве `Library`, чтобы round-trip не переставлял записи местами.

/// Битая строка индекса: без обязательного поля запись собрать нельзя.
struct LibraryRowError: Error, CustomStringConvertible {
  var table: String
  var column: String
  var description: String { String(localized: "таблица \(table): пустое поле \(column)") }
}

enum LibraryDatabase {
  /// Версия данных библиотеки (`Library.currentSchemaVersion`) — пишется в `PRAGMA user_version`
  /// после всех миграций (`LibraryStore.openPool`), а не внутри одной из них.
  static let userVersion = Library.currentSchemaVersion

  // MARK: - Схема

  static func migrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(
        sql: """
          CREATE TABLE projects (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            position INTEGER NOT NULL
          )
          """)

      try db.execute(
        sql: """
          CREATE TABLE meetings (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT,
            title TEXT NOT NULL,
            date REAL,
            source_path TEXT NOT NULL,
            duration REAL,
            expected_speakers INTEGER,
            language TEXT NOT NULL,
            engines TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            processed_at REAL,
            processing_seconds REAL,
            utterance_count INTEGER,
            speaker_count INTEGER,
            speaker_assignments TEXT NOT NULL,
            track_urls TEXT NOT NULL,
            video_url TEXT,
            chat_url TEXT,
            has_transcript INTEGER NOT NULL,
            is_partial_transcript INTEGER NOT NULL,
            position INTEGER NOT NULL
          )
          """)
      try db.execute(sql: "CREATE INDEX meetings_on_project_id ON meetings(project_id)")
      try db.execute(sql: "CREATE INDEX meetings_on_date ON meetings(date)")

      try db.execute(
        sql: """
          CREATE TABLE people (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            voice_samples TEXT NOT NULL,
            samples TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            position INTEGER NOT NULL
          )
          """)

      try db.execute(
        sql: """
          CREATE TABLE followups (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            meeting_id TEXT NOT NULL,
            imported_at REAL NOT NULL,
            source TEXT NOT NULL,
            method TEXT,
            summary TEXT,
            raw_text TEXT,
            position INTEGER NOT NULL
          )
          """)
      try db.execute(sql: "CREATE INDEX followups_on_project_id ON followups(project_id)")
      try db.execute(sql: "CREATE INDEX followups_on_meeting_id ON followups(meeting_id)")

      try db.execute(
        sql: """
          CREATE TABLE decisions (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            meeting_id TEXT,
            followup_id TEXT,
            text TEXT NOT NULL,
            timestamp REAL,
            meeting_date REAL,
            created_at REAL NOT NULL,
            order_index INTEGER NOT NULL,
            position INTEGER NOT NULL
          )
          """)
      try db.execute(sql: "CREATE INDEX decisions_on_project_id ON decisions(project_id)")
      try db.execute(sql: "CREATE INDEX decisions_on_meeting_id ON decisions(meeting_id)")

      try db.execute(
        sql: """
          CREATE TABLE action_items (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            meeting_id TEXT,
            followup_id TEXT,
            text TEXT NOT NULL,
            owner TEXT,
            owner_person_id TEXT,
            due TEXT,
            due_text TEXT,
            status TEXT NOT NULL,
            meeting_date REAL,
            created_at REAL NOT NULL,
            completed_at REAL,
            order_index INTEGER NOT NULL,
            position INTEGER NOT NULL
          )
          """)
      try db.execute(sql: "CREATE INDEX action_items_on_project_id ON action_items(project_id)")
      try db.execute(sql: "CREATE INDEX action_items_on_meeting_id ON action_items(meeting_id)")

      try db.execute(
        sql: """
          CREATE TABLE questions (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            meeting_id TEXT,
            followup_id TEXT,
            text TEXT NOT NULL,
            status TEXT NOT NULL,
            meeting_date REAL,
            created_at REAL NOT NULL,
            answered_at REAL,
            order_index INTEGER NOT NULL,
            position INTEGER NOT NULL
          )
          """)
      try db.execute(sql: "CREATE INDEX questions_on_project_id ON questions(project_id)")
      try db.execute(sql: "CREATE INDEX questions_on_meeting_id ON questions(meeting_id)")

      // Индексы наполняются хранилищем (никакого external content и триггеров): реплики живут в
      // transcript.json, а записи памяти — в обычных таблицах, и обе стороны обновляются точечно.
      // `search_text` — нормализованная копия (ё→е), оригинал `text` лежит рядом UNINDEXED.
      try db.create(virtualTable: LibraryDatabase.utteranceIndex, using: FTS5()) { table in
        table.tokenizer = .unicode61(diacritics: .remove)
        table.column("meeting_id").notIndexed()
        table.column("idx").notIndexed()
        table.column("start").notIndexed()
        table.column("end").notIndexed()
        table.column("speaker_id").notIndexed()
        table.column("text").notIndexed()
        table.column("search_text")
      }

      try db.create(virtualTable: LibraryDatabase.memoryIndex, using: FTS5()) { table in
        table.tokenizer = .unicode61(diacritics: .remove)
        table.column("item_id").notIndexed()
        table.column("kind").notIndexed()
        table.column("project_id").notIndexed()
        table.column("meeting_id").notIndexed()
        table.column("text").notIndexed()
        table.column("search_text")
      }
    }
    return migrator
  }

  static let utteranceIndex = "utterance_index"
  static let memoryIndex = "memory_index"
  /// Номер колонки `search_text` для `highlight()`: у обоих индексов она последняя.
  static let utteranceSearchColumn = 6
  static let memorySearchColumn = 5

  /// Род записи памяти в `memory_index`.
  enum MemoryKind: String {
    case decision
    case action
    case question
  }

  // MARK: - Чтение

  /// Прочитанная библиотека и жалобы на пропущенные строки.
  struct LibraryRead {
    var library = Library()
    /// Строки, которые не удалось собрать в запись: их пропуск лучше, чем откладывание всей базы.
    var warnings: [String] = []
  }

  /// Читает библиотеку целиком. Ошибка SQLite бросается наружу (её обрабатывает `LibraryStore` как
  /// битый индекс), а нечитаемая строка — например, статус встречи от более новой версии приложения —
  /// пропускается с предупреждением: из-за одной записи пользователь не должен терять всю библиотеку.
  static func read(_ db: Database) throws -> LibraryRead {
    let coder = LibraryCoder()
    var library = Library()
    var warnings: [String] = []

    func rows<T>(_ table: String, _ build: (Row) throws -> T) throws -> [T] {
      try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY position, rowid")
        .compactMap { row in
          do {
            return try build(row)
          } catch {
            warnings.append(skipped(row, table: table, error: error))
            return nil
          }
        }
    }

    library.projects = try rows("projects") { try project(from: $0) }
    library.meetings = try rows("meetings") { try meeting(from: $0, coder: coder) }
    library.people = try rows("people") { try person(from: $0, coder: coder) }
    library.decisions = try rows("decisions") { try decision(from: $0) }
    library.actionItems = try rows("action_items") { try actionItem(from: $0) }
    library.questions = try rows("questions") { try question(from: $0) }
    library.followups = try rows("followups") { try followup(from: $0) }
    return LibraryRead(library: library, warnings: warnings)
  }

  private static func skipped(_ row: Row, table: String, error: any Error) -> String {
    let id: String = row["id"] ?? String(localized: "без id")
    let reason = (error as? LibraryRowError)?.description ?? error.localizedDescription
    return String(localized: "\(table): запись \(id) пропущена — \(reason)")
  }

  /// Пусты ли все таблицы записей: так распознаётся база, оставшаяся от прерванного переноса
  /// `library.json` (индекс реплик не в счёт — без записей он бесполезен).
  static func isEmpty(_ db: Database) throws -> Bool {
    for table in [
      "projects", "meetings", "people", "decisions", "action_items", "questions",
      "followups",
    ] {
      let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
      if count > 0 { return false }
    }
    return true
  }

  // MARK: - Запись

  /// Пишет разницу с прошлым снимком: `previous == nil` — полная синхронизация (upsert всех записей и
  /// удаление тех, кого в библиотеке уже нет). Вызывается внутри одной транзакции.
  ///
  /// `deletingMissing == false` — только дополнение: записи, которых нет в `library`, остаются
  /// (так первое сохранение поверх только что перенесённого `library.json` не стирает перенос).
  static func write(
    _ library: Library, previous: Library?, deletingMissing: Bool = true, in db: Database
  ) throws {
    let coder = LibraryCoder()

    func plan<Element: Identifiable & Hashable & Sendable>(
      _ current: [Element], previous: [Element]?
    ) -> TableSync<Element> where Element.ID == UUID {
      var sync = Self.plan(current, previous: previous)
      guard !deletingMissing else { return sync }
      sync.deletions = []
      sync.deleteMissing = false
      return sync
    }

    try apply(
      plan(library.projects, previous: previous?.projects), table: "projects", in: db
    ) { record, position, db in
      try db.execute(
        sql: "INSERT OR REPLACE INTO projects (id, name, created_at, position) VALUES (?, ?, ?, ?)",
        arguments: [
          record.id.uuidString, record.name, record.createdAt.timeIntervalSince1970,
          position,
        ])
    }

    let meetings = plan(library.meetings, previous: previous?.meetings)
    try apply(meetings, table: "meetings", in: db) { record, position, db in
      try db.execute(sql: meetingInsertSQL, arguments: meetingArguments(record, position, coder))
    }
    // Реплики удалённой встречи не должны переживать её запись: иначе поиск ведёт в никуда.
    for id in meetings.deletions { try removeUtterances(meetingID: id, in: db) }
    if meetings.deleteMissing { try deleteMissingUtterances(keptIDs: meetings.keptIDs, in: db) }

    try apply(plan(library.people, previous: previous?.people), table: "people", in: db) {
      record, position, db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO people
            (id, name, voice_samples, samples, created_at, updated_at, position)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.id.uuidString, record.name, try coder.json(record.voiceSamples),
          try coder.json(record.samples), record.createdAt.timeIntervalSince1970,
          record.updatedAt.timeIntervalSince1970, position,
        ])
    }

    try apply(plan(library.followups, previous: previous?.followups), table: "followups", in: db) {
      record, position, db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO followups
            (id, project_id, meeting_id, imported_at, source, method, summary, raw_text, position)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.id.uuidString, record.projectID.uuidString, record.meetingID.uuidString,
          record.importedAt.timeIntervalSince1970, record.source.rawValue, record.method,
          record.summary, record.rawText, position,
        ])
    }

    try applyMemory(
      plan(library.decisions, previous: previous?.decisions), table: "decisions", kind: .decision,
      in: db
    ) { record, position, db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO decisions
            (id, project_id, meeting_id, followup_id, text, timestamp, meeting_date, created_at,
             order_index, position)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.id.uuidString, record.projectID.uuidString, record.meetingID?.uuidString,
          record.followupID?.uuidString, record.text, record.timestamp,
          record.meetingDate?.timeIntervalSince1970, record.createdAt.timeIntervalSince1970,
          record.order, position,
        ])
    }

    try applyMemory(
      plan(library.actionItems, previous: previous?.actionItems), table: "action_items",
      kind: .action, in: db
    ) { record, position, db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO action_items
            (id, project_id, meeting_id, followup_id, text, owner, owner_person_id, due, due_text,
             status, meeting_date, created_at, completed_at, order_index, position)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.id.uuidString, record.projectID.uuidString, record.meetingID?.uuidString,
          record.followupID?.uuidString, record.text, record.owner,
          record.ownerPersonID?.uuidString, record.due, record.dueText, record.status.rawValue,
          record.meetingDate?.timeIntervalSince1970, record.createdAt.timeIntervalSince1970,
          record.completedAt?.timeIntervalSince1970, record.order, position,
        ])
    }

    try applyMemory(
      plan(library.questions, previous: previous?.questions), table: "questions", kind: .question,
      in: db
    ) { record, position, db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO questions
            (id, project_id, meeting_id, followup_id, text, status, meeting_date, created_at,
             answered_at, order_index, position)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.id.uuidString, record.projectID.uuidString, record.meetingID?.uuidString,
          record.followupID?.uuidString, record.text, record.status.rawValue,
          record.meetingDate?.timeIntervalSince1970, record.createdAt.timeIntervalSince1970,
          record.answeredAt?.timeIntervalSince1970, record.order, position,
        ])
    }
  }

  // MARK: - Индекс реплик

  /// Переиндексирует реплики встречи: старые строки удаляются, новые вставляются (одна транзакция).
  static func indexUtterances(_ utterances: [Utterance], meetingID: UUID, in db: Database) throws {
    try removeUtterances(meetingID: meetingID, in: db)
    for (index, utterance) in utterances.enumerated() {
      let text = LibraryStore.normalizedText(utterance.text)
      guard !text.isEmpty else { continue }
      try db.execute(
        sql: """
          INSERT INTO utterance_index
            (meeting_id, idx, start, end, speaker_id, text, search_text)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          meetingID.uuidString, index, utterance.start, utterance.end, utterance.speakerID, text,
          LibraryStore.searchText(text),
        ])
    }
  }

  static func removeUtterances(meetingID: UUID, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM utterance_index WHERE meeting_id = ?", arguments: [meetingID.uuidString])
  }

  private static func deleteMissingUtterances(keptIDs: [UUID], in db: Database) throws {
    guard !keptIDs.isEmpty else {
      try db.execute(sql: "DELETE FROM utterance_index")
      return
    }
    let placeholders = Array(repeating: "?", count: keptIDs.count).joined(separator: ", ")
    try db.execute(
      sql: "DELETE FROM utterance_index WHERE meeting_id NOT IN (\(placeholders))",
      arguments: StatementArguments(keptIDs.map(\.uuidString)))
  }

  // MARK: - Разница коллекций

  /// План синхронизации таблицы с массивом записей.
  struct TableSync<Element: Identifiable & Hashable & Sendable> where Element.ID == UUID {
    var upserts: [(element: Element, position: Int)] = []
    var deletions: [UUID] = []
    /// Снимка не было: всё, чего нет в `keptIDs`, удаляется одним запросом.
    var deleteMissing = false
    var keptIDs: [UUID] = []
  }

  /// Запись считается неизменной, если совпали и содержимое, и место в массиве.
  static func plan<Element: Identifiable & Hashable & Sendable>(
    _ current: [Element], previous: [Element]?
  ) -> TableSync<Element> where Element.ID == UUID {
    var sync = TableSync<Element>()
    sync.keptIDs = current.map(\.id)
    guard let previous else {
      sync.deleteMissing = true
      sync.upserts = Array(current.enumerated()).map { ($0.element, $0.offset) }
      return sync
    }
    var stored: [UUID: (element: Element, position: Int)] = [:]
    for (position, element) in previous.enumerated() { stored[element.id] = (element, position) }
    for (position, element) in current.enumerated() {
      if let old = stored[element.id], old.element == element, old.position == position { continue }
      sync.upserts.append((element, position))
    }
    let currentIDs = Set(sync.keptIDs)
    sync.deletions = previous.map(\.id).filter { !currentIDs.contains($0) }
    return sync
  }

  static func apply<Element>(
    _ sync: TableSync<Element>,
    table: String,
    in db: Database,
    insert: (Element, Int, Database) throws -> Void
  ) throws {
    for id in sync.deletions {
      try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id.uuidString])
    }
    if sync.deleteMissing {
      try deleteMissing(table: table, column: "id", keptIDs: sync.keptIDs, in: db)
    }
    for (element, position) in sync.upserts { try insert(element, position, db) }
  }

  /// То же для записей памяти: вместе со строкой таблицы обновляется строка `memory_index`.
  static func applyMemory<Element: MemoryRecord>(
    _ sync: TableSync<Element>,
    table: String,
    kind: MemoryKind,
    in db: Database,
    insert: (Element, Int, Database) throws -> Void
  ) throws {
    for id in sync.deletions {
      try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id.uuidString])
      try removeMemoryIndex(itemID: id, in: db)
    }
    if sync.deleteMissing {
      try deleteMissing(table: table, column: "id", keptIDs: sync.keptIDs, in: db)
      try deleteMissingMemoryIndex(kind: kind, keptIDs: sync.keptIDs, in: db)
    }
    for (element, position) in sync.upserts {
      try insert(element, position, db)
      try removeMemoryIndex(itemID: element.id, in: db)
      let text = LibraryStore.normalizedText(element.text)
      guard !text.isEmpty else { continue }
      try db.execute(
        sql: """
          INSERT INTO memory_index (item_id, kind, project_id, meeting_id, text, search_text)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          element.id.uuidString, kind.rawValue, element.projectID.uuidString,
          element.meetingID?.uuidString, text, LibraryStore.searchText(text),
        ])
    }
  }

  static func removeMemoryIndex(itemID: UUID, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM memory_index WHERE item_id = ?", arguments: [itemID.uuidString])
  }

  private static func deleteMissingMemoryIndex(kind: MemoryKind, keptIDs: [UUID], in db: Database)
    throws
  {
    guard !keptIDs.isEmpty else {
      try db.execute(sql: "DELETE FROM memory_index WHERE kind = ?", arguments: [kind.rawValue])
      return
    }
    let placeholders = Array(repeating: "?", count: keptIDs.count).joined(separator: ", ")
    var arguments: [(any DatabaseValueConvertible)?] = [kind.rawValue]
    arguments.append(contentsOf: keptIDs.map(\.uuidString))
    try db.execute(
      sql: "DELETE FROM memory_index WHERE kind = ? AND item_id NOT IN (\(placeholders))",
      arguments: StatementArguments(arguments))
  }

  private static func deleteMissing(table: String, column: String, keptIDs: [UUID], in db: Database)
    throws
  {
    guard !keptIDs.isEmpty else {
      try db.execute(sql: "DELETE FROM \(table)")
      return
    }
    let placeholders = Array(repeating: "?", count: keptIDs.count).joined(separator: ", ")
    try db.execute(
      sql: "DELETE FROM \(table) WHERE \(column) NOT IN (\(placeholders))",
      arguments: StatementArguments(keptIDs.map(\.uuidString)))
  }

  // MARK: - Строки в записи

  private static func project(from row: Row) throws -> ProjectRecord {
    ProjectRecord(
      id: try id(row, "id", table: "projects"),
      name: row["name"] ?? "",
      createdAt: try requiredDate(row, "created_at", table: "projects"))
  }

  private static func meeting(from row: Row, coder: LibraryCoder) throws -> MeetingRecord {
    let table = "meetings"
    let source = try require(url(row, "source_path"), table: table, column: "source_path")
    let language: String? = row["language"]
    return MeetingRecord(
      id: try id(row, "id", table: table),
      projectID: uuid(row, "project_id"),
      title: row["title"] ?? "",
      date: date(row, "date"),
      sourceURL: source,
      duration: row["duration"],
      expectedSpeakers: row["expected_speakers"],
      language: language.flatMap(LanguageChoice.init(rawValue:)) ?? .auto,
      engines: try coder.decode(EngineSelection.self, row["engines"]) ?? .accurate,
      status: try coder.decode(MeetingStatus.self, row["status"]) ?? .imported,
      createdAt: try requiredDate(row, "created_at", table: table),
      processedAt: date(row, "processed_at"),
      processingSeconds: row["processing_seconds"],
      utteranceCount: row["utterance_count"],
      speakerCount: row["speaker_count"],
      speakerAssignments: assignments(
        try coder.decode([String: SpeakerAssignment].self, row["speaker_assignments"]) ?? [:]),
      trackURLs: (try coder.decode([String].self, row["track_urls"]) ?? []).compactMap {
        URL(string: $0)
      },
      videoURL: url(row, "video_url"),
      chatURL: url(row, "chat_url"),
      hasTranscript: row["has_transcript"] ?? false,
      isPartialTranscript: row["is_partial_transcript"] ?? false)
  }

  private static func person(from row: Row, coder: LibraryCoder) throws -> PersonRecord {
    let table = "people"
    return PersonRecord(
      id: try id(row, "id", table: table),
      name: row["name"] ?? "",
      voiceSamples: try coder.decode([PersonRecord.VoiceSample].self, row["voice_samples"]) ?? [],
      samples: try coder.decode([PersonRecord.SampleRef].self, row["samples"]) ?? [],
      createdAt: try requiredDate(row, "created_at", table: table),
      updatedAt: try requiredDate(row, "updated_at", table: table))
  }

  private static func decision(from row: Row) throws -> DecisionRecord {
    let table = "decisions"
    return DecisionRecord(
      id: try id(row, "id", table: table),
      projectID: try id(row, "project_id", table: table),
      meetingID: uuid(row, "meeting_id"),
      followupID: uuid(row, "followup_id"),
      text: row["text"] ?? "",
      timestamp: row["timestamp"],
      meetingDate: date(row, "meeting_date"),
      createdAt: try requiredDate(row, "created_at", table: table),
      order: row["order_index"] ?? 0)
  }

  private static func actionItem(from row: Row) throws -> ActionItemRecord {
    let table = "action_items"
    let status: String? = row["status"]
    return ActionItemRecord(
      id: try id(row, "id", table: table),
      projectID: try id(row, "project_id", table: table),
      meetingID: uuid(row, "meeting_id"),
      followupID: uuid(row, "followup_id"),
      text: row["text"] ?? "",
      owner: row["owner"],
      ownerPersonID: uuid(row, "owner_person_id"),
      due: row["due"],
      dueText: row["due_text"],
      status: status.flatMap(ActionStatus.init(rawValue:)) ?? .open,
      meetingDate: date(row, "meeting_date"),
      createdAt: try requiredDate(row, "created_at", table: table),
      completedAt: date(row, "completed_at"),
      order: row["order_index"] ?? 0)
  }

  private static func question(from row: Row) throws -> QuestionRecord {
    let table = "questions"
    let status: String? = row["status"]
    return QuestionRecord(
      id: try id(row, "id", table: table),
      projectID: try id(row, "project_id", table: table),
      meetingID: uuid(row, "meeting_id"),
      followupID: uuid(row, "followup_id"),
      text: row["text"] ?? "",
      status: status.flatMap(QuestionStatus.init(rawValue:)) ?? .open,
      meetingDate: date(row, "meeting_date"),
      createdAt: try requiredDate(row, "created_at", table: table),
      answeredAt: date(row, "answered_at"),
      order: row["order_index"] ?? 0)
  }

  private static func followup(from row: Row) throws -> FollowupRecord {
    let table = "followups"
    let source: String? = row["source"]
    return FollowupRecord(
      id: try id(row, "id", table: table),
      projectID: try id(row, "project_id", table: table),
      meetingID: try id(row, "meeting_id", table: table),
      importedAt: try requiredDate(row, "imported_at", table: table),
      source: source.flatMap(FollowupSource.init(rawValue:)) ?? .pasted,
      method: row["method"],
      summary: row["summary"],
      rawText: row["raw_text"])
  }

  // MARK: - Запись встречи

  private static let meetingInsertSQL = """
    INSERT OR REPLACE INTO meetings
      (id, project_id, title, date, source_path, duration, expected_speakers, language, engines,
       status, created_at, processed_at, processing_seconds, utterance_count, speaker_count,
       speaker_assignments, track_urls, video_url, chat_url, has_transcript, is_partial_transcript,
       position)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

  private static func meetingArguments(
    _ record: MeetingRecord, _ position: Int, _ coder: LibraryCoder
  ) throws -> StatementArguments {
    let assignments = Dictionary(
      uniqueKeysWithValues: record.speakerAssignments.map { (String($0.key), $0.value) })
    let values: [(any DatabaseValueConvertible)?] = [
      record.id.uuidString,
      record.projectID?.uuidString,
      record.title,
      record.date?.timeIntervalSince1970,
      record.sourceURL.absoluteString,
      record.duration,
      record.expectedSpeakers,
      record.language.rawValue,
      try coder.json(record.engines),
      try coder.json(record.status),
      record.createdAt.timeIntervalSince1970,
      record.processedAt?.timeIntervalSince1970,
      record.processingSeconds,
      record.utteranceCount,
      record.speakerCount,
      try coder.json(assignments),
      try coder.json(record.trackURLs.map(\.absoluteString)),
      record.videoURL?.absoluteString,
      record.chatURL?.absoluteString,
      record.hasTranscript,
      record.isPartialTranscript,
      position,
    ]
    return StatementArguments(values)
  }

  // MARK: - Значения строк

  private static func assignments(_ raw: [String: SpeakerAssignment]) -> [Int: SpeakerAssignment] {
    Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
  }

  private static func uuid(_ row: Row, _ column: String) -> UUID? {
    let text: String? = row[column]
    return text.flatMap(UUID.init(uuidString:))
  }

  private static func id(_ row: Row, _ column: String, table: String) throws -> UUID {
    try require(uuid(row, column), table: table, column: column)
  }

  private static func url(_ row: Row, _ column: String) -> URL? {
    let text: String? = row[column]
    return text.flatMap(URL.init(string:))
  }

  private static func date(_ row: Row, _ column: String) -> Date? {
    let seconds: Double? = row[column]
    return seconds.map(Date.init(timeIntervalSince1970:))
  }

  private static func requiredDate(_ row: Row, _ column: String, table: String) throws -> Date {
    try require(date(row, column), table: table, column: column)
  }

  private static func require<T>(_ value: T?, table: String, column: String) throws -> T {
    guard let value else { throw LibraryRowError(table: table, column: column) }
    return value
  }
}

/// Кодирование сложных полей в JSON-колонки. Даты — числом (`timeIntervalSince1970`): round-trip
/// обязан быть точным, иначе записи после чтения перестают быть равными исходным.
final class LibraryCoder {
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init() {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.timeIntervalSince1970)
    }
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      return Date(timeIntervalSince1970: try container.decode(Double.self))
    }
  }

  func json(_ value: some Encodable) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func decode<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T? {
    guard let text, !text.isEmpty else { return nil }
    return try decoder.decode(type, from: Data(text.utf8))
  }
}
