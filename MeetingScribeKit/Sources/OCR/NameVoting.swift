import Core
import Foundation

// Связывание подписей со спикерами диаризации: голосование по перекрытию реплик с отрезками,
// на которых активный спикер известен (SPEC.md §3.4 п. d — «голосование имени по перекрытию»).

public enum NameVoting {
  /// Голосование имени по перекрытию реплик спикера с отрезками активного спикера.
  ///
  /// Для каждого спикера считается доля секунд его реплик, покрытых отрезками с именем X, среди секунд,
  /// покрытых хоть каким-то отрезком: активный спикер виден не на всей записи (speaker view включают
  /// на четверть часа из полутора), и доля от всей речи спикера была бы заведомо мала. Чтобы решение не
  /// строилось на паре секунд, покрытие спикера должно быть не меньше `minimumCoveredSeconds`. Имя с долей
  /// не ниже `minimumShare` становится подсказкой. Одно имя достаётся одному спикеру: конфликты
  /// разбираются жадно по убыванию доли — иначе два спикера получают одно имя и подсказка бесполезна.
  public static func vote(
    spans: [ActiveSpeakerSpan], utterances: [Utterance], minimumShare: Double = 0.6,
    minimumCoveredSeconds: Double = 15
  ) -> [NameHint] {
    let intervals = mergedIntervals(spans)
    guard !intervals.isEmpty else { return [] }

    var bySpeaker: [Int: [Utterance]] = [:]
    for utterance in utterances {
      guard let speakerID = utterance.speakerID, utterance.duration > 0 else { continue }
      bySpeaker[speakerID, default: []].append(utterance)
    }

    struct Candidate {
      let speakerID: Int
      let name: String
      let share: Double
      let count: Int
    }
    var candidates: [Candidate] = []
    let anyRanges =
      mergedIntervals(spans.map { ActiveSpeakerSpan(start: $0.start, end: $0.end, name: "") })[""]
      ?? []
    for (speakerID, speech) in bySpeaker {
      // Знаменатель — только речь спикера под отрезками активного спикера (с любым именем).
      let total = speech.reduce(0.0) { sum, utterance in
        sum
          + anyRanges.reduce(0) {
            $0 + max(0, min($1.end, utterance.end) - max($1.start, utterance.start))
          }
      }
      guard total >= max(minimumCoveredSeconds, 0), total > 0 else { continue }
      for (name, ranges) in intervals {
        var covered = 0.0
        var count = 0
        for utterance in speech {
          let overlap = ranges.reduce(0) {
            $0 + max(0, min($1.end, utterance.end) - max($1.start, utterance.start))
          }
          if overlap > 0 { count += 1 }
          covered += overlap
        }
        let share = min(covered / total, 1)
        guard share >= minimumShare, count > 0 else { continue }
        candidates.append(
          Candidate(speakerID: speakerID, name: name, share: share, count: count))
      }
    }

    var takenSpeakers: Set<Int> = []
    var takenNames: Set<String> = []
    var hints: [NameHint] = []
    for candidate in candidates.sorted(by: {
      ($0.share, $0.count, $1.name) > ($1.share, $1.count, $0.name)
    }) {
      let key = NameMatching.normalized(candidate.name)
      guard !takenSpeakers.contains(candidate.speakerID), !takenNames.contains(key) else {
        continue
      }
      takenSpeakers.insert(candidate.speakerID)
      takenNames.insert(key)
      hints.append(
        NameHint(
          name: candidate.name, source: .ocr, count: candidate.count,
          speakerID: candidate.speakerID, share: candidate.share))
    }
    return hints.sorted { ($0.speakerID ?? .max) < ($1.speakerID ?? .max) }
  }

  /// Подсказки для транскрипта: имена из roster, которые голосование не привязало к спикеру (без
  /// `speakerID` — просто список участников), плюс результаты голосования.
  public static func hints(from report: OCRReport, utterances: [Utterance]) -> [NameHint] {
    let votes = vote(spans: report.spans, utterances: utterances)
    let bound = Set(votes.map { NameMatching.normalized($0.name) })
    let free = report.roster.filter { !bound.contains(NameMatching.normalized($0.name)) }
    return free + votes
  }

  /// Отрезки одного имени, склеенные в непересекающиеся интервалы: иначе перекрытие считается дважды.
  static func mergedIntervals(_ spans: [ActiveSpeakerSpan]) -> [String: [(
    start: Double, end: Double
  )]] {
    var byName: [String: [ActiveSpeakerSpan]] = [:]
    for span in spans where span.duration > 0 {
      byName[span.name, default: []].append(span)
    }
    return byName.mapValues { list in
      var merged: [(start: Double, end: Double)] = []
      for span in list.sorted(by: { $0.start < $1.start }) {
        if var last = merged.last, span.start <= last.end {
          last.end = max(last.end, span.end)
          merged[merged.count - 1] = last
        } else {
          merged.append((span.start, span.end))
        }
      }
      return merged
    }
  }
}
