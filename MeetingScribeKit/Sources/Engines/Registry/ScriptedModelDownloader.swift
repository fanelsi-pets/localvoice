import Core
import Foundation

/// Сценарное «скачивание» моделей для UI-тестов и превью: без сети, но с честным байтовым прогрессом,
/// паузой, докачкой и манифестом. Включается вместе со сценарными движками (`-MSFakeEngines YES`),
/// поэтому онбординг в UI-тесте проходит весь путь «Скачать → полоса в мегабайтах → модели на месте»
/// за секунды и без 1,7 ГБ трафика.
///
/// Что имитируется: план файлов из `ModelID.requiredEntries` с размерами по `downloadSpec.approximateBytes`,
/// события примерно 10 раз в секунду со скоростью, отмена с сохранением докачанного (следующий вызов
/// продолжает с того же места) и создание файлов модели в `ModelStore` (пустые заглушки — так
/// `ModelStore.isPresent` становится истиной, а вкладка «Диагностика» видит манифест).
public actor ScriptedModelDownloader: ModelDownloading {
  /// Сколько «качается» одна модель, с.
  public let secondsPerModel: Double
  public let store: ModelStore
  public let downloaderVersion: String

  /// Сколько байт модели уже «скачано»: отмена сохраняет это значение, следующий вызов продолжает с него.
  private var progressByModel: [ModelID: Int64] = [:]

  /// Событий прогресса в секунду.
  private static let ticksPerSecond: Double = 10

  public init(
    store: ModelStore, secondsPerModel: Double = 2, downloaderVersion: String = "scripted"
  ) {
    self.store = store
    self.secondsPerModel = max(secondsPerModel, 0)
    self.downloaderVersion = downloaderVersion
  }

  // MARK: - ModelDownloading

  public func plan(_ model: ModelID) async throws -> ModelDownloadPlan {
    ModelDownloadPlan(
      model: model,
      revision: "scripted",
      files: Self.files(for: model),
      existingBytes: existingBytes(for: model))
  }

  public func download(_ model: ModelID, progress: ModelDownloadProgressSink?) async throws
    -> ModelManifest
  {
    let files = Self.files(for: model)
    let total = files.reduce(0) { $0 + $1.size }
    var completed = existingBytes(for: model)

    progress?(
      ModelDownloadProgress(
        model: model, phase: .listing, bytesCompleted: completed, bytesTotal: total,
        filesTotal: files.count))

    // Скорость постоянная: полная модель качается `secondsPerModel`, докачка — пропорционально меньше.
    let ticks = max(Int((secondsPerModel * Self.ticksPerSecond).rounded()), 1)
    let step = max(total / Int64(ticks), 1)
    let interval = secondsPerModel > 0 ? 1 / Self.ticksPerSecond : 0
    let speed = interval > 0 ? Double(step) / interval : nil

    while completed < total {
      if Task.isCancelled {
        progressByModel[model] = completed
        throw ModelDownloadError.cancelled
      }
      if interval > 0 {
        do {
          try await Task.sleep(for: .seconds(interval))
        } catch {
          progressByModel[model] = completed
          throw ModelDownloadError.cancelled
        }
      }
      completed = min(completed + step, total)
      progressByModel[model] = completed
      let index = Self.fileIndex(forBytes: completed, in: files)
      progress?(
        ModelDownloadProgress(
          model: model, phase: .downloading, bytesCompleted: completed, bytesTotal: total,
          filesCompleted: index, filesTotal: files.count,
          currentFile: files.indices.contains(index) ? files[index].path : files.last?.path,
          bytesPerSecond: speed))
    }

    try createFiles(for: model)
    let manifest = ModelManifest(
      model: model, repo: model.downloadSpec.repo, revision: "scripted", files: files,
      downloaderVersion: downloaderVersion)
    do {
      try store.writeManifest(manifest)
    } catch {
      throw ModelDownloadError.fileSystem(error.localizedDescription)
    }
    progress?(
      ModelDownloadProgress(
        model: model, phase: .finished, bytesCompleted: total, bytesTotal: total,
        filesCompleted: files.count, filesTotal: files.count))
    return manifest
  }

  public func verify(_ model: ModelID, progress: ModelDownloadProgressSink?) async throws
    -> ModelVerification
  {
    let files = Self.files(for: model)
    progress?(
      ModelDownloadProgress(
        model: model, phase: .verifying, bytesTotal: files.reduce(0) { $0 + $1.size },
        filesTotal: files.count))
    let directory = store.directory(for: model)
    let missing = model.requiredEntries.filter {
      !FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
    }
    progress?(
      ModelDownloadProgress(
        model: model, phase: .finished, filesCompleted: files.count, filesTotal: files.count))
    return ModelVerification(
      model: model, checkedFiles: files.count, missing: missing,
      hasManifest: store.manifest(for: model) != nil)
  }

  // MARK: - Внутреннее

  private func existingBytes(for model: ModelID) -> Int64 {
    if let saved = progressByModel[model] { return saved }
    return store.isPresent(model) ? Self.files(for: model).reduce(0) { $0 + $1.size } : 0
  }

  /// План файлов: ключевые записи модели с размерами, пропорциональными ожидаемому объёму загрузки.
  static func files(for model: ModelID) -> [ModelFile] {
    let entries = model.requiredEntries
    guard !entries.isEmpty else {
      return [ModelFile(path: "model.bin", size: model.downloadSpec.approximateBytes)]
    }
    let total = max(model.downloadSpec.approximateBytes, Int64(entries.count))
    let share = total / Int64(entries.count)
    return entries.enumerated().map { index, entry in
      let isLast = index == entries.count - 1
      return ModelFile(
        path: entry, size: isLast ? total - share * Int64(entries.count - 1) : share)
    }
  }

  /// Сколько файлов «докачано» к этому числу байт.
  static func fileIndex(forBytes bytes: Int64, in files: [ModelFile]) -> Int {
    var accumulated: Int64 = 0
    for (index, file) in files.enumerated() {
      accumulated += file.size
      if bytes < accumulated { return index }
    }
    return max(files.count - 1, 0)
  }

  /// Заглушки файлов модели: `.mlmodelc` и записи без расширения — папки (как у настоящих моделей),
  /// остальное — пустые файлы. Так `ModelStore.isPresent` становится истиной без гигабайтов на диске.
  private func createFiles(for model: ModelID) throws {
    let directory = store.directory(for: model)
    let manager = FileManager.default
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      for entry in model.requiredEntries {
        let url = directory.appending(path: entry)
        let isFolder = url.pathExtension.isEmpty || url.pathExtension == "mlmodelc"
        if isFolder {
          try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } else if !manager.fileExists(atPath: url.path) {
          try Data().write(to: url, options: .atomic)
        }
      }
    } catch {
      throw ModelDownloadError.fileSystem(error.localizedDescription)
    }
  }
}
