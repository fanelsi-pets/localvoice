import Foundation

// Контракт скачивания моделей (SPEC.md §3.7 п. 10, §3.8): прогресс в байтах, докачка после обрыва,
// проверка контрольных сумм. Реализация — модуль ModelDownload (сеть только здесь и в проверке
// обновлений); сценарная заглушка — в Engines для UI-тестов; интерфейс работает через протокол.

/// Откуда и что скачивать для модели: репозиторий Hugging Face, ревизия, подпапка и записи верхнего
/// уровня. Точные файлы и байты даёт листинг дерева (`ModelDownloading.plan`); `approximateBytes` —
/// оценка для онбординга до первого запроса в сеть (замер по HF tree API 2026-09-05).
public struct ModelDownloadSpec: Hashable, Sendable {
  public var repo: String
  public var revision: String
  /// Подпапка репозитория, которая и есть папка модели; `nil` — корень репозитория.
  public var subpath: String?
  /// Файлы и папки верхнего уровня (относительно `subpath`), которые нужны; `nil` — всё содержимое.
  public var entries: [String]?
  /// Ожидаемый объём, байт.
  public var approximateBytes: Int64

  public init(
    repo: String, revision: String = "main", subpath: String? = nil, entries: [String]? = nil,
    approximateBytes: Int64
  ) {
    self.repo = repo
    self.revision = revision
    self.subpath = subpath
    self.entries = entries
    self.approximateBytes = approximateBytes
  }

  /// Путь в репозитории для файла модели («<subpath>/<path>»).
  public func remotePath(for relativePath: String) -> String {
    guard let subpath, !subpath.isEmpty else { return relativePath }
    return "\(subpath)/\(relativePath)"
  }

  /// Нужна ли запись дерева: сравнивается первый компонент пути относительно `subpath`.
  public func includes(relativePath: String) -> Bool {
    guard let entries else { return true }
    let first = relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    return entries.contains(first)
  }
}

extension ModelID {
  /// Что скачивать. Наборы файлов совпадают с тем, что кладут сами библиотеки (проверено по папкам
  /// после `argmax-cli`/FluidAudio): целиком тянуть репозитории FluidAudio нельзя — там по несколько
  /// вариантов энкодера (parakeet — 3.6 GB против 0.48 GB нужных).
  public var downloadSpec: ModelDownloadSpec {
    switch self {
    case .whisperLargeV3Turbo:
      ModelDownloadSpec(repo: hubRepo, subpath: rawValue, approximateBytes: 1_638_500_000)
    case .whisperLargeV3:
      ModelDownloadSpec(repo: hubRepo, subpath: rawValue, approximateBytes: 3_090_300_000)
    case .whisperTokenizer:
      ModelDownloadSpec(
        repo: hubRepo, entries: ["config.json", "tokenizer.json", "tokenizer_config.json"],
        approximateBytes: 2_800_000)
    case .speakerKitPyannote:
      ModelDownloadSpec(
        repo: hubRepo, entries: ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"],
        approximateBytes: 33_100_000)
    case .parakeetTDTv3:
      ModelDownloadSpec(
        repo: hubRepo,
        entries: [
          "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
          "JointDecisionv3.mlmodelc",
          "config.json", "parakeet_vocab.json", "parakeet_v3_vocab.json",
        ],
        approximateBytes: 483_000_000)
    case .fluidDiarizer:
      ModelDownloadSpec(
        repo: hubRepo,
        entries: [
          "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc",
          "config.json", "plda-parameters.json", "xvector-transform.json",
        ],
        approximateBytes: 22_000_000)
    }
  }
}

/// Один файл модели: путь внутри папки модели, размер и контрольная сумма из листинга Hugging Face
/// (LFS — sha256 содержимого; остальные — git-oid, sha1 от «blob <size>\0<содержимое>»).
public struct ModelFile: Hashable, Sendable, Codable {
  public var path: String
  public var size: Int64
  public var sha256: String?
  public var blobSHA1: String?

  public init(path: String, size: Int64, sha256: String? = nil, blobSHA1: String? = nil) {
    self.path = path
    self.size = size
    self.sha256 = sha256
    self.blobSHA1 = blobSHA1
  }
}

