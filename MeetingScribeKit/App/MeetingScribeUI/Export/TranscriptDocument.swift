import SwiftUI
import UniformTypeIdentifiers

/// Формат экспорта (SPEC.md §3.5): Markdown `TranscribeFull`, SRT с именами, JSON полной структуры.
nonisolated public enum ExportFormat: String, CaseIterable, Hashable, Sendable {
  case markdown
  case srt
  case json

  public var title: String {
    switch self {
    case .markdown: "Markdown (TranscribeFull)"
    case .srt: "SRT"
    case .json: "JSON"
    }
  }

  /// Типы файлов: `md` и `srt` не входят в системный список, поэтому берутся по расширению
  /// с откатом на обычный текст.
  public var contentType: UTType {
    switch self {
    case .markdown: UTType(filenameExtension: "md") ?? .plainText
    case .srt: UTType(filenameExtension: "srt") ?? .plainText
    case .json: .json
    }
  }

  public var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .srt: "srt"
    case .json: "json"
    }
  }
}

/// Документ для `.fileExporter`: текст уже отрендерен моделью, документ его только записывает —
/// «Скопировать» и «Сохранить» получают одну и ту же строку (SPEC.md §7 п. 6).
nonisolated public struct TranscriptDocument: FileDocument, Hashable, Sendable {
  public static var readableContentTypes: [UTType] {
    [ExportFormat.markdown.contentType, ExportFormat.srt.contentType, .json, .plainText]
  }

  public var text: String
  public var contentType: UTType

  public init(text: String, contentType: UTType) {
    self.text = text
    self.contentType = contentType
  }

  public init(text: String, format: ExportFormat) {
    self.init(text: text, contentType: format.contentType)
  }

  public init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents,
      let text = String(data: data, encoding: .utf8)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.text = text
    self.contentType = configuration.contentType
  }

  /// Содержимое файла — то же, что уходит в буфер обмена.
  public var data: Data { Data(text.utf8) }

  public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
