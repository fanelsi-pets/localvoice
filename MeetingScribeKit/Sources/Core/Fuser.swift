import Foundation

/// Сшивка слов и спикеров (SPEC.md §3.3): каждое слово получает спикера по максимальному перекрытию с turn,
/// сегменты ASR делятся на границах смены спикера, реплики короче `mergeShorterThan` приклеиваются к соседним
/// того же спикера, соседние реплики одного спикера и языка собираются в абзац, наложения речи помечаются.
public enum Fuser {
  /// Допуск сравнения таймкодов: «пауза ровно 1 с» не должна зависеть от ошибки Double (2.3 − 1.3 ≠ 1.0).
  private static let timeTolerance = 1e-9

  public struct Options: Hashable, Sendable {
    /// Если слово ни с кем не перекрывается — берём ближайший turn не дальше этого расстояния (с).
    public var maxDistanceToNearestTurn: Double
    /// Доля длительности слова, начиная с которой перекрытие с другим спикером считается наложением речи.
    public var overlapShare: Double
    /// Реплика короче этого (с) приклеивается к соседней того же спикера; 0 и меньше — шаг выключен.
    public var mergeShorterThan: Double
    /// Наибольшая пауза (с) между короткой репликой и соседом, при которой они склеиваются.
    public var maxMergeGap: Double
    /// Наибольшая пауза (с) между соседними репликами одного спикера и языка, при которой они собираются
    /// в один абзац; 0 и меньше — шаг выключен.
    public var joinSameSpeakerGap: Double
    /// Предел длительности (с) собранной реплики: монолог не превращается в один нечитаемый абзац.
    public var maxJoinedDuration: Double

    public init(
      maxDistanceToNearestTurn: Double = 0.5,
      overlapShare: Double = 0.3,
      mergeShorterThan: Double = 0.6,
      maxMergeGap: Double = 1.0,
      joinSameSpeakerGap: Double = 1.0,
      maxJoinedDuration: Double = 45
    ) {
      self.maxDistanceToNearestTurn = maxDistanceToNearestTurn
      self.overlapShare = overlapShare
      self.mergeShorterThan = mergeShorterThan
      self.maxMergeGap = maxMergeGap
      self.joinSameSpeakerGap = joinSameSpeakerGap
      self.maxJoinedDuration = maxJoinedDuration
    }
  }

  public struct Assignment: Hashable, Sendable {
    public var speakerID: Int?
    public var overlapped: Bool

    public init(speakerID: Int?, overlapped: Bool) {
      self.speakerID = speakerID
      self.overlapped = overlapped
    }
  }

  /// Возвращает реплики в порядке времени. Сегменты без слов приписываются целиком и участвуют в склейках
  /// по своим `start`/`end`.
  public static func fuse(segments: [Segment], turns: [Turn], options: Options = Options())
    -> [Utterance]
  {
    let split = splitBySpeaker(segments: segments, turns: turns, options: options)
    let merged = mergeShort(split, options: options)
    return joinAdjacent(merged, options: options)
  }

  /// Склеивает тексты слов: у Whisper слова несут ведущий пробел, у Parakeet — нет.
  public static func joinText(_ words: [Word]) -> String {
    let hasLeadingSpaces = words.contains { $0.text.first?.isWhitespace == true }
    let joined: String
    if hasLeadingSpaces {
      joined = words.map(\.text).joined()
    } else {
      // Слова уже без ведущих пробелов (реплика после сшивки): куски вроде «-то», «.» или «,»
      // у Whisper приходят без пробела и должны прилипать к предыдущему слову — «что-то», а не «что -то».
      joined = words.reduce(into: "") { result, word in
        if !result.isEmpty, !(word.text.first.map(attachedPunctuation.contains) ?? false) {
          result.append(" ")
        }
        result.append(word.text)
      }
    }
    return joined.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Знаки, которые Whisper отдаёт отдельным куском без пробела перед ними.
  private static let attachedPunctuation: Set<Character> = [
    "-", ",", ".", "!", "?", ":", ";", ")", "»", "…",
  ]

  // MARK: - Шаг 1: слово → спикер, деление сегментов на границах смены спикера

  private static func splitBySpeaker(segments: [Segment], turns: [Turn], options: Options)
    -> [Utterance]
  {
    let index = TurnIndex(turns)
    var utterances: [Utterance] = []
    var previousSpeaker: Int?

    for segment in segments.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
      if segment.words.isEmpty {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let assignment = index.assign(
          from: segment.start, to: segment.end, fallback: previousSpeaker, options: options)
        utterances.append(
          Utterance(
            start: segment.start, end: segment.end, speakerID: assignment.speakerID,
            language: segment.language, text: text, words: [], overlapped: assignment.overlapped))
        previousSpeaker = assignment.speakerID ?? previousSpeaker
        continue
      }

      var builder: UtteranceBuilder?
      for word in segment.words.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
        let assignment = index.assign(
          from: word.start, to: word.end, fallback: previousSpeaker, options: options)
        if builder?.speakerID == assignment.speakerID, builder != nil {
          builder?.append(word, overlapped: assignment.overlapped)
        } else {
          if let finished = builder?.build(language: segment.language) {
            utterances.append(finished)
          }
          builder = UtteranceBuilder(
            speakerID: assignment.speakerID, first: word, overlapped: assignment.overlapped)
        }
        previousSpeaker = assignment.speakerID ?? previousSpeaker
      }
      if let finished = builder?.build(language: segment.language) {
        utterances.append(finished)
      }
    }
    // Сегменты могут перекрываться (ASR по кускам спикеров с разными смещениями) — итог сортируется глобально.
    return utterances.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  // MARK: - Шаг 2: короткие реплики приклеиваются к соседним того же спикера

