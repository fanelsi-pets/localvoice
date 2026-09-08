import Core
import FluidAudio
import Foundation

/// Адаптер офлайн-диаризатора FluidAudio 0.15.6 (VBx-порт pyannote community-1, Apache-2.0) — резервный
/// диаризатор рядом со SpeakerKit.
///
/// Внутри модуля имена `Diarizer`, `DiarizationResult`, `DiarizerConfig` есть и в Core, и в FluidAudio,
/// поэтому типы Core квалифицируются явно.
public actor FluidAudioDiarizer: Core.Diarizer {
  public nonisolated let descriptor: EngineDescriptor
  private let modelStore: ModelStore
  /// Загруженные модели: `OfflineDiarizerModels` — Sendable-структура, менеджер создаётся под каждый вызов,
  /// потому что число спикеров задаётся конфигом при создании менеджера.
  private var models: OfflineDiarizerModels?

  public init(modelStore: ModelStore) {
    self.modelStore = modelStore
    self.descriptor = EngineDescriptor(
      name: "FluidAudio", model: "speaker-diarization VBx", version: "0.15.6")
  }

  // MARK: - Подготовка моделей

  /// Скачивает и загружает модели офлайн-диаризатора. `ModelHub` кладёт файлы в
  /// `<переданная папка>/speaker-diarization`, поэтому передаём `fluidBase` — раскладка совпадает
  /// с `ModelID.fluidDiarizer` (`fluid/speaker-diarization`).
  ///
  /// `OfflineDiarizerManager.prepareModels` не принимает `progressHandler` и не отдаёт загруженные модели,
  /// поэтому вызываем тот же `OfflineDiarizerModels.load`, что и он.
  public func prepare(progress: ProgressSink?) async throws {
    guard models == nil else { return }
    try modelStore.ensureDirectories()
    let directory = modelStore.fluidBase
    do {
      // Скачивание отдаёт прогресс, загрузка CoreML — нет: пульс держит стадию живой (SPEC.md §3.7 п. 4).
      models = try await ProgressHeartbeat.run(
        stage: .modelDownload, pulse: String(localized: "Загрузка \(ModelID.fluidDiarizer.title)"),
        sink: progress
      ) {
        try await OfflineDiarizerModels.load(
          from: directory,
          progressHandler: { update in progress?(Self.downloadEvent(update)) }
        )
      }
    } catch {
      throw Self.engineError(
        from: error,
        fallback: .modelUnavailable(
          String(
            localized:
              "FluidAudio speaker-diarization в \(directory.path): \(error.localizedDescription)"))
      )
    }
    progress?(.fraction(.modelDownload, 1))
  }

  // MARK: - Диаризация

  public func diarize(_ audio: PCMAudio, hints: DiarizationHints, progress: ProgressSink?)
    async throws
    -> Core.DiarizationResult
  {
    guard let models else { throw EngineError.notPrepared(descriptor.name) }
    try Self.checkCancellation()
    guard !audio.isEmpty else {
      throw EngineError.invalidAudio(String(localized: "пустой фрагмент аудио"))
    }

    let totalSeconds = audio.duration
    let raw: (segments: [TimedSpeakerSegment], speakerDatabase: [String: [Float]]?)
    do {
      raw = try await Self.process(
        samples: audio.samples,
        models: models,
        config: Self.config(for: hints),
        totalSeconds: totalSeconds,
        progress: progress
      )
    } catch {
      throw Self.engineError(
        from: error, fallback: .inferenceFailed("FluidAudio: \(error.localizedDescription)"))
    }
    try Self.checkCancellation()
    progress?(
      ProgressEvent(stage: .diarization, fractionOfStage: 1, totalAudioSeconds: totalSeconds))
    return Self.result(segments: raw.segments, speakerDatabase: raw.speakerDatabase)
  }

  /// Менеджер FluidAudio — не-Sendable класс, поэтому создаётся и используется целиком внутри одного
  /// неизолированного вызова и наружу не выходит. Результат разбирается на части сразу: имя
  /// `DiarizationResult` занято и в Core, и в FluidAudio, а обратиться к типу библиотеки как
  /// `FluidAudio.DiarizationResult` нельзя — в модуле есть пустая структура с именем `FluidAudio`.
  private static func process(
    samples: [Float],
    models: OfflineDiarizerModels,
    config: OfflineDiarizerConfig,
    totalSeconds: Double,
    progress: ProgressSink?
  ) async throws -> (segments: [TimedSpeakerSegment], speakerDatabase: [String: [Float]]?) {
    let manager = OfflineDiarizerManager(config: config)
    manager.initialize(models: models)
    let result = try await manager.process(
      audio: samples,
      progressCallback: { done, total in
        guard let progress, total > 0 else { return }
        progress(
          ProgressEvent(
            stage: .diarization,
            fractionOfStage: min(max(Double(done) / Double(total), 0), 1),
            totalAudioSeconds: totalSeconds
          )
        )
      }
    )
    return (result.segments, result.speakerDatabase)
  }

  /// Число спикеров ненадёжно определяется автоматически (PLAN.md §4), поэтому подсказки идут в кластеризацию:
  /// `numSpeakers` в FluidAudio перекрывает `min`/`max`.
  static func config(for hints: DiarizationHints) -> OfflineDiarizerConfig {
    var config = OfflineDiarizerConfig.default
    config.clustering.numSpeakers = hints.expectedSpeakers
    config.clustering.minSpeakers = hints.minSpeakers
    config.clustering.maxSpeakers = hints.maxSpeakers
    return config
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

  /// FluidAudio нумерует спикеров строками («S1», «S2»). Числовые строки берём как есть, остальные нумеруем
  /// по порядку первого появления, пропуская номера, уже занятые числовыми идентификаторами.
  static func speakerNumbers(for identifiers: [String]) -> [String: Int] {
    var ordered: [String] = []
    var seen: Set<String> = []
    for identifier in identifiers where seen.insert(identifier).inserted {
      ordered.append(identifier)
    }

    var numbers: [String: Int] = [:]
    var used: Set<Int> = []
    for identifier in ordered {
      guard let value = Int(identifier.trimmingCharacters(in: .whitespaces)) else { continue }
      numbers[identifier] = value
      used.insert(value)
    }

    var next = 0
    for identifier in ordered where numbers[identifier] == nil {
      while used.contains(next) { next += 1 }
      numbers[identifier] = next
      used.insert(next)
    }
    return numbers
  }

  /// Отображение результата FluidAudio в Core без постобработки: склейка осколков и overlap — фаза 1.
  static func result(segments: [TimedSpeakerSegment], speakerDatabase: [String: [Float]]?)
    -> Core.DiarizationResult
  {
    let database = speakerDatabase ?? [:]
    let numbers = speakerNumbers(for: segments.map(\.speakerId) + database.keys.sorted())

    let turns =
      segments
      .map { segment in
        Turn(
          start: Double(segment.startTimeSeconds),
          end: Double(max(segment.startTimeSeconds, segment.endTimeSeconds)),
          speakerID: numbers[segment.speakerId] ?? 0,
          confidence: Double(segment.qualityScore)
        )
      }
      .sorted { ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID) }

    var embeddings: [Int: [Float]] = [:]
    for (identifier, vector) in database {
      guard let number = numbers[identifier] else { continue }
      embeddings[number] = vector
    }

    return Core.DiarizationResult(turns: turns, embeddings: embeddings)
  }

  // MARK: - Вспомогательное

  static func checkCancellation() throws {
    if Task.isCancelled { throw EngineError.cancelled }
  }

  static func engineError(from error: any Error, fallback: EngineError) -> EngineError {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    if let engineError = error as? EngineError { return engineError }
    return fallback
  }
}