/// План скачивания после листинга: точные файлы, байты и сколько из них уже лежит на диске
/// (готовые файлы и части `.part`, с которых продолжится загрузка).
public struct ModelDownloadPlan: Hashable, Sendable {
  public var model: ModelID
  /// Ревизия репозитория (sha коммита, если API его отдал, иначе имя ветки).
  public var revision: String
  public var files: [ModelFile]
  public var existingBytes: Int64
  /// Байты только целых файлов (без частей): при отказе сервера от `Range` часть качается заново,
  /// поэтому свободное место считается по этому значению.
  public var completedBytes: Int64

  public init(
    model: ModelID, revision: String, files: [ModelFile], existingBytes: Int64 = 0,
    completedBytes: Int64 = 0
  ) {
    self.model = model
    self.revision = revision
    self.files = files
    self.existingBytes = existingBytes
    self.completedBytes = completedBytes
  }

  public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
  public var remainingBytes: Int64 { max(totalBytes - existingBytes, 0) }
  /// Сколько может понадобиться скачать в худшем случае (части не в счёт).
  public var bytesToFetchWorstCase: Int64 { max(totalBytes - completedBytes, 0) }
}

/// Событие прогресса скачивания одной модели: байты, файлы, скорость (SPEC.md §3.7 п. 10).
public struct ModelDownloadProgress: Hashable, Sendable {
  public enum Phase: String, Hashable, Sendable, Codable {
    /// Листинг репозитория (короткая сетевая операция без байтов).
    case listing
    case downloading
    case verifying
    case finished
  }

  public var model: ModelID
  public var phase: Phase
  public var bytesCompleted: Int64
  public var bytesTotal: Int64
  public var filesCompleted: Int
  public var filesTotal: Int
  /// Файл, который качается или проверяется сейчас (путь внутри папки модели).
  public var currentFile: String?
  /// Скорость по скользящему окну, байт/с; `nil` — ещё не измерена.
  public var bytesPerSecond: Double?
  public var timestamp: Date

  public init(
    model: ModelID,
    phase: Phase,
    bytesCompleted: Int64 = 0,
    bytesTotal: Int64 = 0,
    filesCompleted: Int = 0,
    filesTotal: Int = 0,
    currentFile: String? = nil,
    bytesPerSecond: Double? = nil,
    timestamp: Date = Date()
  ) {
    self.model = model
    self.phase = phase
    self.bytesCompleted = bytesCompleted
    self.bytesTotal = bytesTotal
    self.filesCompleted = filesCompleted
    self.filesTotal = filesTotal
    self.currentFile = currentFile
    self.bytesPerSecond = bytesPerSecond
    self.timestamp = timestamp
  }

  /// Доля 0…1 по байтам; без известного объёма — 0, после завершения — 1.
  public var fraction: Double {
    if phase == .finished { return 1 }
    guard bytesTotal > 0 else { return 0 }
    return min(max(Double(bytesCompleted) / Double(bytesTotal), 0), 1)
  }
}

public typealias ModelDownloadProgressSink = @Sendable (ModelDownloadProgress) -> Void

/// Манифест скачанной модели — `<папка модели>/.meetingscribe-manifest.json`: откуда, какой ревизии,
/// какие файлы и суммы. По нему вкладка «Диагностика» показывает версии моделей, а `verify` проверяет
/// файлы без сети.
public struct ModelManifest: Hashable, Sendable, Codable {
  public static let fileName = ".meetingscribe-manifest.json"

  public var model: ModelID
  public var repo: String
  public var revision: String
  public var files: [ModelFile]
  public var downloadedAt: Date
  /// Версия приложения или CLI, которые скачали модель.
  public var downloaderVersion: String

  public init(
    model: ModelID, repo: String, revision: String, files: [ModelFile], downloadedAt: Date = Date(),
    downloaderVersion: String
  ) {
    self.model = model
    self.repo = repo
    self.revision = revision
    self.files = files
    self.downloadedAt = downloadedAt
    self.downloaderVersion = downloaderVersion
  }

  public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

  /// Короткая ревизия для интерфейса («a1b2c3d» либо «main»).
  public var shortRevision: String {
    revision.count > 12 ? String(revision.prefix(7)) : revision
  }
}

extension ModelStore {
  public func manifestURL(for model: ModelID) -> URL {
    directory(for: model).appending(path: ModelManifest.fileName)
  }

