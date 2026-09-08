import Core
import Foundation

extension MeetingInfo {
  /// Сведения о встрече из расположения файла: папка локальной записи Zoom называется
  /// `YYYY-MM-DD HH.MM.SS <название комнаты>` (скилл zoom-import) — оттуда дата и название;
  /// иначе название — имя файла, дата — дата создания файла.
  public static func inferred(from source: URL, fileManager: FileManager = .default) -> MeetingInfo
  {
    let folder = source.deletingLastPathComponent().lastPathComponent
    if let parsed = parseZoomFolderName(folder) {
      return MeetingInfo(title: parsed.title, date: parsed.date)
    }
    let attributes = try? fileManager.attributesOfItem(atPath: source.path(percentEncoded: false))
    let date =
      attributes?[.creationDate] as? Date ?? attributes?[.modificationDate] as? Date
    return MeetingInfo(title: source.deletingPathExtension().lastPathComponent, date: date)
  }

  /// Заполняет пустые поля из `fallback` (явные значения пользователя важнее выведенных).
  public func filling(missingFrom fallback: MeetingInfo) -> MeetingInfo {
    MeetingInfo(
      title: title?.isEmpty == false ? title : fallback.title,
      date: date ?? fallback.date,
      project: project?.isEmpty == false ? project : fallback.project)
  }

  /// `2026-08-14 17.14.57 Anatoliy Rogalskiy's Personal Meeting Room` → дата (локальный часовой пояс) и название.
  static func parseZoomFolderName(_ name: String, timeZone: TimeZone = .current) -> (
    date: Date, title: String
  )? {
    let pattern = #"^(\d{4})-(\d{2})-(\d{2}) (\d{2})\.(\d{2})\.(\d{2}) (.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: name, range: NSRange(name.startIndex..., in: name)),
      match.numberOfRanges == 8
    else { return nil }
    func group(_ index: Int) -> String {
      String(name[Range(match.range(at: index), in: name)!])
    }
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = timeZone
    components.year = Int(group(1))
    components.month = Int(group(2))
    components.day = Int(group(3))
    components.hour = Int(group(4))
    components.minute = Int(group(5))
    components.second = Int(group(6))
    guard components.isValidDate, let date = components.date else { return nil }
    let title = group(7).trimmingCharacters(in: .whitespacesAndNewlines)
    return (date, title.isEmpty ? name : title)
  }
}
