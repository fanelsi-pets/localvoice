import Foundation
import Synchronization

// Родительский прогресс обработки (SPEC.md §3.7): веса стадий в секундах ожидаемой работы, монотонная общая доля,
// собственный учёт секунд аудио для ASR по вызовам, пульс, оценка оставшегося времени и сторож зависания.
//
// Модель:
// - вес стадии — ожидаемые секунды работы по плану; у завершённой стадии это фактическое время, у текущей —
//   max(оценка, уже прошедшее в стадии), поэтому затянувшаяся стадия не даёт полосе «улететь» вперёд;
// - общая доля = Σ вес × доля / Σ вес и никогда не уменьшается (SPEC.md §3.7 п. 3): пересчёт весов меняет
//   только прогноз времени, но не заполненность полосы;
// - `modelDownload` вне взвешенного плана (SPEC.md §3.7 п. 10 — у скачивания свой прогресс в мегабайтах):
//   он показывает стадию, долю стадии, байты и пульс, но не двигает общую долю и не участвует в ETA;
// - ETA — по сглаженной скорости текущей стадии (секунд аудио на секунду работы), для будущих стадий — план
//   с поправкой на отношение фактического времени завершённых стадий к ожидаемому.

/// План стадий: ожидаемая стоимость в секундах работы. `modelDownload` в план не входит (SPEC.md §3.7 п. 10 —
/// у скачивания собственный прогресс), поэтому он не двигает общую долю и не участвует в ETA.
public struct ProgressPlan: Hashable, Sendable {
  public var audioSeconds: Double
  /// Секунд работы на секунду аудио (замеры docs/BENCH-2026-09-02.md и CHANGELOG фазы 0).
  public var rates: [Stage: Double]
  /// Постоянная стоимость стадии в секундах.
  public var fixedSeconds: [Stage: Double]

  /// Взвешенные стадии в порядке выполнения.
  public static let weightedStages: [Stage] = [
    .decoding, .diarization, .languageDetection, .transcription, .fusion, .export,
  ]

  public init(audioSeconds: Double, rates: [Stage: Double], fixedSeconds: [Stage: Double]) {
    self.audioSeconds = max(audioSeconds, 0)
    self.rates = rates
    self.fixedSeconds = fixedSeconds
  }

  /// Стандартный план: turbo — 0.05 с работы на секунду аудио (26x), Parakeet — 0.006.
  public static func standard(audioSeconds: Double, asrRate: Double = 0.05) -> ProgressPlan {
    ProgressPlan(
      audioSeconds: audioSeconds,
      rates: [.decoding: 0.001, .diarization: 0.002, .transcription: asrRate],
      fixedSeconds: [.languageDetection: 6, .fusion: 0.5, .export: 0.5])
  }

  public func estimatedSeconds(for stage: Stage) -> Double {
    (rates[stage] ?? 0) * audioSeconds + (fixedSeconds[stage] ?? 0)
  }

  public var totalEstimatedSeconds: Double {
    Self.weightedStages.reduce(0) { $0 + estimatedSeconds(for: $1) }
  }
}

/// Сторож зависания (SPEC.md §3.7 п. 6).
public enum ProgressHealth: Hashable, Sendable {
  case normal
  /// Событий от движков нет дольше 20 с.
  case slow(sinceSeconds: Double)
  /// Событий нет 3 минуты — предложить отмену и отчёт диагностики.
  case stuck(sinceSeconds: Double)
}

/// Снимок состояния обработки для строки прогресса, тулбара и карточки встречи.
public struct ProgressSnapshot: Hashable, Sendable {
  public var stage: Stage?
  public var stageFraction: Double
  /// Общая доля 0…1; никогда не уменьшается.
  public var overallFraction: Double
  public var timecode: Double?
  public var pulse: String?
  public var processedAudioSeconds: Double?
  public var totalAudioSeconds: Double?
  public var bytesCompleted: Int64?
  public var bytesTotal: Int64?
  public var elapsedSeconds: Double
  /// Появляется после 15 с работы или 10 % прогресса.
  public var estimatedRemainingSeconds: Double?
  public var health: ProgressHealth
  /// Фактическое время завершённых стадий.
  public var completedStages: [Stage: Double]
  /// Секунд с последнего события движков — честная метрика живости, отдельная от снимков по таймеру.
  public var engineEventGapSeconds: Double
  public var maxEngineEventGapSeconds: Double
  public var isFinished: Bool
  public var isCancelled: Bool
  public var failure: String?

