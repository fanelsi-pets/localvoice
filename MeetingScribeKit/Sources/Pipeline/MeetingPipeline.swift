import Core
import Export
import Foundation
import Ingest
import Synchronization

/// Как выбирается язык распознавания.
public enum LanguagePolicy: Hashable, Sendable {
  /// Язык каждого спикера определяется по его речи после диаризации (SPEC.md §3.2, ADR-003).
  /// Без диаризации — язык первых 30 секунд записи.
  case perSpeaker
  /// Один язык на всю запись (`--language ru`).
  case fixed(Language)
}

public enum ExportFormat: String, CaseIterable, Hashable, Sendable, Codable {
  case markdown
  case srt
  case json
}

public struct ExportOptions: Hashable, Sendable {
  public var formats: Set<ExportFormat>
  /// Таймкоды с десятыми долями в TranscribeFull.
  public var tenths: Bool
  /// Помечать реплики на наложении речи в TranscribeFull.
  public var markOverlap: Bool

  public init(
    formats: Set<ExportFormat> = Set(ExportFormat.allCases), tenths: Bool = false,
    markOverlap: Bool = false
  ) {
    self.formats = formats
    self.tenths = tenths
    self.markOverlap = markOverlap
  }
}

public struct PipelineConfiguration: Sendable {
  public var hints: DiarizationHints
  public var skipDiarization: Bool
  public var language: LanguagePolicy
  public var router: LanguageRouter.Options
  public var fuser: Fuser.Options
  public var filter: HallucinationFilter.Options
  /// Сведения о встрече; пустые поля дополняются из имени папки Zoom (`MeetingInfo.inferred`).
  public var meeting: MeetingInfo
  public var export: ExportOptions
  /// Ожидаемая стоимость распознавания для плана прогресса: секунд работы на секунду аудио
  /// (turbo — 0.05, Parakeet — 0.006; замеры фазы 0).
  public var asrRate: Double
  /// Подсказки имён (`chat.txt`, OCR) — попадают в `Transcript.nameHints` и сверяются с именами дорожек.
  public var nameHints: [NameHint]
  /// Сколько секунд речи собирать в отпечаток голоса дорожки (0 — отпечатки не снимать, диаризатор не нужен).
  public var voiceSampleSeconds: Double
  /// Параметры детектора речи на раздельных дорожках (`PipelineInput.tracks`).
  public var speechActivity: SpeechActivityDetector.Options

  public init(
    hints: DiarizationHints = .none,
    skipDiarization: Bool = false,
    language: LanguagePolicy = .perSpeaker,
    router: LanguageRouter.Options = LanguageRouter.Options(),
    fuser: Fuser.Options = Fuser.Options(),
    filter: HallucinationFilter.Options = HallucinationFilter.Options(),
    meeting: MeetingInfo = MeetingInfo(),
    export: ExportOptions = ExportOptions(),
    asrRate: Double = 0.05,
    nameHints: [NameHint] = [],
    voiceSampleSeconds: Double = 60,
    speechActivity: SpeechActivityDetector.Options = SpeechActivityDetector.Options()
  ) {
    self.hints = hints
    self.skipDiarization = skipDiarization
    self.language = language
    self.router = router
    self.fuser = fuser
    self.filter = filter
    self.meeting = meeting
    self.export = export
    self.asrRate = asrRate
    self.nameHints = nameHints
    self.voiceSampleSeconds = voiceSampleSeconds
    self.speechActivity = speechActivity
  }
}

/// Итог полного прогона. Файлов пайплайн не пишет: строки экспорта кладёт вызывающий
/// (CLI — на диск, приложение — в `fileExporter` или буфер обмена).
public struct PipelineResult: Sendable {
  public var transcript: Transcript
  public var rendered: [ExportFormat: String]
  public var filterReport: HallucinationFilter.Report
  public var regions: [LanguageRegion]
  /// Максимальный интервал между событиями движков за прогон — честная метрика живости (SPEC.md §7 п. 8).
  public var maxEngineEventGapSeconds: Double
}

/// Результаты завершённых стадий на момент отмены (SPEC.md §3.7 п. 7).
public struct PartialResult: Sendable {
  public var decoded: DecodedAudio?
  public var diarization: DiarizationResult?
  public var speakerLanguages: [SpeakerLanguage] = []
  public var regions: [LanguageRegion] = []
  /// Сегменты, успевшие прийти в ленту `discovered` до отмены, по времени.
  public var segments: [Segment] = []
  public var completedStages: [Stage] = []
  public var timings: [StageTiming] = []
  /// Транскрипт из того, что есть (фильтр и сшивка по имеющимся turn'ам); nil, если сегментов нет.
  public var transcript: Transcript?

  public init() {}
}

public enum PipelineError: Error, LocalizedError {
  case cancelled(partial: PartialResult)
  case stageFailed(Stage, underlying: any Error)

