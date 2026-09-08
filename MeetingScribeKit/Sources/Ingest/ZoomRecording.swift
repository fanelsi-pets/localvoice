import Core
import Foundation

/// Папка локальной записи Zoom (скилл zoom-import): общий трек `audio*.m4a`, видео `video*.mp4`,
/// `recording.conf`, `chat.txt` и подпапка `Audio Record/` с раздельными дорожками участников
/// (SPEC.md §2 п. 7, §3.1). Структура только читает файловую систему: в `~/Documents/Zoom` ничего
/// не создаётся и не изменяется.
public struct ZoomRecording: Hashable, Sendable {
  /// Раздельная дорожка участника: `Audio Record/audio<Имя><цифры>.m4a`.
  public struct Track: Hashable, Sendable {
    public var url: URL
    /// Имя участника из имени файла, сверенное с подсказками (`chat.txt`); `nil` — не разобрано.
    public var participantName: String?
    /// Сырая часть имени файла между `audio` и хвостовыми цифрами.
    public var rawName: String

    public init(url: URL, participantName: String?, rawName: String) {
      self.url = url
      self.participantName = participantName
      self.rawName = rawName
    }
  }

  public var folder: URL
  /// Общий трек `audio*.m4a` (из `recording.conf`, иначе первый по алфавиту по маске).
  public var audioURL: URL?
  /// Видео `video*.mp4` — нужно для распознавания подписей (OCR, SPEC.md §3.4).
  public var videoURL: URL?
  public var chatURL: URL?
  /// Дорожки из `Audio Record/`, отсортированные по имени файла.
  public var tracks: [Track]
  /// Название и дата встречи из имени папки.
  public var meetingInfo: MeetingInfo

  public init(
    folder: URL,
    audioURL: URL? = nil,
    videoURL: URL? = nil,
    chatURL: URL? = nil,
    tracks: [Track] = [],
    meetingInfo: MeetingInfo = MeetingInfo()
  ) {
    self.folder = folder
    self.audioURL = audioURL
    self.videoURL = videoURL
    self.chatURL = chatURL
    self.tracks = tracks
    self.meetingInfo = meetingInfo
  }

  /// Есть раздельные дорожки — режим multi-track: ASR по дорожкам, диаризация не нужна.
  public var hasSeparateTracks: Bool { !tracks.isEmpty }

  /// Находит запись по папке или по любому файлу внутри неё (в том числе внутри `Audio Record/`).
  /// `nil` — путь не существует или не похож на запись Zoom: нет `recording.conf` и нет
  /// `audio*.m4a`/`video*.mp4`.
  public static func locate(_ url: URL, fileManager: FileManager = .default) -> ZoomRecording? {
    guard let folder = folder(for: url, fileManager: fileManager) else { return nil }
    let names = fileNames(in: folder, fileManager: fileManager)

    let confName = names.first { $0.caseInsensitiveCompare(confFileName) == .orderedSame }
    let items = confName.map { readConf(folder.appending(path: $0)) } ?? []
    // Пустой или битый `recording.conf` не должен ронять разбор — тогда работают маски имён.
    let audioURL =
      firstExisting(items.compactMap(\.audio), in: folder, fileManager: fileManager)
      ?? first(names, prefix: "audio", extension: "m4a").map { folder.appending(path: $0) }
    let videoURL =
      firstExisting(items.compactMap(\.video), in: folder, fileManager: fileManager)
      ?? first(names, prefix: "video", extension: "mp4").map { folder.appending(path: $0) }
    guard confName != nil || audioURL != nil || videoURL != nil else { return nil }

    let chatURL =
      names
      .first { $0.caseInsensitiveCompare(chatFileName) == .orderedSame }
      .map { folder.appending(path: $0) }
    let chatNames =
      chatURL
      .flatMap { try? ZoomChat.read($0) }
      .map { ZoomChat.participantNames(in: $0).map(\.name) } ?? []

    return ZoomRecording(
      folder: folder,
      audioURL: audioURL,
      videoURL: videoURL,
      chatURL: chatURL,
      tracks: tracks(in: folder, hints: chatNames, fileManager: fileManager),
      meetingInfo: meetingInfo(folder: folder, fileManager: fileManager))
  }

