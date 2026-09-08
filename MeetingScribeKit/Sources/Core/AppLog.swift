import Foundation
import OSLog

/// Журнал приложения через унифицированный лог системы: по подсистеме отчёт о проблеме собирает
/// последние записи без аудио и текста реплик (SPEC.md §3.8 — «лог без аудио»). Правило: в журнал
/// не попадают ни текст распознанного, ни имена людей — только стадии, длительности, ошибки и размеры.
public enum AppLog {
  public static let subsystem = "app.meetingscribe.MeetingScribe"

  public static let app = Logger(subsystem: subsystem, category: "app")
  public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
  public static let download = Logger(subsystem: subsystem, category: "download")
  public static let store = Logger(subsystem: subsystem, category: "store")
  public static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")

  /// Одна запись журнала в отчёте.
  public struct Entry: Hashable, Sendable, Codable {
    public var date: Date
    public var category: String
    public var level: String
    public var message: String

    public init(date: Date, category: String, level: String, message: String) {
      self.date = date
      self.category = category
      self.level = level
      self.message = message
    }
  }

  /// Последние записи текущего процесса по подсистеме приложения. Доступно без прав: хранилище
  /// открывается в области текущего процесса.
  public static func recentEntries(since interval: TimeInterval = 3600, limit: Int = 500) throws
    -> [Entry]
  {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let position = store.position(date: Date().addingTimeInterval(-interval))
    let predicate = NSPredicate(format: "subsystem == %@", subsystem)
    let entries = try store.getEntries(at: position, matching: predicate)
    var result: [Entry] = []
    for case let entry as OSLogEntryLog in entries {
      result.append(
        Entry(
          date: entry.date,
          category: entry.category,
          level: Self.name(entry.level),
          message: entry.composedMessage))
    }
    return Array(result.suffix(limit))
  }

  private static func name(_ level: OSLogEntryLog.Level) -> String {
    switch level {
    case .debug: "debug"
    case .info: "info"
    case .notice: "notice"
    case .error: "error"
    case .fault: "fault"
    case .undefined: "undefined"
    @unknown default: "unknown"
    }
  }
}