  /// Реплика короче `mergeShorterThan` приклеивается к соседней реплике того же спикера — сначала к предыдущей,
  /// иначе к следующей — если пауза не больше `maxMergeGap`. Соседа нет — реплика остаётся как есть
  /// (SPEC.md §3.3). Склейка со следующей отдаётся дальше по списку, поэтому цепочка осколков схлопывается.
  private static func mergeShort(_ utterances: [Utterance], options: Options) -> [Utterance] {
    guard options.mergeShorterThan > 0, utterances.count > 1 else { return utterances }
    var pending = utterances
    var result: [Utterance] = []
    result.reserveCapacity(pending.count)
    var index = 0

    while index < pending.count {
      let current = pending[index]
      if current.duration < options.mergeShorterThan - timeTolerance {
        if let previous = result.last, gluable(previous, current, gap: options.maxMergeGap) {
          result[result.count - 1] = combineShort(previous, current)
          index += 1
          continue
        }
        if index + 1 < pending.count, gluable(current, pending[index + 1], gap: options.maxMergeGap)
        {
          pending[index + 1] = combineShort(current, pending[index + 1])
          index += 1
          continue
        }
      }
      result.append(current)
      index += 1
    }
    return result
  }

  private static func gluable(_ first: Utterance, _ second: Utterance, gap: Double) -> Bool {
    first.speakerID == second.speakerID && pause(first, second) <= gap + timeTolerance
  }

  /// Пауза между репликами; реплики, наехавшие друг на друга, считаются идущими подряд.
  private static func pause(_ first: Utterance, _ second: Utterance) -> Double {
    max(0, second.start - first.end)
  }

  /// Язык склеенной короткой реплики — язык более длинной части, при равенстве — предыдущей;
  /// если у неё языка нет — язык короткой (страховка для сегментов без языка).
  private static func combineShort(_ first: Utterance, _ second: Utterance) -> Utterance {
    let (longer, shorter) = first.duration >= second.duration ? (first, second) : (second, first)
    return combine(first, second, language: longer.language ?? shorter.language)
  }

  // MARK: - Шаг 3: соседние реплики одного спикера и языка — в один абзац

  /// Подряд идущие реплики одного спикера и одного языка с паузой не больше `joinSameSpeakerGap`
  /// собираются в абзац, пока длительность результата не превышает `maxJoinedDuration`.
  private static func joinAdjacent(_ utterances: [Utterance], options: Options) -> [Utterance] {
    guard options.joinSameSpeakerGap > 0, utterances.count > 1 else { return utterances }
    var result: [Utterance] = []
    result.reserveCapacity(utterances.count)

    for utterance in utterances {
      guard
        let accumulated = result.last,
        accumulated.speakerID == utterance.speakerID,
        accumulated.language == utterance.language,
        pause(accumulated, utterance) <= options.joinSameSpeakerGap + timeTolerance,
        max(accumulated.end, utterance.end) - min(accumulated.start, utterance.start)
          <= options.maxJoinedDuration + timeTolerance
      else {
        result.append(utterance)
        continue
      }
      result[result.count - 1] = combine(accumulated, utterance, language: accumulated.language)
    }
    return result
  }

  // MARK: - Склейка двух реплик

