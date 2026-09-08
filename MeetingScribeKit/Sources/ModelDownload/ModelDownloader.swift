import Core
import Foundation

/// Загрузчик моделей с Hugging Face (SPEC.md §3.7 п. 10, §3.8): листинг дерева репозитория, скачивание
/// файлов с докачкой `Range` в `<файл>.part`, проверка контрольных сумм, манифест. Сеть — только здесь
/// и в проверке обновлений; пути к файлам — только через `ModelStore`.
public actor ModelDownloader: ModelDownloading {
  public let store: ModelStore
  public let downloaderVersion: String
  let session: URLSession
  /// Свободное место на томе моделей; подменяется в тестах (проверять на реальном диске нечего).
  let availableDiskBytes: @Sendable (URL) -> Int64?
  /// - Parameters:
  ///   - store: хранилище моделей (пути только через него).
  ///   - session: сессия для сети; по умолчанию — `ephemeral` без cookies и кэша; тесты подставляют
  ///     сессию с `URLProtocol`-заглушкой.
  ///   - downloaderVersion: версия приложения/CLI для манифеста.
  public init(
    store: ModelStore, session: URLSession? = nil,
    downloaderVersion: String = ModelDownloadInfo.version
  ) {
    self.store = store
    self.session = session ?? Self.makeSession()
    self.downloaderVersion = downloaderVersion
    self.availableDiskBytes = { SystemInfo.availableDiskBytes(at: $0) }
  }

  /// Тот же загрузчик с подменённым источником свободного места (тесты нехватки диска).
  public init(
    store: ModelStore,
    session: URLSession?,
    downloaderVersion: String,
    availableDiskBytes: @escaping @Sendable (URL) -> Int64?
  ) {
    self.store = store
    self.session = session ?? Self.makeSession()
    self.downloaderVersion = downloaderVersion
    self.availableDiskBytes = availableDiskBytes
  }

  public static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.httpAdditionalHeaders = ["User-Agent": "MeetingScribe/1.0 (macOS)"]
    return URLSession(configuration: configuration)
  }

  // MARK: - План

  public func plan(_ model: ModelID) async throws -> ModelDownloadPlan {
    let spec = model.downloadSpec
    let client = HubClient(session: session)
    var revision = spec.revision
    do {
      if let sha = try await client.revisionSHA(repo: spec.repo, revision: spec.revision) {
        revision = sha
      }
    } catch let error as ModelDownloadError where error == .cancelled {
      throw error
    } catch {
      // Не критично: без sha качаем по имени ветки — листинг и файлы просто идут из «main».
      AppLog.download.notice(
        "ревизия \(spec.repo, privacy: .public) недоступна, работаем по ветке \(spec.revision, privacy: .public)"
      )
    }

    let entries = try await client.tree(
      repo: spec.repo, revision: revision, subpath: spec.subpath)
    let prefix = spec.subpath.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
    var files: [ModelFile] = []
    for entry in entries where entry.isFile {
      guard entry.path.hasPrefix(prefix) else { continue }
      let relative = String(entry.path.dropFirst(prefix.count))
      guard !relative.isEmpty, spec.includes(relativePath: relative) else { continue }
      // Путь из чужого ответа не должен уводить запись за пределы папки модели.
      guard Self.isSafeRelativePath(relative) else {
        AppLog.download.error(
          "пропущен подозрительный путь в листинге \(spec.repo, privacy: .public)")
        continue
      }
      files.append(
        ModelFile(
          path: relative,
          size: entry.size,
          sha256: entry.lfs?.oid,
          blobSHA1: entry.lfs == nil ? entry.oid : nil))
    }
    files.sort { $0.path < $1.path }
    guard !files.isEmpty else {
      throw ModelDownloadError.listingFailed(
        repo: spec.repo,
        reason: String(localized: "в ревизии \(revision) нет файлов модели \(model.rawValue)"))
    }

    let directory = store.directory(for: model)
    var existing: Int64 = 0
    var completed: Int64 = 0
    for file in files {
      let target = directory.appending(path: file.path)
      if let size = fileSize(target), size == file.size {
        existing += size
        completed += size
        continue
      }
      if let part = fileSize(Self.partURL(for: target)) {
        existing += min(part, file.size)
      }
    }
    return ModelDownloadPlan(
      model: model, revision: revision, files: files, existingBytes: existing,
      completedBytes: completed)
  }

  // MARK: - Скачивание

  public func download(_ model: ModelID, progress: ModelDownloadProgressSink?) async throws
    -> ModelManifest
  {
    let spec = model.downloadSpec
    let tracker = DownloadProgressTracker(model: model, sink: progress)
    tracker.emit(.listing, force: true)
    // Листинг — до двух сетевых запросов с таймаутом 30 с без байтов: раз в секунду отдаём событие,
    // чтобы интерфейс показывал прошедшее время, а не замерший ноль (SPEC.md §3.7 п. 4).
    // Событие пульса собирается без трекера: у листинга нет байтов, а сам трекер живёт в акторе.
    let listingPulse = Task { [progress, model] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }
        progress?(ModelDownloadProgress(model: model, phase: .listing))
      }
    }
    defer { listingPulse.cancel() }
    do {
      let plan = try await plan(model)
      listingPulse.cancel()
      tracker.start(
        bytesTotal: plan.totalBytes, filesTotal: plan.files.count,
        alreadyOnDisk: plan.existingBytes)
      tracker.emit(.downloading, force: true)
      try checkDiskSpace(remaining: plan.bytesToFetchWorstCase)

      let directory = store.directory(for: model)
      try makeDirectory(directory)
      AppLog.download.info(
        """
        загрузка \(model.rawValue, privacy: .public): файлов \(plan.files.count, privacy: .public), \
        всего \(plan.totalBytes, privacy: .public) байт, уже есть \(plan.existingBytes, privacy: .public)
        """)

      for file in plan.files {
        try Task.checkCancellation()
        try await fetch(
          file, spec: spec, revision: plan.revision, directory: directory, tracker: tracker)
        tracker.completeFile(size: file.size)
        tracker.emit(.downloading, force: true)
      }

      let manifest = ModelManifest(
        model: model,
        repo: spec.repo,
        revision: plan.revision,
        files: plan.files,
        downloaderVersion: downloaderVersion)
      do {
        try store.writeManifest(manifest)
      } catch {
        throw ModelDownloadError.file(error, path: ModelManifest.fileName)
      }
      tracker.emit(.verifying, force: true)
      tracker.finish()
      AppLog.download.info(
        "готово \(model.rawValue, privacy: .public), ревизия \(manifest.shortRevision, privacy: .public)"
      )
      return manifest
    } catch {
      let mapped = ModelDownloadError.network(error)
      AppLog.download.error(
        "сбой загрузки \(model.rawValue, privacy: .public): \(String(describing: mapped), privacy: .public)"
      )
      throw mapped
    }
  }

  /// Один файл: готовый с верной суммой пропускаем, иначе качаем в `.part` и проверяем сумму,
  /// при несовпадении — ещё одна попытка с нуля.
  private func fetch(
    _ file: ModelFile,
    spec: ModelDownloadSpec,
    revision: String,
    directory: URL,
    tracker: DownloadProgressTracker
  ) async throws {
    let target = directory.appending(path: file.path)
    let part = Self.partURL(for: target)

    if let size = fileSize(target) {
      if size == file.size {
        tracker.beginFile(file.path, have: file.size)
        tracker.emit(.verifying, force: true)
        if try matches(file, at: target, tracker: tracker) {
          try remove(part)
          return
        }
      }
      AppLog.download.notice(
        "файл \(file.path, privacy: .public) на диске не совпал с репозиторием — качаем заново")
      try remove(target)
      try remove(part)
    }

    let url = HubClient.fileURL(
      repo: spec.repo, revision: revision, path: spec.remotePath(for: file.path))
    for attempt in 1...2 {
      try Task.checkCancellation()
      try await receive(file, from: url, into: part, tracker: tracker)
      tracker.emit(.verifying, force: true)
      let size = fileSize(part) ?? 0
      if size == file.size, try matches(file, at: part, tracker: tracker) {
        try move(part, to: target)
        return
      }
      AppLog.download.error(
        "контрольная сумма \(file.path, privacy: .public) не совпала (попытка \(attempt, privacy: .public))"
      )
      try remove(part)
      if attempt == 2 { throw ModelDownloadError.checksumMismatch(file: file.path) }
      tracker.restartCurrentFile()
    }
  }

  /// Совпадает ли контрольная сумма файла; без сумм в листинге верим размеру.
  private func matches(_ file: ModelFile, at url: URL, tracker: DownloadProgressTracker) throws
    -> Bool
  {
    guard let expectation = FileHash.kind(for: file) else { return true }
    let digest = try FileHash.compute(expectation.kind, ofFileAt: url) { _ in
      try Task.checkCancellation()
      tracker.emit(.verifying)
    }
    return digest == expectation.expected
  }

  private func checkDiskSpace(remaining: Int64) throws {
    let required = remaining + HardwareCheck.diskReserveBytes
    guard let available = availableDiskBytes(store.root) else { return }
    guard available >= required else {
      throw ModelDownloadError.insufficientDiskSpace(
        requiredBytes: required, availableBytes: available)
    }
  }

  // MARK: - Проверка

  public func verify(_ model: ModelID, progress: ModelDownloadProgressSink?) async throws
    -> ModelVerification
  {
    let directory = store.directory(for: model)
    let tracker = DownloadProgressTracker(model: model, sink: progress)

    guard let manifest = store.manifest(for: model) else {
      // Модель из старого кэша или скачанная библиотекой: сумм нет, проверяем присутствие ключевых записей.
      tracker.start(bytesTotal: 0, filesTotal: model.requiredEntries.count)
      var missing: [String] = []
      for entry in model.requiredEntries {
        tracker.beginFile(entry)
        tracker.emit(.verifying)
        if !FileManager.default.fileExists(atPath: directory.appending(path: entry).path) {
          missing.append(entry)
        }
        tracker.completeFile(size: 0)
      }
      tracker.finish()
      return ModelVerification(
        model: model,
        checkedFiles: model.requiredEntries.count,
        missing: missing,
        hasManifest: false)
    }

    tracker.start(bytesTotal: manifest.totalBytes, filesTotal: manifest.files.count)
    tracker.emit(.verifying, force: true)
    var missing: [String] = []
    var corrupted: [String] = []
    for file in manifest.files {
      try Task.checkCancellation()
      tracker.beginFile(file.path, have: file.size)
      tracker.emit(.verifying, force: true)
      let url = directory.appending(path: file.path)
      guard let size = fileSize(url) else {
        missing.append(file.path)
        tracker.completeFile(size: file.size)
        continue
      }
      if size != file.size {
        corrupted.append(file.path)
      } else {
        do {
          if try !matches(file, at: url, tracker: tracker) { corrupted.append(file.path) }
        } catch is CancellationError {
          throw ModelDownloadError.cancelled
        } catch {
          // Файл есть, но не читается — для пользователя это то же самое, что повреждён.
          corrupted.append(file.path)
        }
      }
      tracker.completeFile(size: file.size)
    }
    tracker.finish()
    if !missing.isEmpty || !corrupted.isEmpty {
      AppLog.download.error(
        """
        проверка \(model.rawValue, privacy: .public): нет \(missing.count, privacy: .public), \
        повреждено \(corrupted.count, privacy: .public)
        """)
    }
    return ModelVerification(
      model: model,
      checkedFiles: manifest.files.count,
      missing: missing,
      corrupted: corrupted,
      hasManifest: true)
  }

  // MARK: - Файлы

  /// Путь внутри папки модели: без «..», без абсолютных путей и без пустых компонентов.
  static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.hasPrefix("/"), !path.contains("\u{0}") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty
      && components.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
  }

  static func partURL(for target: URL) -> URL {
    target.deletingLastPathComponent()
      .appending(path: target.lastPathComponent + ".part")
  }

  /// Размер обычного файла; `nil` — файла нет или это папка. Через `FileManager`, а не
  /// `URL.resourceValues`: тот кэширует значения в самом `URL`, и размер растущего `.part` устаревает.
  func fileSize(_ url: URL) -> Int64? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: url.path(percentEncoded: false)),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber
    else { return nil }
    return size.int64Value
  }

  func makeDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw ModelDownloadError.file(error, path: url.lastPathComponent)
    }
  }

  func remove(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw ModelDownloadError.file(error, path: url.lastPathComponent)
    }
  }

  /// Готовый файл появляется на своём месте одним переименованием: незавершённой загрузки на нём не видно.
  func move(_ source: URL, to target: URL) throws {
    do {
      try remove(target)
      try FileManager.default.moveItem(at: source, to: target)
    } catch {
      throw ModelDownloadError.file(error, path: target.lastPathComponent)
    }
  }
}
