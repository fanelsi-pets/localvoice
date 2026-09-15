import Core
import Foundation

/// Второй проход распознавания: окна, где текста нет, хотя речь есть.
///
/// Две причины пропусков. 1) WhisperKit в чанковом прогоне иногда возвращает сегмент без единого токена
/// на живой речи (наложение голосов, граница клипа, состояние декодера); его откат по температуре при нуле
/// токенов не срабатывает — степень сжатия 0, средняя вероятность 0, признак тишины 0, и пустой ответ
/// принимается как уверенный. 2) На коротком клипе (раздельные дорожки, шумная дорожка) декодер не отдаёт
/// вообще ничего — ни сегмента, ни слова, и по транскрипту речь выглядит тишиной. Проверено 2026-09-15 на
/// записях 74 и 22 мин: те же окна, поданные отдельным вызовом с запасом по краям и языком региона,
/// распознаются.
///
/// Здесь оба случая пересчитываются отдельными вызовами: сначала пустые сегменты, затем реплики
/// диаризации, покрытые текстом меньше чем на треть. Найденный текст проходит защиту от галлюцинаций
/// на шуме (средняя вероятность, степень сжатия) и не дублирует уже распознанные слова.
public enum EmptyWindowRecovery {
  public struct Options: Hashable, Sendable {
    /// Пустой сегмент короче этого (с) не пересчитывается.
    public var minimumSeconds: Double
    /// Минимальное перекрытие пустого сегмента с речью по диаризации (с); без диаризации не проверяется.
    public var minimumSpeechSeconds: Double
    /// Запас по краям окна при повторном вызове (с).
    public var paddingSeconds: Double
    /// Предел числа окон за прогон (обе стадии): защита от вырожденного прогона; 400 покрывает встречу на два часа,
    /// где WhisperKit потерял до трети чанков (2026-09-15).
    public var maximumWindows: Int
    /// Реплика диаризации не короче этого (с) считается кандидатом на пропуск речи.
    public var uncoveredMinimumSeconds: Double
    /// Доля реплики, покрытая текстом, ниже которой реплика считается пропущенной.
    public var uncoveredCoverage: Double
    /// Соседние пропущенные реплики одного спикера ближе этого (с) объединяются в одно окно.
    public var uncoveredMergeGapSeconds: Double
    /// Найденный сегмент со средней log-вероятностью ниже этой отбрасывается: так выглядит галлюцинация на шуме.
    public var minimumAverageLogprob: Double
    /// Найденный сегмент со степенью сжатия выше этой отбрасывается: зацикленный текст.
    public var maximumCompressionRatio: Double

    public init(
      minimumSeconds: Double = 2, minimumSpeechSeconds: Double = 1, paddingSeconds: Double = 1,
      maximumWindows: Int = 400, uncoveredMinimumSeconds: Double = 2,
      uncoveredCoverage: Double = 0.3,
      uncoveredMergeGapSeconds: Double = 1.5, minimumAverageLogprob: Double = -1.2,
      maximumCompressionRatio: Double = 2.4
    ) {
      self.minimumSeconds = minimumSeconds
      self.minimumSpeechSeconds = minimumSpeechSeconds
      self.paddingSeconds = paddingSeconds
      self.maximumWindows = maximumWindows
      self.uncoveredMinimumSeconds = uncoveredMinimumSeconds
      self.uncoveredCoverage = uncoveredCoverage
      self.uncoveredMergeGapSeconds = uncoveredMergeGapSeconds
      self.minimumAverageLogprob = minimumAverageLogprob
      self.maximumCompressionRatio = maximumCompressionRatio
    }
  }

  public struct Result: Sendable {
    /// Сегменты по времени: пустые окна заменены найденными, пропуски речи дополнены, остальное как было.
    public var segments: [Segment]
    public var recovered: [RecoveredWindow]
  }

  /// Причины пересчёта в `RecoveredWindow.reason`.
  public static let reasonEmpty = "empty"
  public static let reasonUncovered = "uncovered"

