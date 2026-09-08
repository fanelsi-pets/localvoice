import Foundation

/// Детектор речевой активности для раздельных дорожек Zoom (SPEC.md §2 п. 7, §3.1).
///
/// На дорожке `Audio Record/audio<Имя><цифры>.m4a` говорит один участник, всё остальное время Zoom пишет
/// цифровую тишину, а дорожки выровнены по началу записи. Значит, диаризация не нужна: отрезки речи одной
/// дорожки — это готовые `Turn` с известным спикером, а склеенные регионы — клипы одного вызова ASR
/// (`AsrOptions.clips`; WhisperKit пропускает клип короче 1 с целиком, поэтому минимум региона — 1.2 с).
///
/// Порог адаптивный: шумовой пол — 20-й перцентиль энергии кадров с ненулевым сигналом (цифровые нули
/// в оценку не идут, иначе пол всегда −inf), порог — на `thresholdAboveFloorDB` выше пола, но не ниже
/// `minimumLevelDB`. Сверху порог ограничен уровнем громких кадров минус запас: на дорожке, где ненулевые
/// кадры — сплошная речь без комнатного шума (чистый Zoom-трек, синтетика в тестах), 20-й перцентиль равен
/// уровню речи, и правило «пол + 10 дБ» отрезало бы речь целиком. Ограничение никогда не опускает порог
/// ниже `minimumLevelDB`, поэтому дорожка из одного тихого шума речью не становится.
public enum SpeechActivityDetector {
  public struct Options: Hashable, Sendable {
    /// Кадр анализа, с.
    public var frameSeconds: Double
    /// Порог над шумовым полом (20-й перцентиль энергии кадров), дБ.
    public var thresholdAboveFloorDB: Double
    /// Абсолютный минимум уровня речи, дБFS (цифровая тишина Zoom даёт -inf: порог не может уйти ниже).
    public var minimumLevelDB: Double
    /// Сколько тишины после речи ещё считается речью, с.
    public var hangoverSeconds: Double
    /// Отрезки короче отбрасываются, с.
    public var minimumSpeechSeconds: Double
    /// Паузы короче сливаются, с.
    public var mergeGapSeconds: Double
    /// Запас по краям отрезка, с (не выходит за границы аудио и не создаёт перекрытий соседних отрезков).
    public var paddingSeconds: Double

    public init(
      frameSeconds: Double = 0.02,
      thresholdAboveFloorDB: Double = 10,
      minimumLevelDB: Double = -45,
      hangoverSeconds: Double = 0.3,
      minimumSpeechSeconds: Double = 0.3,
      mergeGapSeconds: Double = 0.3,
      paddingSeconds: Double = 0.15
    ) {
      self.frameSeconds = frameSeconds
      self.thresholdAboveFloorDB = thresholdAboveFloorDB
      self.minimumLevelDB = minimumLevelDB
      self.hangoverSeconds = hangoverSeconds
      self.minimumSpeechSeconds = minimumSpeechSeconds
      self.mergeGapSeconds = mergeGapSeconds
      self.paddingSeconds = paddingSeconds
    }
  }

  /// Уровень цифровой тишины: 20·log10(0) = −inf, в расчётах нужен конечный минимум.
  public static let silenceLevelDB = -160.0

  /// Перцентиль «громких» кадров и запас под ним для верхней границы порога (см. описание типа).
  private static let loudPercentile = 0.95
  private static let loudMarginDB = 12.0
  /// Допуск сравнения секунд: границы кадров считаются в Double.
  private static let epsilon = 1e-9

  /// Отрезок речи на таймлайне дорожки.
  private struct Region {
    var start: Double
    var end: Double
    var duration: Double { end - start }
  }

  // MARK: - Отрезки речи

