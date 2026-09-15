import Core
import Foundation

/// Второй проход по пустым окнам распознавания.
///
/// WhisperKit в чанковом прогоне иногда возвращает сегмент без единого токена на живой речи: наложение
/// голосов, граница клипа, состояние декодера (проверено 2026-09-15 на записях 74 и 22 мин: 10 и 7 окон
/// по 3–24 с). Его откат по температуре при нуле токенов не срабатывает — степень сжатия 0, средняя
/// вероятность 0, признак тишины 0, и пустой ответ принимается как уверенный. Те же окна, поданные
/// отдельным вызовом с запасом по краям, распознаются. Здесь такие окна пересчитываются: сначала с языком
/// региона, при повторной пустоте — с автоопределением языка движком; ничего не найдено — окно остаётся
/// пустым и уходит в фильтр как раньше.
public enum EmptyWindowRecovery {
  public struct Options: Hashable, Sendable {
    /// Пустой сегмент короче этого (с) не пересчитывается.
    public var minimumSeconds: Double
    /// Минимальное перекрытие с речью по диаризации (с); без диаризации перекрытие не проверяется.
    public var minimumSpeechSeconds: Double
    /// Запас по краям окна при повторном вызове (с).
    public var paddingSeconds: Double
    /// Предел числа окон за прогон — защита от вырожденного прогона, где пусто всё.
    public var maximumWindows: Int

    public init(
      minimumSeconds: Double = 2, minimumSpeechSeconds: Double = 1, paddingSeconds: Double = 1,
      maximumWindows: Int = 200
    ) {
      self.minimumSeconds = minimumSeconds
      self.minimumSpeechSeconds = minimumSpeechSeconds
      self.paddingSeconds = paddingSeconds
      self.maximumWindows = maximumWindows
    }
  }

  public struct Result: Sendable {
    /// Сегменты по времени: пустые окна заменены найденными, ненайденные оставлены как были.
    public var segments: [Segment]
    public var recovered: [RecoveredWindow]
  }

  /// Пустой сегмент: ни слов, ни текста.
  public static func isEmpty(_ segment: Segment) -> Bool {
    segment.words.isEmpty && segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Окна, которые стоит пересчитать: пустые, не короче минимума, с речью по диаризации (если она есть).
  static func candidates(in segments: [Segment], turns: [Turn]?, options: Options) -> [Segment] {
    segments.filter { segment in
      guard isEmpty(segment), segment.duration >= options.minimumSeconds else { return false }
      guard let turns else { return true }
      let speech = turns.reduce(0.0) { $0 + $1.overlap(from: segment.start, to: segment.end) }
      return speech >= options.minimumSpeechSeconds
    }
  }

  /// Пересчёт. `languageAt` — язык региона по времени (nil — пусть определяет движок); `discovered` получает
  /// найденные сегменты, как и основной вызов; `progress` — пульс на каждое окно.
  public static func recover(
    segments: [Segment],
    audio: PCMAudio,
    turns: [Turn]?,
    languageAt: @Sendable (Double) -> Language?,
    wordTimestamps: Bool,
    engine: any AsrEngine,
    options: Options = Options(),
    discovered: SegmentSink? = nil,
    progress: ProgressSink? = nil
  ) async throws -> Result {
    let windows = Array(
      candidates(in: segments, turns: turns, options: options).prefix(options.maximumWindows))
    guard !windows.isEmpty else { return Result(segments: segments, recovered: []) }

    var replacements: [Segment: [Segment]] = [:]
    var recovered: [RecoveredWindow] = []
    for (index, window) in windows.enumerated() {
      try Task.checkCancellation()
      progress?(
        ProgressEvent(
          stage: .transcription, timecode: window.start,
          pulse: String(localized: "пересчёт пропуска \(index + 1)/\(windows.count)")))
      let start = max(0, window.start - options.paddingSeconds)
      let end = min(audio.duration, window.end + options.paddingSeconds)
      guard end > start else { continue }
      let slice = audio.slice(from: start, to: end)
      let regionLanguage = languageAt((window.start + window.end) / 2)
      var attempts: [Language?] = [regionLanguage]
      if regionLanguage != nil { attempts.append(nil) }

      var found: [Segment] = []
      var used: Language? = nil
      var tried = 0
      for language in attempts {
        tried += 1
        let result = try await engine.transcribe(
          slice,
          options: AsrOptions(
            language: language, wordTimestamps: wordTimestamps, timeOffset: start, clips: []),
          progress: nil, discovered: nil)
        found = trimmed(result, to: window.start, end: window.end)
        if !found.isEmpty {
          used = language
          break
        }
      }
      recovered.append(
        RecoveredWindow(
          start: window.start, end: window.end, language: used, attempts: tried,
          segments: found.count))
      if !found.isEmpty {
        replacements[window] = found
        discovered?(found)
      }
    }

    var output: [Segment] = []
    output.reserveCapacity(segments.count + recovered.count)
    for segment in segments {
      if let found = replacements[segment] {
        output.append(contentsOf: found)
      } else {
        output.append(segment)
      }
    }
    return Result(
      segments: output.sorted { ($0.start, $0.end) < ($1.start, $1.end) }, recovered: recovered)
  }

  /// Оставляет от результата только то, что попадает в окно: запас по краям может захватить соседей.
  /// Со словами — по середине слова, текст собирается из оставшихся слов; без слов — по середине сегмента.
  static func trimmed(_ segments: [Segment], to start: Double, end: Double) -> [Segment] {
    var result: [Segment] = []
    for segment in segments {
      if segment.words.isEmpty {
        let middle = (segment.start + segment.end) / 2
        guard middle >= start, middle <= end, !isEmpty(segment) else { continue }
        var copy = segment
        copy.start = max(segment.start, start)
        copy.end = min(segment.end, end)
        result.append(copy)
        continue
      }
      let words = segment.words.filter { word in
        let middle = (word.start + word.end) / 2
        return middle >= start && middle <= end
      }
      guard !words.isEmpty else { continue }
      let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      var copy = segment
      copy.words = words
      copy.text = text
      copy.start = max(words.first!.start, start)
      copy.end = min(words.last!.end, end)
      if copy.end < copy.start { copy.end = copy.start }
      result.append(copy)
    }
    return result
  }
}
