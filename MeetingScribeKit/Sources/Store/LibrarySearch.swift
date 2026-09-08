import Core
import Foundation
import GRDB

// Полнотекстовый поиск по библиотеке (SPEC.md §3.6): реплики всех встреч и записи памяти проекта.
// Индексы — обычные таблицы FTS5 с токенизатором `unicode61 remove_diacritics 2`. Он сворачивает
// регистр кириллицы, но не считает «ё» и «е» одной буквой (и, к счастью, не сводит украинские «ї», «й»
// к «і», «и»), поэтому в индекс кладётся нормализованная копия `search_text` (только ё→е), а оригинал
// лежит рядом UNINDEXED-колонкой и возвращается пользователю как есть.

/// Найденное место: реплика встречи или запись памяти проекта.
public struct SearchHit: Identifiable, Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// Реплика транскрипта: номер в списке и таймкоды для перехода.
    case utterance(index: Int, start: Double, end: Double, speakerID: Int?)
    case decision(UUID)
    case actionItem(UUID)
    case question(UUID)
  }

  public var kind: Kind
  public var meetingID: UUID?
  public var projectID: UUID?
  /// Оригинальный текст (с «ё»), целиком.
  public var text: String
  /// Диапазоны совпадений в `text` для подсветки.
  public var highlights: [Range<String.Index>]
  /// Оценка релевантности bm25: чем меньше, тем лучше совпадение.
  public var rank: Double

  public init(
    kind: Kind,
    meetingID: UUID? = nil,
    projectID: UUID? = nil,
    text: String,
    highlights: [Range<String.Index>] = [],
    rank: Double = 0
  ) {
    self.kind = kind
    self.meetingID = meetingID
    self.projectID = projectID
    self.text = text
    self.highlights = highlights
    self.rank = rank
  }

  /// Устойчивый идентификатор для списков SwiftUI: не зависит от порядка выдачи.
  public var id: String {
    switch kind {
    case .utterance(let index, _, _, _):
      "u:\(meetingID?.uuidString ?? "-"):\(index)"
    case .decision(let itemID): "d:\(itemID.uuidString)"
    case .actionItem(let itemID): "a:\(itemID.uuidString)"
    case .question(let itemID): "q:\(itemID.uuidString)"
    }
  }

  /// Запись памяти проекта, если найдено не в репликах.
  public var itemID: UUID? {
    switch kind {
    case .utterance: nil
    case .decision(let itemID), .actionItem(let itemID), .question(let itemID): itemID
    }
  }

  /// Начало реплики, с — для перехода к месту в записи.
  public var start: Double? {
    if case .utterance(_, let start, _, _) = kind { return start }
    return nil
  }
}

extension LibraryStore {
  /// Маркеры `highlight()`: управляющие символы не встречаются в расшифровке и не ломают разбор.
  static let highlightStart: Character = "\u{1}"
  static let highlightEnd: Character = "\u{2}"