  /// Отрезки речи одного человека на дорожке → turn'ы со `speakerID`, по времени, без перекрытий.
  /// Границы шире самой речи: конец удлиняется на `hangoverSeconds`, оба края — на `paddingSeconds`
  /// (чтобы ASR не срезал первый и последний звук). Точные границы речи дают опции с нулями.
  public static func turns(in audio: PCMAudio, speakerID: Int, options: Options = Options())
    -> [Turn]
  {
    // Кадр меньше 5 мс не имеет смысла (и превратил бы 3-часовую дорожку в десятки миллионов кадров).
    let frameSize = max(PCMAudio.sampleIndex(forSeconds: max(options.frameSeconds, 0.005)), 1)
    let levels = frameLevels(audio.samples, frameSize: frameSize)
    guard let threshold = threshold(for: levels, options: options) else { return [] }

    let duration = audio.duration
    let frameSeconds = PCMAudio.seconds(forSampleIndex: frameSize)
    var regions = rawRegions(
      levels: levels, threshold: threshold, frameSeconds: frameSeconds, duration: duration)
    // Пауза внутри фразы (вдох, стык слов) не делит речь: сначала склейка, потом отбор по длительности —
    // иначе осколки фразы отсеиваются как щелчки.
    regions = merged(regions, gap: max(options.mergeGapSeconds, 0))
    regions = regions.filter { $0.duration >= options.minimumSpeechSeconds - epsilon }
    guard !regions.isEmpty else { return [] }

    if options.hangoverSeconds > 0 {
      for index in regions.indices {
        regions[index].end = min(regions[index].end + options.hangoverSeconds, duration)
      }
      regions = merged(regions, gap: 0)
    }
    regions = padded(regions, padding: max(options.paddingSeconds, 0), duration: duration)
    return regions.map { Turn(start: $0.start, end: $0.end, speakerID: speakerID) }
  }

  /// Суммарная речь, с.
  public static func speechSeconds(_ turns: [Turn]) -> Double {
    turns.reduce(0) { $0 + max($1.duration, 0) }
  }

  // MARK: - Клипы для ASR

  /// Клипы для ASR: turn'ы, слитые при паузах ≤ `mergeGap`, регионы короче `minimumSeconds` расширяются
  /// до минимума (симметрично, в пределах аудио `duration`) или вливаются в соседа; результат — по времени,
  /// без перекрытий, внутри `0...duration`.
  public static func clipRanges(
    from turns: [Turn], duration: Double, mergeGap: Double = 1.0, minimumSeconds: Double = 1.2
  ) -> [ClosedRange<Double>] {
    guard duration > 0 else { return [] }
    let clamped =
      turns
      .map { Region(start: max($0.start, 0), end: min($0.end, duration)) }
      .filter { $0.duration > epsilon }
      .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    guard !clamped.isEmpty else { return [] }
    var regions = merged(clamped, gap: max(mergeGap, 0))
    regions = expandedToMinimum(regions, minimum: max(minimumSeconds, 0), duration: duration)
    return regions.map { $0.start...$0.end }
  }

  // MARK: - Энергия кадров

  /// RMS каждого кадра в дБFS одним проходом по сэмплам (3-часовая дорожка — 172 M сэмплов, ~537 K кадров).
  private static func frameLevels(_ samples: [Float], frameSize: Int) -> [Double] {
    guard frameSize > 0, !samples.isEmpty else { return [] }
    let count = (samples.count + frameSize - 1) / frameSize
    var levels = [Double](repeating: silenceLevelDB, count: count)
    samples.withUnsafeBufferPointer { input in
      levels.withUnsafeMutableBufferPointer { output in
        for frame in 0..<count {
          let lower = frame * frameSize
          let upper = min(lower + frameSize, input.count)
          var energy = 0.0
          for index in lower..<upper {
            let value = Double(input[index])
            energy += value * value
          }
          guard upper > lower else { continue }
          let rms = (energy / Double(upper - lower)).squareRoot()
          output[frame] = rms > 0 ? max(20 * log10(rms), silenceLevelDB) : silenceLevelDB
        }
      }
    }
    return levels
  }

  /// Порог речи, дБFS; `nil` — все кадры цифровая тишина, речи на дорожке нет.
  private static func threshold(for levels: [Double], options: Options) -> Double? {
    var voiced = levels.filter { $0 > silenceLevelDB }
    guard !voiced.isEmpty else { return nil }
    voiced.sort()
    let floor = percentile(voiced, 0.20)
    let loud = percentile(voiced, loudPercentile)
    let adaptive = max(floor + options.thresholdAboveFloorDB, options.minimumLevelDB)
    return max(min(adaptive, loud - loudMarginDB), options.minimumLevelDB)
  }