  /// Подсказки имён: сначала дорожки (`.track`, `speakerID` — номер дорожки с 1), затем авторы
  /// `chat.txt` (`.chat`, `count` — число сообщений, по убыванию). Имена из разных источников не
  /// схлопываются: источник виден в инспекторе спикеров (SPEC.md §3.4).
  public func nameHints() -> [NameHint] {
    var hints: [NameHint] = tracks.enumerated().compactMap { index, track in
      guard let name = track.participantName else { return nil }
      return NameHint(name: name, source: .track, speakerID: index + 1)
    }
    if let chatURL, let messages = try? ZoomChat.read(chatURL) {
      hints += ZoomChat.participantNames(in: messages)
    }
    return hints
  }

  // MARK: - Файлы папки записи

  private static let confFileName = "recording.conf"
  private static let chatFileName = "chat.txt"
  private static let tracksFolderName = "Audio Record"

  /// `recording.conf`: `{"magic_number":"…","items":[{"process":100,"audio":"…","video":"…"}]}`.
  private struct RecordingConf: Decodable {
    struct Item: Decodable {
      var audio: String?
      var video: String?
    }
    var items: [Item]?
  }

  /// Папка записи для произвольного пути: сама папка, папка файла или родитель `Audio Record/`.
  private static func folder(for url: URL, fileManager: FileManager) -> URL? {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
    else { return nil }
    var folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    if folder.lastPathComponent.caseInsensitiveCompare(tracksFolderName) == .orderedSame {
      folder = folder.deletingLastPathComponent()
    }
    return folder.standardizedFileURL
  }

  /// Имена файлов (без подпапок) в алфавитном порядке.
  private static func fileNames(in folder: URL, fileManager: FileManager) -> [String] {
    contents(of: folder, fileManager: fileManager)
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
      .map(\.lastPathComponent)
      .sorted()
  }

  private static func contents(of folder: URL, fileManager: FileManager) -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
      ?? []
  }

  private static func readConf(_ url: URL) -> [RecordingConf.Item] {
    guard let data = try? Data(contentsOf: url),
      let conf = try? JSONDecoder().decode(RecordingConf.self, from: data)
    else { return [] }
    return conf.items ?? []
  }

  /// Первый из перечисленных в `recording.conf` файлов, который действительно лежит в папке.
  private static func firstExisting(
    _ names: [String], in folder: URL, fileManager: FileManager
  ) -> URL? {
    for name in names where !name.isEmpty {
      let url = folder.appending(path: name)
      if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
    }
    return nil
  }

  private static func first(_ names: [String], prefix: String, extension ext: String) -> String? {
    names.first {
      $0.lowercased().hasPrefix(prefix) && ($0 as NSString).pathExtension.lowercased() == ext
    }
  }

  private static func tracks(in folder: URL, hints: [String], fileManager: FileManager) -> [Track] {
    let subfolders = contents(of: folder, fileManager: fileManager)
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    guard
      let directory = subfolders.first(where: {
        $0.lastPathComponent.caseInsensitiveCompare(tracksFolderName) == .orderedSame
      })
    else { return [] }
    return
      fileNames(in: directory, fileManager: fileManager)
      .filter {
        $0.lowercased().hasPrefix("audio") && ($0 as NSString).pathExtension.lowercased() == "m4a"
      }
      .map { name in
        Track(
          url: directory.appending(path: name),
          participantName: ZoomTrackName.participantName(fromFileName: name, hints: hints),
          rawName: ZoomTrackName.rawName(fromFileName: name) ?? "")
      }
  }

  /// Имя папки Zoom (`YYYY-MM-DD HH.MM.SS Название`) даёт дату и название встречи; папка с другим
  /// именем — название по имени папки, дата по её атрибутам.
  private static func meetingInfo(folder: URL, fileManager: FileManager) -> MeetingInfo {
    if let parsed = MeetingInfo.parseZoomFolderName(folder.lastPathComponent) {
      return MeetingInfo(title: parsed.title, date: parsed.date)
    }
    let attributes = try? fileManager.attributesOfItem(atPath: folder.path(percentEncoded: false))
    let date = attributes?[.creationDate] as? Date ?? attributes?[.modificationDate] as? Date
    return MeetingInfo(title: folder.lastPathComponent, date: date)
  }
}

