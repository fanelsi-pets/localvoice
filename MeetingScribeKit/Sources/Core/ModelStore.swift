import Foundation

/// Модели, которые умеет скачивать и хранить приложение.
public enum ModelID: String, CaseIterable, Codable, Sendable, Hashable {
  case whisperLargeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"
  case whisperLargeV3 = "openai_whisper-large-v3"
  case speakerKitPyannote = "speakerkit-coreml"
  case parakeetTDTv3 = "parakeet-tdt-0.6b-v3"
  case fluidDiarizer = "speaker-diarization"
  /// Токенизатор Whisper: WhisperKit грузит его отдельно от модели (`ModelUtilities.loadTokenizer`).
  case whisperTokenizer = "whisper-large-v3-tokenizer"

  public var title: String {
    switch self {
    case .whisperLargeV3Turbo: "Whisper large-v3 turbo (WhisperKit)"
    case .whisperLargeV3: String(localized: "Whisper large-v3 (WhisperKit, максимальное качество)")
    case .whisperTokenizer: String(localized: "Токенизатор Whisper (openai/whisper-large-v3)")
    case .speakerKitPyannote: "SpeakerKit pyannote community-1"
    case .parakeetTDTv3: "Parakeet TDT 0.6B v3 (FluidAudio)"
    case .fluidDiarizer: "FluidAudio speaker-diarization (VBx)"
    }
  }

  /// Репозиторий Hugging Face (все не gated, токен не нужен).
  public var hubRepo: String {
    switch self {
    case .whisperLargeV3Turbo, .whisperLargeV3: "argmaxinc/whisperkit-coreml"
    case .whisperTokenizer: "openai/whisper-large-v3"
    case .speakerKitPyannote: "argmaxinc/speakerkit-coreml"
    case .parakeetTDTv3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    case .fluidDiarizer: "FluidInference/speaker-diarization-coreml"
    }
  }

  /// Ожидаемый размер загрузки, МБ (для онбординга) — из `downloadSpec` (точные байты даёт листинг).
  public var approximateSizeMB: Int {
    Int(downloadSpec.approximateBytes / 1_000_000)
  }

  public var license: String {
    switch self {
    case .whisperLargeV3Turbo, .whisperLargeV3, .whisperTokenizer: "MIT (OpenAI Whisper)"
    case .speakerKitPyannote, .fluidDiarizer: "CC-BY-4.0 (pyannote community-1)"
    case .parakeetTDTv3: "CC-BY-4.0 (NVIDIA)"
    }
  }

  /// Путь папки модели относительно `ModelStore.root`. Раскладка повторяет кэш библиотек:
  /// `hf/` — downloadBase для argmax (Hub-раскладка `models/<org>/<repo>`), `fluid/` — папка моделей FluidAudio.
  public var relativePath: String {
    switch self {
    case .whisperLargeV3Turbo, .whisperLargeV3:
      "hf/models/argmaxinc/whisperkit-coreml/\(rawValue)"
    case .whisperTokenizer:
      "hf/models/openai/whisper-large-v3"
    case .speakerKitPyannote:
      "hf/models/argmaxinc/speakerkit-coreml"
    case .parakeetTDTv3:
      "fluid/parakeet-tdt-0.6b-v3"
    case .fluidDiarizer:
      "fluid/speaker-diarization"
    }
  }

  /// Файлы и папки, без которых модель неполна: обрыв скачивания или импорта не должен выглядеть готовой моделью.
  public var requiredEntries: [String] {
    switch self {
    case .whisperLargeV3Turbo, .whisperLargeV3:
      ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
    case .whisperTokenizer:
      ["tokenizer.json", "config.json"]
    case .speakerKitPyannote:
      ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"]
    case .parakeetTDTv3:
      [
        "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json",
      ]
    case .fluidDiarizer:
      ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
    }
  }

