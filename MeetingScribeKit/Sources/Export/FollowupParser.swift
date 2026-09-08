import Core
import Foundation

// Разбор ответа внешней модели на промпт follow-up (SPEC.md §3.6). Ответ приходит из буфера обмена
// или от локальной LLM, поэтому парсер терпим к формату: сначала ищется обязательный блок
// ```meeting-followup с JSON, при неудаче — секции Markdown «Решения/Задачи/Вопросы» (ru/uk/en).
// Модуль ничего не пишет и не знает о хранилище: он превращает текст в структуры.

/// Результат разбора ответа модели. `warnings` объясняют, почему выбран тот или иной путь, —
/// их показывает интерфейс импорта follow-up.
public struct ParsedFollowup: Hashable, Codable, Sendable {
  /// Каким способом получен результат.
  public enum Method: String, Codable, Sendable {
    /// Разобран блок ```meeting-followup (основной путь).
    case jsonBlock
    /// Блока не было или он сломан — разобраны секции Markdown.
    case markdownSections
    /// Ни блока, ни знакомых секций.
    case none
  }

  public struct Decision: Hashable, Codable, Sendable {
    public var text: String
    /// Таймкод реплики в секундах, если разобран.
    public var timestamp: Double?
    /// Исходная строка таймкода («00:41:12»); `nil` — таймкод пришёл числом или отсутствует.
    public var timestampText: String?

    public init(text: String, timestamp: Double? = nil, timestampText: String? = nil) {
      self.text = text
      self.timestamp = timestamp
      self.timestampText = timestampText
    }
  }

  public struct Action: Hashable, Codable, Sendable {
    public var text: String
    public var owner: String?
    /// Срок ISO-днём («2026-09-10»).
    public var due: String?
    /// Срок, который не удалось привести к дате («до пятницы»); заполняется вместо `due`.
    public var dueText: String?

    public init(text: String, owner: String? = nil, due: String? = nil, dueText: String? = nil) {
      self.text = text
      self.owner = owner
      self.due = due
      self.dueText = dueText
    }
  }

  public struct Question: Hashable, Codable, Sendable {
    public var text: String

    public init(text: String) {
      self.text = text
    }
  }

  public var method: Method
  public var decisions: [Decision]
  public var actions: [Action]
  public var questions: [Question]
  public var summary: String?
  public var warnings: [String]

  public init(
    method: Method = .none,
    decisions: [Decision] = [],
    actions: [Action] = [],
    questions: [Question] = [],
    summary: String? = nil,
    warnings: [String] = []
  ) {
    self.method = method
    self.decisions = decisions
    self.actions = actions
    self.questions = questions
    self.summary = summary
    self.warnings = warnings
  }

  /// Нет ни решений, ни задач, ни вопросов (резюме само по себе смысла для библиотеки не имеет).
  public var isEmpty: Bool { decisions.isEmpty && actions.isEmpty && questions.isEmpty }
}

public enum FollowupParser {
  /// Разбирает ответ модели. Никогда не бросает: непонятный текст — это `method == .none`.
  public static func parse(_ text: String) -> ParsedFollowup {
    let normalized = normalize(text)
    var warnings: [String] = []
    var blocks = fencedBlocks(in: normalized, requireTag: true)
    if blocks.isEmpty {
      // Модель оградила блок как ```json или без слова (так делает Gemini): принимаем последний
      // фенс-блок, внутри которого есть ожидаемые ключи.
      let candidates = fencedBlocks(in: normalized, requireTag: false)
      if let block = candidates.last(where: { looksLikeFollowup($0.content) }) {
        blocks = [block]
        warnings.append("блок оформлен как ```json без слова meeting-followup — принят по ключам")
      }
    }
    if blocks.count > 1 {
      warnings.append("найдено блоков meeting-followup: \(blocks.count) — разобран последний")
    }
    if let block = blocks.last {
      if !block.closed {
        warnings.append("блок meeting-followup не закрыт — прочитан до конца текста")
      }
      if let object = json(from: block.content, warnings: &warnings) {
        return fromJSON(object, warnings: warnings)
      }
    }
    var fallback = fromMarkdown(normalized)
    fallback.warnings = warnings + fallback.warnings
    return fallback
  }

  // MARK: - Документ без служебного блока

