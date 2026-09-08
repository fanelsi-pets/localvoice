import Core
import Foundation
import Ingest
import Observation
import Pipeline
import Store

/// Сообщение координатора владельцу библиотеки (`AppModel`): обновлённая запись встречи и готовые транскрипты.
nonisolated public enum ProcessingUpdate: Sendable {
  /// Статус, счётчики, время обработки или длительность изменились — запись нужно сохранить в индекс.
  case recordChanged(MeetingRecord)
  /// Транскрипт сохранён в `LibraryStore` и готов к показу (частичный — после отмены).
  case transcriptReady(meetingID: UUID, transcript: Transcript, isPartial: Bool)
  /// Обработка закончилась (успех, отмена или ошибка) — момент для системного уведомления.
  case finished(MeetingRecord, success: Bool)
}

/// Событие пайплайна для интерфейса. Колбэки `discovered`/`diarized`/`languages` приходят с рабочих потоков
/// движков (и по 1000+ раз на длинной записи), поэтому они только кладут значение в `AsyncStream`, а разбирает
/// поток одна задача координатора на главном акторе — без `Task { @MainActor }` на каждое событие.
nonisolated enum PipelineSignal: Sendable {
  case segments([Segment])
  case diarization(DiarizationResult)
  case languages([SpeakerLanguage])
}

/// Очередь обработки встреч: один прогон за раз (движки тяжёлые, адаптеры сериализуют вызовы сами),
/// остальные ждут с позицией в очереди. Владеет задачей пайплайна и задачами-потребителями снимков
/// прогресса и ленты сегментов, поэтому живёт в `App`, а не во вью: обработка продолжается при закрытом окне
/// (SPEC.md §3.7 п. 8). Все колбэки движков приходят с рабочих потоков и попадают сюда через `AsyncStream`.
@Observable
public final class ProcessingCoordinator {
  public let engines: any EngineProviding
  public let store: LibraryStore
  public let settings: AppSettings

  /// Встреча, которая обрабатывается сейчас.
  public private(set) var activeMeetingID: UUID?
  /// Ожидающие встречи в порядке очереди.
  public private(set) var queue: [UUID] = []
  /// Модели прогресса по встречам: остаются после завершения, чтобы карточка показывала итог.
  public private(set) var progressModels: [UUID: MeetingProgressModel] = [:]

  /// Получатель обновлений — `AppModel`. Вызывается на главном акторе.
  public var onUpdate: ((ProcessingUpdate) -> Void)?

  /// Встреча, поставленная в очередь: запись на момент постановки и имя проекта для шапки экспорта.
  /// Запись остаётся и после завершения — она нужна отчёту диагностики и повторной постановке.
  private struct Job {
    var record: MeetingRecord
    var projectName: String?
    /// Языки-кандидаты маршрутизатора (Settings → «Языки»): язык выбирается по спикеру среди них.
    var candidates: [Language]
  }

  @ObservationIgnored private var jobs: [UUID: Job] = [:]
  /// Единственный воркер очереди: пока он жив, встречи разбираются по одной.
  @ObservationIgnored private var worker: Task<Void, Never>?
  /// Задача текущего прогона — её отменяет «Отменить» (движки и пайплайн укладываются в 2 с).
  @ObservationIgnored private var activeRun: Task<PipelineResult, any Error>?
  @ObservationIgnored private var activeReporter: ProgressReporter?
  /// Сколько сегментов пришло в ленту каждой встречи — число для отчёта диагностики (без текста).
  @ObservationIgnored private var feedCounts: [UUID: Int] = [:]

  /// Закладки доступа к исходникам записей (песочница хоста, ADR-010); `nil` — обычные пути.
  public let sourceBookmarks: SourceBookmarkStore?

  public init(
    engines: any EngineProviding, store: LibraryStore, settings: AppSettings,
    sourceBookmarks: SourceBookmarkStore? = nil
  ) {
    self.engines = engines
    self.store = store
    self.settings = settings
    self.sourceBookmarks = sourceBookmarks
  }

  public var isProcessing: Bool { activeMeetingID != nil }

  public var hasPendingWork: Bool { activeMeetingID != nil || !queue.isEmpty }

  public func progress(for id: UUID) -> MeetingProgressModel? {
    progressModels[id]
  }

