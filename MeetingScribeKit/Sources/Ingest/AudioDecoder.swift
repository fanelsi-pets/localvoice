import AVFoundation
import Core
import Foundation
import Synchronization

/// Потоковый декодер записи в рабочий формат движков: mono 16 kHz Float32 (SPEC.md §3.1).
///
/// Файл не загружается в память целиком: `AVAssetReader` отдаёт LPCM блоками (частоту и даунмикс
/// делает сама AVFoundation), каждый блок сразу уходит в `<cacheDirectory>/audio16k.wav`.
/// Пик памяти — четверть мегабайта буферов плюс внутренние очереди AVFoundation, поэтому
/// двухчасовое видео декодируется в пределах 500 MB.
public struct AudioDecoder: AudioDecoding {
  /// Имя файла кэша: другие модули берут путь отсюда, а не собирают строкой.
  public static let outputFileName = "audio16k.wav"

  /// Контейнеры, которые AVFoundation не открывает. Проверяются до обращения к файлу,
  /// чтобы вместо «сбой чтения» показать понятную причину.
  static let unsupportedContainers: [String: String] = [
    "mkv": String(localized: "контейнер Matroska"),
    "mka": String(localized: "контейнер Matroska"),
    "webm": String(localized: "контейнер WebM"),
    "ogg": String(localized: "контейнер Ogg"),
    "oga": String(localized: "контейнер Ogg"),
    "opus": String(localized: "Opus в контейнере Ogg"),
  ]

  /// Сколько кадров копится перед записью в WAV: 64 K × 4 байта = 256 KB — потолок буфера декодера.
  private static let flushFrames = 1 << 16

  /// Шаг отчётов о прогрессе в секундах обработанного аудио (SPEC.md §3.7: не реже раза в секунду).
  private static let progressStepSeconds = 1.0

  /// Выделенная очередь: `copyNextSampleBuffer()` блокирует поток, кооперативный пул для этого нельзя.
  private static let readerQueue = DispatchQueue(
    label: "app.meetingscribe.ingest.decode", qos: .userInitiated, attributes: .concurrent)

  /// Настройки вывода: LPCM Float32, 16 kHz, mono, interleaved little-endian.
  private static var outputSettings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: Double(PCMAudio.sampleRate),
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
  }

  public init() {}

  public func decode(_ source: URL, into cacheDirectory: URL, progress: ProgressSink?) async throws
    -> DecodedAudio
  {
    try Self.validate(source)
    if Task.isCancelled { throw IngestError.cancelled }

    let asset = AVURLAsset(url: source)
    let track = try await Self.audioTrack(of: asset, source: source)
    let totalHint = await Self.containerDuration(of: asset, track: track)
    let target = try Self.prepareTarget(in: cacheDirectory, source: source)
    let session = try Self.makeSession(asset: asset, track: track, source: source)

    let frames: Int
    do {
      frames = try await Self.runOffCooperativePool(
        session: session, source: source, target: target, totalHint: totalHint, progress: progress)
    } catch {
      // Обрывок WAV хуже отсутствующего: следующий запуск не должен принять его за готовый кэш.
      try? FileManager.default.removeItem(at: target)
      throw error
    }
    guard frames > 0 else {
      try? FileManager.default.removeItem(at: target)
      throw IngestError.decodingFailed(source, reason: String(localized: "аудиодорожка пуста"))
    }

    let duration = PCMAudio.seconds(forSampleIndex: frames)
    progress?(.audio(.decoding, processed: duration, total: duration))
    return DecodedAudio(
      url: target, sourceURL: source, duration: duration, sampleCount: frames)
  }

  public func loadPCM(_ decoded: DecodedAudio) async throws -> PCMAudio {
    try WAVFile.read(decoded.url)
  }

  public func probe(_ source: URL) async throws -> AudioProbe {
    try await Self.probe(source)
  }

  /// Быстрая справка о файле без декодирования: длительность, частота, каналы, есть ли видео.
  public static func probe(_ url: URL) async throws -> AudioProbe {
    try validate(url)
    let asset = AVURLAsset(url: url)
    let track = try await audioTrack(of: asset, source: url)
    let duration = await containerDuration(of: asset, track: track)
    let formats = (try? await track.load(.formatDescriptions)) ?? []
    let basic = formats.first.flatMap {
      CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
    }
    let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
    return AudioProbe(
      url: url,
      duration: duration,
      sampleRate: basic?.mSampleRate ?? 0,
      channelCount: Int(basic?.mChannelsPerFrame ?? 0),
      hasVideo: hasVideo,
      formatName: basic.map { fourCharacterCode($0.mFormatID) } ?? "")
  }
}

// MARK: - Подготовка

