import Core
import Foundation

// Экспорт vault для Obsidian (SPEC.md §3.6): `vault/<проект>/meetings/YYYY-MM-DD-<slug>.md`
// с YAML-frontmatter и телом заметки. Формат зафиксирован golden-файлом
// Tests/ExportTests/Golden/obsidian_fixture.md. Модуль ничего не пишет на диск — только рендер
// и имена; запись файлов делает вызывающий (Store/приложение).

/// Итоги встречи для заметки: последний сохранённый follow-up встречи целиком.
public struct ObsidianNote: Hashable, Sendable {
  /// Markdown follow-up; `nil` — follow-up к встрече не сохраняли.
  public var followup: String?

  public init(followup: String? = nil) {
    self.followup = followup
  }
}

public enum ObsidianVaultExporter {
  /// Заметка встречи целиком: YAML-frontmatter + тело. Из `options` берутся часовой пояс,
  /// десятые доли и пометки наложения; промпт follow-up и контекст проекта в заметку не идут.
  public static func render(
    _ transcript: Transcript, note: ObsidianNote = .init(),
    options: TranscribeFullOptions = .init()
  ) -> String {
    (frontmatter(transcript, note: note, options: options)
      + body(transcript, note: note, options: options)).joined(separator: "\n") + "\n"
  }

  /// `2026-08-14-синк-по-продукту.md` — дата встречи, иначе дата обработки.
  public static func fileName(for transcript: Transcript, timeZone: TimeZone = .current) -> String {
    let date = transcript.meeting.date ?? transcript.createdAt
    let day = TranscribeFullExporter.dateFormatter(timeZone).string(from: date)
    return "\(day)-\(slug(transcript.displayTitle)).md"
  }

  /// `vault/<проект>/meetings/<файл>` — путь заметки внутри vault (SPEC.md §3.6).
  public static func relativePath(
    project: String?, transcript: Transcript, timeZone: TimeZone = .current
  ) -> String {
    "vault/\(folderName(project: project))/meetings/\(fileName(for: transcript, timeZone: timeZone))"
  }

  /// Имя файла из названия встречи: строчные буквы, дефисы вместо всего остального, ≤ 80 символов.
  /// Кириллица остаётся — Obsidian и файловая система с ней работают.
  public static func slug(_ title: String) -> String {
    let mapped = title.lowercased().map { character -> Character in
      character.isLetter || character.isNumber ? character : "-"
    }
    let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
    let limited = String(collapsed.prefix(80))
    let trimmed = limited.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "meeting" : trimmed
  }

