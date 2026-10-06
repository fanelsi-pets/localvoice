import SwiftUI

/// Follow-up как документ: заголовки, списки, таблицы и абзацы Markdown вместо сырого текста.
/// Разбор построчный и намеренно простой — ровно то, что пишет модель по инструкции follow-up;
/// внутри строк работают жирный, курсив, код и ссылки (`AttributedString(markdown:)`).
struct MarkdownDocumentView: View {
  let markdown: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      inline(text)
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 6 : 2)
        .fixedSize(horizontal: false, vertical: true)
    case .paragraph(let text):
      inline(text)
        .fixedSize(horizontal: false, vertical: true)
    case .item(let marker, let indent, let text):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(marker)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        inline(text)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(indent) * 16)
    case .table(let header, let rows):
      table(header: header, rows: rows)
    case .rule:
      Divider()
    case .code(let text):
      Text(text)
        .font(.callout.monospaced())
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
  }

  /// Таблица задач: колонки делят ширину, длинный текст переносится внутри ячейки, а не раздвигает
  /// документ.
  private func table(header: [String], rows: [[String]]) -> some View {
    let columns = max(header.count, rows.map(\.count).max() ?? 0)
    return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
      GridRow {
        ForEach(0..<columns, id: \.self) { column in
          inline(header[safe: column] ?? "")
            .font(.callout.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(0..<columns, id: \.self) { column in
            inline(row[safe: column] ?? "")
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }

  private func inline(_ text: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    let attributed = (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)
    return Text(attributed)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title2.weight(.semibold)
    case 2: .title3.weight(.semibold)
    default: .headline
    }
  }
}

/// Блок Markdown, который умеет показать `MarkdownDocumentView`.
enum MarkdownBlock: Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  /// Пункт списка: маркер («•» или «3.»), уровень вложенности, текст.
  case item(marker: String, indent: Int, text: String)
  case table(header: [String], rows: [[String]])
  case rule
  case code(String)

  static func parse(_ markdown: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var table: [[String]] = []
    var code: [String]?

    func flushParagraph() {
      guard !paragraph.isEmpty else { return }
      blocks.append(.paragraph(paragraph.joined(separator: " ")))
      paragraph = []
    }
    func flushTable() {
      guard !table.isEmpty else { return }
      blocks.append(.table(header: table[0], rows: Array(table.dropFirst())))
      table = []
    }

    for rawLine in markdown.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") {
        if let lines = code {
          blocks.append(.code(lines.joined(separator: "\n")))
          code = nil
        } else {
          flushParagraph()
          flushTable()
          code = []
        }
        continue
      }
      if code != nil {
        code?.append(rawLine)
        continue
      }
      if line.hasPrefix("|") {
        flushParagraph()
        let cells = tableCells(line)
        // Строка-разделитель `|---|:---:|` задаёт выравнивание — показывать её нечего.
        if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) {
          table.append(cells)
        }
        continue
      }
      flushTable()
      if line.isEmpty {
        flushParagraph()
        continue
      }
      if let heading = heading(line) {
        flushParagraph()
        blocks.append(heading)
      } else if line == "---" || line == "***" || line == "___" {
        flushParagraph()
        blocks.append(.rule)
      } else if let item = item(rawLine) {
        flushParagraph()
        blocks.append(item)
      } else {
        paragraph.append(line)
      }
    }
    if let code { blocks.append(.code(code.joined(separator: "\n"))) }
    flushParagraph()
    flushTable()
    return blocks
  }

  private static func heading(_ line: String) -> MarkdownBlock? {
    let level = line.prefix { $0 == "#" }.count
    guard (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") else { return nil }
    return .heading(level: level, text: line.dropFirst(level).trimmingCharacters(in: .whitespaces))
  }

  private static func item(_ rawLine: String) -> MarkdownBlock? {
    let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count / 2
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) {
      return .item(marker: "•", indent: indent, text: String(line.dropFirst(bullet.count)))
    }
    let digits = line.prefix { $0.isNumber }
    guard !digits.isEmpty, digits.count <= 3 else { return nil }
    let rest = line.dropFirst(digits.count)
    guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
    return .item(marker: "\(digits).", indent: indent, text: String(rest.dropFirst(2)))
  }

  private static func tableCells(_ line: String) -> [String] {
    var body = line
    if body.hasPrefix("|") { body.removeFirst() }
    if body.hasSuffix("|") { body.removeLast() }
    return body.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