extension AudioDecoder {
  private static func validate(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
    guard exists, !isDirectory.boolValue else { throw IngestError.fileNotFound(url) }
    if let reason = unsupportedContainers[url.pathExtension.lowercased()] {
      throw IngestError.unsupportedContainer(url, reason: reason)
    }
  }

  private static func audioTrack(of asset: AVURLAsset, source: URL) async throws -> AVAssetTrack {
    let tracks: [AVAssetTrack]
    do {
      tracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
      throw IngestError.decodingFailed(source, reason: error.localizedDescription)
    }
    guard let track = tracks.first else { throw IngestError.noAudioTrack(source) }
    return track
  }

  /// Длительность по контейнеру — только оценка для полосы прогресса; итоговая берётся из числа сэмплов.
  private static func containerDuration(of asset: AVURLAsset, track: AVAssetTrack) async -> Double {
    if let duration = try? await asset.load(.duration) {
      let seconds = CMTimeGetSeconds(duration)
      if seconds.isFinite, seconds > 0 { return seconds }
    }
    if let range = try? await track.load(.timeRange) {
      let seconds = CMTimeGetSeconds(range.end)
      if seconds.isFinite, seconds > 0 { return seconds }
    }
    return 0
  }

  private static func prepareTarget(in cacheDirectory: URL, source: URL) throws -> URL {
    do {
      try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    } catch {
      throw IngestError.decodingFailed(
        source,
        reason:
          String(
            localized:
              "не удалось создать папку кэша \(cacheDirectory.path): \(error.localizedDescription)")
      )
    }
    return cacheDirectory.appending(path: outputFileName)
  }

  private static func makeSession(asset: AVURLAsset, track: AVAssetTrack, source: URL) throws
    -> DecodeSession
  {
    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw IngestError.decodingFailed(source, reason: error.localizedDescription)
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    // Данные читаются один раз и сразу копируются в наш буфер — копия внутри AVFoundation не нужна.
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw IngestError.decodingFailed(
        source, reason: String(localized: "дорожку нельзя привести к LPCM 16 kHz mono"))
    }
    reader.add(output)
    return DecodeSession(reader: reader, output: output)
  }

  private static func fourCharacterCode(_ value: AudioFormatID) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

// MARK: - Чтение вне кооперативного пула

extension AudioDecoder {
  /// Запускает блокирующее чтение на выделенной очереди и связывает его с отменой задачи.
  private static func runOffCooperativePool(
    session: DecodeSession,
    source: URL,
    target: URL,
    totalHint: Double,
    progress: ProgressSink?
  ) async throws -> Int {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Int, any Error>) in
        readerQueue.async {
          do {
            let frames = try write(
              session: session, source: source, target: target, totalHint: totalHint,
              progress: progress)
            continuation.resume(returning: frames)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      session.cancel()
    }
  }

  /// Владеет `AVAudioFile`: файл закрывается (и дописывает заголовок) на выходе из функции.
  private static func write(
    session: DecodeSession,
    source: URL,
    target: URL,
    totalHint: Double,
    progress: ProgressSink?
  ) throws -> Int {
    guard !session.isCancelled else { throw IngestError.cancelled }
    let file: AVAudioFile
    do {
      file = try WAVFile.open(forWriting: target)
    } catch {
      throw IngestError.decodingFailed(
        source,
        reason: String(
          localized: "не удалось создать \(target.lastPathComponent): \(error.localizedDescription)"
        )
      )
    }
    do {
      return try pump(
        session: session, file: file, source: source, totalHint: totalHint, progress: progress)
    } catch let error as IngestError {
      throw error
    } catch {
      throw IngestError.decodingFailed(source, reason: error.localizedDescription)
    }
  }

  /// Цикл чтения: блок сэмплов → буфер 256 KB → WAV. Возвращает число записанных кадров.
  private static func pump(
    session: DecodeSession,
    file: AVAudioFile,
    source: URL,
    totalHint: Double,
    progress: ProgressSink?
  ) throws -> Int {
    let reader = session.reader
    let output = session.output
    // Старт и отмена — под одним замком: `cancelReading()` до `startReading()` заканчивается
    // NSInternalInconsistencyException «cannot be called again» (замечено под нагрузкой в тестах).
    guard session.startReading() else {
      if session.isCancelled { throw IngestError.cancelled }
      throw IngestError.decodingFailed(source, reason: failureReason(reader))
    }

    var pending: [Float] = []
    pending.reserveCapacity(flushFrames)
    var frames = 0
    var position = 0.0
    var reported = 0.0
    var finished = false

    // Полоса появляется до первого блока: пользователь видит, что стадия началась.
    progress?(.audio(.decoding, processed: 0, total: totalHint))

    while !finished {
      if session.isCancelled { throw IngestError.cancelled }
      // Пул на каждой итерации: CoreMedia отдаёт autorelease-объекты, без него память растёт.
      try autoreleasepool {
        guard let sample = output.copyNextSampleBuffer() else {
          finished = true
          return
        }
        let written = try append(sample, to: file, pending: &pending)
        frames += written
        position = max(position, presentation(of: sample, fallback: frames))
        if position - reported >= progressStepSeconds {
          reported = position
          progress?(.audio(.decoding, processed: position, total: max(totalHint, position)))
        }
      }
    }

    if session.isCancelled { throw IngestError.cancelled }
    switch reader.status {
    case .completed:
      break
    case .cancelled:
      throw IngestError.cancelled
    default:
      throw IngestError.decodingFailed(source, reason: failureReason(reader))
    }
    if !pending.isEmpty {
      try WAVFile.append(pending[...], to: file)
    }
    return frames
  }