  /// Объединяет две соседние реплики: слова — по времени, границы — по крайним, `overlapped` — OR.
  private static func combine(_ first: Utterance, _ second: Utterance, language: Language?)
    -> Utterance
  {
    let words = (first.words + second.words).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    return Utterance(
      start: min(first.start, second.start),
      end: max(first.end, second.end),
      speakerID: first.speakerID,
      language: language,
      text: combinedText(first, second, words: words),
      words: words,
      overlapped: first.overlapped || second.overlapped)
  }

  /// Текст пересобирается из слов, если он у обеих реплик получен из слов; иначе тексты соединяются пробелом.
  /// Проверка по тексту, а не по наличию слов: у реплики, уже склеенной с сегментом без word timestamps,
  /// слова есть, но текст шире слов — пересборка потеряла бы часть речи.
  private static func combinedText(_ first: Utterance, _ second: Utterance, words: [Word]) -> String
  {
    guard textMatchesWords(first), textMatchesWords(second) else {
      return [first.text, second.text].filter { !$0.isEmpty }.joined(separator: " ")
    }
    return joinText(words)
  }

  private static func textMatchesWords(_ utterance: Utterance) -> Bool {
    !utterance.words.isEmpty && utterance.text == joinText(utterance.words)
  }
}

/// Индекс turn'ов, отсортированных по началу, с префиксным максимумом концов для быстрого поиска кандидатов.
struct TurnIndex {
  let turns: [Turn]
  private let prefixMaxEnd: [Double]

  init(_ turns: [Turn]) {
    self.turns = turns.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    var running = -Double.infinity
    prefixMaxEnd = self.turns.map { turn in
      running = max(running, turn.end)
      return running
    }
  }

  func assign(from start: Double, to end: Double, fallback: Int?, options: Fuser.Options)
    -> Fuser.Assignment
  {
    guard !turns.isEmpty else { return Fuser.Assignment(speakerID: fallback, overlapped: false) }
    let window = max(options.maxDistanceToNearestTurn, 0)
    let duration = max(end - start, 0.05)

    // Первый turn, который может дотянуться до слова: prefixMaxEnd монотонен, поэтому бинарный поиск корректен.
    let threshold = start - window
    var low = 0
    var high = turns.count
    while low < high {
      let middle = (low + high) / 2
      if prefixMaxEnd[middle] < threshold { low = middle + 1 } else { high = middle }
    }

    var overlapBySpeaker: [Int: Double] = [:]
    var nearestDistance = Double.infinity
    var nearestSpeaker: Int?
    var index = low
    while index < turns.count {
      let turn = turns[index]
      if turn.start > end + window { break }
      let overlap = turn.overlap(from: start, to: end)
      if overlap > 0 {
        overlapBySpeaker[turn.speakerID, default: 0] += overlap
      } else {
        let distance = turn.start > end ? turn.start - end : start - turn.end
        if distance < nearestDistance {
          nearestDistance = distance
          nearestSpeaker = turn.speakerID
        }
      }
      index += 1
    }

    if let best = overlapBySpeaker.values.max() {
      let tied = overlapBySpeaker.filter { $0.value >= best - 1e-9 }.map(\.key)
      let chosen: Int
      if let fallback, tied.contains(fallback) {
        chosen = fallback
      } else {
        chosen = tied.min() ?? fallback ?? 0
      }
      let overlapped = overlapBySpeaker.contains { speaker, overlap in
        speaker != chosen && overlap >= options.overlapShare * duration
      }
      return Fuser.Assignment(speakerID: chosen, overlapped: overlapped)
    }
    if let nearestSpeaker, nearestDistance <= window {
      return Fuser.Assignment(speakerID: nearestSpeaker, overlapped: false)
    }
    return Fuser.Assignment(speakerID: fallback, overlapped: false)
  }
}

struct UtteranceBuilder {
  let speakerID: Int?
  private(set) var words: [Word]
  private(set) var overlapped: Bool

  init(speakerID: Int?, first: Word, overlapped: Bool) {
    self.speakerID = speakerID
    self.words = [first]
    self.overlapped = overlapped
  }

  mutating func append(_ word: Word, overlapped: Bool) {
    words.append(word)
    self.overlapped = self.overlapped || overlapped
  }

  func build(language: Language?) -> Utterance? {
    let text = Fuser.joinText(words)
    guard !text.isEmpty, let first = words.first else { return nil }
    let cleaned = words.map { word in
      var copy = word
      copy.text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return copy
    }
    return Utterance(
      start: first.start,
      end: words.map(\.end).max() ?? first.end,
      speakerID: speakerID,
      language: language,
      text: text,
      words: cleaned,
      overlapped: overlapped)
  }
}