  /// Папки репозиториев, которые `importExisting` переносит из старых кэшей (`<org>/<repo>` для Hub, имя папки для FluidAudio).
  static var importableHubRepos: Set<String> {
    Set(allCases.filter { $0.relativePath.hasPrefix("hf/") }.map(\.hubRepo))
  }

  static var importableFluidFolders: Set<String> {
    Set(
      allCases.filter { $0.relativePath.hasPrefix("fluid/") }.map {
        String($0.relativePath.dropFirst("fluid/".count))
      })
  }
}

/// Состояние модели на диске.
public struct ModelStatus: Hashable, Sendable {
  public var id: ModelID
  public var url: URL
  public var isPresent: Bool
  public var sizeBytes: UInt64?

  public init(id: ModelID, url: URL, isPresent: Bool, sizeBytes: UInt64?) {
    self.id = id
    self.url = url
    self.isPresent = isPresent
    self.sizeBytes = sizeBytes
  }
}

/// Единственный источник путей к моделям (CLAUDE.md). Корень — `~/Library/Application Support/MeetingScribe/Models`,
/// переопределяется переменной окружения `MEETINGSCRIBE_MODELS_DIR` (CLI, тесты).
public struct ModelStore: Hashable, Sendable {
  public static let environmentVariable = "MEETINGSCRIBE_MODELS_DIR"
  public static let applicationSupportSubpath = "MeetingScribe/Models"

  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  /// Стандартное хранилище: переменная окружения либо Application Support.
  public static func standard(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> ModelStore {
    if let override = environment[environmentVariable], !override.isEmpty {
      return ModelStore(root: URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
    }
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    return ModelStore(root: base.appending(path: applicationSupportSubpath))
  }

  /// `downloadBase` для WhisperKit/SpeakerKit (внутри Hub кладёт `models/<org>/<repo>`).
  public var hfBase: URL { root.appending(path: "hf") }

  /// Папка моделей FluidAudio (внутри — `parakeet-tdt-0.6b-v3`, `speaker-diarization`).
  public var fluidBase: URL { root.appending(path: "fluid") }

  public func directory(for model: ModelID) -> URL {
    root.appending(path: model.relativePath)
  }

  /// Модель считается присутствующей, если на месте все её ключевые файлы (`ModelID.requiredEntries`)
  /// и в папке нет недокачанных частей `.part`: загрузчик создаёт папки заранее, и без этой проверки
  /// остановленная на последнем файле модель выглядела бы готовой, а движок падал бы на загрузке.
  public func isPresent(_ model: ModelID, fileManager: FileManager = .default) -> Bool {
    let url = directory(for: model)
    guard
      model.requiredEntries.allSatisfy({
        fileManager.fileExists(atPath: url.appending(path: $0).path)
      })
    else { return false }
    return !hasIncompleteDownload(model, fileManager: fileManager)
  }

  /// Есть ли в папке модели части `.part` незавершённой загрузки.
  public func hasIncompleteDownload(_ model: ModelID, fileManager: FileManager = .default) -> Bool {
    let url = directory(for: model)
    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { return false }
    for case let file as URL in enumerator where file.pathExtension == "part" {
      return true
    }
    return false
  }

  public func ensureDirectories(fileManager: FileManager = .default) throws {
    for url in [root, hfBase.appending(path: "models"), fluidBase] {
      do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      } catch {
        throw ModelStoreError.cannotCreateDirectory(url, reason: error.localizedDescription)
      }
    }
  }

  public func status(fileManager: FileManager = .default) -> [ModelStatus] {
    ModelID.allCases.map { id in
      let url = directory(for: id)
      let present = isPresent(id, fileManager: fileManager)
      return ModelStatus(
        id: id,
        url: url,
        isPresent: present,
        sizeBytes: present ? Self.directorySize(url, fileManager: fileManager) : nil
      )
    }
  }

  // MARK: - Импорт уже скачанных моделей

  /// Где модели лежат после прогонов `argmax-cli` и `fluidaudiocli` (docs/BENCH-2026-09-02.md).
  public struct LegacyLocations: Hashable, Sendable {
    /// `~/Documents/huggingface/models` — Hub-кэш WhisperKit/SpeakerKit по умолчанию.
    public var huggingFaceModels: URL
    /// `~/Library/Application Support/FluidAudio/Models`.
    public var fluidAudioModels: URL

    public init(huggingFaceModels: URL, fluidAudioModels: URL) {
      self.huggingFaceModels = huggingFaceModels
      self.fluidAudioModels = fluidAudioModels
    }

    public static func standard(fileManager: FileManager = .default) -> LegacyLocations {
      let home = fileManager.homeDirectoryForCurrentUser
      let appSupport =
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? home.appending(path: "Library/Application Support")
      return LegacyLocations(
        huggingFaceModels: home.appending(path: "Documents/huggingface/models"),
        fluidAudioModels: appSupport.appending(path: "FluidAudio/Models")
      )
    }
  }

  public struct ImportReport: Hashable, Sendable {
    public var imported: [String] = []
    public var skipped: [String] = []
    public var missingSources: [String] = []
    /// «имя: причина» — сбои копирования отдельных папок; остальные переносятся.
    public var failed: [String] = []

    public init() {}
  }

  /// Переносит известные модели (`ModelID`) из старых кэшей в хранилище (на APFS `copyItem` создаёт клоны —
  /// быстро и без места). Существующие папки не перезаписываются; чужие репозитории не трогаются.
  public func importExisting(
    from legacy: LegacyLocations? = nil,
    fileManager: FileManager = .default
  ) throws -> ImportReport {
    let legacy = legacy ?? .standard(fileManager: fileManager)
    try ensureDirectories(fileManager: fileManager)
    var report = ImportReport()

    // Hub-раскладка: models/<org>/<repo> → hf/models/<org>/<repo>, папка репозитория целиком (включая .cache).
    if let organizations = Self.subdirectories(
      of: legacy.huggingFaceModels, fileManager: fileManager)
    {
      for organization in organizations {
        for repo in Self.subdirectories(of: organization, fileManager: fileManager) ?? [] {
          let label = "\(organization.lastPathComponent)/\(repo.lastPathComponent)"
          guard ModelID.importableHubRepos.contains(label) else { continue }
          let destination = hfBase.appending(path: "models")
            .appending(path: organization.lastPathComponent)
            .appending(path: repo.lastPathComponent)
          try Self.copyIfMissing(
            repo, to: destination, label: label, report: &report, fileManager: fileManager)
        }
      }
    } else {
      report.missingSources.append(legacy.huggingFaceModels.path)
    }

    if let repos = Self.subdirectories(of: legacy.fluidAudioModels, fileManager: fileManager) {
      for repo in repos where ModelID.importableFluidFolders.contains(repo.lastPathComponent) {
        let destination = fluidBase.appending(path: repo.lastPathComponent)
        try Self.copyIfMissing(
          repo, to: destination, label: "FluidAudio/\(repo.lastPathComponent)",
          report: &report, fileManager: fileManager)
      }
    } else {
      report.missingSources.append(legacy.fluidAudioModels.path)
    }
    return report
  }

  // MARK: - Внутреннее

  private static func subdirectories(of url: URL, fileManager: FileManager) -> [URL]? {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return nil }
    return entries.filter {
      (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func copyIfMissing(
    _ source: URL,
    to destination: URL,
    label: String,
    report: inout ImportReport,
    fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: destination.path) {
      report.skipped.append(label)
      return
    }
    do {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.copyItem(at: source, to: destination)
      report.imported.append(label)
    } catch {
      try? fileManager.removeItem(at: destination)
      report.failed.append("\(label): \(error.localizedDescription)")
    }
  }

  private static func directorySize(_ url: URL, fileManager: FileManager) -> UInt64? {
    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey], options: [])
    else { return nil }
    var total: UInt64 = 0
    for case let file as URL in enumerator {
      if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        total += UInt64(size)
      }
    }
    return total
  }
}