/// Имя участника из имени файла раздельной дорожки Zoom: `audio<Имя><случайные цифры>.m4a`
/// (пример из документации Zoom — `audioJohnSmith98796876.m4a`; пробелы в имени удалены).
public enum ZoomTrackName {
  /// `audioIvanMinin98796876.m4a` → `Ivan Minin`, `audioАндрейШепель123.m4a` → `Андрей Шепель`,
  /// `audioLana555.m4a` → `Lana`. Если среди `hints` (имена из `chat.txt`, известные люди) есть имя,
  /// совпадающее без пробелов, регистра и диакритики, возвращается подсказка в её написании.
  /// `nil` — файл не по маске (нет префикса `audio`) или имя пустое (общий трек `audio<цифры>.m4a`).
  public static func participantName(fromFileName name: String, hints: [String] = []) -> String? {
    guard let raw = rawName(fromFileName: name) else { return nil }
    if let hint = matchingHint(for: raw, in: hints) { return hint }
    let words = splitWords(raw)
    return words.isEmpty ? nil : words
  }

  /// Часть имени файла между `audio` и хвостовыми цифрами; `nil` — маска не совпала или имя пустое.
  public static func rawName(fromFileName name: String) -> String? {
    let base = (name as NSString).deletingPathExtension
    guard base.lowercased().hasPrefix("audio") else { return nil }
    var rest = Substring(base.dropFirst("audio".count))
    while let last = rest.last, last.isNumber { rest = rest.dropLast() }
    // Хвост вида `Ivan_123` оставляет разделитель — он не часть имени.
    while let last = rest.last, last == "_" || last == "-" || last == "." || last.isWhitespace {
      rest = rest.dropLast()
    }
    let trimmed = rest.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Подсказка, совпадающая с именем из файла без пробелов, регистра и диакритики; второй проход —
  /// без знаков препинания, потому что Zoom удаляет из имени файла пробелы, но может оставить дефис.
  private static func matchingHint(for raw: String, in hints: [String]) -> String? {
    let candidates =
      hints
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !candidates.isEmpty else { return nil }
    let strict = folded(raw, dropPunctuation: false)
    if !strict.isEmpty,
      let hit = candidates.first(where: { folded($0, dropPunctuation: false) == strict })
    {
      return hit
    }
    let loose = folded(raw, dropPunctuation: true)
    guard !loose.isEmpty else { return nil }
    return candidates.first { folded($0, dropPunctuation: true) == loose }
  }

  private static func folded(_ value: String, dropPunctuation: Bool) -> String {
    let normalized = value.folding(
      options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    return String(
      String.UnicodeScalarView(
        normalized.unicodeScalars.filter { scalar in
          if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
          if dropPunctuation,
            CharacterSet.punctuationCharacters.contains(scalar)
              || CharacterSet.symbols.contains(scalar)
          {
            return false
          }
          return true
        }))
  }

  /// Слова слитного имени: заглавная после строчной или цифры (`IvanMinin`), заглавная перед строчной
  /// в цепочке заглавных (`JSONParser`), смена алфавита (`AndreyШепель`); `_` — вместо пробела.
  static func splitWords(_ raw: String) -> String {
    let characters = Array(raw)
    var result = ""
    for (index, character) in characters.enumerated() {
      if character == "_" {
        result.append(" ")
        continue
      }
      if index > 0 {
        let previous = characters[index - 1]
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        let startsWord =
          (character.isUppercase && (previous.isLowercase || previous.isNumber))
          || (character.isUppercase && previous.isUppercase && next?.isLowercase == true)
          || (character.isLetter && previous.isLetter
            && isCyrillic(character) != isCyrillic(previous))
        if startsWord, result.last?.isWhitespace == false { result.append(" ") }
      }
      result.append(character)
    }
    return result.split(separator: " ").joined(separator: " ")
  }

  private static func isCyrillic(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first else { return false }
    return (0x0400...0x052F).contains(scalar.value)
  }
}
