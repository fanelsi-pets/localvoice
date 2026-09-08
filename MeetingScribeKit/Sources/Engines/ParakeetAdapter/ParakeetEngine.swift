import AVFoundation
import Core
import FluidAudio
import Foundation

/// Адаптер Parakeet TDT 0.6B v3 (FluidAudio 0.15.6, Apache-2.0): быстрый режим и «второе мнение» к WhisperKit.
///
/// Языковой параметр FluidAudio не передаётся никогда (docs/DECISIONS.md ADR-002): он включает фильтр токенов
/// по алфавиту, который не различает ru/uk и давит латиницу. Язык в результат кладётся из `options.language`:
/// сама модель языка не знает.
public actor ParakeetEngine: AsrEngine {
  /// Пауза между словами, по которой начинается новый сегмент.
  static let segmentGapSeconds: Double = 0.7
  /// Предел длины сегмента: более длинные куски неудобны и в интерфейсе, и при сшивке со спикерами.
  static let maxSegmentSeconds: Double = 30
  /// Короче этого куска FluidAudio не принимает аудио (`ASRError.invalidAudioData`).
  static let minimumAudioSeconds = ASRConstants.minimumAudioDurationSeconds
  /// Больше этого числа семплов (15 с) FluidAudio отдаёт прогресс в `transcriptionProgressStream`.
  static let progressThresholdSamples = ASRConstants.maxModelSamples

  public nonisolated let descriptor: EngineDescriptor
  private let modelStore: ModelStore
  private var manager: AsrManager?

  public init(modelStore: ModelStore) {
    self.modelStore = modelStore
    self.descriptor = EngineDescriptor(
      name: "Parakeet", model: "parakeet-tdt-0.6b-v3", version: "0.15.6")
  }

  // MARK: - Подготовка моделей

  /// Скачивает модели в `<Models>/fluid/parakeet-tdt-0.6b-v3` и загружает их в `AsrManager`.
  /// Если файлы уже на месте, FluidAudio не ходит в сеть (`AsrModels.modelsExist`).
  public func prepare(progress: ProgressSink?) async throws {
    guard manager == nil else { return }
    try modelStore.ensureDirectories()
    let directory = modelStore.directory(for: .parakeetTDTv3)

    let models: AsrModels
    do {
      // `AsrModels` кладёт файлы в `<родитель directory>/<folderName репозитория>`, а folderName v3 —
      // ровно `parakeet-tdt-0.6b-v3`, поэтому раскладка совпадает с `ModelID.parakeetTDTv3`.
      models = try await AsrModels.downloadAndLoad(
        to: directory,
        version: .v3,
        progressHandler: { update in progress?(Self.downloadEvent(update)) }
      )
    } catch {
      throw Self.engineError(
        from: error,
        fallback: .modelUnavailable(
          String(localized: "Parakeet TDT v3 в \(directory.path): \(error.localizedDescription)"))
      )
    }

    let manager = AsrManager(config: .default)
    do {
      // Загрузка CoreML-моделей идёт без собственных событий — держим стадию живой пульсом (SPEC.md §3.7 п. 4).
      try await ProgressHeartbeat.run(
        stage: .modelDownload, pulse: String(localized: "Загрузка \(ModelID.parakeetTDTv3.title)"),
        sink: progress
      ) {
        try await manager.loadModels(models)
      }
    } catch {
      throw Self.engineError(
        from: error,
        fallback: .modelUnavailable("Parakeet TDT v3: \(error.localizedDescription)")
      )
    }
    self.manager = manager
    progress?(.fraction(.modelDownload, 1))
  }

  // MARK: - Распознавание

  public func detectLanguage(_ audio: PCMAudio) async throws -> LanguageDetection {
    throw EngineError.unsupported(
      String(localized: "Parakeet не определяет язык: у модели нет языкового входа"))
  }

  /// Языка на входе у модели нет (ADR-002): язык по спикеру и клипы по языкам для Parakeet бессмысленны.
  public nonisolated var supportsLanguageSelection: Bool { false }

  /// Клипы (`options.clips`) распознаются по одному вырезанным куском со своим смещением — у FluidAudio
  /// нет аналога `clipTimestamps`; лента `discovered` получает сегменты каждого куска по его завершении.
  public func transcribe(
    _ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?, discovered: SegmentSink?
  ) async throws -> [Segment] {
    guard !options.clips.isEmpty else {
      let segments = try await transcribeWhole(audio, options: options, progress: progress)
      if !segments.isEmpty { discovered?(segments) }
      return segments
    }
    var collected: [Segment] = []
    for clip in options.clips.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      var clipOptions = options
      clipOptions.clips = []
      clipOptions.timeOffset = options.timeOffset + clip.lowerBound
      let segments = try await transcribeWhole(
        audio.slice(from: clip.lowerBound, to: clip.upperBound), options: clipOptions,
        progress: progress)
      if !segments.isEmpty { discovered?(segments) }
      collected.append(contentsOf: segments)
    }
    return collected.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  private func transcribeWhole(_ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?)
    async throws -> [Segment]
  {
    guard let manager else { throw EngineError.notPrepared(descriptor.name) }
    try Self.checkCancellation()
    guard !audio.isEmpty else {
      throw EngineError.invalidAudio(String(localized: "пустой фрагмент аудио"))
    }
    let total = audio.duration
    guard total >= Self.minimumAudioSeconds else { return [] }

    let progressTask = await progressTask(
      manager: manager,
      emitsProgress: audio.sampleCount > Self.progressThresholdSamples,
      totalSeconds: total,
      offset: options.timeOffset,
      progress: progress
    )

    var state = TdtDecoderState.make()
    let result: ASRResult
    do {
      result = try await manager.transcribe(audio.samples, decoderState: &state, language: nil)
    } catch {
      await Self.stop(progressTask)
      throw Self.engineError(
        from: error, fallback: .inferenceFailed("Parakeet: \(error.localizedDescription)"))
    }
    await Self.stop(progressTask)
    try Self.checkCancellation()

    progress?(
      .audio(
        .transcription, processed: total, total: total, timecode: options.timeOffset + total))
    return Self.segments(from: result, options: options, audioDuration: total)
  }

  /// Дисковый режим FluidAudio для больших файлов: память постоянна, аудио читается кусками.
  /// Читается через `AVAudioFile`, поэтому подходят звуковые контейнеры (m4a, wav, mp3); видео — через `Ingest`.
  public func transcribeFile(_ url: URL, options: AsrOptions, progress: ProgressSink?) async throws
    -> [Segment]
  {
    guard let manager else { throw EngineError.notPrepared(descriptor.name) }
    try Self.checkCancellation()
    let total = try Self.duration(of: url)
    guard total >= Self.minimumAudioSeconds else { return [] }

    let progressTask = await progressTask(
      manager: manager,
      emitsProgress: total * Double(PCMAudio.sampleRate) > Double(Self.progressThresholdSamples),
      totalSeconds: total,
      offset: options.timeOffset,
      progress: progress
    )

    var state = TdtDecoderState.make()
    let result: ASRResult
    do {
      result = try await manager.transcribe(url, decoderState: &state, language: nil)
    } catch {
      await Self.stop(progressTask)
      throw Self.engineError(
        from: error, fallback: .inferenceFailed("Parakeet: \(error.localizedDescription)"))
    }
    await Self.stop(progressTask)
    try Self.checkCancellation()

    progress?(
      .audio(
        .transcription, processed: total, total: total, timecode: options.timeOffset + total))
    return Self.segments(from: result, options: options, audioDuration: total)
  }

  // MARK: - Прогресс

  /// Читает `transcriptionProgressStream` в отдельной задаче. Поток живёт один вызов: FluidAudio закрывает его
  /// в `finishSession()`/`failSession()`, поэтому задача завершается сама; `stop` — страховка от зависания.
  private func progressTask(
    manager: AsrManager,
    emitsProgress: Bool,
    totalSeconds: Double,
    offset: Double,
    progress: ProgressSink?
  ) async -> Task<Void, Never>? {
    guard let progress, emitsProgress else { return nil }
    let stream = await manager.transcriptionProgressStream
    return Task {
      var last: Double = 0
      do {
        for try await fraction in stream {
          last = min(max(fraction, last), 1)  // монотонность полосы (SPEC.md §3.7)
          progress(
            .audio(
              .transcription,
              processed: last * totalSeconds,
              total: totalSeconds,
              timecode: offset + last * totalSeconds))
        }
      } catch {
        // Поток закрыт ошибкой или отменой — прогресс больше не нужен, ошибку вернёт сам `transcribe`.
      }
    }
  }

  private static func stop(_ task: Task<Void, Never>?) async {
    guard let task else { return }
    task.cancel()
    await task.value
  }

  static func downloadEvent(_ update: DownloadProgress) -> ProgressEvent {
    ProgressEvent(
      stage: .modelDownload,
      fractionOfStage: min(max(update.fractionCompleted, 0), 1),
      pulse: pulse(for: update.phase)
    )
  }

  /// FluidAudio отдаёт только долю и фазу: байты внутри `ProgressReporter` наружу не выведены.
  static func pulse(for phase: DownloadPhase) -> String {
    switch phase {
    case .listing:
      String(localized: "Список файлов модели")
    case .downloading(let completed, let total):
      String(localized: "Скачивание файлов: \(completed)/\(total)")
    case .compiling(let name):
      String(localized: "Компиляция \(name)")
    }
  }

  // MARK: - Отображение результата

  /// Слова из таймингов токенов: `buildWordTimings` склеивает sentencepiece-куски по маркеру `▁`.
  /// У Parakeet нет вероятности слова — кладём общую уверенность результата.
  static func words(from timings: [TokenTiming], offset: Double, probability: Double?) -> [Word] {
    buildWordTimings(from: timings).map { timing in
      Word(
        start: timing.startTime + offset,
        end: max(timing.startTime, timing.endTime) + offset,
        text: timing.word,
        probability: probability
      )
    }
  }

  /// Режет поток слов на сегменты: пауза длиннее `segmentGapSeconds` или длина больше `maxSegmentSeconds`.
  static func segments(fromWords words: [Word], language: Core.Language?) -> [Segment] {
    var segments: [Segment] = []
    var current: [Word] = []

    func flush() {
      guard let first = current.first, let last = current.last else { return }
      segments.append(
        Segment(
          start: first.start,
          end: max(first.start, last.end),
          text: current.map(\.text).joined(separator: " "),
          language: language,
          words: current
        )
      )
      current = []
    }

    for word in words {
      if let last = current.last, let first = current.first {
        let gap = word.start - last.end
        let length = max(word.end, last.end) - first.start
        if gap > segmentGapSeconds || length > maxSegmentSeconds { flush() }
      }
      current.append(word)
    }
    flush()
    return segments
  }

  /// Полное отображение результата FluidAudio в сегменты Core. Если таймингов нет, а текст есть —
  /// один сегмент на весь переданный кусок (лучше грубый таймкод, чем потерянная речь).
  static func segments(from result: ASRResult, options: AsrOptions, audioDuration: Double)
    -> [Segment]
  {
    let confidence =
      result.confidence.isFinite && result.confidence > 0
      ? Double(result.confidence) : nil
    let words = words(
      from: result.tokenTimings ?? [], offset: options.timeOffset, probability: confidence)
    let segments = segments(fromWords: words, language: options.language)
    if !segments.isEmpty { return segments }

    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    return [
      Segment(
        start: options.timeOffset,
        end: options.timeOffset + audioDuration,
        text: text,
        language: options.language,
        words: []
      )
    ]
  }

  // MARK: - Вспомогательное

  static func duration(of url: URL) throws -> Double {
    do {
      let file = try AVAudioFile(forReading: url)
      return Double(file.length) / file.fileFormat.sampleRate
    } catch {
      throw EngineError.invalidAudio(
        String(
          localized:
            "не удалось прочитать «\(url.lastPathComponent)»: \(error.localizedDescription)"))
    }
  }

  static func checkCancellation() throws {
    if Task.isCancelled { throw EngineError.cancelled }
  }

  static func engineError(from error: any Error, fallback: EngineError) -> EngineError {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    if let engineError = error as? EngineError { return engineError }
    return fallback
  }
}
