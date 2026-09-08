import Foundation

/// Язык речи. Кодируется как ISO-639-1 код; `other` — любой код вне трёх основных языков проекта.
public enum Language: Hashable, Sendable {
  case ru
  case uk
  case en
  case other(String)
  case unknown

  public init(code: String?) {
    guard
      let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !raw.isEmpty
    else {
      self = .unknown
      return
    }
    switch raw {
    case "ru", "rus", "russian": self = .ru
    case "uk", "ukr", "ukrainian": self = .uk
    case "en", "eng", "english": self = .en
    case "unknown", "und": self = .unknown
    default: self = .other(raw)
    }
  }

  /// ISO-639-1 код (или произвольный код для `other`).
  public var code: String {
    switch self {
    case .ru: "ru"
    case .uk: "uk"
    case .en: "en"
    case .other(let code): code
    case .unknown: "unknown"
    }
  }

  public var isKnown: Bool {
    if case .unknown = self { return false }
    return true
  }
}

extension Language: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(code: try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(code)
  }
}

extension Language: CustomStringConvertible {
  public var description: String { code }
}

/// Выбор языка обработки в интерфейсе: «авто» — язык по каждому спикеру (ADR-003), иначе один язык на файл.
public enum LanguageChoice: String, CaseIterable, Codable, Sendable, Hashable {
  case auto
  case ru
  case uk
  case en

  /// `nil` — язык по каждому спикеру.
  public var language: Language? {
    switch self {
    case .auto: nil
    case .ru: .ru
    case .uk: .uk
    case .en: .en
    }
  }

  public var title: String {
    switch self {
    case .auto: String(localized: "Авто, по каждому спикеру")
    case .ru: String(localized: "Русский")
    case .uk: String(localized: "Українська")
    case .en: "English"
    }
  }
}
