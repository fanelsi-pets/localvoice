import AVFoundation
import Core
import Foundation
import WhisperKit

/// Распознавание речи через WhisperKit (argmax-oss-swift 1.1.0, MIT).
///
/// Движок держится внутри актора: `WhisperKit` — не `Sendable`-класс. Инициализатор ничего не делает,
/// модели загружаются в `prepare(progress:)` (или лениво при первом вызове).
///
/// Пути только через `ModelStore`: `hfBase` = `downloadBase` Hub-раскладки
/// (`hf/models/argmaxinc/whisperkit-coreml/<variant>`, токенизатор — `hf/models/openai/whisper-large-v3`).
/// Если модель уже лежит в хранилище, конфигурация задаёт `modelFolder`, и `WhisperKit.setupModels`
/// не делает ни одного сетевого запроса.
public actor WhisperKitEngine: AsrEngine {
  public nonisolated let descriptor: EngineDescriptor

  private let modelStore: ModelStore
  private let model: ModelID
  private let verbose: Bool

  private var whisperKit: WhisperKit?
  /// Общая загрузка для параллельных вызовов: модель на 1.6 GB не должна грузиться дважды; отмена одного
  /// ждущего загрузку не прерывает (SharedLoader).
  private let loader = SharedLoader()
  /// Вызовы модели строго по одному (см. `exclusively`); ожидание в очереди отменяемо.
  private let gate = SerialGate()

  public init(modelStore: ModelStore, model: ModelID = .whisperLargeV3Turbo, verbose: Bool = false)
  {
    self.modelStore = modelStore
    self.model = model
    self.verbose = verbose
    self.descriptor = EngineDescriptor(name: "WhisperKit", model: model.rawValue, version: "1.1.0")
  }

  // MARK: - Подготовка моделей

  /// Куда смотреть за моделями. `modelFolder == nil` — модели нет на диске, нужна сеть.
  struct ModelPlan: Equatable, Sendable {
    var variant: String
    var repo: String
    /// `downloadBase` в терминах Hub: внутри — `models/<org>/<repo>/<variant>`.
    var downloadBase: URL
    /// Папка токенизатора: Hub ищет `models/openai/whisper-large-v3/tokenizer.json`
    /// (`ModelUtilities.loadTokenizer`, WhisperKit/Utilities/ModelUtilities.swift:17–66).
    var tokenizerFolder: URL
    /// Локальная папка модели. Задана — сеть не нужна (`WhisperKit.setupModels`, WhisperKit.swift:320–322).
    var modelFolder: URL?
    /// Токенизатор лежит отдельно (`hf/models/openai/whisper-large-v3`); без него WhisperKit докачает его сам.
    var tokenizerPresent: Bool = true

    var needsDownload: Bool { modelFolder == nil }
  }

  static func plan(modelStore: ModelStore, model: ModelID, fileManager: FileManager = .default)
    -> ModelPlan
  {
    ModelPlan(
      variant: model.rawValue,
      repo: model.hubRepo,
      downloadBase: modelStore.hfBase,
      tokenizerFolder: modelStore.hfBase,
      modelFolder: modelStore.isPresent(model, fileManager: fileManager)
        ? modelStore.directory(for: model) : nil,
      tokenizerPresent: modelStore.isPresent(.whisperTokenizer, fileManager: fileManager)
    )
  }

  static func configuration(for plan: ModelPlan, verbose: Bool) -> WhisperKitConfig {
    WhisperKitConfig(
      model: plan.variant,
      downloadBase: plan.downloadBase,
      modelRepo: plan.repo,
      modelFolder: plan.modelFolder?.path,
      tokenizerFolder: plan.tokenizerFolder,
      verbose: verbose,
      logLevel: verbose ? .debug : .none,
      prewarm: false,
      load: true,
      download: plan.needsDownload
    )
  }

  public func prepare(progress: ProgressSink?) async throws {
    _ = try await loadedEngine(progress: progress)
  }

  private func loadedEngine(progress: ProgressSink?) async throws -> WhisperKit {
    if let whisperKit { return whisperKit }
    do {
      try await loader.load { [self] in try await self.load(progress: progress) }
    } catch {
      throw Self.engineError(from: error, fallback: .modelUnavailable(model.title))
    }
    guard let whisperKit else { throw EngineError.notPrepared(descriptor.name) }
    return whisperKit
  }

  private func load(progress: ProgressSink?) async throws {
    var plan = Self.plan(modelStore: modelStore, model: model)
    if plan.needsDownload {
      plan.modelFolder = try await download(plan: plan, progress: progress)
    }
    if !plan.tokenizerPresent {
      progress?(
        ProgressEvent(
          stage: .modelDownload, fractionOfStage: 0,
          pulse: String(localized: "Скачивание \(ModelID.whisperTokenizer.title)")))
    }
    do {
      // Загрузка и (при первом запуске) компиляция CoreML занимает до минут без собственных событий —
      // держим стадию живой пульсом (SPEC.md §3.7 п. 4).
      let configuration = Self.configuration(for: plan, verbose: verbose)
      whisperKit = try await ProgressHeartbeat.run(
        stage: .modelDownload, pulse: String(localized: "Загрузка \(model.title)"), sink: progress
      ) {
        try await WhisperKit(configuration)
      }
    } catch {
      throw Self.engineError(
        from: error,
        fallback: .modelUnavailable("\(model.title) — \(error.localizedDescription)")
      )
    }
  }

  /// Скачивает модель с прогрессом. Hub считает прогресс файлами, а не байтами
  /// (`HubApi.snapshot`, ArgmaxCore/External/Hub/HubApi.swift:657–689), поэтому передаём только долю стадии.
  private func download(plan: ModelPlan, progress: ProgressSink?) async throws -> URL {
    try modelStore.ensureDirectories()
    let sink = progress
    let title = model.title
    sink?(ProgressEvent(stage: .modelDownload, fractionOfStage: 0, pulse: title))
    do {
      let folder = try await WhisperKit.download(
        variant: plan.variant,
        downloadBase: plan.downloadBase,
        useBackgroundSession: false,
        from: plan.repo,
        token: nil,
        progressCallback: { hubProgress in
          sink?(
            ProgressEvent(
              stage: .modelDownload,
              fractionOfStage: hubProgress.fractionCompleted,
              pulse: title
            ))
        }
      )
      try Task.checkCancellation()
      sink?(ProgressEvent(stage: .modelDownload, fractionOfStage: 1, pulse: title))
      return folder
    } catch {
      throw Self.engineError(
        from: error,
        fallback: .modelUnavailable("\(title) — \(error.localizedDescription)")
      )
    }
  }

  // MARK: - Язык

  public func detectLanguage(_ audio: PCMAudio) async throws -> LanguageDetection {
    guard !audio.isEmpty else {
      throw EngineError.invalidAudio(
        String(localized: "пустой фрагмент, определять язык не по чему"))
    }
    return try await exclusively {
      let engine = try await loadedEngine(progress: nil)
      return try await detectLanguage(samples: Self.head(of: audio), engine: engine)
    }
  }

  private func detectLanguage(samples: [Float], engine: WhisperKit) async throws
    -> LanguageDetection
  {
    do {
      // sic: опечатка в API WhisperKit (detectLangauge).
      let detection = try await engine.detectLangauge(audioArray: samples)
      return WhisperKitMapping.languageDetection(
        language: detection.language, probabilities: detection.langProbs)
    } catch {
      throw Self.engineError(
        from: error,
        fallback: .inferenceFailed(
          String(localized: "определение языка: \(error.localizedDescription)")))
    }
  }

  /// Язык обязателен: умолчание WhisperKit (`language = nil`) молча даёт английский.
  private func resolvedLanguage(
    requested: Language?,
    head: @autoclosure () throws -> [Float],
    engine: WhisperKit,
    progress: ProgressSink?
  ) async throws -> Language {
    if let requested, requested.isKnown { return requested }
    progress?(ProgressEvent(stage: .languageDetection, fractionOfStage: 0))
    let detection = try await detectLanguage(samples: try head(), engine: engine)
    guard detection.language.isKnown else {
      throw EngineError.inferenceFailed(String(localized: "не удалось определить язык фрагмента"))
    }
    progress?(
      ProgressEvent(
        stage: .languageDetection, fractionOfStage: 1, pulse: detection.language.code))
    return detection.language
  }

  // MARK: - Распознавание

  public func transcribe(
    _ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?, discovered: SegmentSink?
  ) async throws -> [Segment] {
    guard !audio.isEmpty else { return [] }
    return try await exclusively {
      let engine = try await loadedEngine(progress: progress)
      let language = try await resolvedLanguage(
        requested: options.language, head: Self.head(of: audio), engine: engine, progress: progress)
      let decodeOptions = WhisperKitMapping.decodingOptions(
        language: language, wordTimestamps: options.wordTimestamps, clips: options.clips)
      let tracker = WhisperKitProgressTracker(
        totalAudioSeconds: audio.duration, timeOffset: options.timeOffset)
      let sink = progress
      let offset = options.timeOffset

      // Чанковый путь (`chunkingStrategy: .vad`) берёт только колбэк экземпляра и сам добавляет смещение чанка
      // (WhisperKit.swift:846–852); параметр `segmentCallback` доходит лишь до аудио короче одного окна.
      // Сегменты здесь уже со словами (TranscribeTask.swift:201→260) — это и пульс, и лента для вызывающего:
      // при отмене всё, что успело прийти в `discovered`, остаётся у него (SPEC.md §3.7 п. 7).
      let segmentCallback: SegmentDiscoveryCallback = { segments in
        if let event = tracker.event(for: segments) { sink?(event) }
        if let discovered {
          discovered(WhisperKitMapping.segments(segments, offset: offset, language: language))
        }
      }
      engine.segmentDiscoveryCallback = segmentCallback
      defer { engine.segmentDiscoveryCallback = nil }

      let results: [TranscriptionResult]
      do {
        results = try await withTaskCancellationHandler {
          try await engine.transcribe(
            audioArray: audio.samples,
            audioArrayOffset: 0,
            decodeOptions: decodeOptions,
            callback: { update in
              guard !tracker.isCancelled else { return false }
              if let event = tracker.livenessEvent() { sink?(event) }
              return nil
            },
            segmentCallback: segmentCallback
          )
        } onCancel: {
          tracker.cancel()
        }
      } catch {
        throw Self.engineError(from: error, fallback: .inferenceFailed(error.localizedDescription))
      }

      if tracker.isCancelled { throw EngineError.cancelled }
      sink?(tracker.completionEvent())
      return WhisperKitMapping.segments(results, offset: options.timeOffset)
    }
  }

  /// Распознавание файла силами движка: инкрементальная загрузка, как в замере
  /// `--incremental-loading` (docs/BENCH-2026-09-02.md §2b) — пик памяти не растёт с длиной записи.
  public func transcribeFile(_ url: URL, options: AsrOptions, progress: ProgressSink?) async throws
    -> [Segment]
  {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw EngineError.invalidAudio(String(localized: "файл не найден: \(url.path)"))
    }
    return try await exclusively {
      let engine = try await loadedEngine(progress: progress)
      let language = try await resolvedLanguage(
        requested: options.language, head: try Self.head(ofFileAt: url), engine: engine,
        progress: progress)
      // Инкрементальная загрузка клипы не поддерживает (WhisperKit.swift:1198–1202) — файл целиком.
      let decodeOptions = WhisperKitMapping.decodingOptions(
        language: language, wordTimestamps: options.wordTimestamps)
      let tracker = WhisperKitProgressTracker(
        totalAudioSeconds: Self.duration(ofFileAt: url), timeOffset: options.timeOffset)
      let sink = progress

      // Путь `transcribe(audioPath:)` не принимает segmentCallback: сегменты приходят в колбэк экземпляра
      // (WhisperKit.swift:1060 и 844).
      engine.segmentDiscoveryCallback = { segments in
        if let event = tracker.event(for: segments) { sink?(event) }
      }
      defer { engine.segmentDiscoveryCallback = nil }

      let results: [TranscriptionResult]
      do {
        results = try await withTaskCancellationHandler {
          try await engine.transcribe(
            audioPath: url.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: decodeOptions,
            callback: { update in
              guard !tracker.isCancelled else { return false }
              if let event = tracker.livenessEvent() { sink?(event) }
              return nil
            }
          )
        } onCancel: {
          tracker.cancel()
        }
      } catch {
        throw Self.engineError(from: error, fallback: .inferenceFailed(error.localizedDescription))
      }

      if tracker.isCancelled { throw EngineError.cancelled }
      sink?(tracker.completionEvent())
      return WhisperKitMapping.segments(results, offset: options.timeOffset)
    }
  }

  // MARK: - Очередь вызовов

  /// Вызовы модели идут строго по одному: WhisperKit хранит `segmentDiscoveryCallback` на экземпляре, а чанковый
  /// путь берёт только его — параллельные вызовы затёрли бы колбэк друг у друга (и делили бы один декодер).
  /// Очередь FIFO (`SerialGate`); отмена ждущего вызова срабатывает сразу, не дожидаясь текущего.
  private func exclusively<T>(_ body: () async throws -> T) async throws -> T {
    do {
      try await gate.acquire()
    } catch {
      throw EngineError.cancelled
    }
    do {
      let result = try await body()
      await gate.release()
      return result
    } catch {
      await gate.release()
      throw error
    }
  }

  // MARK: - Внутреннее

  /// Первые 30 секунд — окно, по которому Whisper определяет язык.
  private static func head(of audio: PCMAudio) -> [Float] {
    Array(
      audio.samples.prefix(
        PCMAudio.sampleIndex(forSeconds: WhisperKitMapping.languageDetectionSeconds)))
  }

  private static func head(ofFileAt url: URL) throws -> [Float] {
    do {
      let buffer = try AudioProcessor.loadAudio(
        fromPath: url.path, endTime: WhisperKitMapping.languageDetectionSeconds)
      return AudioProcessor.convertBufferToArray(buffer: buffer)
    } catch {
      throw EngineError.invalidAudio(
        String(
          localized:
            "не удалось прочитать начало «\(url.lastPathComponent)»: \(error.localizedDescription)")
      )
    }
  }

  private static func duration(ofFileAt url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    let sampleRate = file.fileFormat.sampleRate
    guard sampleRate > 0 else { return 0 }
    return Double(file.length) / sampleRate
  }

  private static func engineError(from error: any Error, fallback: @autoclosure () -> EngineError)
    -> EngineError
  {
    if let engineError = error as? EngineError { return engineError }
    if error is CancellationError { return .cancelled }
    return fallback()
  }
}
