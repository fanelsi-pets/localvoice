import Foundation

// Пользовательские правки транскрипта (SPEC.md §3.3: «переназначить реплику, объединить двух спикеров,
// разделить спикера по временному диапазону»; DESIGN.md §3: «Разделить здесь», «Объединить с предыдущей»).
// Операции чистые и детерминированные: меняют только переданный транскрипт, сохраняют монотонность
// таймкодов и согласованность `utterances`, `turns`, `speakers`, `speakerLanguages`, `speakerEmbeddings`,
// `tracks`. Хранилище (Store) сохраняет результат, движки в правках не участвуют.

extension Transcript {

  // MARK: - Сводка по спикерам

  /// Пересчитывает `speakers` из реплик (`SpeakerStats.summarize`), сохраняя подтверждённые имена по speakerID.
  /// Спикер без реплик из сводки исчезает: сводка описывает то, что попадёт в экспорт (SPEC.md §3.5).
  public mutating func recomputeSpeakers() {
    recomputeSpeakers(names: confirmedNames)
  }

  /// Имена, которые уже стоят в сводке: правка пользователя не должна теряться при пересчёте.
  private var confirmedNames: [Int: String] {
    var names: [Int: String] = [:]
    for speaker in speakers {
      guard let id = speaker.speakerID, let name = speaker.name, !name.isEmpty else { continue }
      names[id] = name
    }
    return names
  }

  private mutating func recomputeSpeakers(names: [Int: String]) {
    var stats = SpeakerStats.summarize(utterances, languages: speakerLanguages)
    for index in stats.indices {
      guard let id = stats[index].speakerID, let name = names[id] else { continue }
      stats[index].name = name
    }
    speakers = stats
  }

  /// Следующий свободный номер спикера. Кроме реплик, turn'ов и сводки просматриваются языки, отпечатки
  /// и дорожки: спикер мог остаться только там (например, после объединения всех его реплик).
  public var nextSpeakerID: Int {
    var maximum = 0
    for utterance in utterances {
      if let id = utterance.speakerID { maximum = max(maximum, id) }
    }
    for turn in turns { maximum = max(maximum, turn.speakerID) }
    for speaker in speakers {
      if let id = speaker.speakerID { maximum = max(maximum, id) }
    }
    for entry in speakerLanguages { maximum = max(maximum, entry.speakerID) }
    for embedding in speakerEmbeddings { maximum = max(maximum, embedding.speakerID) }
    for track in tracks { maximum = max(maximum, track.speakerID) }
    return max(maximum + 1, 1)
  }

  // MARK: - Правки реплик

  /// Реплика `index` → спикер `speakerID` (`nil` — неизвестный). Turn'ы диаризации не трогаются: это
  /// исходные данные движка, а правка касается конкретной реплики (SPEC.md §3.3).
  @discardableResult
  public mutating func reassignUtterance(at index: Int, to speakerID: Int?) -> Bool {
    guard utterances.indices.contains(index) else { return false }
    guard utterances[index].speakerID != speakerID else { return true }
    utterances[index].speakerID = speakerID
    recomputeSpeakers()
    return true
  }

  /// Склеивает реплику `index` с предыдущей (DESIGN.md §3, «Объединить с предыдущей»): спикер и язык —
  /// предыдущей (если у неё языка нет — язык текущей), слова по времени, `overlapped` — OR,
  /// текст — как в `Fuser`: из слов, если обе реплики собраны из слов, иначе через пробел.
  @discardableResult
  public mutating func mergeUtteranceWithPrevious(at index: Int) -> Bool {
    guard index > 0, utterances.indices.contains(index) else { return false }
    let previous = utterances[index - 1]
    let current = utterances[index]
    let words = (previous.words + current.words).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    utterances[index - 1] = Utterance(
      start: min(previous.start, current.start),
      end: max(previous.end, current.end),
      speakerID: previous.speakerID,
      language: previous.language ?? current.language,
      text: TranscriptEdit.combinedText(previous, current, words: words),
      words: words,
      overlapped: previous.overlapped || current.overlapped)
    utterances.remove(at: index)
    recomputeSpeakers()
    return true
  }