  /// Ставит встречу в очередь (или запускает сразу, если очередь пуста). `projectName` — для шапки
  /// экспорта, `candidates` — языки встреч из настроек (по умолчанию — `AppSettings.meetingLanguages`).
  public func enqueue(
    _ record: MeetingRecord, projectName: String? = nil, candidates: [Language]? = nil
  ) {
    // Повторная постановка той, что уже обрабатывается, ничего не меняет: прогон один.
    guard activeMeetingID != record.id else { return }
    var record = record
    record.status = .queued
    jobs[record.id] = Job(
      record: record, projectName: projectName,
      candidates: candidates ?? settings.orderedMeetingLanguages)
    // Новый прогон — новая модель прогресса: итоги прошлого прогона на карточке не смешиваются с текущим.
    progressModels[record.id] = MeetingProgressModel(
      meetingID: record.id, includesDiarization: record.engines.diarizer != nil)
    feedCounts[record.id] = 0
    if !queue.contains(record.id) { queue.append(record.id) }
    updateQueuePositions()
    onUpdate?(.recordChanged(record))
    startWorkerIfNeeded()
  }

  /// Отменяет обработку или убирает из очереди. Отмена срабатывает не дольше 2 с (SPEC.md §3.7 п. 7),
  /// результаты завершённых стадий и сегменты ленты сохраняются частичным транскриптом.
  public func cancel(_ id: UUID) {
    if activeMeetingID == id {
      activeRun?.cancel()
      return
    }
    guard let index = queue.firstIndex(of: id) else { return }
    queue.remove(at: index)
    // Обработка не начиналась: показывать нечего, встреча возвращается в исходное состояние.
    progressModels[id] = nil
    feedCounts[id] = nil
    updateQueuePositions()
    guard var job = jobs[id] else { return }
    job.record.status = .imported
    jobs[id] = job
    onUpdate?(.recordChanged(job.record))
  }

  /// Встреча удалена из библиотеки: снять с очереди и забыть прогон. Если она обрабатывается сейчас,
  /// прогон отменяется, а его итоги (в том числе частичный транскрипт) не сохраняются и не рассылаются —
  /// иначе удалённая встреча «воскресала» бы записью и папкой на диске.
  public func forget(_ id: UUID) {
    if activeMeetingID == id {
      activeRun?.cancel()
    } else if let index = queue.firstIndex(of: id) {
      queue.remove(at: index)
    }
    jobs[id] = nil
    progressModels[id] = nil
    feedCounts[id] = nil
    updateQueuePositions()
  }

  /// «Отменить и собрать отчёт» (сторож 3 мин): пишет отчёт диагностики без аудио в `Diagnostics/`,
  /// затем отменяет. Возвращает путь отчёта.
  public func cancelAndCollectReport(_ id: UUID) async -> URL? {
    var url: URL?
    if let report = makeReport(for: id), let text = try? report.json() {
      url = try? await store.writeDiagnostics(text, fileName: report.fileName)
    }
    cancel(id)
    return url
  }

  /// Отчёт о текущем состоянии обработки (без аудио и текста реплик) — для «Отменить и собрать отчёт»
  /// и пункта Help → Диагностика.
  public func makeReport(for id: UUID) -> DiagnosticsReport? {
    guard let job = jobs[id] else { return nil }
    let model = progressModels[id]
    return DiagnosticsReport(
      appVersion: MeetingScribeUIInfo.version,
      meetingID: id,
      meetingTitle: job.record.title,
      durationSeconds: job.record.duration,
      engines: job.record.engines,
      snapshot: model?.snapshot ?? activeReporter?.snapshot ?? .idle,
      stages: model?.stageChecks ?? [],
      feedSegmentCount: feedCounts[id] ?? 0,
      queuePosition: model?.queuePosition,
      isActive: activeMeetingID == id,
      memory: ProcessMemory.snapshot())
  }

  // MARK: - Очередь