  /// Полнотекстовый поиск (SPEC.md §3.6) по репликам всех встреч и по решениям, задачам и вопросам.
  /// `projectID` ограничивает выдачу проектом. Пустой запрос — пустая выдача. Порядок — по bm25.
  public func search(_ query: String, projectID: UUID? = nil, limit: Int = 200) throws
    -> [SearchHit]
  {
    guard limit > 0, let pattern = Self.ftsQuery(from: query) else { return [] }
    let pool = try database()
    do {
      let hits = try pool.read { db in
        try Self.utteranceHits(pattern: pattern, projectID: projectID, limit: limit, in: db)
          + Self.memoryHits(pattern: pattern, projectID: projectID, limit: limit, in: db)
      }
      // bm25 отрицателен, лучшие совпадения — меньше; `id` разводит равные оценки предсказуемо.
      return Array(hits.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }.prefix(limit))
    } catch {
      throw LibraryStoreError.searchFailed(query: query, reason: error.localizedDescription)
    }
  }

  /// Запрос FTS5 из текста пользователя: слова (буквы и цифры, всё остальное — разделитель), ё→е,
  /// каждое как префикс в кавычках и через пробел (то есть AND). Синтаксис FTS5 пользователю недоступен:
  /// кавычки, звёздочки и `OR` в запросе — обычные символы, а не операторы.
  public nonisolated static func ftsQuery(from text: String) -> String? {
    let tokens = searchText(text).split { !$0.isLetter && !$0.isNumber }
    guard !tokens.isEmpty else { return nil }
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
  }

  /// Текст в индексе: NFC и без пробелов по краям — так смещения подсветки ложатся на оригинал.
  nonisolated static func normalizedText(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Копия для FTS: только ё→е (число символов не меняется). Украинские буквы не трогаем — «ї» и «і»
  /// разные, и «киів» не должно находить «Київ».
  nonisolated static func searchText(_ text: String) -> String {
    normalizedText(text)
      .replacingOccurrences(of: "ё", with: "е")
      .replacingOccurrences(of: "Ё", with: "Е")
  }

  // MARK: - Запросы

  private static func utteranceHits(
    pattern: String, projectID: UUID?, limit: Int, in db: Database
  ) throws -> [SearchHit] {
    var sql = """
      SELECT meeting_id, idx, start, end, speaker_id, text,
             (SELECT project_id FROM meetings WHERE meetings.id = utterance_index.meeting_id)
               AS project_id,
             highlight(utterance_index, \(LibraryDatabase.utteranceSearchColumn), ?, ?) AS marked,
             bm25(utterance_index) AS score
      FROM utterance_index
      WHERE utterance_index MATCH ?
      """
    var arguments: [(any DatabaseValueConvertible)?] = [
      String(highlightStart), String(highlightEnd), pattern,
    ]
    if let projectID {
      sql += "\n  AND meeting_id IN (SELECT id FROM meetings WHERE project_id = ?)"
      arguments.append(projectID.uuidString)
    }
    sql += "\nORDER BY rank LIMIT ?"
    arguments.append(limit)

    return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
      let text: String = row["text"] ?? ""
      let marked: String = row["marked"] ?? ""
      let meetingText: String? = row["meeting_id"]
      let projectText: String? = row["project_id"]
      return SearchHit(
        kind: .utterance(
          index: row["idx"] ?? 0, start: row["start"] ?? 0, end: row["end"] ?? 0,
          speakerID: row["speaker_id"]),
        meetingID: meetingText.flatMap(UUID.init(uuidString:)),
        projectID: projectText.flatMap(UUID.init(uuidString:)),
        text: text,
        highlights: highlightRanges(marked: marked, text: text),
        rank: row["score"] ?? 0)
    }
  }

  private static func memoryHits(
    pattern: String, projectID: UUID?, limit: Int, in db: Database
  ) throws -> [SearchHit] {
    var sql = """
      SELECT item_id, kind, project_id, meeting_id, text,
             highlight(memory_index, \(LibraryDatabase.memorySearchColumn), ?, ?) AS marked,
             bm25(memory_index) AS score
      FROM memory_index
      WHERE memory_index MATCH ?
      """
    var arguments: [(any DatabaseValueConvertible)?] = [
      String(highlightStart), String(highlightEnd), pattern,
    ]
    if let projectID {
      sql += "\n  AND project_id = ?"
      arguments.append(projectID.uuidString)
    }
    sql += "\nORDER BY rank LIMIT ?"
    arguments.append(limit)

    return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
      .compactMap { row in
        let itemText: String? = row["item_id"]
        let kindText: String? = row["kind"]
        guard let itemID = itemText.flatMap(UUID.init(uuidString:)),
          let kind = kindText.flatMap(LibraryDatabase.MemoryKind.init(rawValue:))
        else { return nil }
        let text: String = row["text"] ?? ""
        let marked: String = row["marked"] ?? ""
        let meetingText: String? = row["meeting_id"]
        let projectText: String? = row["project_id"]
        let hitKind: SearchHit.Kind =
          switch kind {
          case .decision: .decision(itemID)
          case .action: .actionItem(itemID)
          case .question: .question(itemID)
          }
        return SearchHit(
          kind: hitKind,
          meetingID: meetingText.flatMap(UUID.init(uuidString:)),
          projectID: projectText.flatMap(UUID.init(uuidString:)),
          text: text,
          highlights: highlightRanges(marked: marked, text: text),
          rank: row["score"] ?? 0)
      }
  }

  /// Переносит подсветку с `search_text` (с маркерами) на оригинал: нормализация ё→е не меняет число
  /// символов, поэтому смещения совпадают. Разошлись — лучше вернуть без подсветки, чем подсветить не то.
  static func highlightRanges(marked: String, text: String) -> [Range<String.Index>] {
    var offsets: [Range<Int>] = []
    var offset = 0
    var openedAt: Int?
    for character in marked {
      switch character {
      case highlightStart: openedAt = offset
      case highlightEnd:
        if let start = openedAt, start < offset { offsets.append(start..<offset) }
        openedAt = nil
      default: offset += 1
      }
    }
    let total = text.count
    guard offset == total, !offsets.isEmpty else { return [] }
    return offsets.compactMap { range in
      guard range.upperBound <= total else { return nil }
      let start = text.index(text.startIndex, offsetBy: range.lowerBound)
      let end = text.index(text.startIndex, offsetBy: range.upperBound)
      return start..<end
    }
  }
}