  public var errorDescription: String? {
    switch self {
    case .cancelled(let partial):
      let stages = partial.completedStages.map(\.title).joined(separator: ", ")
      return String(
        localized:
          "Обработка отменена. Сохранены результаты стадий: \(stages.isEmpty ? String(localized: "нет") : stages)."
      )
    case .stageFailed(let stage, let underlying):
      return String(
        localized: "Ошибка на стадии «\(stage.title)»: \(underlying.localizedDescription)")
    }
  }

  public var stage: Stage? {
    if case .stageFailed(let stage, _) = self { return stage }
    return nil
  }
}

/// Продуктовый пайплайн (SPEC.md §3.2–3.5, §3.7): подготовка моделей → декодирование → диаризация →
/// язык по спикеру → распознавание (один вызов на язык с клипами) → фильтр галлюцинаций → сшивка → рендер экспорта.
///
/// Движки приходят через протоколы Core; прогресс — в `ProgressReporter` вызывающего; отмена — отменой задачи:
/// между стадиями проверяется `Task.checkCancellation`, внутри стадий её уважают движки, а всё, что успело прийти
/// в ленту сегментов, возвращается в `PipelineError.cancelled(partial:)`.
public actor MeetingPipeline {
  private let decoder: any AudioDecoding
  private let asr: any AsrEngine
  private let diarizer: (any Diarizer)?

  public init(decoder: any AudioDecoding, asr: any AsrEngine, diarizer: (any Diarizer)?) {
    self.decoder = decoder
    self.asr = asr
    self.diarizer = diarizer
  }

  /// Полный прогон общего трека — обёртка над `run(input:)`; поведение не менялось с фазы 1.
  public func run(
    source: URL,
    cacheDirectory: URL,
    configuration: PipelineConfiguration = PipelineConfiguration(),
    reporter: ProgressReporter,
    discovered: SegmentSink? = nil,
    diarized: (@Sendable (DiarizationResult) -> Void)? = nil,
    languages: (@Sendable ([SpeakerLanguage]) -> Void)? = nil
  ) async throws -> PipelineResult {
    try await run(
      input: .file(source), cacheDirectory: cacheDirectory, configuration: configuration,
      reporter: reporter, discovered: discovered, diarized: diarized, languages: languages)
  }

  /// Полный прогон. `discovered` — лента готовых сегментов для интерфейса (SPEC.md §3.7, карточка встречи);
  /// `diarized` и `languages` отдают результат диаризации и языки спикеров сразу по готовности стадии —
  /// лента может показывать спикеров и язык ещё до сшивки. Все колбэки приходят с рабочих потоков.
  ///
  /// `.tracks` — раздельные дорожки Zoom (SPEC.md §2 п. 7): стадии те же, но стадия `diarization` — это
  /// детектор речи по дорожкам и отпечатки голосов, а распознавание и сшивка идут по каждой дорожке отдельно.
  public func run(
    input: PipelineInput,
    cacheDirectory: URL,
    configuration: PipelineConfiguration = PipelineConfiguration(),
    reporter: ProgressReporter,
    discovered: SegmentSink? = nil,
    diarized: (@Sendable (DiarizationResult) -> Void)? = nil,
    languages: (@Sendable ([SpeakerLanguage]) -> Void)? = nil
  ) async throws -> PipelineResult {
    let heartbeat = reporter.startHeartbeat()
    defer { heartbeat.cancel() }

    let run = RunState(reporter: reporter)
    run.asrDescriptor = asr.descriptor
    run.diarizerDescriptor =
      Self.voiceEngine(diarizer, input: input, configuration: configuration)?
      .descriptor
    let collector = SegmentCollector(forward: discovered)
    do {
      let result: PipelineResult
      switch input {
      case .file(let source):
        result = try await execute(
          source: source, cacheDirectory: cacheDirectory, configuration: configuration, run: run,
          collector: collector, diarized: diarized, languages: languages)
      case .tracks(let tracks, let mix):
        result = try await executeTracks(
          tracks: tracks, mix: mix, cacheDirectory: cacheDirectory, configuration: configuration,
          run: run, collector: collector, diarized: diarized, languages: languages)
      }
      reporter.finish()
      return result
    } catch {
      if Self.isCancellation(error) {
        var partial = run.partial
        partial.segments = collector.snapshot
        partial.transcript =
          partial.segments.isEmpty
          ? nil
          : Self.partialTranscript(
            input: input, configuration: configuration, run: run, collector: collector)
        reporter.cancel()
        throw PipelineError.cancelled(partial: partial)
      }
      if let pipelineError = error as? PipelineError {
        reporter.fail(pipelineError.localizedDescription)
        throw pipelineError
      }
      let stage = run.currentStage ?? .modelDownload
      reporter.fail("\(stage.title): \(error.localizedDescription)")
      throw PipelineError.stageFailed(stage, underlying: error)
    }
  }

  // MARK: - Стадии

  private func execute(
    source: URL,
    cacheDirectory: URL,
    configuration: PipelineConfiguration,
    run: RunState,
    collector: SegmentCollector,
    diarized: (@Sendable (DiarizationResult) -> Void)?,
    languages: (@Sendable ([SpeakerLanguage]) -> Void)?
  ) async throws -> PipelineResult {
    let reporter = run.reporter

    // 0. Модели: вне взвешенного плана (SPEC.md §3.7 п. 10) — только стадия и пульс.
    try await stage(.modelDownload, run: run) {
      try await asr.prepare(progress: reporter.sink)
      if let diarizer, !configuration.skipDiarization {
        try await diarizer.prepare(progress: reporter.sink)
      }
    }

    // 1. План прогресса по длительности из заголовка контейнера, затем декодирование.
    let decoded = try await stage(.decoding, run: run) {
      let probe = try await decoder.probe(source)
      reporter.setPlan(
        .standard(
          audioSeconds: probe.duration > 0 ? probe.duration : Self.unknownDurationSeconds,
          asrRate: configuration.asrRate))
      let decoded = try await decoder.decode(
        source, into: cacheDirectory, progress: reporter.sink)
      if abs(decoded.duration - probe.duration) > 1 {
        reporter.setPlan(
          .standard(audioSeconds: decoded.duration, asrRate: configuration.asrRate))
      }
      return decoded
    }
    run.partial.decoded = decoded
    run.setAudioSeconds(decoded.duration, forLast: .decoding)
    // Чтение кэша в память — внутри стадии: полоса не замирает «между стадиями», отмена проверяется до чтения.
    let pcm = try await stage(.decoding, run: run, audioSeconds: decoded.duration, timed: false) {
      reporter.sink(
        ProgressEvent(
          stage: .decoding, fractionOfStage: 1, totalAudioSeconds: decoded.duration,
          pulse: String(localized: "загрузка аудио в память")))
      return try await decoder.loadPCM(decoded)
    }

    // 2. Диаризация; метки спикеров — по первому появлению, с 1.
    var diarization: DiarizationResult?
    if let diarizer, !configuration.skipDiarization {
      diarization = try await stage(.diarization, run: run, audioSeconds: pcm.duration) {
        try await diarizer.diarize(pcm, hints: configuration.hints, progress: reporter.sink)
          .renumberedByFirstAppearance(startingAt: 1)
      }
      run.partial.diarization = diarization
      if let diarization { diarized?(diarization) }
    } else {
      reporter.stageSkipped(.diarization)
    }

    // 3. Язык по спикеру и регионы одного языка.
    let (speakerLanguages, regions) = try await stage(.languageDetection, run: run) {
      try await routeLanguages(
        diarization: diarization, audio: pcm, configuration: configuration,
        progress: reporter.sink)
    }
    run.partial.speakerLanguages = speakerLanguages
    run.partial.regions = regions
    languages?(speakerLanguages)

    // 4. Распознавание: один вызов на язык; клипы — регионы этого языка; секунды суммирует агрегатор.
    let calls = LanguageRouter.clips(regions)
    let aggregator = AudioProgressAggregator(
      totalSeconds: pcm.duration, calls: calls.map(\.ranges))
    let segments = try await stage(.transcription, run: run, audioSeconds: pcm.duration) {
      var collected: [Segment] = []
      for (index, call) in calls.enumerated() {
        try Task.checkCancellation()
        let wholeFile =
          calls.count == 1 && call.ranges.count == 1
          && call.ranges[0].lowerBound <= 0 && call.ranges[0].upperBound >= pcm.duration - 0.01
        let options = AsrOptions(
          language: call.language, wordTimestamps: true, timeOffset: 0,
          clips: wholeFile ? [] : call.ranges)
        let result = try await asr.transcribe(
          pcm, options: options, progress: aggregator.sink(forCall: index, base: reporter.sink),
          discovered: collector.sink)
        aggregator.callCompleted(index)
        collected.append(contentsOf: result)
      }
      return collected.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    // 5. Фильтр галлюцинаций и сшивка.
    let assembled = try await stage(.fusion, run: run) {
      Self.assemble(
        source: source, configuration: configuration, run: run, segments: segments,
        regions: regions)
    }

    // 6. Рендер экспорта (файлы пишет вызывающий).
    return try await deliver(
      assembled, run: run, configuration: configuration, regions: regions)
  }

  // MARK: - Стадии: раздельные дорожки Zoom

  /// Прогон по раздельным дорожкам (SPEC.md §2 п. 7, скилл zoom-import): дорожки выровнены по началу записи,
  /// на дорожке говорит один участник, остальное — цифровая тишина. Стадии те же, что у общего трека, чтобы
  /// прогресс, карточка встречи и ADR-004 работали без изменений, но `diarization` — это детектор речи по
  /// дорожкам и отпечатки голосов, а распознавание и сшивка идут по каждой дорожке отдельно.
  ///
  /// Память: PCM только одной дорожки за раз на каждой стадии (SPEC.md §4) — WAV перечитывается из кэша.
  private func executeTracks(
    tracks inputs: [TrackInput],
    mix: URL?,
    cacheDirectory: URL,
    configuration: PipelineConfiguration,
    run: RunState,
    collector: SegmentCollector,
    diarized: (@Sendable (DiarizationResult) -> Void)?,
    languages: (@Sendable ([SpeakerLanguage]) -> Void)?
  ) async throws -> PipelineResult {
    let reporter = run.reporter
    guard !inputs.isEmpty else {
      // Дорожек нет — обрабатываем общий трек, как обычный файл.
      guard let mix else {
        throw PipelineError.stageFailed(
          .decoding, underlying: IngestError.noAudioTrack(cacheDirectory))
      }
      return try await execute(
        source: mix, cacheDirectory: cacheDirectory, configuration: configuration, run: run,
        collector: collector, diarized: diarized, languages: languages)
    }
    // Имя участника: из `TrackInput`, иначе из имени файла дорожки со сверкой по подсказкам (`chat.txt`).
    let hintNames = configuration.nameHints.map(\.name)
    run.tracks = inputs.enumerated().map { index, input in
      var input = input
      if input.participantName == nil {
        input.participantName = ZoomTrackName.participantName(
          fromFileName: input.url.lastPathComponent, hints: hintNames)
      }
      return TrackRun(speakerID: index + 1, input: input)
    }
    let count = run.tracks.count
    let embedder = Self.voiceEngine(
      diarizer, input: .tracks(inputs, mix: mix), configuration: configuration)

    // 0. Модели: ASR обязателен, диаризатор — только ради отпечатков голоса (SPEC.md §3.4).
    try await stage(.modelDownload, run: run) {
      try await asr.prepare(progress: reporter.sink)
      if let embedder { try await embedder.prepare(progress: reporter.sink) }
    }

    // 1. Декодирование: каждая дорожка — в `<кэш>/tracks/<номер>/audio16k.wav`; прогресс стадии —
    // суммарные секунды всех дорожек, план — по длительности встречи (максимум по дорожкам).
    try await stage(.decoding, run: run) {
      var probed: [Double] = []
      for track in run.tracks {
        try Task.checkCancellation()
        probed.append(try await decoder.probe(track.url).duration)
      }
      let total = probed.reduce(0, +)
      reporter.setPlan(
        Self.trackPlan(
          meetingSeconds: probed.max() ?? Self.unknownDurationSeconds, trackCount: count,
          speechSeconds: nil, configuration: configuration))
      var processed = 0.0
      for index in run.tracks.indices {
        try Task.checkCancellation()
        let track = run.tracks[index]
        let base = processed
        let title = String(localized: "дорожка \(index + 1)/\(count): \(track.title)")
        let sink: ProgressSink = { event in
          let done = base + (event.processedAudioSeconds ?? 0)
          reporter.report(
            ProgressEvent(
              stage: .decoding, processedAudioSeconds: done, totalAudioSeconds: max(total, done),
              timecode: event.timecode, pulse: title))
        }
        let decoded = try await decoder.decode(
          track.url, into: Self.trackCache(cacheDirectory, index: index + 1), progress: sink)
        run.tracks[index].decoded = decoded
        processed += decoded.duration
      }
    }
    // Длительность встречи — самая длинная дорожка: они выровнены по началу записи.
    let meetingSeconds = run.tracks.map(\.duration).max() ?? 0
    run.partial.decoded = run.tracks.max { $0.duration < $1.duration }?.decoded
    run.setAudioSeconds(meetingSeconds, forLast: .decoding)
    reporter.setPlan(
      Self.trackPlan(
        meetingSeconds: meetingSeconds, trackCount: count, speechSeconds: nil,
        configuration: configuration))

    // 2. Вместо диаризации — отрезки речи на каждой дорожке и отпечаток её голоса.
    let diarization = try await stage(.diarization, run: run, audioSeconds: meetingSeconds) {
      for index in run.tracks.indices {
        try Task.checkCancellation()
        guard let decoded = run.tracks[index].decoded else { continue }
        let pcm = try await decoder.loadPCM(decoded)
        let speakerID = run.tracks[index].speakerID
        let turns = SpeechActivityDetector.turns(
          in: pcm, speakerID: speakerID, options: configuration.speechActivity)
        run.tracks[index].turns = turns
        run.tracks[index].clips = SpeechActivityDetector.clipRanges(
          from: turns, duration: pcm.duration)
        let pulse = Self.trackPulse(run.tracks[index], index: index, count: count)
        reporter.report(
          .fraction(.diarization, Double(index) / Double(count), pulse: pulse))
        if let embedder,
          let probe = MultiTrack.voiceProbe(
            speakerID: speakerID, turns: turns, audio: pcm,
            targetSeconds: configuration.voiceSampleSeconds)
        {
          run.tracks[index].embedding = try await embedder.voiceEmbedding(
            for: probe,
            progress: Self.trackSink(
              reporter.sink, stage: .diarization, index: index, count: count, pulse: pulse))
        }
        reporter.report(
          .fraction(.diarization, Double(index + 1) / Double(count), pulse: pulse))
      }
      return DiarizationResult(
        turns: run.tracks.flatMap(\.turns).sorted {
          ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID)
        },
        speakerCount: count,
        embeddings: Dictionary(
          run.tracks.compactMap { track in track.embedding.map { (track.speakerID, $0) } },
          uniquingKeysWith: { first, _ in first }))
    }
    run.partial.diarization = diarization
    diarized?(diarization)
    // Речь известна — распознавание стоит по клипам, а не по всей встрече.
    let clipSeconds = run.tracks.reduce(0) { $0 + $1.clipSeconds }
    reporter.setPlan(
      Self.trackPlan(
        meetingSeconds: meetingSeconds, trackCount: count, speechSeconds: clipSeconds,
        configuration: configuration))

    // 3. Язык каждой дорожки: дорожка — один спикер, поэтому маршрутизация идёт по её собственной речи.
    let (speakerLanguages, regions) = try await stage(.languageDetection, run: run) {
      try await routeTrackLanguages(
        run: run, configuration: configuration, progress: reporter.sink)
    }
    run.partial.speakerLanguages = speakerLanguages
    run.partial.regions = regions
    languages?(speakerLanguages)

    // 4. Распознавание: один вызов на дорожку с её языком и клипами; дорожка без речи пропускается.
    let callable = run.tracks.filter { !$0.clips.isEmpty }
    let aggregator = AudioProgressAggregator(
      totalSeconds: clipSeconds, calls: callable.map(\.clips))
    let segmentsByTrack = try await stage(
      .transcription, run: run, audioSeconds: clipSeconds
    ) {
      var collected: [Int: [Segment]] = [:]
      for (call, track) in callable.enumerated() {
        try Task.checkCancellation()
        guard let decoded = track.decoded else { continue }
        let pcm = try await decoder.loadPCM(decoded)
        let options = AsrOptions(
          language: track.language, wordTimestamps: true, timeOffset: 0, clips: track.clips)
        let segments = try await asr.transcribe(
          pcm, options: options,
          progress: aggregator.sink(forCall: call, base: reporter.sink),
          discovered: collector.sink(forTrack: track.speakerID))
        aggregator.callCompleted(call)
        collected[track.speakerID] = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
      }
      return collected
    }

    // 5. Фильтр галлюцинаций и сшивка — по каждой дорожке отдельно, затем слияние реплик по времени.
    let assembled = try await stage(.fusion, run: run) {
      let result = MultiTrack.assemble(
        tracks: run.tracks, segmentsByTrack: segmentsByTrack, mix: mix, duration: meetingSeconds,
        configuration: configuration, engines: run.engineInfo,
        speakerLanguages: speakerLanguages, regions: regions, timings: run.timings,
        createdAt: Self.wholeSeconds(Date()))
      return Assembled(transcript: result.transcript, report: result.report)
    }

    // 6. Рендер экспорта (файлы пишет вызывающий).
    return try await deliver(
      assembled, run: run, configuration: configuration, regions: regions)
  }

  /// Язык каждой дорожки. `.fixed` — как на общем треке (без единого вызова детекции); движок без выбора
  /// языка — `unsupported`; иначе `LanguageRouter.route` по речи самой дорожки.
  private func routeTrackLanguages(
    run: RunState, configuration: PipelineConfiguration, progress: ProgressSink?
  ) async throws -> ([SpeakerLanguage], [LanguageRegion]) {
    let count = run.tracks.count
    if case .fixed(let language) = configuration.language {
      for index in run.tracks.indices { run.tracks[index].language = language }
      progress?(
        .fraction(.languageDetection, 1, pulse: String(localized: "язык задан: \(language.code)")))
      return (
        run.tracks.map {
          SpeakerLanguage(
            speakerID: $0.speakerID, language: language, confidence: 1, probeSeconds: 0,
            method: .forced)
        }, MultiTrack.regions(run.tracks)
      )
    }
    guard asr.supportsLanguageSelection else {
      progress?(
        .fraction(.languageDetection, 1, pulse: String(localized: "движок без выбора языка")))
      return (
        run.tracks.map {
          SpeakerLanguage(
            speakerID: $0.speakerID, language: .unknown, confidence: 0, probeSeconds: 0,
            method: .unsupported)
        }, MultiTrack.regions(run.tracks)
      )
    }

    var languages: [SpeakerLanguage] = []
    for index in run.tracks.indices {
      try Task.checkCancellation()
      let track = run.tracks[index]
      guard !track.turns.isEmpty, let decoded = track.decoded else { continue }
      let pcm = try await decoder.loadPCM(decoded)
      let routed = try await LanguageRouter.route(
        diarization: DiarizationResult(turns: track.turns), audio: pcm, engine: asr,
        options: configuration.router,
        progress: Self.trackSink(
          progress, stage: .languageDetection, index: index, count: count,
          pulse: Self.trackPulse(track, index: index, count: count)))
      languages.append(contentsOf: routed)
      run.tracks[index].language = routed.first { $0.speakerID == track.speakerID }?.language
    }
    progress?(.fraction(.languageDetection, 1))
    return (languages.sorted { $0.speakerID < $1.speakerID }, MultiTrack.regions(run.tracks))
  }

  /// Рендер экспорта и итог прогона — общий хвост обоих режимов. JSON рендерится последним: он содержит
  /// время стадии экспорта и итоговый пик памяти.
  private func deliver(
    _ assembled: Assembled, run: RunState, configuration: PipelineConfiguration,
    regions: [LanguageRegion]
  ) async throws -> PipelineResult {
    var rendered = try await stage(.export, run: run) {
      try Self.render(
        assembled.transcript,
        options: ExportOptions(
          formats: configuration.export.formats.subtracting([.json]),
          tenths: configuration.export.tenths, markOverlap: configuration.export.markOverlap))
    }
    var transcript = assembled.transcript
    transcript.timings = run.timings
    transcript.peakMemoryBytes = ProcessMemory.snapshot()?.peakResidentBytes
    if configuration.export.formats.contains(.json) {
      rendered[.json] = String(decoding: try TranscriptJSON.encode(transcript), as: UTF8.self)
    }
    return PipelineResult(
      transcript: transcript,
      rendered: rendered,
      filterReport: assembled.report,
      regions: regions,
      maxEngineEventGapSeconds: run.reporter.snapshot.maxEngineEventGapSeconds)
  }

  /// Язык каждого спикера и регионы одного языка по политике.
  private func routeLanguages(
    diarization: DiarizationResult?,
    audio: PCMAudio,
    configuration: PipelineConfiguration,
    progress: ProgressSink?
  ) async throws -> ([SpeakerLanguage], [LanguageRegion]) {
    let turns = diarization?.turns ?? []
    let speakerIDs = diarization?.speakerIDs ?? []
    let duration = audio.duration

    if !asr.supportsLanguageSelection {
      progress?(
        .fraction(.languageDetection, 1, pulse: String(localized: "движок без выбора языка")))
      let languages = speakerIDs.map {
        SpeakerLanguage(
          speakerID: $0, language: .unknown, confidence: 0, probeSeconds: 0, method: .unsupported)
      }
      return (
        languages, Self.singleRegion(duration: duration, language: nil, speakerIDs: speakerIDs)
      )
    }

    if case .fixed(let language) = configuration.language {
      progress?(
        .fraction(.languageDetection, 1, pulse: String(localized: "язык задан: \(language.code)")))
      let languages = speakerIDs.map {
        SpeakerLanguage(
          speakerID: $0, language: language, confidence: 1, probeSeconds: 0, method: .forced)
      }
      return (
        languages, Self.singleRegion(duration: duration, language: language, speakerIDs: speakerIDs)
      )
    }

    guard let diarization, !turns.isEmpty else {
      // Без диаризации — язык первых 30 с, иначе язык по умолчанию.
      progress?(.fraction(.languageDetection, 0))
      let language: Language
      let detection: LanguageDetection?
      do {
        detection = try await asr.detectLanguage(audio.slice(from: 0, to: 30))
      } catch {
        // Отмена пробрасывается; прочие ошибки детекции — язык по умолчанию.
        if Self.isCancellation(error) { throw error }
        detection = nil
      }
      if let detection,
        case .confident(let detected, _) = LanguageRouter.decide(
          detection, options: configuration.router)
      {
        language = detected
      } else {
        language = configuration.router.fallback ?? .ru
      }
      progress?(
        .fraction(.languageDetection, 1, pulse: String(localized: "язык записи: \(language.code)")))
      return ([], Self.singleRegion(duration: duration, language: language, speakerIDs: []))
    }

    let languages = try await LanguageRouter.route(
      diarization: diarization, audio: audio, engine: asr, options: configuration.router,
      progress: progress)
    let byID = Dictionary(languages.map { ($0.speakerID, $0.language) }) { first, _ in first }
    let regions = LanguageRouter.regions(
      turns: turns, languages: byID, duration: duration, options: configuration.router)
    return (languages, regions)
  }

  private static func singleRegion(duration: Double, language: Language?, speakerIDs: [Int])
    -> [LanguageRegion]
  {
    [LanguageRegion(start: 0, end: max(duration, 0), language: language, speakerIDs: speakerIDs)]
  }

  // MARK: - Дорожки: вспомогательное

  /// Диаризатор, который будет использован в этом прогоне: на общем треке — для разделения по голосам,
  /// на дорожках — только ради отпечатков голоса (`voiceSampleSeconds > 0`). `nil` — стадия его не зовёт
  /// и в `Transcript.engines.diarizer` он не попадает (тогда `embeddingSpace` пуст, и это правильно).
  static func voiceEngine(
    _ diarizer: (any Diarizer)?, input: PipelineInput, configuration: PipelineConfiguration
  ) -> (any Diarizer)? {
    guard let diarizer, !configuration.skipDiarization else { return nil }
    if case .tracks = input, configuration.voiceSampleSeconds <= 0 { return nil }
    return diarizer
  }

  /// План прогресса для дорожек (ADR-004): `speechSeconds` нет до детектора речи — до него распознавание
  /// оценивается по длительности встречи (суммарная речь всех дорожек примерно равна ей).
  static func trackPlan(
    meetingSeconds: Double, trackCount: Int, speechSeconds: Double?,
    configuration: PipelineConfiguration
  ) -> ProgressPlan {
    let seconds = meetingSeconds > 0 ? meetingSeconds : unknownDurationSeconds
    return MultiTrack.plan(
      meetingSeconds: seconds,
      trackCount: trackCount,
      speechSeconds: speechSeconds ?? seconds,
      voiceSampleSeconds: configuration.skipDiarization ? 0 : configuration.voiceSampleSeconds,
      asrRate: configuration.asrRate)
  }

  /// Кэш дорожки: `<кэш встречи>/tracks/<номер с 1>/audio16k.wav` (папку создаёт декодер).
  static func trackCache(_ cacheDirectory: URL, index: Int) -> URL {
    cacheDirectory
      .appending(path: "tracks", directoryHint: .isDirectory)
      .appending(path: "\(index)", directoryHint: .isDirectory)
  }

  /// Пульс дорожки: «дорожка 2/5: Іван Мінін · речь 12 мин» (SPEC.md §3.7 п. 4).
  static func trackPulse(_ track: TrackRun, index: Int, count: Int) -> String {
    let minutes = Int((track.speechSeconds / 60).rounded())
    let speech =
      track.turns.isEmpty
      ? String(localized: "речи нет")
      : (minutes >= 1
        ? String(localized: "речь \(minutes) мин")
        : String(localized: "речь \(Int(track.speechSeconds.rounded())) с"))
    return String(localized: "дорожка \(index + 1)/\(count): \(track.title) · \(speech)")
  }

  /// Прогресс подстадии одной дорожки: доля стадии — `(номер дорожки + доля подстадии) / число дорожек`.
  /// Иначе события движка внутри первой же дорожки выставили бы стадию в 100 %.
  static func trackSink(
    _ base: ProgressSink?, stage: Stage, index: Int, count: Int, pulse: String?
  ) -> ProgressSink {
    { event in
      guard let base else { return }
      guard event.stage == stage else {
        base(event)
        return
      }
      let share = (Double(index) + (event.estimatedFraction ?? 0)) / Double(max(count, 1))
      base(
        ProgressEvent(
          stage: stage, fractionOfStage: min(max(share, 0), 1), timecode: event.timecode,
          pulse: event.pulse ?? pulse))
    }
  }

  // MARK: - Сборка

  private struct Assembled {
    var transcript: Transcript
    var report: HallucinationFilter.Report
  }

  /// Транскрипт из того, что успело прийти к моменту отмены (SPEC.md §3.7 п. 7): на дорожках сегменты
  /// приходят в ленту с номером дорожки, поэтому сшивка идёт той же функцией, что и в полном прогоне.
  private static func partialTranscript(
    input: PipelineInput, configuration: PipelineConfiguration, run: RunState,
    collector: SegmentCollector
  ) -> Transcript {
    switch input {
    case .tracks(_, let mix) where !run.tracks.isEmpty:
      return MultiTrack.assemble(
        tracks: run.tracks, segmentsByTrack: collector.byTrack, mix: mix,
        duration: run.tracks.map(\.duration).max() ?? 0,
        configuration: configuration, engines: run.engineInfo,
        speakerLanguages: run.partial.speakerLanguages, regions: run.partial.regions,
        timings: run.timings, createdAt: wholeSeconds(Date())
      ).transcript
    case .tracks(let tracks, let mix):
      let source = mix ?? tracks.first?.url ?? URL(fileURLWithPath: "/")
      return assemble(
        source: source, configuration: configuration, run: run, segments: collector.snapshot,
        regions: run.partial.regions
      ).transcript
    case .file(let source):
      return assemble(
        source: source, configuration: configuration, run: run, segments: collector.snapshot,
        regions: run.partial.regions
      ).transcript
    }
  }

  /// Фильтр галлюцинаций → сшивка → транскрипт. Используется и для частичного результата при отмене.
  private static func assemble(
    source: URL,
    configuration: PipelineConfiguration,
    run: RunState,
    segments: [Segment],
    regions: [LanguageRegion]
  ) -> Assembled {
    let turns = run.partial.diarization?.turns ?? []
    // Отпечатки голосов — центроиды диаризации с весом в секундах речи (фаза 3, SPEC.md §3.4).
    let embeddings: [SpeakerEmbedding] = (run.partial.diarization?.embeddings ?? [:])
      .map { speakerID, vector in
        SpeakerEmbedding(
          speakerID: speakerID, vector: vector,
          speechSeconds: run.partial.diarization?.speechSeconds(for: speakerID) ?? 0)
      }
      .sorted { $0.speakerID < $1.speakerID }
    let report = HallucinationFilter.filter(
      segments, turns: turns.isEmpty ? nil : turns, options: configuration.filter)
    let utterances = Fuser.fuse(segments: report.kept, turns: turns, options: configuration.fuser)
    let decoded = run.partial.decoded
    // Даты — до целых секунд: JSON кодирует их в ISO 8601 без долей, round-trip должен давать равную структуру.
    var meeting = configuration.meeting.filling(missingFrom: MeetingInfo.inferred(from: source))
    meeting.date = meeting.date.map(Self.wholeSeconds)
    let transcript = Transcript(
      createdAt: Self.wholeSeconds(Date()),
      meeting: meeting,
      audio: AudioInfo(
        sourceURL: source, fileName: source.lastPathComponent,
        duration: decoded?.duration ?? (segments.map(\.end).max() ?? 0)),
      engines: EngineInfo(
        asr: run.asrDescriptor ?? EngineDescriptor(name: "—"),
        diarizer: run.diarizerDescriptor),
      utterances: utterances,
      turns: turns,
      speakerLanguages: run.partial.speakerLanguages,
      timings: run.timings,
      peakMemoryBytes: ProcessMemory.snapshot()?.peakResidentBytes,
      diagnostics: TranscriptDiagnostics(
        dropped: report.dropped, regions: regions, noSpeechEvidence: report.noSpeechEvidence),
      speakerEmbeddings: embeddings)
    return Assembled(transcript: transcript, report: report)
  }

  private static func render(_ transcript: Transcript, options: ExportOptions) throws
    -> [ExportFormat: String]
  {
    var rendered: [ExportFormat: String] = [:]
    for format in options.formats {
      switch format {
      case .markdown:
        rendered[format] = TranscribeFullExporter.render(
          transcript,
          options: TranscribeFullOptions(tenths: options.tenths, markOverlap: options.markOverlap))
      case .srt:
        rendered[format] = SRTExporter.render(transcript)
      case .json:
        rendered[format] = String(decoding: try TranscriptJSON.encode(transcript), as: UTF8.self)
      }
    }
    return rendered
  }

  // MARK: - Внутреннее

  /// Длительность для плана, пока контейнер её не сообщил: час — порядок типичной встречи.
  static let unknownDurationSeconds: Double = 3600

  static func wholeSeconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
  }

  static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case .cancelled = error as? EngineError { return true }
    if case .cancelled = error as? IngestError { return true }
    if case .cancelled = error as? PipelineError { return true }
    return false
  }

  /// Состояние одного прогона: стадии, тайминги, частичные результаты. Живёт внутри актора.
  private final class RunState {
    let reporter: ProgressReporter
    var partial = PartialResult()
    var timings: [StageTiming] = []
    var currentStage: Stage?
    var asrDescriptor: EngineDescriptor?
    var diarizerDescriptor: EngineDescriptor?
    /// Раздельные дорожки прогона; пусто — обрабатывается общий трек.
    var tracks: [TrackRun] = []

    init(reporter: ProgressReporter) {
      self.reporter = reporter
    }

    var engineInfo: EngineInfo {
      EngineInfo(asr: asrDescriptor ?? EngineDescriptor(name: "—"), diarizer: diarizerDescriptor)
    }

    func setAudioSeconds(_ seconds: Double, forLast stage: Stage) {
      guard let index = timings.lastIndex(where: { $0.stage == stage }) else { return }
      timings[index].audioSeconds = seconds
      partial.timings = timings
    }
  }

  /// Стадия с отчётом о начале/конце, замером времени и записью в завершённые.
  /// `timed: false` — продолжение уже завершённой стадии (та же стадия в снимке, время добавляется к ней).
  private func stage<T>(
    _ stage: Stage, run: RunState, audioSeconds: Double? = nil, timed: Bool = true,
    _ body: () async throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    run.currentStage = stage
    if timed { run.reporter.stageStarted(stage) }
    let clock = ContinuousClock()
    let started = clock.now
    let result = try await body()
    let elapsed = clock.now - started
    let seconds =
      Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    if timed {
      run.timings.append(StageTiming(stage: stage, seconds: seconds, audioSeconds: audioSeconds))
      run.partial.completedStages.append(stage)
      run.reporter.stageFinished(stage)
    } else if let index = run.timings.lastIndex(where: { $0.stage == stage }) {
      run.timings[index].seconds += seconds
    }
    run.partial.timings = run.timings
    return result
  }
}

