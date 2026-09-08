import Core
import Foundation

/// JSON-экспорт полной структуры транскрипта (SPEC.md §3.5: «JSON — полная структура со словами и языками»).
public enum TranscriptJSON {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  public static func encode(_ transcript: Transcript) throws -> Data {
    try encoder().encode(transcript)
  }

  public static func decode(_ data: Data) throws -> Transcript {
    try decoder().decode(Transcript.self, from: data)
  }

  public static func write(_ transcript: Transcript, to url: URL) throws {
    try encode(transcript).write(to: url, options: .atomic)
  }
}