  /// Окно для пересчёта.
  struct Window: Hashable, Sendable {
    var start: Double
    var end: Double
    var reason: String
    /// Пустой сегмент, который окно заменяет (у пропусков речи — nil).
    var replacing: Segment?
  }

  /// Пустой сегмент: ни слов, ни текста.
  public static func isEmpty(_ segment: Segment) -> Bool {
    segment.words.isEmpty && segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Стадия 1: пустые сегменты не короче минимума, с речью по диаризации (если она есть).
  static func candidates(in segments: [Segment], turns: [Turn]?, options: Options) -> [Segment] {
    segments.filter { segment in
      guard isEmpty(segment), segment.duration >= options.minimumSeconds else { return false }
      guard let turns else { return true }
      let speech = turns.reduce(0.0) { $0 + $1.overlap(from: segment.start, to: segment.end) }
      return speech >= options.minimumSpeechSeconds
    }
  }

  /// Отрезки, где текст уже есть: слова, а у сегмента без слов — сам сегмент.
  static func textSpans(_ segments: [Segment]) -> [(start: Double, end: Double)] {
    var spans: [(start: Double, end: Double)] = []
    for segment in segments where !isEmpty(segment) {
      if segment.words.isEmpty {
        spans.append((segment.start, segment.end))
      } else {
        for word in segment.words { spans.append((word.start, word.end)) }
      }
    }
    return spans.sorted { $0.start < $1.start }
  }

  static func covered(_ start: Double, _ end: Double, by spans: [(start: Double, end: Double)])
    -> Double
  {
    var total = 0.0
    for span in spans {
      if span.start >= end { break }
      total += max(0, min(span.end, end) - max(span.start, start))
    }
    return total
  }

  /// Стадия 2: реплики диаризации не короче минимума, покрытые текстом меньше порога; соседние реплики
  /// одного спикера объединяются в одно окно.
  static func uncoveredWindows(turns: [Turn], segments: [Segment], options: Options) -> [Window] {
    let spans = textSpans(segments)
    var windows: [(start: Double, end: Double, speaker: Int)] = []
    for turn in turns.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
      let length = turn.end - turn.start
      guard length >= options.uncoveredMinimumSeconds else { continue }
      guard covered(turn.start, turn.end, by: spans) < options.uncoveredCoverage * length else {
        continue
      }
      if var last = windows.last, last.speaker == turn.speakerID,
        turn.start - last.end <= options.uncoveredMergeGapSeconds
      {
        last.end = max(last.end, turn.end)
        windows[windows.count - 1] = last
      } else {
        windows.append((turn.start, turn.end, turn.speakerID))
      }
    }
    return windows.map {
      Window(start: $0.start, end: $0.end, reason: reasonUncovered, replacing: nil)
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
    // Стадия 1: пустые сегменты.
    var windows = candidates(in: segments, turns: turns, options: options).map {
      Window(start: $0.start, end: $0.end, reason: reasonEmpty, replacing: $0)
    }
    var output = segments
    var recovered: [RecoveredWindow] = []
    var processed = 0

    func run(_ batch: [Window], total: Int) async throws {
      for window in batch {
        try Task.checkCancellation()
        processed += 1
        progress?(
          ProgressEvent(
            stage: .transcription, timecode: window.start,
            pulse: String(localized: "пересчёт пропуска \(processed)/\(total)")))
        let spans = textSpans(output)
        let found = try await decode(
          window, audio: audio, existing: spans, languageAt: languageAt,
          wordTimestamps: wordTimestamps, engine: engine, options: options)
        recovered.append(
          RecoveredWindow(
            start: window.start, end: window.end, language: found.language,
            attempts: found.attempts,
            segments: found.segments.count, reason: window.reason))
        guard !found.segments.isEmpty else { continue }
        if let replacing = window.replacing, let index = output.firstIndex(of: replacing) {
          output.replaceSubrange(index...index, with: found.segments)
        } else {
          output.append(contentsOf: found.segments)
        }
        discovered?(found.segments)
      }
    }

    let firstBatch = Array(windows.prefix(options.maximumWindows))
    try await run(firstBatch, total: firstBatch.count)

    // Стадия 2: речь по диаризации без текста — с учётом того, что нашла стадия 1.
    if let turns, !turns.isEmpty, processed < options.maximumWindows {
      windows = uncoveredWindows(turns: turns, segments: output, options: options)
      let secondBatch = Array(windows.prefix(options.maximumWindows - processed))
      let total = processed + secondBatch.count
      try await run(secondBatch, total: total)
    }

    return Result(
      segments: output.sorted { ($0.start, $0.end) < ($1.start, $1.end) }, recovered: recovered)
  }

  struct Decoded {
    var segments: [Segment]
    var language: Language?
    var attempts: Int
  }

  /// Один пересчёт окна: запас по краям, попытка с языком региона, затем с автоопределением; результат
  /// обрезается по окну, очищается от уже распознанных слов и от галлюцинаций.
  static func decode(
    _ window: Window, audio: PCMAudio, existing: [(start: Double, end: Double)],
    languageAt: @Sendable (Double) -> Language?, wordTimestamps: Bool, engine: any AsrEngine,
    options: Options
  ) async throws -> Decoded {
    let start = max(0, window.start - options.paddingSeconds)
    let end = min(audio.duration, window.end + options.paddingSeconds)
    guard end > start else { return Decoded(segments: [], language: nil, attempts: 0) }
    let slice = audio.slice(from: start, to: end)
    let regionLanguage = languageAt((window.start + window.end) / 2)
    var attempts: [Language?] = [regionLanguage]
    if regionLanguage != nil { attempts.append(nil) }
    var tried = 0
    for language in attempts {
      tried += 1
      let result = try await engine.transcribe(
        slice,
        options: AsrOptions(
          language: language, wordTimestamps: wordTimestamps, timeOffset: start, clips: []),
        progress: nil, discovered: nil)
      let inside = trimmed(result, to: window.start, end: window.end)
      let fresh = withoutCovered(inside, existing: existing)
      let kept = fresh.filter { Self.plausible($0, options: options) }
      if !kept.isEmpty {
        return Decoded(segments: kept, language: language, attempts: tried)
      }
    }
    return Decoded(segments: [], language: nil, attempts: tried)
  }

  /// Галлюцинация на шуме: слишком низкая средняя вероятность или зацикленный текст.
  static func plausible(_ segment: Segment, options: Options) -> Bool {
    if let logprob = segment.avgLogprob, logprob < options.minimumAverageLogprob { return false }
    if let ratio = segment.compressionRatio, ratio > options.maximumCompressionRatio {
      return false
    }
    return true
  }

  /// Убирает слова, середина которых уже покрыта распознанным текстом (запас по краям захватывает соседей).
  static func withoutCovered(_ segments: [Segment], existing: [(start: Double, end: Double)])
    -> [Segment]
  {
    guard !existing.isEmpty else { return segments }
    var result: [Segment] = []
    for segment in segments {
      if segment.words.isEmpty {
        let middle = (segment.start + segment.end) / 2
        let taken = existing.contains { $0.start <= middle && middle <= $0.end }
        if !taken { result.append(segment) }
        continue
      }
      let words = segment.words.filter { word in
        let middle = (word.start + word.end) / 2
        return !existing.contains { $0.start <= middle && middle <= $0.end }
      }
      guard !words.isEmpty else { continue }
      let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      var copy = segment
      copy.words = words
      copy.text = text
      // Границы сегмента уже обрезаны по окну: слова с краёв могут начинаться чуть раньше.
      copy.start = max(words.first!.start, segment.start)
      copy.end = max(min(words.last!.end, segment.end), copy.start)
      result.append(copy)
    }
    return result
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