  /// Манифест модели, если она скачана этим приложением; модели из старых кэшей манифеста не имеют.
  public func manifest(for model: ModelID, fileManager: FileManager = .default) -> ModelManifest? {
    let url = manifestURL(for: model)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder.decode(ModelManifest.self, from: data)
  }

  public func writeManifest(_ manifest: ModelManifest, fileManager: FileManager = .default) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = manifestURL(for: manifest.model)
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(manifest).write(to: url, options: .atomic)
    } catch {
      throw ModelStoreError.cannotCreateDirectory(url, reason: error.localizedDescription)
    }
  }
}

/// Итог проверки модели на диске.
public struct ModelVerification: Hashable, Sendable {
  public var model: ModelID
  public var checkedFiles: Int
  public var missing: [String]
  public var corrupted: [String]
  /// Манифеста нет — проверить можно только присутствие ключевых файлов (`ModelID.requiredEntries`).
  public var hasManifest: Bool

  public init(
    model: ModelID, checkedFiles: Int, missing: [String] = [], corrupted: [String] = [],
    hasManifest: Bool
  ) {
    self.model = model
    self.checkedFiles = checkedFiles
    self.missing = missing
    self.corrupted = corrupted
    self.hasManifest = hasManifest
  }

  public var isValid: Bool { missing.isEmpty && corrupted.isEmpty }
}

/// Ошибки скачивания. Тексты объясняют, что случилось и что сделать (DESIGN.md §1).
public enum ModelDownloadError: Error, LocalizedError, Hashable, Sendable {
  /// Сети нет или сервер недоступен.
  case offline(String)
  case listingFailed(repo: String, reason: String)
  case httpStatus(Int, file: String)
  case checksumMismatch(file: String)
  case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
  case fileSystem(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .offline(let reason):
      String(
        localized:
          "Нет соединения с Hugging Face: \(reason). Проверьте интернет и нажмите «Продолжить» — загрузка продолжится с того же места."
      )
    case .listingFailed(let repo, let reason):
      String(localized: "Не удалось получить список файлов \(repo): \(reason).")
    case .httpStatus(let status, let file):
      String(
        localized: "Сервер ответил \(status) на запрос файла \(file). Повторите попытку позже.")
    case .checksumMismatch(let file):
      String(
        localized:
          "Контрольная сумма файла \(file) не совпала: файл скачан повреждённым и будет скачан заново."
      )
    case .insufficientDiskSpace(let required, let available):
      String(
        localized:
          "Недостаточно места на диске: нужно \(ProcessMemory.format(UInt64(max(required, 0)))), свободно \(ProcessMemory.format(UInt64(max(available, 0)))). Освободите место и повторите."
      )
    case .fileSystem(let reason):
      String(localized: "Не удалось записать файл модели: \(reason).")
    case .cancelled:
      String(localized: "Скачивание остановлено. Скачанное сохранено — можно продолжить позже.")
    }
  }
}

/// Скачивание и проверка моделей. Реализации: `ModelDownloader` (модуль ModelDownload, сеть),
/// `ScriptedModelDownloader` (Engines, заглушка для UI-тестов). Все методы вызываются из любого контекста;
/// колбэки прогресса приходят с произвольных потоков.
public protocol ModelDownloading: Sendable {
  /// Листинг репозитория: точные файлы и байты, включая уже скачанное. Нужна сеть.
  func plan(_ model: ModelID) async throws -> ModelDownloadPlan

  /// Докачивает недостающее (с `Range`-докачкой частей), проверяет контрольные суммы, пишет манифест.
  /// Отмена задачи Swift сохраняет частично скачанное и бросает `ModelDownloadError.cancelled`.
  func download(_ model: ModelID, progress: ModelDownloadProgressSink?) async throws
    -> ModelManifest

  /// Проверяет файлы модели по манифесту без сети; без манифеста — только присутствие ключевых файлов.
  func verify(_ model: ModelID, progress: ModelDownloadProgressSink?) async throws
    -> ModelVerification
}

extension ModelDownloading {
  /// Скачивает несколько моделей по очереди; прогресс — по каждой модели отдельно.
  public func download(_ models: [ModelID], progress: ModelDownloadProgressSink?) async throws
    -> [ModelManifest]
  {
    var manifests: [ModelManifest] = []
    for model in models {
      manifests.append(try await download(model, progress: progress))
    }
    return manifests
  }
}
