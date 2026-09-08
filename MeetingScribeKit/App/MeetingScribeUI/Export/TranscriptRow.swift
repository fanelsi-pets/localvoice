import Core
import Foundation
import SwiftUI

/// Строка списка транскрипта: готовое значение для `List` — вью не считает имена, цвета и подсветку сама.
/// Пересчитывается при смене транскрипта, поиска или фильтра, но не на тиках прогресса.
nonisolated public struct TranscriptRow: Identifiable, Hashable, Sendable {
  /// Индекс реплики в транскрипте: устойчив при фильтрации и нужен для правки текста.
  public var id: Int
  /// Позиция в показанном списке — идентификатор доступности `transcript.row.<position>`.
  public var position: Int
  public var start: Double
  public var end: Double
  public var speakerID: Int?
  public var speakerName: String
  /// Индекс в `SpeakerPalette`; `nil` — спикер не определён.
  public var paletteIndex: Int?
  public var text: String
  public var language: Language?
  public var overlapped: Bool
  /// Найденные вхождения поискового запроса — для подсветки.
  public var matchRanges: [Range<String.Index>]

  public init(
    id: Int,
    position: Int,
    start: Double,
    end: Double,
    speakerID: Int?,
    speakerName: String,
    paletteIndex: Int?,
    text: String,
    language: Language?,
    overlapped: Bool,
    matchRanges: [Range<String.Index>] = []
  ) {
    self.id = id
    self.position = position
    self.start = start
    self.end = end
    self.speakerID = speakerID
    self.speakerName = speakerName
    self.paletteIndex = paletteIndex
    self.text = text
    self.language = language
    self.overlapped = overlapped
    self.matchRanges = matchRanges
  }

  public var color: Color { SpeakerPalette.color(paletteIndex: paletteIndex) }

  /// Текст с подсветкой найденного: жирный акцентный цвет на вхождениях запроса.
  public var highlightedText: AttributedString {
    var attributed = AttributedString(text)
    guard !matchRanges.isEmpty else { return attributed }
    for range in matchRanges {
      guard let bounds = Range(range, in: attributed) else { continue }
      attributed[bounds].font = .body.bold()
      attributed[bounds].foregroundColor = .accentColor
    }
    return attributed
  }
}

extension TranscriptRow {
  /// Строит строки транскрипта: имена и цвета спикеров, фильтр по спикеру и поиск с диапазонами вхождений.
  /// Поиск нечувствителен к регистру и диакритике (украинская «і» и «ї» ищутся как есть).
  public static func rows(
    from transcript: Transcript, search: String = "", speakerFilter: Int? = nil
  ) -> [TranscriptRow] {
    let names = Dictionary(
      transcript.speakers.map { ($0.speakerID, $0.displayName) },
      uniquingKeysWith: { first, _ in
        first
      })
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    var rows: [TranscriptRow] = []
    rows.reserveCapacity(transcript.utterances.count)
    for (index, utterance) in transcript.utterances.enumerated() {
      if let speakerFilter, utterance.speakerID != speakerFilter { continue }
      let matches = query.isEmpty ? [] : occurrences(of: query, in: utterance.text)
      if !query.isEmpty, matches.isEmpty { continue }
      rows.append(
        TranscriptRow(
          id: index,
          position: rows.count,
          start: utterance.start,
          end: utterance.end,
          speakerID: utterance.speakerID,
          speakerName: names[utterance.speakerID]
            ?? SpeakerStats.placeholderName(for: utterance.speakerID),
          paletteIndex: SpeakerPalette.index(for: utterance.speakerID),
          text: utterance.text,
          language: utterance.language,
          overlapped: utterance.overlapped,
          matchRanges: matches))
    }
    return rows
  }

  static func occurrences(of query: String, in text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
      let range = text.range(
        of: query, options: [.caseInsensitive, .diacriticInsensitive],
        range: searchStart..<text.endIndex)
    {
      ranges.append(range)
      searchStart =
        range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
    }
    return ranges
  }
}
