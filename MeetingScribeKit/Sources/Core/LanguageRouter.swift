import Foundation

/// Язык по спикеру (SPEC.md §3.2, ADR-003): проба речи каждого спикера → `detectLanguage` → при неоднозначности
/// сравнение декодирования с каждым кандидатом → регионы одного языка на таймлайне → клипы для вызова ASR на язык.
public struct LanguageRouter: Sendable {
  public struct Options: Hashable, Sendable {
    /// Языки, между которыми выбираем; остальные вероятности отбрасываются, оставшиеся ренормализуются.
    public var candidates: [Language]
    /// Сколько секунд речи спикера собрать в пробу (окно определения языка у Whisper — 30 с).
    public var probeTargetSeconds: Double
    /// Не больше стольких секунд с одного turn'а — чтобы в пробу попали 3+ разных места записи.
    public var probeTurnCapSeconds: Double
    /// Turn'ы короче не берутся в пробу.
    public var probeMinimumTurnSeconds: Double
    /// Спикеры с меньшей суммарной речью язык не определяют — получают fallback.
    public var minimumSpeechSeconds: Double
    /// Уверенность (после ренормализации), ниже которой решение неоднозначно.
    public var minimumConfidence: Double
    /// Отношение top1/top2, ниже которого решение неоднозначно.
    public var ambiguityRatio: Double
    /// Неоднозначные случаи решать сравнением декодирования пробы с каждым из двух кандидатов.
    public var tieBreakByDecoding: Bool
    /// Язык по умолчанию; nil — доминирующий среди уверенно определённых, иначе язык первых 30 с, иначе ru.
    public var fallback: Language?
    /// Регионы короче вливаются в соседа: WhisperKit пропускает клипы короче 1 с целиком.
    public var minimumRegionSeconds: Double

    public init(
      candidates: [Language] = [.ru, .uk, .en],
      probeTargetSeconds: Double = 24,
      probeTurnCapSeconds: Double = 8,
      probeMinimumTurnSeconds: Double = 1,
      minimumSpeechSeconds: Double = 3,
      minimumConfidence: Double = 0.5,
      ambiguityRatio: Double = 1.5,
      tieBreakByDecoding: Bool = true,
      fallback: Language? = nil,
      minimumRegionSeconds: Double = 1.2
    ) {
      self.candidates = candidates
      self.probeTargetSeconds = probeTargetSeconds
      self.probeTurnCapSeconds = probeTurnCapSeconds
      self.probeMinimumTurnSeconds = probeMinimumTurnSeconds
      self.minimumSpeechSeconds = minimumSpeechSeconds
      self.minimumConfidence = minimumConfidence
      self.ambiguityRatio = ambiguityRatio
      self.tieBreakByDecoding = tieBreakByDecoding
      self.fallback = fallback
      self.minimumRegionSeconds = minimumRegionSeconds
    }
  }

  /// Проба речи спикера: отрезки записи, из которых склеивается аудио для определения языка.
  public struct Probe: Hashable, Sendable {
    public var speakerID: Int
    public var ranges: [ClosedRange<Double>]
    public var seconds: Double

    public init(speakerID: Int, ranges: [ClosedRange<Double>], seconds: Double) {
      self.speakerID = speakerID
      self.ranges = ranges
      self.seconds = seconds
    }

    /// Аудио пробы: отрезки в порядке времени, склеенные подряд.
    public func audio(from audio: PCMAudio) -> PCMAudio {
      PCMAudio.concatenate(ranges.map { audio.slice(from: $0.lowerBound, to: $0.upperBound) })
    }
  }

  public enum Decision: Hashable, Sendable {
    case confident(Language, confidence: Double)
    /// Кандидаты по убыванию вероятности (два верхних) — нужен тай-брейк.
    case ambiguous([Language])
    case unknown
  }

  /// Клипы одного вызова ASR: все регионы одного языка, по времени.
  public struct LanguageClips: Hashable, Sendable {
    public var language: Language?
    public var ranges: [ClosedRange<Double>]
    public var seconds: Double

    public init(language: Language?, ranges: [ClosedRange<Double>], seconds: Double) {
      self.language = language
      self.ranges = ranges
      self.seconds = seconds
    }
  }