  public init(
    stage: Stage? = nil,
    stageFraction: Double = 0,
    overallFraction: Double = 0,
    timecode: Double? = nil,
    pulse: String? = nil,
    processedAudioSeconds: Double? = nil,
    totalAudioSeconds: Double? = nil,
    bytesCompleted: Int64? = nil,
    bytesTotal: Int64? = nil,
    elapsedSeconds: Double = 0,
    estimatedRemainingSeconds: Double? = nil,
    health: ProgressHealth = .normal,
    completedStages: [Stage: Double] = [:],
    engineEventGapSeconds: Double = 0,
    maxEngineEventGapSeconds: Double = 0,
    isFinished: Bool = false,
    isCancelled: Bool = false,
    failure: String? = nil
  ) {
    self.stage = stage
    self.stageFraction = stageFraction
    self.overallFraction = overallFraction
    self.timecode = timecode
    self.pulse = pulse
    self.processedAudioSeconds = processedAudioSeconds
    self.totalAudioSeconds = totalAudioSeconds
    self.bytesCompleted = bytesCompleted
    self.bytesTotal = bytesTotal
    self.elapsedSeconds = elapsedSeconds
    self.estimatedRemainingSeconds = estimatedRemainingSeconds
    self.health = health
    self.completedStages = completedStages
    self.engineEventGapSeconds = engineEventGapSeconds
    self.maxEngineEventGapSeconds = maxEngineEventGapSeconds
    self.isFinished = isFinished
    self.isCancelled = isCancelled
    self.failure = failure
  }

  public static let idle = ProgressSnapshot()

  public var percent: Int { Int((min(max(overallFraction, 0), 1) * 100).rounded(.down)) }

  /// «около 4 минут» — округлённая формулировка (SPEC.md §3.7 п. 5).
  public var remainingDescription: String? {
    estimatedRemainingSeconds.map(ProgressPhrasing.remaining)
  }
}

/// Приёмник событий движков и источник снимков. Состояние под `Mutex`: события приходят с рабочих потоков,
/// снимки читают CLI и главный актор приложения.
public final class ProgressReporter: Sendable {
  public static let slowAfterSeconds: Double = 20
  public static let stuckAfterSeconds: Double = 180
  public static let estimateAfterSeconds: Double = 15
  public static let estimateAfterFraction: Double = 0.1
  /// Коэффициент EMA для скорости стадии и поправки весов.
  public static let smoothing: Double = 0.3
  /// Окно измерения скорости: события живости приходят по 4 раза в секунду и часто без новых секунд аудио,
  /// поэтому мгновенная скорость считается не чаще, чем раз в это время, — иначе EMA уходит в ноль на паузах.
  static let rateWindowSeconds: Double = 2

  private struct State {
    var plan: ProgressPlan?
    var snapshot = ProgressSnapshot.idle
    /// Монотонная доля каждой стадии.
    var stageFractions: [Stage: Double] = [:]
    /// Начало первой взвешенной стадии: от него считается «время работы» (скачивание моделей не в счёт).
    var startedAt: Double?
    var finishedAt: Double?
    var stageStartedAt: [Stage: Double] = [:]
    /// Пропущенные стадии (например, диаризация выключена): вес 0, доля 1.
    var skippedStages: Set<Stage> = []
    /// Последнее событие от движков или стадий (тик таймера сюда не входит).
    var lastEventAt: Double?
    /// Скорость текущей стадии в секундах аудио на секунду работы и точка последнего замера.
    var rateStage: Stage?
    var rate: Double?
    var rateSampledAt: Double?
    var rateProcessed: Double = 0
    /// Поправка ожидания будущих стадий: EMA отношения «фактическое / ожидаемое» по завершённым.
    var correction: Double = 1
    var continuations: [UUID: AsyncStream<ProgressSnapshot>.Continuation] = [:]
  }

  private let state: Mutex<State>
  private let timeSource: @Sendable () -> Double

  /// `timeSource` — монотонные секунды; в тестах подменяется ручными часами.
  public init(plan: ProgressPlan? = nil, timeSource: (@Sendable () -> Double)? = nil) {
    self.state = Mutex(State(plan: plan))
    self.timeSource = timeSource ?? { ProcessInfo.processInfo.systemUptime }
  }

