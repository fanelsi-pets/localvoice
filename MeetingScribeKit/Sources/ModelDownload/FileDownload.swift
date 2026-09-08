import Core
import Foundation

/// Что происходит с файлом по ходу загрузки.
enum FileStreamEvent: Sendable {
  /// Сервер ответил; `restartedFromZero` — на запрос с `Range` пришёл 200, файл идёт с нуля.
  case response(restartedFromZero: Bool)
  /// Столько байтов файла уже лежит в `.part`.
  case wrote(Int64)
}

/// Приёмник тела ответа: пишет куски прямо в `<файл>.part` на очереди делегата и отдаёт лентой
/// только счётчики, поэтому память не растёт, а отмена сохраняет всё, что успело записаться.
///
/// Почему делегат, а не `session.bytes(for:)`: `URLSession.AsyncBytes` отдаёт тело по одному байту —
/// замер 2026-09-05 на файле 13.2 MB репозитория speakerkit-coreml: 0.15 МБ/с против 2.65 МБ/с у
/// обычной загрузки того же файла в той же сессии. Для модели в 1.6 GB это часы против минут.
///
/// Все поля трогает только последовательная очередь делегата `URLSession`, потребитель читает
/// лишь ленту событий — отсюда `@unchecked Sendable`.
final class FileStreamWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let events: AsyncThrowingStream<FileStreamEvent, Error>

  private let part: URL
  private let fileName: String
  private let requestedOffset: Int64
  private let continuation: AsyncThrowingStream<FileStreamEvent, Error>.Continuation
  private var handle: FileHandle?
  private var offset: Int64 = 0
  private var written: Int64 = 0

  init(part: URL, offset: Int64, fileName: String) {
    self.part = part
    self.requestedOffset = max(offset, 0)
    self.fileName = fileName
    let (stream, continuation) = AsyncThrowingStream<FileStreamEvent, Error>.makeStream(
      bufferingPolicy: .unbounded)
    events = stream
    self.continuation = continuation
    super.init()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      finish(ModelDownloadError.httpStatus(0, file: fileName))
      completionHandler(.cancel)
      return
    }
    var restarted = false
    switch http.statusCode {
    case 206:
      offset = requestedOffset
    case 200:
      // Сервер не принял `Range` (так отвечают некоторые зеркала) — файл придёт целиком.
      restarted = requestedOffset > 0
      offset = 0
    default:
      finish(ModelDownloadError.httpStatus(http.statusCode, file: fileName))
      completionHandler(.cancel)
      return
    }
    do {
      try openFile()
    } catch {
      finish(error)
      completionHandler(.cancel)
      return
    }
    continuation.yield(.response(restartedFromZero: restarted))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let handle else { return }
    do {
      try handle.write(contentsOf: data)
    } catch {
      finish(ModelDownloadError.file(error, path: fileName))
      dataTask.cancel()
      return
    }
    written += Int64(data.count)
    continuation.yield(.wrote(offset + written))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    closeFile()
    if let error {
      continuation.finish(throwing: ModelDownloadError.network(error))
    } else {
      continuation.finish()
    }
  }

  private func openFile() throws {
    if !FileManager.default.fileExists(atPath: part.path(percentEncoded: false)) {
      guard
        FileManager.default.createFile(
          atPath: part.path(percentEncoded: false), contents: nil)
      else {
        throw ModelDownloadError.fileSystem(
          String(localized: "не удалось создать \(part.lastPathComponent)"))
      }
    }
    do {
      let handle = try FileHandle(forWritingTo: part)
      // Обрезаем хвост прошлой попытки: докачка продолжает ровно с того места, что запросили.
      try handle.truncate(atOffset: UInt64(offset))
      try handle.seek(toOffset: UInt64(offset))
      self.handle = handle
    } catch {
      throw ModelDownloadError.file(error, path: part.lastPathComponent)
    }
  }

  private func closeFile() {
    try? handle?.close()
    handle = nil
  }

  private func finish(_ error: Error) {
    closeFile()
    continuation.finish(throwing: error)
  }
}

extension ModelDownloader {
  /// Качает один файл в `<файл>.part`: продолжает с уже скачанного (`Range: bytes=N-`) и обновляет
  /// прогресс. Отмена оставляет `.part` на диске — следующий запуск дотянет остаток
  /// (SPEC.md §3.8: возобновление загрузки).
  func receive(
    _ file: ModelFile,
    from url: URL,
    into part: URL,
    tracker: DownloadProgressTracker
  ) async throws {
    try makeDirectory(part.deletingLastPathComponent())
    var offset = fileSize(part) ?? 0
    if offset > 0, offset >= file.size {
      // Часть длиннее самого файла: остаток от другой ревизии — начинаем заново.
      try remove(part)
      offset = 0
    }
    tracker.beginFile(file.path, have: offset)

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    if offset > 0 {
      request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
    }

    let writer = FileStreamWriter(part: part, offset: offset, fileName: file.path)
    let task = session.dataTask(with: request)
    task.delegate = writer
    task.resume()

    var lastTotal = offset
    do {
      for try await event in writer.events {
        switch event {
        case .response(let restartedFromZero):
          if restartedFromZero {
            AppLog.download.notice(
              "докачка \(file.path, privacy: .public) не поддержана сервером — качаем с нуля")
            lastTotal = 0
            tracker.restartCurrentFile()
          }
        case .wrote(let total):
          tracker.advance(fileBytes: total, newBytes: max(total - lastTotal, 0))
          lastTotal = total
          tracker.emit(.downloading)
        }
        if Task.isCancelled { break }
      }
    } catch {
      task.cancel()
      throw ModelDownloadError.network(error)
    }
    if Task.isCancelled {
      // Соединение обрываем, `.part` оставляем: это и есть точка продолжения.
      task.cancel()
      throw ModelDownloadError.cancelled
    }
    tracker.emit(.downloading, force: true)
  }
}
