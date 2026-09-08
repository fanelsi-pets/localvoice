import Core
import Foundation

/// Счётчик байтов и скорости для событий `ModelDownloadProgress` (SPEC.md §3.7 п. 10): байты считаются
/// по всей модели, уже скачанное засчитывается сразу, показанное значение никогда не уменьшается —
/// при перезапуске файла (сервер проигнорировал `Range`) оно замирает, пока загрузка не догонит.
/// Живёт внутри одного вызова `ModelDownloader`, поэтому не `Sendable` и без блокировок.
final class DownloadProgressTracker {
  /// Не чаще ~10 событий в секунду: чаще незачем ни интерфейсу, ни строке CLI.
  static let minimumInterval = Duration.milliseconds(100)
  /// Окно для скорости: короткое усредняет рывки CDN, длинное отстаёт от реальности.
  static let speedWindow = Duration.seconds(5)

  private let model: ModelID
  private let sink: ModelDownloadProgressSink?
  private let clock = ContinuousClock()

  private var bytesTotal: Int64 = 0
  private var filesTotal = 0
  private var filesCompleted = 0
  /// Сумма размеров файлов, которые уже готовы (скачаны в этот раз или лежали на диске).
  private var completedBytes: Int64 = 0
  /// Байты текущего файла, включая часть, докачанную с прошлого запуска.
  private var currentBytes: Int64 = 0
  private var currentFile: String?
  /// Потолок показанного: гарантия монотонности.
  private var emitted: Int64 = 0
  /// Фактически прочитано из сети за этот прогон — по нему считается скорость.
  private var received: Int64 = 0
  private var samples: [(at: ContinuousClock.Instant, bytes: Int64)] = []
  private var lastEmit: ContinuousClock.Instant?

  init(model: ModelID, sink: ModelDownloadProgressSink?) {
    self.model = model
    self.sink = sink
  }

  /// - Parameter alreadyOnDisk: байты, которые уже лежат в папке модели (готовые файлы и части
  ///   `.part`): они засчитываются сразу, чтобы продолженная загрузка не начиналась с нуля.
  func start(bytesTotal: Int64, filesTotal: Int, alreadyOnDisk: Int64 = 0) {
    self.bytesTotal = max(bytesTotal, 0)
    self.filesTotal = filesTotal
    emitted = min(max(alreadyOnDisk, 0), self.bytesTotal)
  }

  /// Начало работы с файлом: `have` — сколько его байтов уже на диске (готовый `.part` или проверяемый файл).
  func beginFile(_ path: String, have: Int64 = 0) {
    currentFile = path
    currentBytes = max(have, 0)
  }

  /// Сервер ответил 200 на `Range`: файл качается с нуля, показанные байты замораживаются.
  func restartCurrentFile() {
    currentBytes = 0
  }

  /// Прогресс внутри файла: `fileBytes` — сколько его байтов уже на диске, `newBytes` — сколько
  /// байтов пришло из сети с прошлого вызова (для скорости).
  func advance(fileBytes: Int64, newBytes: Int64) {
    currentBytes = max(fileBytes, 0)
    guard newBytes > 0 else { return }
    received += newBytes
    let now = clock.now
    samples.append((now, received))
    while let first = samples.first, now - first.at > Self.speedWindow, samples.count > 2 {
      samples.removeFirst()
    }
  }

  func completeFile(size: Int64) {
    completedBytes += max(size, 0)
    filesCompleted += 1
    currentBytes = 0
  }

  /// Событие прогресса; без `force` срабатывает троттлинг (не чаще ~10 раз в секунду).
  /// Возвращает отправленное событие — тестам и журналу удобнее видеть, что ушло.
  @discardableResult
  func emit(_ phase: ModelDownloadProgress.Phase, force: Bool = false) -> ModelDownloadProgress? {
    let now = clock.now
    if !force, let lastEmit, now - lastEmit < Self.minimumInterval { return nil }
    lastEmit = now
    emitted = min(max(emitted, completedBytes + currentBytes), max(bytesTotal, 0))
    let event = ModelDownloadProgress(
      model: model,
      phase: phase,
      bytesCompleted: emitted,
      bytesTotal: bytesTotal,
      filesCompleted: filesCompleted,
      filesTotal: filesTotal,
      currentFile: phase == .finished ? nil : currentFile,
      bytesPerSecond: speed(at: now))
    sink?(event)
    return event
  }

  /// Завершение: полоса доходит до конца ровно один раз.
  @discardableResult
  func finish() -> ModelDownloadProgress? {
    currentFile = nil
    currentBytes = 0
    completedBytes = bytesTotal
    filesCompleted = filesTotal
    return emit(.finished, force: true)
  }

  /// Скорость по скользящему окну; `nil` — данных мало (меньше четверти секунды наблюдений).
  private func speed(at now: ContinuousClock.Instant) -> Double? {
    while let first = samples.first, now - first.at > Self.speedWindow, samples.count > 1 {
      samples.removeFirst()
    }
    guard let first = samples.first, let last = samples.last, samples.count > 1 else { return nil }
    let span =
      Double((last.at - first.at).components.seconds)
      + Double((last.at - first.at).components.attoseconds) / 1e18
    guard span >= 0.25 else { return nil }
    return Double(last.bytes - first.bytes) / span
  }
}
