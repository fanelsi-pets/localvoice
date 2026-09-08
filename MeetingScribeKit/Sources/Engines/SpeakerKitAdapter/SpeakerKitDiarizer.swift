import ArgmaxCore
import Core
import Foundation
import SpeakerKit

/// Диаризация через SpeakerKit (pyannote community-1, argmax-oss-swift 1.1.0, MIT).
///
/// Модели держатся внутри актора. Инициализатор ничего не делает: скачивание и загрузка — в `prepare(progress:)`
/// (или лениво при первом вызове `diarize`).
///
/// Пути только через `ModelStore`: `hfBase` — `downloadBase` Hub-раскладки, папка репозитория —
/// `hf/models/argmaxinc/speakerkit-coreml`. Если модели на месте, конфигурация задаёт `modelFolder`,
/// и `PyannoteModelLoader.resolveModels` возвращает путь сразу, не обращаясь к сети
/// (SpeakerKit/Pyannote/PyannoteModelManager.swift:63–68; `ModelManager.downloadModels` тоже пропускает
/// скачивание при заданном `modelFolder`, ArgmaxCore/ModelManager.swift:94–99).
///
/// Внутри модуля имена `Diarizer` и `DiarizationResult` есть и в Core, и в SpeakerKit — Core-типы квалифицируем.
public actor SpeakerKitDiarizer: Core.Diarizer {
  public nonisolated let descriptor: EngineDescriptor

  private let modelStore: ModelStore
  private let verbose: Bool

  private var speakerKit: SpeakerKit?
  /// Общая загрузка для параллельных вызовов: модели грузятся один раз; отмена одного ждущего её не прерывает.
  private let loader = SharedLoader()

  public init(modelStore: ModelStore, verbose: Bool = false) {
    self.modelStore = modelStore
    self.verbose = verbose
    self.descriptor = EngineDescriptor(
      name: "SpeakerKit", model: "pyannote community-1", version: "1.1.0")
  }

  // MARK: - Подготовка моделей

  /// Куда смотреть за моделями. `modelFolder == nil` — моделей нет на диске, нужна сеть.
  struct ModelPlan: Equatable, Sendable {
    /// `downloadBase` в терминах Hub: внутри — `models/<org>/<repo>`.
    var downloadBase: URL
    var repo: String
    /// Локальная папка с `speaker_segmenter/`, `speaker_embedder/`, `speaker_clusterer/`.
    var modelFolder: URL?

    var needsDownload: Bool { modelFolder == nil }
  }

  static func plan(modelStore: ModelStore, fileManager: FileManager = .default) -> ModelPlan {
    ModelPlan(
      downloadBase: modelStore.hfBase,
      repo: ModelID.speakerKitPyannote.hubRepo,
      modelFolder: modelStore.isPresent(.speakerKitPyannote, fileManager: fileManager)
        ? modelStore.directory(for: .speakerKitPyannote) : nil
    )
  }

  /// Конфигурация pyannote. `download: false` даже когда моделей нет: иначе `SpeakerKit.init` скачает их
  /// молча, без прогресса (SpeakerKit.swift:33–35). Флаг включается перед `downloadModels(progressCallback:)`.
  static func configuration(for plan: ModelPlan, verbose: Bool) -> PyannoteConfig {
    PyannoteConfig(
      downloadBase: plan.downloadBase.path,
      modelRepo: plan.repo,
      modelFolder: plan.modelFolder?.path,
      download: false,
      load: false,
      verbose: verbose
    )
  }

  /// Разрешает скачивание перед `downloadModels(progressCallback:)`.
  /// Флаг читается в момент запроса моделей (`PyannoteModelLoader.resolveModels`,
  /// SpeakerKit/Pyannote/PyannoteModelManager.swift:80), поэтому `SpeakerKit.init` остаётся пустым,
  /// а прогресс скачивания — нашим.
  @discardableResult
  static func allowingDownload(_ configuration: PyannoteConfig) -> PyannoteConfig {
    configuration.download = true
    return configuration
  }

  public func prepare(progress: ProgressSink?) async throws {
    _ = try await loadedEngine(progress: progress)
  }

  private func loadedEngine(progress: ProgressSink?) async throws -> SpeakerKit {
    if let speakerKit { return speakerKit }
    do {
      try await loader.load { [self] in try await self.load(progress: progress) }
    } catch {
      throw Self.engineError(
        from: error, fallback: .modelUnavailable(ModelID.speakerKitPyannote.title))
    }
    guard let speakerKit else { throw EngineError.notPrepared(descriptor.name) }
    return speakerKit
  }

  private func load(progress: ProgressSink?) async throws {
    let plan = Self.plan(modelStore: modelStore)
    let configuration = Self.configuration(for: plan, verbose: verbose)
    do {
      let engine = try await SpeakerKit(configuration)
      if plan.needsDownload {
        try modelStore.ensureDirectories()
        Self.allowingDownload(configuration)
        try await download(with: engine, progress: progress)
      }
      try await ProgressHeartbeat.run(
        stage: .modelDownload,
        pulse: String(localized: "Загрузка \(ModelID.speakerKitPyannote.title)"), sink: progress
      ) {
        try await engine.ensureModelsLoaded()
      }
      speakerKit = engine
    } catch {
      throw Self.engineError(
        from: error,
        fallback: .modelUnavailable(
          "\(ModelID.speakerKitPyannote.title) — \(error.localizedDescription)")
      )
    }
  }

  /// Скачивает модели с прогрессом. Hub считает прогресс файлами, а не байтами
  /// (`HubApi.snapshot`, ArgmaxCore/External/Hub/HubApi.swift:657–689), поэтому передаём только долю стадии.
  private func download(with engine: SpeakerKit, progress: ProgressSink?) async throws {
    let sink = progress
    let title = ModelID.speakerKitPyannote.title
    sink?(ProgressEvent(stage: .modelDownload, fractionOfStage: 0, pulse: title))
    if let manager = engine.diarizer as? ModelManager {
      try await manager.downloadModels(progressCallback: { hubProgress in
        sink?(
          ProgressEvent(
            stage: .modelDownload,
            fractionOfStage: hubProgress.fractionCompleted,
            pulse: title
          ))
      })
    } else {
      try await engine.diarizer.downloadModels()
    }
    try Task.checkCancellation()
    sink?(ProgressEvent(stage: .modelDownload, fractionOfStage: 1, pulse: title))
  }

  // MARK: - Диаризация

  /// Делит запись по голосам. Отмену SpeakerKit проверяет сам (`Task.checkCancellation` в пайплайне),
  /// мы её только пробрасываем как `EngineError.cancelled`.
  public func diarize(_ audio: PCMAudio, hints: DiarizationHints, progress: ProgressSink?)
    async throws
    -> Core.DiarizationResult
  {
    guard !audio.isEmpty else {
      throw EngineError.invalidAudio(String(localized: "пустой фрагмент, делить по голосам нечего"))
    }
    let engine = try await loadedEngine(progress: progress)
    let options = SpeakerKitMapping.options(for: hints)
    let totalAudioSeconds = audio.duration
    let sink = progress
    sink?(
      ProgressEvent(
        stage: .diarization, fractionOfStage: 0, totalAudioSeconds: totalAudioSeconds))

    do {
      let result = try await engine.diarize(
        audioArray: audio.samples,
        options: options,
        progressCallback: { diarizationProgress in
          sink?(
            ProgressEvent(
              stage: .diarization,
              fractionOfStage: diarizationProgress.fractionCompleted,
              totalAudioSeconds: totalAudioSeconds
            ))
        }
      )
      try Task.checkCancellation()
      sink?(
        ProgressEvent(
          stage: .diarization, fractionOfStage: 1, totalAudioSeconds: totalAudioSeconds))
      return Core.DiarizationResult(
        turns: SpeakerKitMapping.turns(result.segments),
        speakerCount: result.speakerCount,
        embeddings: result.speakerCentroidEmbeddings
      )
    } catch {
      throw Self.engineError(from: error, fallback: .inferenceFailed(error.localizedDescription))
    }
  }

  // MARK: - Внутреннее

  private static func engineError(from error: any Error, fallback: @autoclosure () -> EngineError)
    -> EngineError
  {
    if let engineError = error as? EngineError { return engineError }
    if error is CancellationError { return .cancelled }
    return fallback()
  }
}