  /// Копирует сэмплы блока в буфер, сбрасывая его в файл по мере наполнения.
  private static func append(
    _ sample: CMSampleBuffer, to file: AVAudioFile, pending: inout [Float]
  ) throws -> Int {
    var written = 0
    try sample.withAudioBufferList(flags: []) { list, _ in
      // Формат вывода — mono interleaved, поэтому в списке ровно один буфер.
      guard list.count > 0, let raw = list[0].mData else { return }
      let values = UnsafeBufferPointer(
        start: raw.assumingMemoryBound(to: Float.self),
        count: Int(list[0].mDataByteSize) / MemoryLayout<Float>.size)
      var index = 0
      while index < values.count {
        let take = min(flushFrames - pending.count, values.count - index)
        pending.append(contentsOf: UnsafeBufferPointer(rebasing: values[index..<(index + take)]))
        index += take
        if pending.count >= flushFrames {
          try WAVFile.append(pending[...], to: file)
          pending.removeAll(keepingCapacity: true)
        }
      }
      written = values.count
    }
    return written
  }

  /// Конец блока по таймкоду записи; если таймкод недоступен — по числу записанных кадров.
  private static func presentation(of sample: CMSampleBuffer, fallback frames: Int) -> Double {
    let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
    guard stamp.isNumeric else { return PCMAudio.seconds(forSampleIndex: frames) }
    let seconds =
      CMTimeGetSeconds(stamp)
      + PCMAudio.seconds(forSampleIndex: CMSampleBufferGetNumSamples(sample))
    return seconds.isFinite ? seconds : PCMAudio.seconds(forSampleIndex: frames)
  }

  private static func failureReason(_ reader: AVAssetReader) -> String {
    if let error = reader.error { return error.localizedDescription }
    switch reader.status {
    case .unknown: return String(localized: "неизвестный статус AVAssetReader")
    case .reading: return String(localized: "чтение прервано на середине")
    case .completed: return String(localized: "чтение завершено без данных")
    case .failed: return String(localized: "сбой AVAssetReader")
    case .cancelled: return String(localized: "чтение отменено")
    @unknown default: return String(localized: "статус AVAssetReader \(reader.status.rawValue)")
    }
  }
}

// MARK: - Сессия чтения

/// Держит `AVAssetReader` между async-контекстом и рабочим потоком.
///
/// `@unchecked Sendable` осознанно: reader и output после создания трогает только рабочий поток,
/// а флаг отмены закрыт `Mutex`. `cancelReading()` документирован как безопасный из любого потока —
/// именно он разблокирует зависший `copyNextSampleBuffer()`.
private final class DecodeSession: @unchecked Sendable {
  let reader: AVAssetReader
  let output: AVAssetReaderTrackOutput
  /// Флаги отмены и старта под одним замком: `cancelReading()` зовётся только у запущенного reader'а,
  /// а `startReading()` не зовётся после отмены.
  private struct Flags {
    var cancelled = false
    var started = false
  }
  private let flags = Mutex(Flags())

  init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
    self.reader = reader
    self.output = output
  }

  var isCancelled: Bool { flags.withLock { $0.cancelled } }

  /// Запускает чтение, если сессия не отменена. `false` — отменена или reader не стартовал.
  /// Замок держится только вокруг флагов: `startReading()` блокирующий, а `cancel()` не должен его ждать;
  /// отмена, пришедшая во время старта, добирается сразу после него.
  func startReading() -> Bool {
    let cancelledBefore = flags.withLock { $0.cancelled }
    guard !cancelledBefore else { return false }
    let started = reader.startReading()
    let cancelledMeanwhile = flags.withLock { flags -> Bool in
      flags.started = started
      return flags.cancelled
    }
    if started, cancelledMeanwhile {
      reader.cancelReading()
      return false
    }
    return started
  }

  func cancel() {
    let shouldCancelReader = flags.withLock { flags -> Bool in
      let wasCancelled = flags.cancelled
      flags.cancelled = true
      return !wasCancelled && flags.started
    }
    guard shouldCancelReader else { return }
    reader.cancelReading()
  }
}