  public func setPlan(_ plan: ProgressPlan) {
    update { state in state.plan = plan }
  }

  public var plan: ProgressPlan? { state.withLock { $0.plan } }

  public var snapshot: ProgressSnapshot { state.withLock { $0.snapshot } }

  /// Приёмник событий движков и стадий.
  public var sink: ProgressSink {
    { [self] event in self.report(event) }
  }

  public func report(_ event: ProgressEvent) {
    update { state in
      let now = timeSource()
      noteEvent(&state, now: now)
      if state.startedAt == nil, event.stage != .modelDownload { state.startedAt = now }
      if state.stageStartedAt[event.stage] == nil { state.stageStartedAt[event.stage] = now }
      state.snapshot.stage = event.stage
      if let fraction = event.estimatedFraction {
        state.stageFractions[event.stage] = max(state.stageFractions[event.stage] ?? 0, fraction)
      }
      if let processed = event.processedAudioSeconds {
        state.snapshot.processedAudioSeconds = max(
          state.snapshot.processedAudioSeconds ?? 0, processed)
      }
      if let total = event.totalAudioSeconds { state.snapshot.totalAudioSeconds = total }
      if let timecode = event.timecode { state.snapshot.timecode = timecode }
      if let pulse = event.pulse, !pulse.isEmpty { state.snapshot.pulse = pulse }
      state.snapshot.bytesCompleted = event.bytesCompleted ?? state.snapshot.bytesCompleted
      state.snapshot.bytesTotal = event.bytesTotal ?? state.snapshot.bytesTotal
      sampleRate(&state, event: event, now: now)
    }
  }

  public func stageStarted(_ stage: Stage) {
    update { state in
      let now = timeSource()
      noteEvent(&state, now: now)
      if state.startedAt == nil, stage != .modelDownload { state.startedAt = now }
      state.stageStartedAt[stage] = now
      state.snapshot.stage = stage
      // Пульс и секунды относятся к стадии: на переходе они обнуляются, чтобы не показывать чужой таймкод.
      state.snapshot.processedAudioSeconds = nil
      state.snapshot.totalAudioSeconds = nil
      state.snapshot.timecode = nil
      state.snapshot.pulse = nil
      state.snapshot.bytesCompleted = nil
      state.snapshot.bytesTotal = nil
      state.rateStage = nil
      state.rate = nil
      state.rateSampledAt = nil
      state.rateProcessed = 0
    }
  }

  public func stageFinished(_ stage: Stage) {
    update { state in
      let now = timeSource()
      noteEvent(&state, now: now)
      state.stageFractions[stage] = 1
      state.skippedStages.remove(stage)
      let started = state.stageStartedAt[stage] ?? now
      let actual = max(now - started, 0)
      state.snapshot.completedStages[stage] = actual
      // Поправка на будущие стадии: во сколько раз стадия оказалась дольше или короче плана.
      if let plan = state.plan, ProgressPlan.weightedStages.contains(stage) {
        let expected = plan.estimatedSeconds(for: stage)
        if expected > 0, actual > 0 {
          state.correction += Self.smoothing * (actual / expected - state.correction)
        }
      }
    }
  }

  /// Стадия не выполняется в этом прогоне (диаризация выключена, движок без выбора языка): вес 0, доля 1 —
  /// полоса не «зависает» на пропущенном куске плана.
  public func stageSkipped(_ stage: Stage) {
    update { state in
      state.skippedStages.insert(stage)
      state.stageFractions[stage] = 1
    }
  }

  public func finish() {
    update { state in
      for stage in ProgressPlan.weightedStages { state.stageFractions[stage] = 1 }
      state.finishedAt = timeSource()
      state.snapshot.isFinished = true
      state.snapshot.overallFraction = 1
      state.snapshot.stageFraction = 1
    }
    closeStreams()
  }

  public func cancel() {
    update { state in
      state.finishedAt = timeSource()
      state.snapshot.isCancelled = true
      state.snapshot.isFinished = true
    }
    closeStreams()
  }

  public func fail(_ message: String) {
    update { state in
      state.finishedAt = timeSource()
      state.snapshot.failure = message
      state.snapshot.isFinished = true
    }
    closeStreams()
  }