/// Копит сегменты из ленты движка (колбэки приходят с рабочих потоков) и пробрасывает их наружу.
/// В режиме дорожек сегменты помечаются номером дорожки: при отмене сшивка идёт по дорожкам,
/// а не по одному общему списку, иначе слово на наложении речи уйдёт чужому спикеру.
final class SegmentCollector: Sendable {
  /// Ключ общего трека: дорожки нумеруются с 1.
  static let mixTrack = 0

  private let storage = Mutex<[Int: [Segment]]>([:])
  private let forward: SegmentSink?

  init(forward: SegmentSink?) {
    self.forward = forward
  }

  var sink: SegmentSink { sink(forTrack: Self.mixTrack) }

  func sink(forTrack track: Int) -> SegmentSink {
    { [self] segments in
      self.storage.withLock { $0[track, default: []].append(contentsOf: segments) }
      self.forward?(segments)
    }
  }

  /// Все собранные сегменты по времени.
  var snapshot: [Segment] {
    storage.withLock {
      $0.values.flatMap { $0 }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }
  }

  /// Сегменты по дорожкам, каждая — по времени.
  var byTrack: [Int: [Segment]] {
    storage.withLock { $0.mapValues { $0.sorted { ($0.start, $0.end) < ($1.start, $1.end) } } }
  }
}