  /// Перцентиль отсортированного массива по ближайшему рангу.
  private static func percentile(_ sorted: [Double], _ share: Double) -> Double {
    guard !sorted.isEmpty else { return silenceLevelDB }
    let position = (Double(sorted.count - 1) * min(max(share, 0), 1)).rounded()
    return sorted[min(max(Int(position), 0), sorted.count - 1)]
  }

  // MARK: - Регионы

  /// Подряд идущие кадры выше порога.
  private static func rawRegions(
    levels: [Double], threshold: Double, frameSeconds: Double, duration: Double
  ) -> [Region] {
    var regions: [Region] = []
    var first: Int?
    for (index, level) in levels.enumerated() {
      if level >= threshold {
        if first == nil { first = index }
      } else if let start = first {
        regions.append(
          Region(
            start: Double(start) * frameSeconds, end: min(Double(index) * frameSeconds, duration)))
        first = nil
      }
    }
    if let start = first {
      regions.append(Region(start: Double(start) * frameSeconds, end: duration))
    }
    return regions
  }

  /// Склейка отсортированных регионов, между которыми пауза не больше `gap`.
  private static func merged(_ regions: [Region], gap: Double) -> [Region] {
    var result: [Region] = []
    result.reserveCapacity(regions.count)
    for region in regions {
      if var last = result.last, region.start - last.end <= gap + epsilon {
        last.end = max(last.end, region.end)
        result[result.count - 1] = last
      } else {
        result.append(region)
      }
    }
    return result
  }

  /// Запас по краям: не выходит за `[0, duration]`, а с соседом делит паузу пополам — перекрытий не возникает.
  private static func padded(_ regions: [Region], padding: Double, duration: Double) -> [Region] {
    guard padding > 0, !regions.isEmpty else { return regions }
    return regions.enumerated().map { index, region in
      let lower = index == 0 ? 0 : (regions[index - 1].end + region.start) / 2
      let upper =
        index == regions.count - 1 ? duration : (region.end + regions[index + 1].start) / 2
      return Region(
        start: max(region.start - padding, lower), end: min(region.end + padding, upper))
    }
  }

  /// Регионы короче минимума расширяются симметрично в пределах паузы, а если места нет — вливаются
  /// в ближайшего соседа. Клип короче 1 с WhisperKit пропускает целиком (ADR-003), поэтому коротких быть не должно.
  private static func expandedToMinimum(_ input: [Region], minimum: Double, duration: Double)
    -> [Region]
  {
    guard minimum > 0 else { return input }
    var regions = input
    var index = 0
    while index < regions.count {
      let region = regions[index]
      guard region.duration < minimum - epsilon else {
        index += 1
        continue
      }
      let lower = index == 0 ? 0 : regions[index - 1].end
      let upper = index == regions.count - 1 ? duration : regions[index + 1].start
      let expanded = expanded(region, to: minimum, lower: lower, upper: upper)
      let touchesPrevious = index > 0 && expanded.start <= lower + epsilon
      let touchesNext = index < regions.count - 1 && expanded.end >= upper - epsilon
      if expanded.duration >= minimum - epsilon, !touchesPrevious, !touchesNext {
        regions[index] = expanded
        index += 1
        continue
      }
      let previousGap = index > 0 ? region.start - regions[index - 1].end : .infinity
      let nextGap = index < regions.count - 1 ? regions[index + 1].start - region.end : .infinity
      if index > 0, previousGap <= nextGap {
        regions[index - 1].end = max(regions[index - 1].end, region.end)
        regions.remove(at: index)
        index -= 1
      } else if index < regions.count - 1 {
        regions[index + 1].start = min(regions[index + 1].start, region.start)
        regions.remove(at: index)
      } else {
        // Единственный регион, а вся дорожка короче минимума: отдаём то, что есть.
        regions[index] = expanded
        index += 1
      }
    }
    return regions
  }

  /// Симметричное расширение до `minimum` в пределах `[lower, upper]`.
  private static func expanded(_ region: Region, to minimum: Double, lower: Double, upper: Double)
    -> Region
  {
    let deficit = minimum - region.duration
    guard deficit > 0 else { return region }
    var start = region.start - deficit / 2
    var end = region.end + deficit / 2
    if start < lower {
      end += lower - start
      start = lower
    }
    if end > upper {
      start = max(lower, start - (end - upper))
      end = upper
    }
    return Region(start: start, end: end)
  }
}