  /// Пересчёт по таймеру: прошедшее время, сторож, ETA — снимок обновляется, даже когда движки молчат.
  /// Тик не считается событием движка: пауза в `engineEventGapSeconds` продолжает расти.
  public func tick() {
    update { _ in }
  }

  /// Раз в `interval` зовёт `tick()`. Владелец задачи — тот, кто запускает обработку; отмена — в `defer`.
  public func startHeartbeat(interval: Duration = .seconds(1)) -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else { break }
        self.tick()
        if self.snapshot.isFinished { break }
      }
    }
  }

  /// Поток снимков для одного подписчика; подписчиков может быть несколько (sidebar, тулбар, карточка).
  /// Буфер — только последний снимок: медленный потребитель не копит очередь устаревших значений.
  /// После `finish`/`cancel`/`fail` поток отдаёт финальный снимок и завершается.
  /// `bufferingPolicy` по умолчанию — только последний снимок (потребитель в интерфейсе не копит устаревшие);
  /// `.unbounded` — для журналов и тестов, которым нужны все снимки без потерь.
  public func makeStream(
    bufferingPolicy: AsyncStream<ProgressSnapshot>.Continuation.BufferingPolicy = .bufferingNewest(
      1)
  ) -> AsyncStream<ProgressSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: ProgressSnapshot.self, bufferingPolicy: bufferingPolicy)
    continuation.onTermination = { [weak self] _ in
      self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
    }
    let finalSnapshot: ProgressSnapshot? = state.withLock { state in
      guard !state.snapshot.isFinished else { return state.snapshot }
      state.continuations[id] = continuation
      continuation.yield(state.snapshot)
      return nil
    }
    // `finish()` синхронно зовёт `onTermination`, который берёт тот же мьютекс, — только вне блокировки.
    if let finalSnapshot {
      continuation.yield(finalSnapshot)
      continuation.finish()
    }
    return stream
  }

  // MARK: - Внутреннее

  private func update(_ body: (inout State) -> Void) {
    state.withLock { state in
      body(&state)
      recompute(&state)
      // Снимки уходят подписчикам под тем же мьютексом: иначе два потока опубликуют их в обратном порядке
      // и полоса в интерфейсе откатится назад (SPEC.md §3.7 п. 3).
      for continuation in state.continuations.values { continuation.yield(state.snapshot) }
    }
  }

  private func closeStreams() {
    let continuations = state.withLock { state in
      let values = Array(state.continuations.values)
      state.continuations.removeAll()
      return values
    }
    for continuation in continuations { continuation.finish() }
  }

  /// Отметка события от движка или стадии: интервал живости и его максимум за прогон.
  private func noteEvent(_ state: inout State, now: Double) {
    if let last = state.lastEventAt {
      state.snapshot.maxEngineEventGapSeconds = max(
        state.snapshot.maxEngineEventGapSeconds, now - last)
    }
    state.lastEventAt = now
  }

  /// Мгновенная скорость стадии (секунд аудио на секунду работы) с EMA-сглаживанием.
  private func sampleRate(_ state: inout State, event: ProgressEvent, now: Double) {
    guard event.stage != .modelDownload, let processed = event.processedAudioSeconds else { return }
    if state.rateStage != event.stage {
      state.rateStage = event.stage
      state.rate = nil
      state.rateSampledAt = state.stageStartedAt[event.stage] ?? now
      state.rateProcessed = 0
    }
    let since = state.rateSampledAt ?? now
    let interval = now - since
    guard interval >= Self.rateWindowSeconds else { return }
    let advanced = max(processed - state.rateProcessed, 0)
    let instant = advanced / interval
    state.rate = state.rate.map { $0 + Self.smoothing * (instant - $0) } ?? instant
    state.rateSampledAt = now
    state.rateProcessed = processed
  }

  private func recompute(_ state: inout State) {
    let now = timeSource()
    if let started = state.startedAt {
      state.snapshot.elapsedSeconds = max((state.finishedAt ?? now) - started, 0)
    }
    if let stage = state.snapshot.stage {
      state.snapshot.stageFraction = min(max(state.stageFractions[stage] ?? 0, 0), 1)
    }
    recomputeOverall(&state, now: now)
    recomputeHealth(&state, now: now)
    state.snapshot.estimatedRemainingSeconds = estimateRemaining(state, now: now)
  }

  private func recomputeOverall(_ state: inout State, now: Double) {
    guard state.plan != nil else { return }
    let weights = weights(state, now: now)
    let total = weights.values.reduce(0, +)
    guard total > 0 else { return }
    let done = weights.reduce(0.0) { $0 + $1.value * (state.stageFractions[$1.key] ?? 0) }
    // Монотонность: пересчёт весов меняет прогноз времени, но не заполненность полосы.
    state.snapshot.overallFraction = max(
      state.snapshot.overallFraction, min(max(done / total, 0), 1))
  }

  /// Вес стадии: завершённая — по факту, текущая — max(оценка, прошедшее), остальные — по плану.
  private func weights(_ state: State, now: Double) -> [Stage: Double] {
    guard let plan = state.plan else { return [:] }
    var result: [Stage: Double] = [:]
    for stage in ProgressPlan.weightedStages {
      if state.skippedStages.contains(stage) {
        result[stage] = 0
      } else if let actual = state.snapshot.completedStages[stage] {
        result[stage] = max(actual, 0)
      } else if let started = state.stageStartedAt[stage] {
        result[stage] = max(plan.estimatedSeconds(for: stage), max(now - started, 0))
      } else {
        result[stage] = plan.estimatedSeconds(for: stage)
      }
    }
    return result
  }

  private func recomputeHealth(_ state: inout State, now: Double) {
    guard !state.snapshot.isFinished else {
      state.snapshot.health = .normal
      return
    }
    guard let reference = state.lastEventAt ?? state.startedAt else { return }
    let gap = max(now - reference, 0)
    state.snapshot.engineEventGapSeconds = gap
    state.snapshot.maxEngineEventGapSeconds = max(state.snapshot.maxEngineEventGapSeconds, gap)
    if gap >= Self.stuckAfterSeconds {
      state.snapshot.health = .stuck(sinceSeconds: gap)
    } else if gap >= Self.slowAfterSeconds {
      state.snapshot.health = .slow(sinceSeconds: gap)
    } else {
      state.snapshot.health = .normal
    }
  }

  /// Оставшееся время: текущая стадия по фактической скорости, будущие — по плану с поправкой.
  /// Показывается только после 15 с работы или 10 % прогресса (SPEC.md §3.7 п. 5).
  private func estimateRemaining(_ state: State, now: Double) -> Double? {
    guard let plan = state.plan, !state.snapshot.isFinished else { return nil }
    guard
      state.snapshot.elapsedSeconds >= Self.estimateAfterSeconds
        || state.snapshot.overallFraction >= Self.estimateAfterFraction
    else { return nil }
    guard let current = currentWeightedStage(state),
      let index = ProgressPlan.weightedStages.firstIndex(of: current)
    else { return nil }
    var remaining = remainingOfStage(state, stage: current, plan: plan)
    for stage in ProgressPlan.weightedStages[ProgressPlan.weightedStages.index(after: index)...] {
      guard state.snapshot.completedStages[stage] == nil, !state.skippedStages.contains(stage)
      else { continue }
      remaining += plan.estimatedSeconds(for: stage) * state.correction
    }
    return max(remaining, 0)
  }

  /// Текущая взвешенная стадия: начатая и не завершённая (позже всех начатая), иначе первая незавершённая.
  private func currentWeightedStage(_ state: State) -> Stage? {
    let inFlight = ProgressPlan.weightedStages.filter { stage in
      state.stageStartedAt[stage] != nil && state.snapshot.completedStages[stage] == nil
        && !state.skippedStages.contains(stage)
    }
    if let latest = inFlight.max(by: {
      (state.stageStartedAt[$0] ?? 0) < (state.stageStartedAt[$1] ?? 0)
    }) {
      return latest
    }
    return ProgressPlan.weightedStages.first { stage in
      state.snapshot.completedStages[stage] == nil && !state.skippedStages.contains(stage)
    }
  }

  private func remainingOfStage(_ state: State, stage: Stage, plan: ProgressPlan) -> Double {
    let fraction = min(max(state.stageFractions[stage] ?? 0, 0), 1)
    let byPlan = plan.estimatedSeconds(for: stage) * (1 - fraction)
    guard state.rateStage == stage, let rate = state.rate, rate > 0.001,
      let total = state.snapshot.totalAudioSeconds, total > 0
    else { return byPlan }
    let processed = state.snapshot.processedAudioSeconds ?? 0
    return max(total - processed, 0) / rate
  }
}