  private func startWorkerIfNeeded() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      while true {
        // Проверка очереди и сброс `worker` идут без await: новая постановка в очередь не может
        // проскользнуть между «очередь пуста» и «воркера больше нет».
        guard let self, let id = self.takeNext() else { break }
        await self.process(id)
      }
      self?.worker = nil
    }
  }

  private func takeNext() -> UUID? {
    guard !queue.isEmpty else { return nil }
    let id = queue.removeFirst()
    updateQueuePositions()
    return id
  }

  /// Позиции в очереди: 1 — следующая на обработку; у активной позиции нет.
  private func updateQueuePositions() {
    for (index, id) in queue.enumerated() {
      progressModels[id]?.setQueuePosition(index + 1)
    }
    if let activeMeetingID { progressModels[activeMeetingID]?.setQueuePosition(nil) }
  }

  // MARK: - Прогон

  private func process(_ id: UUID) async {
    guard var job = jobs[id] else { return }
    job.record.status = .processing
    jobs[id] = job
    activeMeetingID = id
    let model =
      progressModels[id]
      ?? MeetingProgressModel(
        meetingID: id, includesDiarization: job.record.engines.diarizer != nil)
    progressModels[id] = model
    updateQueuePositions()
    onUpdate?(.recordChanged(job.record))

    let reporter = ProgressReporter()
    activeReporter = reporter
    let (signals, continuation) = AsyncStream.makeStream(
      of: PipelineSignal.self, bufferingPolicy: .unbounded)
    let snapshots = reporter.makeStream()

    // Обе задачи живут на главном акторе и владеют своим потоком: событий много, а переходов между
    // акторами — по одному на порцию, а не на каждый колбэк движка.
    let feedTask = Task { [weak self] in
      for await signal in signals {
        switch signal {
        case .segments(let segments):
          model.appendFeed(segments)
          self?.feedCounts[id, default: 0] += segments.count
        case .diarization(let result):
          model.setDiarization(result)
        case .languages(let languages):
          model.setLanguages(languages)
        }
      }
    }
    let snapshotTask = Task {
      for await snapshot in snapshots { model.apply(snapshot) }
    }

    // Песочница хоста: доступ к исходнику по закладке открыт на время прогона (ADR-010).
    let sourceAccess = sourceBookmarks?.access(for: id)
    let run = Task<PipelineResult, any Error> {
      [
        engines, record = job.record, projectName = job.projectName, candidates = job.candidates,
        cache = store.meetingDirectory(for: id)
      ] in
      try await Self.runPipeline(
        engines: engines, record: record, projectName: projectName, candidates: candidates,
        cacheDirectory: cache, reporter: reporter, signals: continuation)
    }
    activeRun = run
    let outcome = await run.result
    sourceAccess?.end()

    // Поток снимков закрывает сам пайплайн (`finish`/`cancel`/`fail`). Если до пайплайна дело не дошло
    // (не удалось создать движок), закрываем его здесь — иначе потребитель ждал бы вечно.
    if !reporter.snapshot.isFinished {
      switch outcome {
      case .success:
        reporter.finish()
      case .failure(let error):
        if Self.isCancellation(error) {
          reporter.cancel()
        } else {
          reporter.fail(error.localizedDescription)
        }
      }
    }
    continuation.finish()
    // Итоговый статус — только после того, как лента и снимки разобраны: иначе карточка покажет «Готово»,
    // пока строки ленты ещё летят.
    await feedTask.value
    await snapshotTask.value

    activeRun = nil
    activeReporter = nil
    // Встреча остаётся активной, пока транскрипт не сохранён и статус не разослан: иначе `hasPendingWork`
    // на мгновение станет ложью и приложение согласится закрыться посреди записи результата.
    await complete(id, outcome: outcome)
    activeMeetingID = nil
    updateQueuePositions()
  }

  /// Запуск пайплайна вне главного актора: `nonisolated static` без изоляции — тело выполняется на общем
  /// исполнителе, главный поток свободен для интерфейса.
  nonisolated private static func runPipeline(
    engines: any EngineProviding,
    record: MeetingRecord,
    projectName: String?,
    candidates: [Language],
    cacheDirectory: URL,
    reporter: ProgressReporter,
    signals: AsyncStream<PipelineSignal>.Continuation
  ) async throws -> PipelineResult {
    let asr = try await engines.asr(for: record.engines)
    let diarizer: (any Diarizer)? =
      record.engines.diarizer == nil ? nil : try await engines.diarizer(for: record.engines)
    let pipeline = MeetingPipeline(decoder: engines.decoder(), asr: asr, diarizer: diarizer)
    var configuration = PipelineConfiguration(
      hints: DiarizationHints(expectedSpeakers: record.expectedSpeakers),
      skipDiarization: record.engines.diarizer == nil,
      language: record.language.language.map(LanguagePolicy.fixed) ?? .perSpeaker,
      meeting: MeetingInfo(title: record.title, date: record.date, project: projectName),
      // Форматы экспорта пустые: приложение рендерит экспорт само, уже с именами спикеров.
      export: ExportOptions(formats: []),
      asrRate: record.engines.asrRate)
    // Языки встреч из настроек (SPEC.md §3.2): между ними маршрутизатор выбирает язык каждого спикера.
    if !candidates.isEmpty { configuration.router.candidates = candidates }
    // Подсказки имён из chat.txt (SPEC.md §3.4) — в транскрипт и для сверки имён дорожек.
    if let chatURL = record.chatURL, let messages = try? ZoomChat.read(chatURL) {
      configuration.nameHints = ZoomChat.participantNames(in: messages)
    }
    // Раздельные дорожки Zoom (SPEC.md §2 п. 7): ASR по дорожкам, имена из файлов, диаризация не нужна.
    let input: PipelineInput
    if record.isMultiTrack {
      let hints = configuration.nameHints.map(\.name)
      input = .tracks(
        record.trackURLs.map { url in
          TrackInput(
            url: url,
            participantName: ZoomTrackName.participantName(
              fromFileName: url.lastPathComponent, hints: hints))
        },
        mix: record.sourceURL)
    } else {
      input = .file(record.sourceURL)
    }
    return try await pipeline.run(
      input: input,
      cacheDirectory: cacheDirectory,
      configuration: configuration,
      reporter: reporter,
      discovered: { signals.yield(.segments($0)) },
      diarized: { signals.yield(.diarization($0)) },
      languages: { signals.yield(.languages($0)) })
  }

  // MARK: - Итоги

  private func complete(_ id: UUID, outcome: Result<PipelineResult, any Error>) async {
    guard var job = jobs[id] else { return }
    switch outcome {
    case .success(let result):
      await save(result.transcript, for: id, job: &job, isPartial: false)
    case .failure(let error):
      if let pipelineError = error as? PipelineError {
        switch pipelineError {
        case .cancelled(let partial):
          job.record.status = .cancelled
          if let transcript = partial.transcript {
            await save(transcript, for: id, job: &job, isPartial: true)
            return
          }
        case .stageFailed(let stage, let underlying):
          job.record.status = .failed(
            stage: stage, message: underlying.localizedDescription)
        }
      } else if Self.isCancellation(error) {
        job.record.status = .cancelled
      } else {
        // Сюда попадает всё, что случилось до пайплайна: например, не удалось создать движок.
        job.record.status = .failed(stage: nil, message: error.localizedDescription)
      }
      finish(id, job: job, success: false)
    }
  }

  /// Сохраняет транскрипт и обновляет сводку записи. Ошибка записи — это ошибка обработки: пользователь
  /// должен узнать, что результата на диске нет.
  private func save(
    _ transcript: Transcript, for id: UUID, job: inout Job, isPartial: Bool
  ) async {
    do {
      try await store.saveTranscript(transcript, for: id)
    } catch {
      job.record.hasTranscript = false
      job.record.status = .failed(stage: .export, message: error.localizedDescription)
      finish(id, job: job, success: false)
      return
    }
    job.record.processingSeconds = transcript.timings.reduce(0) { $0 + $1.seconds }
    job.record.utteranceCount = transcript.utterances.count
    job.record.speakerCount = transcript.speakers.filter { $0.speakerID != nil }.count
    if transcript.audio.duration > 0 { job.record.duration = transcript.audio.duration }
    job.record.hasTranscript = true
    job.record.isPartialTranscript = isPartial
    if isPartial {
      job.record.status = .cancelled
    } else {
      job.record.status = .ready
      job.record.processedAt = Date()
    }
    jobs[id] = job
    onUpdate?(.transcriptReady(meetingID: id, transcript: transcript, isPartial: isPartial))
    finish(id, job: job, success: !isPartial)
  }

  private func finish(_ id: UUID, job: Job, success: Bool) {
    jobs[id] = job
    onUpdate?(.recordChanged(job.record))
    onUpdate?(.finished(job.record, success: success))
  }

  nonisolated private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case .cancelled = error as? EngineError { return true }
    if case .cancelled = error as? IngestError { return true }
    if case .cancelled = error as? PipelineError { return true }
    return false
  }
}
