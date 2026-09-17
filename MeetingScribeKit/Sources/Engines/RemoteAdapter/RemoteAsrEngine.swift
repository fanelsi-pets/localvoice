import Core
import Foundation

/// Распознавание в облаке провайдера, которого даёт приложение-хост (`RemoteTranscribing`, ADR-010):
/// в ядре нет ни сети, ни ключей — оно режет запись на куски, пишет их во временные файлы и просит хост
/// распознать каждый. В LocalVoice это Gemini 3.5 Transcribe.
///
/// Почему кусками: запрос со словными таймкодами у Gemini ограничен 30 минутами аудио
/// (ai.google.dev/gemini-api/docs/transcribe, прочитано 16.09.2026). Куски берём вдвое короче предела —
/// так и прогресс идёт чаще, и повтор после ошибки стоит дешевле.
///
/// Спикеров этот движок не размечает: диаризация остаётся локальной (SpeakerKit), иначе метки провайдера
/// внутри каждого куска не сшивались бы между кусками и рассыпались бы голосовые профили (ADR-006).
public actor RemoteAsrEngine: AsrEngine {
  /// Целевая длительность куска, с.
  static let chunkSeconds: Double = 900
  /// На сколько секунд граница куска может съехать в поисках тишины.
  static let boundarySearchSeconds: Double = 20
  /// Окно, по которому ищется самое тихое место.
  static let quietWindowSeconds: Double = 0.5
  /// Паузу длиннее этой между клипами не отправляем в облако: куски разделяются.
  static let maximumSilenceSeconds: Double = 60
  /// Пауза между словами, по которой начинается новый сегмент (как у Parakeet).
  static let segmentGapSeconds: Double = 0.7
  /// Предел длины сегмента: длинные куски неудобны в интерфейсе и при сшивке со спикерами.
  static let maxSegmentSeconds: Double = 30
  /// Сколько кусков едут в облако одновременно. У провайдера запас по запросам большой (у Azure — сотни
  /// в минуту), а канал выгрузки у пользователя один: три потока заметно сокращают ожидание и не занимают
  /// его целиком.
  static let concurrentRequests = 3
  /// Сколько раз повторять запрос, который провайдер отклонил временно (429, 5xx, таймаут).
  static let attempts = 3
  static let retryDelays: [Duration] = [.seconds(5), .seconds(20)]

  public nonisolated let descriptor: EngineDescriptor
  private let client: any RemoteTranscribing
  private let workRoot: URL

  public init(client: any RemoteTranscribing, workRoot: URL? = nil) {
    self.client = client
    self.descriptor = EngineDescriptor(name: client.title, model: client.model)
    self.workRoot =
      workRoot
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "MeetingScribeRemoteClips", isDirectory: true)
  }

  /// Язык выбирает сам провайдер по каждой реплике — ровно то, что нужно смешанной русско-украинской речи.
  public nonisolated var supportsLanguageSelection: Bool { false }

  /// Моделей не качает: проверяет, что провайдер настроен (у LocalVoice — что есть ключ Gemini).
  public func prepare(progress: ProgressSink?) async throws {
    let availability = await client.availability()
    guard availability.isAvailable else {
      throw EngineError.modelUnavailable(
        availability.reason
          ?? String(localized: "\(descriptor.name): провайдер не настроен"))
    }
    progress?(.fraction(.modelDownload, 1, pulse: descriptor.name))
  }

  public func detectLanguage(_ audio: PCMAudio) async throws -> LanguageDetection {
    throw EngineError.unsupported(
      String(localized: "\(descriptor.name) определяет язык сам, отдельного вызова нет"))
  }

  public func transcribe(
    _ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?, discovered: SegmentSink?
  ) async throws -> [Segment] {
    try Self.checkCancellation()
    guard !audio.isEmpty else { return [] }

    let limit = max(60, min(Self.chunkSeconds, client.maximumClipSeconds))
    let ranges = options.clips.isEmpty ? [0...audio.duration] : options.clips
    let chunks = RemoteChunkPlanner.refine(
      RemoteChunkPlanner.plan(
        ranges: ranges, limit: limit, silenceLimit: Self.maximumSilenceSeconds),
      audio: audio, search: Self.boundarySearchSeconds, window: Self.quietWindowSeconds)
    guard !chunks.isEmpty else { return [] }

    let total = chunks.reduce(0) { $0 + $1.duration }
    let directory = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var pending: [Int: [RemoteWord]] = [:]
    var collected: [Segment] = []
    var processed: Double = 0
    var timecode = options.timeOffset + chunks[0].start
    var nextToEmit = 0

    progress?(
      .audio(
        .transcription, processed: 0, total: total, timecode: timecode,
        pulse: String(localized: "\(Self.place(0, of: chunks.count)): отправка")))

    // Куски уезжают пачками по `concurrentRequests`: ждать ответа по одному — значит держать канал
    // простаивающим большую часть времени. Лента реплик всё равно идёт по порядку.
    try await withThrowingTaskGroup(of: (Int, [RemoteWord]).self) { group in
      var scheduled = 0
      while scheduled < min(Self.concurrentRequests, chunks.count) {
        group.addTask(
          operation: self.operation(
            index: scheduled, chunk: chunks[scheduled], audio: audio, options: options,
            directory: directory, count: chunks.count, progress: progress))
        scheduled += 1
      }
      while let (index, words) = try await group.next() {
        try Self.checkCancellation()
        pending[index] = words
        processed += chunks[index].duration
        timecode = max(timecode, options.timeOffset + chunks[index].end)
        // Журнал без текста (SPEC.md §3.8): по нему после прогона видно, не пропал ли кусок целиком.
        AppLog.pipeline.info(
          "remote asr chunk \(index + 1, privacy: .public)/\(chunks.count, privacy: .public): \(chunks[index].duration, privacy: .public) s → \(words.count, privacy: .public) words"
        )
        var pulse = String(localized: "\(Self.place(index, of: chunks.count)): готов")
        // Сегменты отдаются в ленту по порядку: кусок ждёт, пока готовы все предыдущие.
        while let ready = pending[nextToEmit] {
          let segments = Self.segments(
            from: ready, offset: options.timeOffset + chunks[nextToEmit].start,
            language: options.language)
          if !segments.isEmpty {
            discovered?(segments)
            pulse = segments.last?.text ?? pulse
          }
          collected.append(contentsOf: segments)
          pending[nextToEmit] = nil
          nextToEmit += 1
        }
        progress?(
          .audio(
            .transcription, processed: processed, total: total, timecode: timecode, pulse: pulse))
        if scheduled < chunks.count {
          group.addTask(
            operation: self.operation(
              index: scheduled, chunk: chunks[scheduled], audio: audio, options: options,
              directory: directory, count: chunks.count, progress: progress))
          scheduled += 1
        }
      }
    }
    return collected.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  /// Один кусок: запись во временный файл и запрос с повторами. Замыкание отдаётся группе задач, поэтому
  /// нарезка делается заранее — в задачу уезжает только готовый кусок аудио.
  private func operation(
    index: Int, chunk: RemoteChunkPlanner.Chunk, audio: PCMAudio, options: AsrOptions,
    directory: URL, count: Int, progress: ProgressSink?
  ) -> @Sendable () async throws -> (Int, [RemoteWord]) {
    let slice = audio.slice(from: chunk.start, to: chunk.end)
    let place = Self.place(index, of: count)
    return { [self] in
      try Self.checkCancellation()
      let clip = try RemoteAudioClip.write(slice, into: directory, name: "clip-\(index)")
      defer { try? FileManager.default.removeItem(at: clip.url) }
      let words = try await request(
        clip: clip, duration: chunk.duration, language: options.language, place: place,
        progress: progress)
      return (index, words)
    }
  }

  /// «кусок 2 из 5» — для пульса и журнала.
  static func place(_ index: Int, of count: Int) -> String {
    String(localized: "кусок \(index + 1) из \(count)")
  }

  /// Запрос с повторами: временную ошибку провайдера (429, 5xx, таймаут) ждём и повторяем, остальные —
  /// наружу текстом самого провайдера, чтобы в интерфейсе было видно, что именно он ответил. Повтор
  /// сообщается пульсом без секунд: куски идут параллельно, и полосу двигает только их завершение.
  private func request(
    clip: RemoteAudioClip.Written, duration: Double, language: Language?, place: String,
    progress: ProgressSink?
  ) async throws -> [RemoteWord] {
    var attempt = 0
    while true {
      do {
        return try await client.transcribe(
          clip: clip.url, mimeType: clip.mimeType, duration: duration, language: language)
      } catch {
        if Self.isCancellation(error) { throw EngineError.cancelled }
        let retryable = (error as? RemoteTranscriptionError)?.isRetryable ?? false
        guard retryable, attempt < Self.attempts - 1 else {
          throw EngineError.inferenceFailed("\(descriptor.name): \(error.localizedDescription)")
        }
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        progress?(
          ProgressEvent(
            stage: .transcription,
            pulse: String(
              localized: "\(place): повтор после ответа «\(error.localizedDescription)»")))
        do { try await Task.sleep(for: delay) } catch { throw EngineError.cancelled }
        attempt += 1
      }
    }
  }

  // MARK: - Отображение результата

  /// Слова провайдера (таймкоды от начала куска) — в сегменты с абсолютными таймкодами: новый сегмент
  /// начинается после паузы длиннее `segmentGapSeconds` или когда текущий длиннее `maxSegmentSeconds`.
  static func segments(from words: [RemoteWord], offset: Double, language: Language?) -> [Segment] {
    let mapped =
      words
      .map { word in
        Word(
          start: word.start + offset,
          end: max(word.start, word.end) + offset,
          text: word.text.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      .filter { !$0.text.isEmpty }
      .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

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
          words: current))
      current = []
    }

    for word in mapped {
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

  // MARK: - Вспомогательное

  static func checkCancellation() throws {
    if Task.isCancelled { throw EngineError.cancelled }
  }

  static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let engine = error as? EngineError, case .cancelled = engine { return true }
    return (error as NSError).code == NSURLErrorCancelled
  }
}