  /// Погрешность сравнения секунд: границы turn'ов приходят из движка как Double.
  private static let epsilon = 1e-9

  // MARK: - Пробы

  /// Выбирает пробы: длинные turn'ы первыми, не больше `probeTurnCapSeconds` с каждого, до `probeTargetSeconds`.
  /// Спикеры с речью короче `minimumSpeechSeconds` пробы не получают — их язык решается fallback'ом.
  public static func probes(for diarization: DiarizationResult, options: Options = Options())
    -> [Probe]
  {
    var turnsBySpeaker: [Int: [Turn]] = [:]
    for turn in diarization.turns where turn.duration > 0 {
      turnsBySpeaker[turn.speakerID, default: []].append(turn)
    }
    return turnsBySpeaker.keys.sorted().compactMap { speakerID in
      probe(speakerID: speakerID, turns: turnsBySpeaker[speakerID] ?? [], options: options)
    }
  }

  private static func probe(speakerID: Int, turns: [Turn], options: Options) -> Probe? {
    let speechSeconds = turns.reduce(0) { $0 + $1.duration }
    guard speechSeconds >= options.minimumSpeechSeconds else { return nil }
    // Длинные turn'ы первыми (при равной длительности — ранние): в них уверенная речь без обрывков.
    let ordered = turns.sorted {
      $0.duration == $1.duration
        ? ($0.start, $0.end) < ($1.start, $1.end) : $0.duration > $1.duration
    }
    var ranges: [ClosedRange<Double>] = []
    var seconds = 0.0
    for turn in ordered {
      let remaining = options.probeTargetSeconds - seconds
      guard remaining > epsilon else { break }
      guard turn.duration >= options.probeMinimumTurnSeconds else { continue }
      let take = min(turn.duration, min(options.probeTurnCapSeconds, remaining))
      guard take > epsilon else { continue }
      // Берём середину turn'а: на границах чаще всего чужая речь и обрывки слов.
      let start = (turn.start + turn.end) / 2 - take / 2
      ranges.append(start...(start + take))
      seconds += take
    }
    guard !ranges.isEmpty else { return nil }
    return Probe(
      speakerID: speakerID,
      ranges: ranges.sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) },
      seconds: seconds)
  }

  // MARK: - Решение по вероятностям

  /// Решение по вероятностям, ренормализованным по кандидатам.
  public static func decide(_ detection: LanguageDetection, options: Options = Options())
    -> Decision
  {
    let ranked = rank(detection, options: options)
    guard let top = ranked.first else { return .unknown }
    let runnerUp = ranked.count > 1 ? ranked[1].probability : 0
    if top.probability >= options.minimumConfidence,
      runnerUp <= 0 || top.probability / runnerUp >= options.ambiguityRatio
    {
      return .confident(top.language, confidence: top.probability)
    }
    return .ambiguous(ranked.prefix(2).map(\.language))
  }

  /// Вероятности кандидатов после ренормализации, по убыванию (при равенстве — в порядке `candidates`).
  /// Пустой результат — сумма по кандидатам нулевая, языка нет.
  private static func rank(_ detection: LanguageDetection, options: Options)
    -> [(language: Language, probability: Double)]
  {
    let weights = options.candidates.map { max(detection.probabilities[$0] ?? 0, 0) }
    let total = weights.reduce(0, +)
    guard total > 0 else { return [] }
    return zip(options.candidates, weights)
      .map { (language: $0, probability: $1 / total) }
      .enumerated()
      .sorted {
        $0.element.probability == $1.element.probability
          ? $0.offset < $1.offset : $0.element.probability > $1.element.probability
      }
      .map(\.element)
  }

  // MARK: - Маршрутизация

  /// Определяет язык каждого спикера. Движок без `supportsLanguageSelection` — все спикеры `.unsupported`
  /// без единого вызова. Прогресс — стадия `.languageDetection`: доля спикеров и пульс «Спикер 2: uk (0.87)».
  public static func route(
    diarization: DiarizationResult,
    audio: PCMAudio,
    engine: any AsrEngine,
    options: Options = Options(),
    progress: ProgressSink?
  ) async throws -> [SpeakerLanguage] {
    let speakerIDs = diarization.speakerIDs
    guard engine.supportsLanguageSelection else {
      progress?(
        .fraction(
          .languageDetection, 1,
          pulse: String(localized: "\(engine.descriptor.name): язык не выбирается")))
      return unsupported(speakerIDs)
    }

    let speakerProbes = probes(for: diarization, options: options)
    var resolved: [Int: SpeakerLanguage] = [:]
    /// Спикеры, у которых проба была, но решения нет: длительность пробы нужна в диагностике.
    var probedWithoutDecision: [Int: Double] = [:]
    let total = max(speakerProbes.count, 1)

    for (index, probe) in speakerProbes.enumerated() {
      try Task.checkCancellation()
      let probeAudio = probe.audio(from: audio)
      let detection: LanguageDetection
      do {
        detection = try await engine.detectLanguage(probeAudio)
      } catch EngineError.unsupported {
        // Движок не умеет определять язык — язык по спикеру не применяется вовсе (как Parakeet).
        progress?(
          .fraction(
            .languageDetection, 1,
            pulse: String(localized: "\(engine.descriptor.name): язык не выбирается")))
        return unsupported(speakerIDs)
      }

      var pulse = String(localized: "Спикер \(probe.speakerID): язык не определён")
      switch decide(detection, options: options) {
      case .confident(let language, let confidence):
        resolved[probe.speakerID] = SpeakerLanguage(
          speakerID: probe.speakerID, language: language, confidence: confidence,
          probeSeconds: probe.seconds, method: .detected)
        pulse = self.pulse(speakerID: probe.speakerID, language: language, confidence: confidence)
      case .ambiguous(let candidates) where options.tieBreakByDecoding && candidates.count >= 2:
        // Известная путаница uk/ru: побеждает язык, на котором проба декодируется увереннее.
        let winner = try await tieBreak(
          candidates: Array(candidates.prefix(2)), probeAudio: probeAudio, engine: engine)
        let probabilities = rank(detection, options: options)
        let confidence = probabilities.first { $0.language == winner }?.probability ?? 0
        resolved[probe.speakerID] = SpeakerLanguage(
          speakerID: probe.speakerID, language: winner, confidence: confidence,
          probeSeconds: probe.seconds, method: .decodedComparison)
        pulse = self.pulse(speakerID: probe.speakerID, language: winner, confidence: confidence)
      case .ambiguous, .unknown:
        probedWithoutDecision[probe.speakerID] = probe.seconds
      }
      progress?(.fraction(.languageDetection, Double(index + 1) / Double(total), pulse: pulse))
    }

    let needsFallback = speakerIDs.contains { resolved[$0] == nil }
    let fallbackLanguage =
      needsFallback
      ? try await resolveFallback(
        diarization: diarization, resolved: resolved, audio: audio, engine: engine,
        options: options)
      : .ru
    let result = speakerIDs.map { speakerID in
      resolved[speakerID]
        ?? SpeakerLanguage(
          speakerID: speakerID, language: fallbackLanguage, confidence: 0,
          probeSeconds: probedWithoutDecision[speakerID] ?? 0, method: .fallback)
    }
    progress?(.fraction(.languageDetection, 1))
    return result.sorted { $0.speakerID < $1.speakerID }
  }

  private static func pulse(speakerID: Int, language: Language, confidence: Double) -> String {
    String(
      localized: "Спикер \(speakerID): \(language.code) (\(String(format: "%.2f", confidence)))")
  }

  private static func unsupported(_ speakerIDs: [Int]) -> [SpeakerLanguage] {
    speakerIDs.map {
      SpeakerLanguage(
        speakerID: $0, language: .unknown, confidence: 0, probeSeconds: 0, method: .unsupported)
    }
  }

  /// Декодирует пробу каждым кандидатом и выбирает язык с большим средневзвешенным `avgLogprob`.
  private static func tieBreak(
    candidates: [Language], probeAudio: PCMAudio, engine: any AsrEngine
  ) async throws -> Language {
    var best: (language: Language, score: Double)?
    for candidate in candidates {
      let segments = try await engine.transcribe(
        probeAudio,
        options: AsrOptions(language: candidate, wordTimestamps: false),
        progress: nil)
      let score = decodingScore(segments)
      if best == nil || score > best!.score {
        best = (candidate, score)
      }
    }
    return best?.language ?? candidates[0]
  }

  /// Средний `avgLogprob`, взвешенный длительностью сегментов. Нет пригодных сегментов — −∞ (кандидат проиграл).
  static func decodingScore(_ segments: [Segment]) -> Double {
    var weighted = 0.0
    var total = 0.0
    for segment in segments {
      guard let logprob = segment.avgLogprob, logprob != 0 else { continue }
      let weight = max(segment.duration, 0)
      weighted += logprob * weight
      total += weight
    }
    guard total > 0 else { return -.infinity }
    return weighted / total
  }

  /// Язык для спикеров без решения: заданный → доминирующий среди уверенных → язык первых 30 с → ru.
  private static func resolveFallback(
    diarization: DiarizationResult,
    resolved: [Int: SpeakerLanguage],
    audio: PCMAudio,
    engine: any AsrEngine,
    options: Options
  ) async throws -> Language {
    if let fallback = options.fallback { return fallback }
    if let dominant = dominantLanguage(
      diarization: diarization, resolved: resolved, options: options)
    {
      return dominant
    }
    guard !audio.isEmpty else { return .ru }
    try Task.checkCancellation()
    do {
      let detection = try await engine.detectLanguage(audio.slice(from: 0, to: 30))
      if case .confident(let language, _) = decide(detection, options: options) { return language }
    } catch {
      if error is CancellationError || (error as? EngineError) == .cancelled { throw error }
      // Прочие ошибки движка не должны валить маршрутизацию: остаётся язык по умолчанию.
    }
    return .ru
  }

  /// Язык, на котором говорит больше всего секунд записи (по уверенно определённым спикерам).
  private static func dominantLanguage(
    diarization: DiarizationResult, resolved: [Int: SpeakerLanguage], options: Options
  ) -> Language? {
    var seconds: [Language: Double] = [:]
    for entry in resolved.values
    where entry.method == .detected || entry.method == .decodedComparison {
      seconds[entry.language, default: 0] += diarization.speechSeconds(for: entry.speakerID)
    }
    let order = { (language: Language) in options.candidates.firstIndex(of: language) ?? Int.max }
    return
      seconds
      .sorted { $0.value == $1.value ? order($0.key) < order($1.key) : $0.value > $1.value }
      .first?.key
  }

  // MARK: - Регионы и клипы

  /// Отрезок эксклюзивной проекции turn'ов: у каждого момента записи не больше одного спикера.
  private struct Piece {
    var start: Double
    var end: Double
    var speakerID: Int
  }

  /// Непрерывная группа отрезков одного языка до расстановки границ по паузам.
  private struct Run {
    var language: Language?
    var start: Double
    var end: Double
  }

  /// Разбивает `[0, duration]` на регионы одного языка по эксклюзивной проекции turn'ов
  /// (при перекрытии отрезок остаётся за более ранним по началу); границы — середины пауз между turn'ами
  /// разных языков, тишина по краям — соседу, регионы короче `minimumRegionSeconds` вливаются в соседа.
  public static func regions(
    turns: [Turn], languages: [Int: Language], duration: Double, options: Options = Options()
  ) -> [LanguageRegion] {
    guard duration > 0 else { return [] }
    let pieces = exclusiveProjection(turns, duration: duration)
    guard !pieces.isEmpty else {
      // Диаризации нет: весь файл — один регион. Один язык на всех — берём его, иначе язык не выбирается.
      let unique = Set(languages.values)
      return [
        LanguageRegion(
          start: 0, end: duration, language: unique.count == 1 ? unique.first : nil, speakerIDs: [])
      ]
    }

    var runs = self.runs(from: pieces, languages: languages)
    // Граница между языками — середина паузы между ними; без паузы — начало следующего turn'а.
    for index in runs.indices.dropLast() {
      let gapStart = runs[index].end
      let gapEnd = runs[index + 1].start
      let boundary = gapEnd > gapStart ? (gapStart + gapEnd) / 2 : gapEnd
      runs[index].end = boundary
      runs[index + 1].start = boundary
    }
    // Тишина по краям — соседнему региону: клипы покрывают запись целиком.
    runs[0].start = 0
    runs[runs.count - 1].end = duration

    var regions = runs.map {
      LanguageRegion(start: $0.start, end: $0.end, language: $0.language)
    }
    regions = mergeShort(regions, minimum: options.minimumRegionSeconds)
    regions = mergeSameLanguage(regions)
    return assignSpeakers(regions, pieces: pieces)
  }

  /// Эксклюзивная проекция: turn'ы по (start, end), перекрытие остаётся за более ранним по началу.
  private static func exclusiveProjection(_ turns: [Turn], duration: Double) -> [Piece] {
    var pieces: [Piece] = []
    var cursor = 0.0
    for turn in turns.sorted(by: {
      ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID)
    }) {
      let start = max(turn.start, cursor, 0)
      let end = min(turn.end, duration)
      guard end > start + epsilon else { continue }
      pieces.append(Piece(start: start, end: end, speakerID: turn.speakerID))
      cursor = end
    }
    return pieces
  }

  /// Склеивает подряд идущие отрезки одного языка. Отрезок без языка границы не создаёт — вливается в соседа.
  private static func runs(from pieces: [Piece], languages: [Int: Language]) -> [Run] {
    var runs: [Run] = []
    for piece in pieces {
      let language = languages[piece.speakerID]
      if var current = runs.last,
        language == nil || current.language == nil || current.language == language
      {
        current.end = max(current.end, piece.end)
        if current.language == nil { current.language = language }
        runs[runs.count - 1] = current
      } else {
        runs.append(Run(language: language, start: piece.start, end: piece.end))
      }
    }
    return runs
  }

  /// Регионы короче минимума вливаются в более длинного соседа (первый — в следующий), пока такие есть.
  private static func mergeShort(_ input: [LanguageRegion], minimum: Double) -> [LanguageRegion] {
    var regions = input
    while regions.count > 1,
      let index = regions.firstIndex(where: { $0.duration < minimum - epsilon })
    {
      let target: Int
      if index == 0 {
        target = 1
      } else if index == regions.count - 1 {
        target = index - 1
      } else {
        target =
          regions[index - 1].duration >= regions[index + 1].duration ? index - 1 : index + 1
      }
      if target < index {
        regions[target].end = regions[index].end
      } else {
        regions[target].start = regions[index].start
      }
      regions.remove(at: index)
    }
    return regions
  }

  private static func mergeSameLanguage(_ input: [LanguageRegion]) -> [LanguageRegion] {
    var regions: [LanguageRegion] = []
    for region in input {
      if var last = regions.last, last.language == region.language {
        last.end = region.end
        regions[regions.count - 1] = last
      } else {
        regions.append(region)
      }
    }
    return regions
  }

  /// Спикеры региона — по первому появлению их отрезков внутри него.
  private static func assignSpeakers(_ regions: [LanguageRegion], pieces: [Piece])
    -> [LanguageRegion]
  {
    var result = regions
    guard !result.isEmpty else { return result }
    var index = 0
    for piece in pieces {
      let midpoint = (piece.start + piece.end) / 2
      while index < result.count - 1, midpoint >= result[index].end { index += 1 }
      if !result[index].speakerIDs.contains(piece.speakerID) {
        result[index].speakerIDs.append(piece.speakerID)
      }
    }
    return result
  }

  /// Группирует регионы по языку для вызовов ASR; порядок — по убыванию суммарной длительности.
  public static func clips(_ regions: [LanguageRegion]) -> [LanguageClips] {
    var byLanguage: [Language?: [ClosedRange<Double>]] = [:]
    var order: [Language?] = []
    for region in regions where region.duration > epsilon {
      if byLanguage[region.language] == nil { order.append(region.language) }
      byLanguage[region.language, default: []].append(region.range)
    }
    return
      order
      .map { language in
        let ranges = (byLanguage[language] ?? []).sorted { $0.lowerBound < $1.lowerBound }
        return LanguageClips(
          language: language, ranges: ranges,
          seconds: ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) })
      }
      .enumerated()
      .sorted {
        $0.element.seconds == $1.element.seconds
          ? $0.offset < $1.offset : $0.element.seconds > $1.element.seconds
      }
      .map(\.element)
  }
}