/// Собственный учёт секунд аудио для распознавания по вызовам (SPEC.md §3.7 п. 2): `WhisperKit.progress`
/// живёт внутри одного вызова и обнуляется. Позиция на таймлайне из события → накопленная работа
/// (сумма пересечений клипов вызова с `[0, t]`) плюс работа завершённых вызовов; никогда не уменьшается.
public final class AudioProgressAggregator: Sendable {
  private struct State {
    /// Полная работа завершённых вызовов.
    var completedWork: Double = 0
    /// Достигнутая работа каждого вызова, который ещё идёт (вызовов может быть несколько сразу).
    var currentWork: [Int: Double] = [:]
    var completedCalls: Set<Int> = []
  }

  public let totalSeconds: Double
  /// Клипы каждого вызова в порядке вызовов; пустой список — весь файл.
  public let calls: [[ClosedRange<Double>]]
  private let state = Mutex(State())

  public init(totalSeconds: Double, calls: [[ClosedRange<Double>]]) {
    let total = max(totalSeconds, 0)
    self.totalSeconds = total
    self.calls = calls.map { $0.isEmpty ? [0...total] : $0 }
  }

  public func sink(forCall index: Int, base: ProgressSink?) -> ProgressSink {
    { [self] event in
      // Стадии, кроме распознавания, идут как есть: агрегатор считает только секунды аудио ASR.
      guard event.stage == .transcription else {
        base?(event)
        return
      }
      let position = event.timecode ?? event.processedAudioSeconds ?? 0
      let reached = Self.work(in: clips(for: index), upTo: position)
      let work = state.withLock { state -> Double in
        state.currentWork[index] = max(state.currentWork[index] ?? 0, reached)
        return state.completedWork + state.currentWork.values.reduce(0, +)
      }
      base?(
        ProgressEvent(
          stage: .transcription,
          processedAudioSeconds: min(work, totalSeconds),
          totalAudioSeconds: totalSeconds,
          timecode: event.timecode,
          pulse: event.pulse))
    }
  }