  /// Делит реплику `index` на две перед словом `wordIndex` (DESIGN.md §3, «Разделить здесь»):
  /// у первой слова `[0, wordIndex)`, у второй остальные; внутренняя граница — по словам, внешние границы
  /// реплики сохраняются, тексты пересобираются `Fuser.joinText`.
  @discardableResult
  public mutating func splitUtterance(at index: Int, beforeWord wordIndex: Int) -> Bool {
    guard utterances.indices.contains(index) else { return false }
    let utterance = utterances[index]
    guard wordIndex >= 1, wordIndex < utterance.words.count else { return false }
    let head = Array(utterance.words[..<wordIndex])
    let tail = Array(utterance.words[wordIndex...])
    guard let headEnd = head.map(\.end).max(), let tailStart = tail.map(\.start).min(),
      let tailEnd = tail.map(\.end).max()
    else { return false }

    let first = Utterance(
      start: utterance.start,
      end: max(utterance.start, headEnd),
      speakerID: utterance.speakerID,
      language: utterance.language,
      text: Fuser.joinText(head),
      words: head,
      overlapped: utterance.overlapped)
    let second = Utterance(
      start: tailStart,
      end: max(utterance.end, tailEnd),
      speakerID: utterance.speakerID,
      language: utterance.language,
      text: Fuser.joinText(tail),
      words: tail,
      overlapped: utterance.overlapped)
    utterances.replaceSubrange(index...index, with: [first, second])
    recomputeSpeakers()
    return true
  }

  // MARK: - Правки спикеров

  /// Все реплики и turn'ы `source` переходят к `target` (SPEC.md §3.3, DESIGN.md §4 «Объединить с…»).
  /// Соседние реплики одного спикера не склеиваются: пользователь должен видеть, что именно произошло.
  /// Отпечатки складываются взвешенным средним по секундам речи, язык, дорожки и подсказки имён
  /// переезжают на `target`, имя `target` сохраняется (а если его нет — берётся имя `source`).
  public mutating func mergeSpeaker(_ source: Int, into target: Int) {
    guard source != target else { return }
    for index in utterances.indices where utterances[index].speakerID == source {
      utterances[index].speakerID = target
    }
    for index in turns.indices where turns[index].speakerID == source {
      turns[index].speakerID = target
    }
    mergeEmbedding(source, into: target)
    // Запись source уходит вместе со спикером; если у target языка не было — она достаётся ему.
    if let sourceIndex = speakerLanguages.firstIndex(where: { $0.speakerID == source }) {
      if speakerLanguages.contains(where: { $0.speakerID == target }) {
        speakerLanguages.remove(at: sourceIndex)
      } else {
        speakerLanguages[sourceIndex].speakerID = target
      }
    }
    for index in tracks.indices where tracks[index].speakerID == source {
      tracks[index].speakerID = target
    }
    for index in nameHints.indices where nameHints[index].speakerID == source {
      nameHints[index].speakerID = target
    }
    var names = confirmedNames
    if names[target] == nil { names[target] = names[source] }
    names[source] = nil
    recomputeSpeakers(names: names)
  }

  /// Отпечаток объединённого спикера — взвешенное среднее по секундам речи (`VoiceMath.weightedMean`
  /// живёт в модуле Voices и в Core недоступен, поэтому среднее считается здесь).
  private mutating func mergeEmbedding(_ source: Int, into target: Int) {
    guard let sourceIndex = speakerEmbeddings.firstIndex(where: { $0.speakerID == source }) else {
      return
    }
    let moved = speakerEmbeddings[sourceIndex]
    guard let targetIndex = speakerEmbeddings.firstIndex(where: { $0.speakerID == target }) else {
      speakerEmbeddings[sourceIndex].speakerID = target
      return
    }
    let existing = speakerEmbeddings[targetIndex]
    let vector =
      TranscriptEdit.weightedMean([
        (existing.vector, existing.speechSeconds), (moved.vector, moved.speechSeconds),
      ]) ?? existing.vector
    speakerEmbeddings[targetIndex] = SpeakerEmbedding(
      speakerID: target, vector: vector,
      speechSeconds: existing.speechSeconds + moved.speechSeconds)
    speakerEmbeddings.remove(at: sourceIndex)
  }

