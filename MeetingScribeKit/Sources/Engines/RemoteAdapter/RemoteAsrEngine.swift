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

    var collected: [Segment] = []
    var processed: Double = 0
    for (index, chunk) in chunks.enumerated() {
      try Self.checkCancellation()
      let place = String(localized: "кусок \(index + 1) из \(chunks.count)")
      progress?(
        .audio(
          .transcription, processed: processed, total: total,
          timecode: options.timeOffset + chunk.start,
          pulse: String(localized: "\(place): отправка")))

      let clip = try RemoteAudioClip.write(
        audio.slice(from: chunk.start, to: chunk.end), into: directory, name: "clip-\(index)")
      defer { try? FileManager.default.removeItem(at: clip.url) }

      let words = try await request(
        clip: clip, duration: chunk.duration, language: options.language, place: place,
        processed: processed, total: total, timecode: options.timeOffset + chunk.start,
        progress: progress)
      let segments = Self.segments(
        from: words, offset: options.timeOffset + chunk.start, language: options.language)
      // Журнал без текста (SPEC.md §3.8): по нему после прогона видно, не пропал ли кусок целиком.
      AppLog.pipeline.info(
        "remote asr chunk \(index + 1, privacy: .public)/\(chunks.count, privacy: .public): \(chunk.duration, privacy: .public) s → \(words.count, privacy: .public) words"
      )
      if !segments.isEmpty { discovered?(segments) }
      collected.append(contentsOf: segments)

      processed += chunk.duration
      progress?(
        .audio(
          .transcription, processed: processed, total: total,
          timecode: options.timeOffset + chunk.end,
          pulse: segments.last?.text ?? String(localized: "\(place): без речи")))
    }
    return collected.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  /// Запрос с повторами: временную ошибку провайдера (429, 5xx, таймаут) ждём и повторяем, остальные —
  /// наружу текстом самого провайдера, чтобы в интерфейсе было видно, что именно ответил Google.
  private func request(
    clip: RemoteAudioClip.Written, duration: Double, language: Language?, place: String,
    processed: Double, total: Double, timecode: Double, progress: ProgressSink?
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
          .audio(
            .transcription, processed: processed, total: total, timecode: timecode,
            pulse: String(
              localized: "\(place): повтор после ответа «\(error.localizedDescription)»")
          ))
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