  /// Вызов закончился: его клипы засчитываются целиком (последнее событие могло не дойти до конца).
  public func callCompleted(_ index: Int) {
    let seconds = Self.work(in: clips(for: index), upTo: .infinity)
    state.withLock { state in
      guard state.completedCalls.insert(index).inserted else { return }
      state.completedWork += seconds
      state.currentWork[index] = nil
    }
  }

  public var processedSeconds: Double {
    state.withLock { min($0.completedWork + $0.currentWork.values.reduce(0, +), totalSeconds) }
  }

  private func clips(for index: Int) -> [ClosedRange<Double>] {
    calls.indices.contains(index) ? calls[index] : [0...totalSeconds]
  }

  static func work(in ranges: [ClosedRange<Double>], upTo position: Double) -> Double {
    ranges.reduce(0) { $0 + max(0, min($1.upperBound, position) - $1.lowerBound) }
  }
}

/// Округлённая формулировка оставшегося времени (SPEC.md §3.7 п. 5).
public enum ProgressPhrasing {
  public static func remaining(_ seconds: Double) -> String {
    let seconds = max(seconds, 0)
    if seconds < 45 { return String(localized: "меньше минуты") }
    if seconds < 90 { return String(localized: "около минуты") }
    var minutes = Int((seconds / 60).rounded())
    // От десяти минут точность до минуты не нужна и создаёт ложное впечатление точного прогноза.
    if minutes >= 10 { minutes = Int((Double(minutes) / 5).rounded()) * 5 }
    // Минут здесь всегда ≥ 2 и не бывает 21/31/…, поэтому «около N минут» грамматично без форм числа;
    // для других языков формы задаются вариациями String Catalog («около %lld минут»).
    if minutes < 60 { return String(localized: "около \(minutes) минут") }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0
      ? String(localized: "около \(hours) ч") : String(localized: "около \(hours) ч \(rest) мин")
  }

  /// Форма для числительного: 1 — `one`, 2–4 — `few`, остальное — `many` (с учётом 11–14).
  public static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let remainder10 = count % 10
    let remainder100 = count % 100
    if remainder10 == 1, remainder100 != 11 { return one }
    if (2...4).contains(remainder10), !(12...14).contains(remainder100) { return few }
    return many
  }
}
