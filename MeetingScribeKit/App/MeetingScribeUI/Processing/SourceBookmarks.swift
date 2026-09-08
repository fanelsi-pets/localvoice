import Foundation
import os

/// Доступ к исходным файлам записи из App Sandbox (SPEC.md §3.1: security-scoped bookmarks). Нужен хосту,
/// который встраивает ядро как функцию и живёт в песочнице (LocalVoice, ADR-010): доступ к перетащенному или
/// выбранному в диалоге элементу действует только до перезапуска, а повторная обработка, сканирование подписей
/// и воспроизведение исходника случаются позже. При импорте на корневой элемент (папку записи или сам файл)
/// создаётся закладка `<библиотека>/bookmarks/<meetingID>.bookmark`; перед операцией она разрешается, и доступ
/// открыт на время операции (`SourceAccess.end()`). Без песочницы (самостоятельный MeetingScribe) закладки
/// создаются так же, а открытие доступа ничего не меняет — операции идут по обычным путям.
public final class SourceBookmarkStore {
  public let directory: URL
  private let fileManager: FileManager
  private let logger = Logger(subsystem: "app.meetingscribe", category: "SourceBookmarks")

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileManager = fileManager
  }

  public func fileURL(for meetingID: UUID) -> URL {
    directory.appending(path: "\(meetingID.uuidString).bookmark")
  }

  public func hasBookmark(for meetingID: UUID) -> Bool {
    fileManager.fileExists(atPath: fileURL(for: meetingID).path(percentEncoded: false))
  }

  /// Сохраняет закладку на `url` для встречи. Ошибки только в журнал: импорт без закладки должен идти —
  /// в текущем запуске доступ к элементу и так есть.
  public func save(_ url: URL, for meetingID: UUID) {
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let data: Data
      do {
        data = try url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      } catch {
        // Вне песочницы закладка с областью безопасности может не создаваться — обычная тоже переживёт
        // перемещение файла.
        data = try url.bookmarkData(
          options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      }
      try data.write(to: fileURL(for: meetingID), options: .atomic)
    } catch {
      logger.error(
        "Закладка для встречи \(meetingID.uuidString, privacy: .public) не сохранилась: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  public func remove(for meetingID: UUID) {
    try? fileManager.removeItem(at: fileURL(for: meetingID))
  }

  /// Открывает доступ по закладке; `nil` — закладки нет или она не разрешилась: операция идёт по обычному
  /// пути и в песочнице получит понятную ошибку доступа к файлу.
  public func access(for meetingID: UUID) -> SourceAccess? {
    guard let data = try? Data(contentsOf: fileURL(for: meetingID)) else { return nil }
    var isStale = false
    let url: URL
    do {
      url = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &isStale)
    } catch {
      logger.error(
        "Закладка для встречи \(meetingID.uuidString, privacy: .public) не разрешилась: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
    // Устаревшую закладку система просит пересоздать — пока доступ есть.
    if isStale { save(url, for: meetingID) }
    return SourceAccess(url: url, isScoped: url.startAccessingSecurityScopedResource())
  }
}

/// Открытый доступ к исходнику записи: `end()` закрывает его; вызывать один раз.
public struct SourceAccess {
  public let url: URL
  /// Доступ действительно открыт системой (в песочнице); иначе закрывать нечего.
  public let isScoped: Bool

  public func end() {
    if isScoped { url.stopAccessingSecurityScopedResource() }
  }
}
