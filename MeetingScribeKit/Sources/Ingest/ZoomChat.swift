import Core
import Foundation

/// Чат встречи из `chat.txt` папки локальной записи Zoom — источник подсказок имён участников
/// (SPEC.md §3.1, §3.4; скилл zoom-import).
///
/// Форматы строк, которые пишет Zoom:
/// - локальный клиент на этой машине (разделитель после времени — таб):
///   `18:14:55\t From Андрей Шепель : Красивая блок схема`;
/// - документированный: `18:14:55 From Ivan Minin to Everyone: текст`
///   и `18:14:55 From Ivan Minin to Анна(Direct Message): текст`.
///
/// Текст сообщения может содержать двоеточия (ссылки, время), поэтому заголовок отделяется по первому
/// двоеточию после `From`. Строки, не начинающиеся с таймкода, — продолжение предыдущего сообщения.
public enum ZoomChat {
  /// Сообщение чата. Дату Zoom в `chat.txt` не пишет, поэтому время хранится как в файле.
  public struct Message: Hashable, Sendable {
    /// Время как в файле, например `18:14:55`.
    public var time: String
    public var author: String
    /// Кому адресовано: `Everyone`, имя участника; `nil` — в строке нет части `to <кому>`.
    public var recipient: String?
    public var text: String

    public init(time: String, author: String, recipient: String? = nil, text: String) {
      self.time = time
      self.author = author
      self.recipient = recipient
      self.text = text
    }
  }

  /// Разбирает содержимое `chat.txt`. Не бросает: строки, которые не удалось разобрать, приклеиваются
  /// к предыдущему сообщению (многострочный чат) либо пропускаются.
  public static func parse(_ text: String) -> [Message] {
    var messages: [Message] = []
    for rawLine in stripBOM(text).split(
      omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    {
      if let (time, rest) = splitTime(rawLine), let header = splitHeader(rest) {
        messages.append(
          Message(
            time: time, author: header.author, recipient: header.recipient, text: header.text))
        continue
      }
      // Строка без заголовка — продолжение многострочного сообщения (Zoom отбивает его табом).
      let continuation = rawLine.trimmingCharacters(in: .whitespaces)
      guard !continuation.isEmpty, !messages.isEmpty else { continue }
      let index = messages.index(before: messages.endIndex)
      messages[index].text +=
        messages[index].text.isEmpty ? continuation : "\n" + continuation
    }
    return messages
  }

  /// Уникальные авторы по убыванию числа сообщений (при равенстве — по первому появлению в файле).
  public static func participantNames(in messages: [Message]) -> [NameHint] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for message in messages {
      let name = message.author.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { continue }
      if counts[name] == nil { order.append(name) }
      counts[name, default: 0] += 1
    }
    return
      order
      .enumerated()
      .sorted { left, right in
        let leftCount = counts[left.element] ?? 0
        let rightCount = counts[right.element] ?? 0
        return leftCount == rightCount ? left.offset < right.offset : leftCount > rightCount
      }
      .map { NameHint(name: $0.element, source: .chat, count: counts[$0.element] ?? 0) }
  }

  /// Читает `chat.txt`: UTF-8, допускаются BOM и переводы строк `\r\n`.
  public static func read(_ url: URL) throws -> [Message] {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        throw IngestError.fileNotFound(url)
      }
      throw IngestError.decodingFailed(url, reason: error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw IngestError.decodingFailed(
        url, reason: String(localized: "файл чата не в кодировке UTF-8"))
    }
    return parse(text)
  }

  // MARK: - Разбор строки

  /// Убирает метку порядка байтов, где бы она ни встретилась (Zoom для Windows пишет её в начале файла).
  private static func stripBOM(_ text: String) -> String {
    guard text.unicodeScalars.contains("\u{FEFF}") else { return text }
    return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{FEFF}" }))
  }

  /// Таймкод `HH:MM:SS` (часы — одна или две цифры) в начале строки и остаток строки после него.
  private static func splitTime(_ line: Substring) -> (time: String, rest: Substring)? {
    var index = line.startIndex
    var parts: [Substring] = []
    for part in 0..<3 {
      if part > 0 {
        guard index < line.endIndex, line[index] == ":" else { return nil }
        index = line.index(after: index)
      }
      let start = index
      while index < line.endIndex, line[index].isASCII, line[index].isNumber {
        index = line.index(after: index)
      }
      let count = line.distance(from: start, to: index)
      guard count == 2 || (part == 0 && count == 1) else { return nil }
      parts.append(line[start..<index])
    }
    return (parts.joined(separator: ":"), line[index...])
  }

  /// `\t From Андрей Шепель : текст` или ` From Ivan to Everyone: текст` → автор, кому, текст.
  private static func splitHeader(_ rest: Substring) -> (
    author: String, recipient: String?, text: String
  )? {
    var body = rest.drop { $0 == "\t" || $0 == " " }
    guard body.prefix(5).lowercased() == "from " else { return nil }
    body = body.dropFirst(5)
    // Двоеточия внутри текста не мешают: заголовок кончается на первом двоеточии после `From`.
    guard let colon = body.firstIndex(of: ":") else { return nil }
    let header = body[..<colon].trimmingCharacters(in: .whitespaces)
    let text = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    guard !header.isEmpty else { return nil }

    // Адресат — в конце заголовка, поэтому ищем ` to ` с конца: имя может содержать « to ».
    if let separator = header.range(of: " to ", options: .backwards) {
      let author = String(header[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
      let recipient = stripDeliveryMark(String(header[separator.upperBound...]))
      if !author.isEmpty, !recipient.isEmpty {
        return (author, recipient, text)
      }
    }
    return (header, nil, text)
  }

  /// `Анна(Direct Message)` → `Анна`: пометка о личном сообщении не часть имени.
  private static func stripDeliveryMark(_ recipient: String) -> String {
    var value = recipient.trimmingCharacters(in: .whitespaces)
    for mark in ["(Direct Message)", "(Privately)"] where value.count > mark.count {
      if value.lowercased().hasSuffix(mark.lowercased()) {
        value = String(value.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
      }
    }
    return value
  }
}