  /// Имя папки проекта: без символов, запрещённых в путях; пустое — «Без проекта».
  public static func folderName(project: String?) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
    let cleaned = (project ?? "").unicodeScalars
      .map { forbidden.contains($0) ? Character(" ") : Character($0) }
    let collapsed = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let limited = String(collapsed.prefix(80))
      .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    return limited.isEmpty ? "Без проекта" : limited
  }

  // MARK: - Frontmatter

  private static func frontmatter(
    _ transcript: Transcript, note: ObsidianNote, options: TranscribeFullOptions
  ) -> [String] {
    let formatter = TranscribeFullExporter.dateFormatter(options.timeZone)
    var lines = ["---"]
    lines.append("title: \(quoted(transcript.displayTitle))")
    lines.append("date: \(transcript.meeting.date.map(formatter.string(from:)) ?? "null")")
    lines.append("duration: \(quoted(Timecode.hhmmss(transcript.audio.duration)))")
    lines.append(
      "project: \(TranscribeFullExporter.nonEmpty(transcript.meeting.project).map(quoted) ?? "null")"
    )
    lines.append(contentsOf: list("attendees", attendees(transcript).map(quoted)))
    lines.append(contentsOf: map("speaker_map", speakerMap(transcript)))
    lines.append("source: \(quoted(transcript.audio.fileName))")
    lines.append("engines: \(quoted(engines(transcript)))")
    lines.append("generator: \(quoted("MeetingScribe"))")
    lines.append("---")
    lines.append("")
    return lines
  }

  /// Имена участников: спикеры с номерами (реплики без спикера — «Неизвестный» — не участник).
  private static func attendees(_ transcript: Transcript) -> [String] {
    sortedSpeakers(transcript).compactMap { $0.speakerID == nil ? nil : $0.displayName }
  }

  /// `"1": "Имя"` по всем спикерам с номером.
  private static func speakerMap(_ transcript: Transcript) -> [(String, String)] {
    sortedSpeakers(transcript).compactMap { speaker in
      speaker.speakerID.map { (quoted("\($0)"), quoted(speaker.displayName)) }
    }
  }

  private static func sortedSpeakers(_ transcript: Transcript) -> [SpeakerStats] {
    transcript.speakers.sorted { ($0.speakerID ?? Int.max) < ($1.speakerID ?? Int.max) }
  }

  private static func engines(_ transcript: Transcript) -> String {
    [
      transcript.engines.asr.summary,
      transcript.engines.diarizer?.summary ?? TranscribeFullExporter.placeholder,
    ].joined(separator: ", ")
  }

  private static func list(_ key: String, _ values: [String]) -> [String] {
    values.isEmpty ? ["\(key): []"] : ["\(key):"] + values.map { "  - \($0)" }
  }

  private static func map(_ key: String, _ pairs: [(String, String)]) -> [String] {
    pairs.isEmpty ? ["\(key): {}"] : ["\(key):"] + pairs.map { "  \($0.0): \($0.1)" }
  }

  /// Строка YAML в двойных кавычках: экранируются `\`, `"`, переносы и прочие управляющие символы.
  /// Сырой `\r` или `\t` в значении ломает разбор frontmatter, поэтому всё, что ниже пробела (а также
  /// U+0085 и разделители строк U+2028/U+2029), уходит в `\uXXXX`.
  private static func quoted(_ value: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(value.unicodeScalars.count + 2)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      case "\n": escaped += "\\n"
      case "\r": escaped += "\\r"
      case "\t": escaped += "\\t"
      case let control where isControl(control):
        escaped += String(format: "\\u%04X", control.value)
      case let other: escaped.unicodeScalars.append(other)
      }
    }
    return "\"\(escaped)\""
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
      || scalar.value == 0x2028 || scalar.value == 0x2029
  }

  // MARK: - Тело заметки

  private static func body(
    _ transcript: Transcript, note: ObsidianNote, options: TranscribeFullOptions
  ) -> [String] {
    let formatter = TranscribeFullExporter.dateFormatter(options.timeZone)
    let placeholder = TranscribeFullExporter.placeholder
    var lines = ["# \(transcript.displayTitle)"]
    lines.append(
      "Дата: \(transcript.meeting.date.map(formatter.string(from:)) ?? placeholder) "
        + "· Длительность: \(Timecode.hhmmss(transcript.audio.duration)) "
        + "· Проект: \(TranscribeFullExporter.nonEmpty(transcript.meeting.project) ?? placeholder)")
    lines.append("")
    lines.append("## Участники")
    lines.append(contentsOf: TranscribeFullExporter.participantLines(transcript))
    if let followup = TranscribeFullExporter.nonEmpty(note.followup) {
      lines.append("")
      lines.append("## Follow-up")
      lines.append(contentsOf: nested(followup))
    }
    lines.append("")
    lines.append("## Транскрипт")
    lines.append(contentsOf: TranscribeFullExporter.transcriptLines(transcript, options: options))
    return lines
  }

  /// Follow-up внутри заметки: его заголовки опускаются на два уровня («# Follow-up — …» → «###»),
  /// чтобы не спорить с заголовком заметки и разделом «## Follow-up».
  private static func nested(_ markdown: String) -> [String] {
    var inCode = false
    return markdown.components(separatedBy: .newlines).map { line in
      if line.hasPrefix("```") { inCode.toggle() }
      guard !inCode, line.hasPrefix("#") else { return line }
      let level = line.prefix { $0 == "#" }.count
      guard line.dropFirst(level).hasPrefix(" ") else { return line }  // #тег, а не заголовок
      return String(repeating: "#", count: min(level + 2, 6)) + line.dropFirst(level)
    }
  }
}