  /// Делит ответ модели на документ для читателя и служебный блок follow-up. Блок — фенс meeting-followup
  /// либо ```json/без подписи с ключами структуры — убирается из текста вместе с незакрытым хвостом при
  /// стриминге и заголовком, под которым он один стоял («## Служебный блок»); посторонние код-блоки
  /// остаются. Нет блока — документ равен исходному тексту, `machineBlock == nil`. Несколько блоков
  /// склеиваются пустой строкой: `parse` возьмёт последний.
  public static func split(_ text: String) -> (document: String, machineBlock: String?) {
    let lines = normalize(text).components(separatedBy: "\n")
    var kept: [String] = []
    var blocks: [String] = []
    var index = 0
    while index < lines.count {
      // Любой фенс открывает блок (как в Markdown): иначе закрывающие ``` чужого код-блока
      // читались бы как открывающие без подписи.
      guard let marker = fenceMarker(lines[index]) else {
        kept.append(lines[index])
        index += 1
        continue
      }
      let opening = lines[index]
      var body: [String] = []
      var cursor = index + 1
      while cursor < lines.count {
        if isClosingFence(lines[cursor], marker: marker) {
          cursor += 1
          break
        }
        body.append(lines[cursor])
        cursor += 1
      }
      let tagged = openingFence(opening, requireTag: true) != nil
      let untaggedFollowup =
        openingFence(opening, requireTag: false) != nil
        && looksLikeFollowup(body.joined(separator: "\n"))
      if tagged || untaggedFollowup {
        blocks.append(lines[index..<cursor].joined(separator: "\n"))
      } else {
        kept.append(contentsOf: lines[index..<cursor])
      }
      index = cursor
    }
    guard !blocks.isEmpty else { return (text, nil) }
    func trimTrailingBlank() {
      while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        kept.removeLast()
      }
    }
    trimTrailingBlank()
    if let last = kept.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
      kept.removeLast()
      trimTrailingBlank()
    }
    return (kept.joined(separator: "\n"), blocks.joined(separator: "\n\n"))
  }

  /// Маркер любого фенса кода (``` или ~~~ трижды и более) независимо от подписи.
  private static func fenceMarker(_ line: String) -> Character? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
    return trimmed.prefix { $0 == marker }.count >= 3 ? marker : nil
  }

  // MARK: - Подготовка текста

  /// CRLF → LF, прочь BOM и символы нулевой ширины, неразрывные пробелы — обычными.
  private static func normalize(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    var previous: Unicode.Scalar?
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\u{FEFF}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}":
        continue
      case "\u{00A0}", "\u{202F}", "\u{2007}":
        scalars.append(" ")
      case "\r":
        scalars.append("\n")
      case "\n":
        if previous == "\r" { break }
        scalars.append("\n")
      default:
        scalars.append(scalar)
      }
      previous = scalar
    }
    return String(scalars)
  }

  // MARK: - Блок ```meeting-followup

  private struct Block {
    var content: String
    /// Закрывающий фенс найден (иначе блок прочитан до конца текста).
    var closed: Bool
  }

  /// Есть ли в тексте блока ключи структуры follow-up — для блоков без слова meeting-followup.
  private static func looksLikeFollowup(_ content: String) -> Bool {
    ["\"decisions\"", "\"actions\"", "\"questions\"", "\"summary\""].contains {
      content.contains($0)
    }
  }

  private static func fencedBlocks(in text: String, requireTag: Bool) -> [Block] {
    var blocks: [Block] = []
    let lines = text.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
      guard let marker = openingFence(lines[index], requireTag: requireTag) else {
        index += 1
        continue
      }
      index += 1
      var content: [String] = []
      var closed = false
      while index < lines.count {
        if isClosingFence(lines[index], marker: marker) {
          closed = true
          index += 1
          break
        }
        content.append(lines[index])
        index += 1
      }
      blocks.append(Block(content: content.joined(separator: "\n"), closed: closed))
    }
    return blocks
  }

  /// Открывающий фенс блока: ``` или ~~~ (три и более) и слово meeting-followup в любом регистре;
  /// без `requireTag` — также пустая подпись или json (блок, который модель оформила иначе).
  private static func openingFence(_ line: String, requireTag: Bool) -> Character? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
    let fence = trimmed.prefix { $0 == marker }
    guard fence.count >= 3 else { return nil }
    let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).lowercased()
    let normalized = info.replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    if normalized.hasPrefix("meeting-followup") { return marker }
    guard !requireTag else { return nil }
    return ["", "json", "jsonc", "json5"].contains(normalized) ? marker : nil
  }

  private static func isClosingFence(_ line: String, marker: Character) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else { return false }
    return trimmed.allSatisfy { $0 == marker }
  }

  // MARK: - JSON блока и его починка

  /// Разбор содержимого блока с последовательными попытками починки: как есть → снять вложенные
  /// фенсы → убрать хвостовые запятые → оставить только `{…}` → заменить «умные» кавычки.
  private static func json(from content: String, warnings: inout [String]) -> [String: Any]? {
    var attempts: [(repair: String?, text: String)] = []
    func add(_ repair: String?, _ text: String) {
      guard attempts.last?.text != text, !text.isEmpty else { return }
      attempts.append((repair, text))
    }
    let base = content.trimmingCharacters(in: .whitespacesAndNewlines)
    add(nil, base)
    let unfenced = strippingNestedFences(base)
    add("сняты вложенные фенсы", unfenced)
    let withoutCommas = removingTrailingCommas(unfenced)
    add("убраны хвостовые запятые", withoutCommas)
    let sliced = braceSlice(withoutCommas)
    add("оставлен только объект {…}", sliced)
    let straight = replacingSmartQuotes(sliced)
    add("«умные» кавычки заменены на прямые", straight)

    var lastError = "блок пуст"
    for attempt in attempts {
      do {
        let object = try JSONSerialization.jsonObject(with: Data(attempt.text.utf8))
        guard let dictionary = object as? [String: Any] else {
          lastError = "в блоке не JSON-объект"
          continue
        }
        if let repair = attempt.repair {
          warnings.append("блок meeting-followup разобран после починки (\(repair))")
        }
        return dictionary
      } catch {
        lastError = describe(error)
      }
    }
    warnings.append("блок meeting-followup не разобран: \(lastError)")
    return nil
  }

  private static func describe(_ error: any Error) -> String {
    let error = error as NSError
    if let debug = error.userInfo["NSDebugDescription"] as? String { return debug }
    return error.localizedDescription
  }

  /// Снимает фенсы, в которые модель дополнительно завернула JSON (```json … ```).
  private static func strippingNestedFences(_ text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    func isFence(_ line: String) -> Bool {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let marker = trimmed.first, marker == "`" || marker == "~" else { return false }
      return trimmed.prefix { $0 == marker }.count >= 3
    }
    while let first = lines.first,
      first.trimmingCharacters(in: .whitespaces).isEmpty || isFence(first)
    {
      lines.removeFirst()
    }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || isFence(last)
    {
      lines.removeLast()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Убирает запятые перед `]` и `}` вне строк (частая ошибка генерации).
  private static func removingTrailingCommas(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    let characters = Array(text)
    var index = 0
    var inString = false
    var escaped = false
    while index < characters.count {
      let character = characters[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else if character == "\"" {
        inString = true
      } else if character == "," {
        var lookahead = index + 1
        while lookahead < characters.count, characters[lookahead].isWhitespace { lookahead += 1 }
        if lookahead < characters.count,
          characters[lookahead] == "]" || characters[lookahead] == "}"
        {
          index += 1
          continue
        }
      }
      result.append(contentsOf: character.unicodeScalars)
      index += 1
    }
    return String(result)
  }

  /// Оставляет текст от первой `{` до последней `}` — отрезает пояснения модели вокруг JSON.
  private static func braceSlice(_ text: String) -> String {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
    else { return text }
    return String(text[start...end])
  }

  /// Типографские кавычки: “ ” „ ‟ и «ёлочки» « » — их подставляет автозамена macOS при наборе в
  /// русской и украинской раскладках, и так же приходит текст, прошедший через Notes или почту.
  private static func replacingSmartQuotes(_ text: String) -> String {
    var result = text
    for quote in ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00AB}", "\u{00BB}"] {
      result = result.replacingOccurrences(of: quote, with: "\"")
    }
    return result
  }

  // MARK: - Поля JSON

  private static func fromJSON(_ object: [String: Any], warnings: [String]) -> ParsedFollowup {
    let fields = normalizedKeys(object)
    let decisions = array(fields, ["decisions", "решения", "рішення"]).compactMap(decision(from:))
    let actions = array(
      fields, ["actions", "actionitems", "tasks", "todos", "задачи", "завдання"]
    ).compactMap(action(from:))
    let questions = array(
      fields, ["questions", "openquestions", "вопросы", "питання"]
    ).compactMap(question(from:))
    let summary = singleLine(string(value(fields, ["summary", "резюме", "итоги", "підсумок"])))
    return ParsedFollowup(
      method: .jsonBlock,
      decisions: unique(decisions),
      actions: unique(actions),
      questions: unique(questions),
      summary: summary,
      warnings: warnings)
  }

  /// Ключи приводятся к нижнему регистру без `_`, `-` и пробелов: `action_items` == `actionItems`.
  private static func normalizedKeys(_ object: [String: Any]) -> [String: Any] {
    Dictionary(
      object.map { key, value in (normalizedKey(key), value) },
      uniquingKeysWith: { first, _ in
        first
      })
  }

  private static func normalizedKey(_ key: String) -> String {
    key.lowercased().filter { $0 != "_" && $0 != "-" && !$0.isWhitespace }
  }

  private static func value(_ fields: [String: Any], _ keys: [String]) -> Any? {
    for key in keys {
      if let value = fields[key], !(value is NSNull) { return value }
    }
    return nil
  }

  private static func array(_ fields: [String: Any], _ keys: [String]) -> [Any] {
    value(fields, keys) as? [Any] ?? []
  }

  private static func decision(from item: Any) -> ParsedFollowup.Decision? {
    if let text = singleLine(string(item)) { return ParsedFollowup.Decision(text: text) }
    guard let object = item as? [String: Any] else { return nil }
    let fields = normalizedKeys(object)
    guard
      let text = singleLine(
        string(value(fields, ["text", "decision", "title", "description", "решение", "рішення"])))
    else { return nil }
    let stamp = timecode(from: value(fields, ["timestamp", "timecode", "time", "at", "таймкод"]))
    return ParsedFollowup.Decision(text: text, timestamp: stamp.seconds, timestampText: stamp.text)
  }

  private static func action(from item: Any) -> ParsedFollowup.Action? {
    if let text = singleLine(string(item)) { return ParsedFollowup.Action(text: text) }
    guard let object = item as? [String: Any] else { return nil }
    let fields = normalizedKeys(object)
    guard
      let text = singleLine(
        string(
          value(fields, ["text", "task", "action", "title", "description", "item", "задача"])))
    else { return nil }
    let owner = singleLine(
      string(value(fields, ["owner", "assignee", "responsible", "who", "ответственный"])))
    let deadline = self.deadline(
      from: string(value(fields, ["due", "duedate", "deadline", "date", "срок", "термін"])))
    return ParsedFollowup.Action(
      text: text, owner: owner, due: deadline.iso, dueText: deadline.text)
  }

  private static func question(from item: Any) -> ParsedFollowup.Question? {
    if let text = singleLine(string(item)) { return ParsedFollowup.Question(text: text) }
    guard let object = item as? [String: Any] else { return nil }
    let fields = normalizedKeys(object)
    guard
      let text = singleLine(
        string(value(fields, ["text", "question", "title", "вопрос", "питання"])))
    else { return nil }
    return ParsedFollowup.Question(text: text)
  }

  /// Строка поля: `null`, числа и пустые строки — это `nil`.
  private static func string(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Таймкод строкой («[00:41:12]», «41:12») или числом секунд.
  private static func timecode(from value: Any?) -> (seconds: Double?, text: String?) {
    if let text = string(value) { return (Timecode.seconds(from: text), text) }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      let seconds = number.doubleValue
      return seconds >= 0 ? (seconds, nil) : (nil, nil)
    }
    return (nil, nil)
  }

  /// Срок: `YYYY-MM-DD`, `DD.MM.YYYY`, `DD/MM/YYYY` (и `YYYY/MM/DD`) — в ISO-день, иначе сырой текст.
  static func deadline(from value: String?) -> (iso: String?, text: String?) {
    guard let value = singleLine(value) else { return (nil, nil) }
    if let iso = isoDay(from: value) { return (iso, nil) }
    return (nil, value)
  }

  static func isoDay(from text: String) -> String? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let yearFirst = #/^(\d{4})[-./](\d{1,2})[-./](\d{1,2})(?:[T ].*)?$/#
    let dayFirst = #/^(\d{1,2})[./](\d{1,2})[./](\d{4})(?:[T ].*)?$/#
    if let match = text.wholeMatch(of: yearFirst) {
      return day(year: match.1, month: match.2, day: match.3)
    }
    if let match = text.wholeMatch(of: dayFirst) {
      return day(year: match.3, month: match.2, day: match.1)
    }
    return nil
  }

  private static func day(year: Substring, month: Substring, day: Substring) -> String? {
    guard let year = Int(year), let month = Int(month), let day = Int(day),
      (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  // MARK: - Секции Markdown

  private enum Section: Hashable {
    case decisions, actions, questions, summary
  }

  /// Fallback: заголовки `#…`, `**…**` или строка с двоеточием; пункты `-`, `*`, `•`, `1.`, `- [ ]`.
  private static func fromMarkdown(_ text: String) -> ParsedFollowup {
    var items: [Section: [String]] = [:]
    var section: Section?
    var sawSection = false
    var openItem = false
    var fence: Character?

    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let marker = fence {
        if isClosingFence(trimmed, marker: marker) { fence = nil }
        continue
      }
      if let marker = trimmed.first, marker == "`" || marker == "~",
        trimmed.prefix(while: { $0 == marker }).count >= 3
      {
        fence = marker
        openItem = false
        continue
      }
      if trimmed.isEmpty {
        openItem = false
        continue
      }
      if let title = headingTitle(trimmed) {
        section = self.section(of: title)
        sawSection = sawSection || section != nil
        openItem = false
        continue
      }
      if trimmed.hasSuffix(":"), trimmed.count <= 80,
        let matched = self.section(of: String(trimmed.dropLast()))
      {
        section = matched
        sawSection = true
        openItem = false
        continue
      }
      guard let current = section else { continue }
      if let item = bulletItem(trimmed) {
        if !item.isEmpty {
          items[current, default: []].append(item)
          openItem = true
        }
        continue
      }
      if openItem, var list = items[current], !list.isEmpty {
        list[list.count - 1] += " " + trimmed
        items[current] = list
      } else {
        items[current, default: []].append(trimmed)
        openItem = true
      }
    }

    guard sawSection else { return ParsedFollowup(method: .none) }
    let decisions = (items[.decisions] ?? []).compactMap(markdownDecision(from:))
    let actions = (items[.actions] ?? []).compactMap(markdownAction(from:))
    let questions = (items[.questions] ?? []).compactMap { cleaned($0) }.map(
      ParsedFollowup.Question.init(text:))
    return ParsedFollowup(
      method: .markdownSections,
      decisions: unique(decisions),
      actions: unique(actions),
      questions: unique(questions),
      summary: singleLine((items[.summary] ?? []).joined(separator: " ")))
  }

  /// Заголовок: `## Решения`, `**Decisions**`, `__Задачи__`. Возвращает текст заголовка.
  private static func headingTitle(_ line: String) -> String? {
    if line.hasPrefix("#") {
      let title = line.drop(while: { $0 == "#" })
        .trimmingCharacters(in: .whitespaces)
      return title.isEmpty ? nil : String(title.reversed().drop(while: { $0 == "#" }).reversed())
    }
    if let match = line.wholeMatch(of: #/\*\*(.+?)\*\*:?/#) { return String(match.1) }
    if let match = line.wholeMatch(of: #/__(.+?)__:?/#) { return String(match.1) }
    return nil
  }

  private static let sections: [Section: Set<String>] = [
    .decisions: [
      "решения", "принятые решения", "решения встречи", "decisions", "decisions made",
      "key decisions", "рішення", "прийняті рішення",
    ],
    .actions: [
      "задачи", "задачи и поручения", "поручения", "action items", "actions", "tasks",
      "next steps", "задачі", "завдання", "доручення",
    ],
    .questions: [
      "вопросы", "открытые вопросы", "нерешённые вопросы", "questions", "open questions",
      "питання", "відкриті питання",
    ],
    .summary: [
      "резюме", "резюме встречи", "краткое резюме", "краткое резюме встречи", "итоги", "кратко",
      "summary", "підсумок", "підсумки", "резюме зустрічі",
    ],
  ]

  /// Нормализованное название секции → её вид; чужой заголовок — `nil` (секция закрывается).
  private static func section(of title: String) -> Section? {
    let normalized = normalizedTitle(title)
    guard !normalized.isEmpty else { return nil }
    return sections.first { $0.value.contains(normalized) }?.key
  }

  private static func normalizedTitle(_ title: String) -> String {
    var text = title.trimmingCharacters(in: .whitespaces).lowercased()
    text = text.replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "#", with: "")
    if let match = text.prefixMatch(of: #/\s*\d{1,2}\s*[.)]\s*/#) {
      text = String(text[match.range.upperBound...])
    }
    text = text.trimmingCharacters(in: CharacterSet(charactersIn: " :.—–-"))
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Текст пункта списка (маркер и чекбокс сняты) или `nil`, если строка не пункт.
  private static func bulletItem(_ line: String) -> String? {
    guard let match = line.prefixMatch(of: #/([-*•+–—]|\d{1,3}[.)])\s+/#) else { return nil }
    var text = String(line[match.range.upperBound...])
    if let checkbox = text.prefixMatch(of: #/\[[ xX✓хХ]?\]\s*/#) {
      text = String(text[checkbox.range.upperBound...])
    }
    return text.trimmingCharacters(in: .whitespaces)
  }

  /// Из решения вынимается только таймкод — остальное структура решения не хранит.
  private static func markdownDecision(from item: String) -> ParsedFollowup.Decision? {
    let stamp = extractTimecode(from: item)
    guard let text = cleaned(stamp.text) else { return nil }
    return ParsedFollowup.Decision(
      text: text, timestamp: stamp.seconds, timestampText: stamp.timecode)
  }

  /// Из задачи вынимаются срок и ответственный (именно в таком порядке: срок стоит после имени).
  private static func markdownAction(from item: String) -> ParsedFollowup.Action? {
    let deadline = extractDeadline(from: item)
    // Текст чистится между изъятиями: иначе хвост срока («, до 2026-09-10») попадёт в имя.
    let owner = extractOwner(from: cleaned(deadline.text) ?? "")
    guard let text = cleaned(owner.text) else { return nil }
    return ParsedFollowup.Action(
      text: text, owner: owner.owner, due: deadline.iso, dueText: deadline.dueText)
  }

  /// Первый таймкод пункта: `[00:41:12]`, `(00:41:12)`, `00:41:12` в любом месте и `41:12` в начале —
  /// с удалением из текста.
  ///
  /// `MM:SS` без скобок в середине или конце фразы таймкодом не считается: «Перенесли демо на 15:00»
  /// — это время суток, а не место в записи. Промпт просит `HH:MM:SS` (см. `FollowupPrompt.text`),
  /// поэтому три группы принимаются везде, а две — только в скобках или в самом начале пункта.
  static func extractTimecode(from item: String) -> (
    text: String, seconds: Double?, timecode: String?
  ) {
    let pattern = #/([\[(])?(\d{1,3}:\d{1,2}(?::\d{1,2})?(?:[.,]\d{1,3})?)([\])])?/#
    let start = item.firstIndex { !$0.isWhitespace } ?? item.startIndex
    for match in item.matches(of: pattern) {
      let bracketed = isBracketPair(match.1, match.3)
      let withHours = match.2.filter { $0 == ":" }.count == 2
      guard bracketed || withHours || match.range.lowerBound == start else { continue }
      guard let seconds = Timecode.seconds(from: String(match.2)) else { continue }
      var text = item
      // Непарная скобка рядом — часть текста, а не обрамление: убираем только сам таймкод.
      text.removeSubrange(bracketed ? match.range : match.2.startIndex..<match.2.endIndex)
      return (text, seconds, String(match.2))
    }
    return (item, nil, nil)
  }

  /// Таймкод обрамлён скобками — `[41:12]` или `(41:12)`.
  private static func isBracketPair(_ open: Substring?, _ close: Substring?) -> Bool {
    switch (open?.first, close?.first) {
    case ("[", "]"), ("(", ")"): true
    default: false
    }
  }

  /// Срок: `до 2026-09-10`, `до пятницы`, `срок: …`, `due: …`, `deadline …`. Предлог остаётся
  /// частью сырого текста («до пятницы»), метка-ярлык («срок:») — нет.
  static func extractDeadline(from item: String) -> (
    text: String, iso: String?, dueText: String?
  ) {
    let label =
      #/(?i)(?:^|[\s(,;])(?:сроки|срок|дедлайн|термін|due date|due|deadline)\s*[:—–-]?\s+([^,;)\]\n]+?)(?=\s[—–]\s|[,;)\]]|$)/#
    let preposition = #/(?i)(?:^|[\s(,;])(до|by|until|till)\s+([^,;)\]\n]+?)(?=\s[—–]\s|[,;)\]]|$)/#
    if let match = item.firstMatch(of: label) {
      let value = String(match.1).trimmingCharacters(in: .whitespaces)
      let iso = isoDay(from: value)
      return (remainder(of: item, without: match.range), iso, iso == nil ? value : nil)
    }
    for match in item.matches(of: preposition) {
      let value = String(match.2).trimmingCharacters(in: .whitespaces)
      let iso = isoDay(from: value)
      // Предлог «до» встречается и в обычной речи («довести до конца недели список задач»):
      // без даты срок берётся только коротким хвостом в конце пункта.
      let shortTail =
        match.range.upperBound == item.endIndex
        && value.split(whereSeparator: \.isWhitespace).count <= 3
      guard iso != nil || shortTail else { continue }
      return (
        remainder(of: item, without: match.range), iso,
        iso == nil ? "\(match.1.lowercased()) \(value)" : nil
      )
    }
    return (item, nil, nil)
  }

  /// Пункт без изъятого куска. Если от пункта ничего не осталось («срок: 10 сентября» — весь текст
  /// и есть метка срока), изъятие не состоялось: иначе задача исчезла бы из follow-up целиком.
  private static func remainder(of item: String, without range: Range<String.Index>) -> String {
    var text = item
    text.removeSubrange(range)
    return cleaned(text) == nil ? item : text
  }

  /// Ответственный: `(ответственный: Имя)`, `Ответственный: Имя`, `@Имя` или `— Имя` в конце пункта.
  static func extractOwner(from item: String) -> (text: String, owner: String?) {
    let parenthesised =
      #/(?i)\s*\((?:ответственн\w*|відповідальн\w*|owner|assignee|responsible)\s*[:—–-]?\s*([^)\n]+)\)/#
    let labelled =
      #/(?i)(?:^|[\s(,;])(?:ответственн\w*|відповідальн\w*|owner|assignee|responsible)\s*[:—–-]\s*([^,;)\]\n]+?)(?=\s[—–]\s|[,;)\]]|$)/#
    for pattern in [parenthesised, labelled] {
      if let match = item.firstMatch(of: pattern), let name = name(String(match.1)) {
        var text = item
        text.removeSubrange(match.range)
        return (text, name)
      }
    }
    if let match = item.firstMatch(of: #/@([\w.-]+)/#), let name = name(String(match.1)) {
      var text = item
      text.removeSubrange(match.range)
      return (text, name)
    }
    let trailing = #/\s+[—–-]\s+([^—–\n]+)$/#
    let trimmed = item.trimmingCharacters(in: .whitespaces)
    if let match = trimmed.firstMatch(of: trailing), let name = name(String(match.1)),
      looksLikeName(name)
    {
      var text = trimmed
      text.removeSubrange(match.range)
      return (text, name)
    }
    return (item, nil)
  }

  /// Имя без висящей пунктуации по краям.
  private static func name(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!?—–-"))
    return trimmed.isEmpty ? nil : trimmed
  }

  /// «Спикер 1», «Іван Мінін», «QA-команда» — да; «так решили» — нет.
  private static func looksLikeName(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespaces)
    guard let first = text.first, first.isLetter, first.isUppercase, text.count <= 40 else {
      return false
    }
    return (1...3).contains(text.split(whereSeparator: \.isWhitespace).count)
  }

  // MARK: - Общее

  /// Текст пункта после изъятий: без `**`, лишних пробелов и висящей пунктуации по краям.
  private static func cleaned(_ text: String) -> String? {
    let stripped = text.replacingOccurrences(of: "**", with: "")
    let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-"))
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Текст в одну строку: переносы и повторные пробелы схлопываются.
  private static func singleLine(_ text: String?) -> String? {
    guard let text else { return nil }
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
  }

  /// Точные дубликаты убираются, порядок сохраняется.
  private static func unique<Element: Hashable>(_ items: [Element]) -> [Element] {
    var seen: Set<Element> = []
    return items.filter { seen.insert($0).inserted }
  }
}