  /// Разделяет спикера по диапазону (SPEC.md §3.3, DESIGN.md §4 «Разделить по диапазону…»): реплики,
  /// у которых в диапазоне не меньше половины длительности, и куски turn'ов внутри диапазона уходят новому
  /// спикеру. Язык копируется на нового, отпечатка у него нет — его снимут заново по новым turn'ам.
  /// Возвращает id нового спикера или `nil`, если в диапазон ничего не попало.
  @discardableResult
  public mutating func splitSpeaker(_ speakerID: Int, range: ClosedRange<Double>) -> Int? {
    guard range.upperBound > range.lowerBound else { return nil }
    let newID = nextSpeakerID
    var moved = false

    for index in utterances.indices where utterances[index].speakerID == speakerID {
      let utterance = utterances[index]
      let overlap = max(
        0, min(utterance.end, range.upperBound) - max(utterance.start, range.lowerBound))
      let inside =
        utterance.duration > TranscriptEdit.epsilon
        ? overlap >= utterance.duration / 2 - TranscriptEdit.epsilon
        : range.contains(utterance.start)
      guard inside else { continue }
      utterances[index].speakerID = newID
      moved = true
    }

    var updated: [Turn] = []
    updated.reserveCapacity(turns.count + 2)
    for turn in turns {
      guard turn.speakerID == speakerID,
        min(turn.end, range.upperBound) - max(turn.start, range.lowerBound) > TranscriptEdit.epsilon
      else {
        updated.append(turn)
        continue
      }
      // Turn режется по границам диапазона: середина — новому спикеру, края остаются старому.
      let pieces = [
        Turn(
          start: turn.start, end: min(turn.end, range.lowerBound), speakerID: speakerID,
          confidence: turn.confidence),
        Turn(
          start: max(turn.start, range.lowerBound), end: min(turn.end, range.upperBound),
          speakerID: newID, confidence: turn.confidence),
        Turn(
          start: max(turn.start, range.upperBound), end: turn.end, speakerID: speakerID,
          confidence: turn.confidence),
      ]
      updated.append(contentsOf: pieces.filter { $0.duration > TranscriptEdit.epsilon })
      moved = true
    }
    guard moved else { return nil }

    turns = updated.sorted { ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID) }
    if var language = speakerLanguages.first(where: { $0.speakerID == speakerID }) {
      language.speakerID = newID
      speakerLanguages.append(language)
      speakerLanguages.sort { $0.speakerID < $1.speakerID }
    }
    recomputeSpeakers()
    return newID
  }
}

/// Общие мелочи правок: склейка текста как в `Fuser` и взвешенное среднее отпечатков.
enum TranscriptEdit {
  /// Допуск сравнения секунд: таймкоды приходят из движков как Double.
  static let epsilon = 1e-9

  /// Текст пересобирается из слов, только если он у обеих реплик получен из слов (та же проверка, что
  /// в `Fuser`): иначе реплика без word timestamps потеряла бы часть речи.
  static func combinedText(_ first: Utterance, _ second: Utterance, words: [Word]) -> String {
    guard textMatchesWords(first), textMatchesWords(second) else {
      return [first.text, second.text].filter { !$0.isEmpty }.joined(separator: " ")
    }
    return Fuser.joinText(words)
  }

  private static func textMatchesWords(_ utterance: Utterance) -> Bool {
    !utterance.words.isEmpty && utterance.text == Fuser.joinText(utterance.words)
  }

  /// Взвешенное среднее векторов (веса — секунды речи); `nil` — размерности не совпадают или векторов нет.
  static func weightedMean(_ entries: [(vector: [Float], weight: Double)]) -> [Float]? {
    let usable = entries.filter { !$0.vector.isEmpty }
    guard let first = usable.first else { return nil }
    let dimension = first.vector.count
    guard usable.allSatisfy({ $0.vector.count == dimension }) else { return nil }
    let total = usable.reduce(0) { $0 + max($1.weight, 0) }
    var sum = [Double](repeating: 0, count: dimension)
    for entry in usable {
      let weight = total > 0 ? max(entry.weight, 0) / total : 1 / Double(usable.count)
      for index in 0..<dimension { sum[index] += Double(entry.vector[index]) * weight }
    }
    return sum.map(Float.init)
  }
}
