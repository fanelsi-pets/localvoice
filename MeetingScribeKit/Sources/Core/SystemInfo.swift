import Darwin
import Foundation
import Metal

/// Железо и ОС для проверки при первом запуске, вкладки «Диагностика» и отчётов (SPEC.md §2 п. 8, §3.8).
/// Значения снимаются один раз через `current()`; тип `Codable`, чтобы попадать в отчёт о проблеме как есть.
public struct SystemInfo: Hashable, Sendable, Codable {
  /// «Apple M5 Pro».
  public var chip: String?
  /// «Mac17,8».
  public var modelIdentifier: String?
  /// «arm64» / «x86_64».
  public var architecture: String
  public var isAppleSilicon: Bool
  public var physicalMemoryBytes: UInt64
  public var activeProcessorCount: Int
  /// «26.5.2».
  public var osVersion: String
  /// «25F84».
  public var osBuild: String?
  /// Имя Metal-устройства («Apple M5 Pro»); `nil` — Metal недоступен (песочница, виртуальная машина).
  public var gpuName: String?

  public init(
    chip: String?,
    modelIdentifier: String?,
    architecture: String,
    isAppleSilicon: Bool,
    physicalMemoryBytes: UInt64,
    activeProcessorCount: Int,
    osVersion: String,
    osBuild: String?,
    gpuName: String?
  ) {
    self.chip = chip
    self.modelIdentifier = modelIdentifier
    self.architecture = architecture
    self.isAppleSilicon = isAppleSilicon
    self.physicalMemoryBytes = physicalMemoryBytes
    self.activeProcessorCount = activeProcessorCount
    self.osVersion = osVersion
    self.osBuild = osBuild
    self.gpuName = gpuName
  }

  /// Neural Engine есть у всех чипов Apple Silicon; отдельного публичного API для проверки нет,
  /// CoreML сам выбирает ANE при `computeUnits = .all`.
  public var hasNeuralEngine: Bool { isAppleSilicon }

  /// Текущая машина. Metal-устройство создаётся здесь же: под песочницей агента и на виртуальных
  /// машинах его может не быть — это не ошибка, а факт для диагностики.
  public static func current() -> SystemInfo {
    let process = ProcessInfo.processInfo
    let version = process.operatingSystemVersion
    let architecture = sysctlString("hw.machine") ?? "unknown"
    let appleSilicon = sysctlInt("hw.optional.arm64") == 1 || architecture == "arm64"
    return SystemInfo(
      chip: sysctlString("machdep.cpu.brand_string"),
      modelIdentifier: sysctlString("hw.model"),
      architecture: architecture,
      isAppleSilicon: appleSilicon,
      physicalMemoryBytes: process.physicalMemory,
      activeProcessorCount: process.activeProcessorCount,
      osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
      osBuild: sysctlString("kern.osversion"),
      gpuName: MTLCreateSystemDefaultDevice()?.name
    )
  }

  /// Свободное место на томе, где лежит `url` (то, что система готова отдать под важные данные).
  public static func availableDiskBytes(at url: URL) -> Int64? {
    // Папки может ещё не быть (первый запуск): поднимаемся до существующего родителя.
    var probe = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
      probe = probe.deletingLastPathComponent()
    }
    let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  public static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }

  public static func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
  }
}

/// Проверка машины для онбординга и диагностики: что обязательно, что желательно. Тексты — для
/// пользователя (DESIGN.md §1: понятно, что случилось и что сделать).
public struct HardwareCheck: Hashable, Sendable {
  public enum Verdict: Hashable, Sendable {
    case ok
    case warning
    case failure
  }

  public struct Item: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var verdict: Verdict

    public init(id: String, title: String, detail: String, verdict: Verdict) {
      self.id = id
      self.title = title
      self.detail = detail
      self.verdict = verdict
    }
  }

  public var items: [Item]

  public init(items: [Item]) {
    self.items = items
  }

  /// Продолжать можно, если нет ни одного провала: без Apple Silicon модели CoreML не заработают,
  /// без места на диске их не скачать.
  public var canProceed: Bool { !items.contains { $0.verdict == .failure } }
  public var hasWarnings: Bool { items.contains { $0.verdict == .warning } }

  public static let minimumOSMajor = 26
  public static let recommendedMemoryBytes: UInt64 = 16 * 1_073_741_824
  public static let minimumMemoryBytes: UInt64 = 8 * 1_073_741_824
  /// Запас поверх объёма моделей: кэш аудио встреч и временные файлы CoreML.
  public static let diskReserveBytes: Int64 = 2 * 1_073_741_824

  /// - Parameters:
  ///   - requiredBytes: сколько байт моделей предстоит скачать.
  ///   - availableBytes: свободное место на томе моделей; `nil` — определить не удалось.
  public static func evaluate(
    _ info: SystemInfo, requiredBytes: Int64, availableBytes: Int64?
  ) -> HardwareCheck {
    var items: [Item] = []

    let chipName = info.chip ?? info.architecture
    items.append(
      Item(
        id: "chip",
        title: String(localized: "Процессор"),
        detail: info.isAppleSilicon
          ? String(localized: "\(chipName) — Neural Engine и GPU доступны для моделей CoreML")
          : String(
            localized:
              "\(chipName): нужен Mac с Apple Silicon — модели распознавания работают на Neural Engine"
          ),
        verdict: info.isAppleSilicon ? .ok : .failure))

    let major = Int(info.osVersion.split(separator: ".").first ?? "0") ?? 0
    items.append(
      Item(
        id: "os",
        title: "macOS",
        detail: major >= minimumOSMajor
          ? String(localized: "macOS \(info.osVersion)")
          : String(localized: "macOS \(info.osVersion): нужна macOS \(minimumOSMajor) или новее"),
        verdict: major >= minimumOSMajor ? .ok : .failure))

    let memory = ProcessMemory.format(info.physicalMemoryBytes)
    let memoryVerdict: Verdict
    let memoryDetail: String
    if info.physicalMemoryBytes >= recommendedMemoryBytes {
      memoryVerdict = .ok
      memoryDetail = String(localized: "\(memory) — хватит и для модели large-v3")
    } else if info.physicalMemoryBytes >= minimumMemoryBytes {
      memoryVerdict = .warning
      memoryDetail = String(
        localized:
          "\(memory): режим «точный» с large-v3 turbo работает, модель large-v3 может не поместиться"
      )
    } else {
      memoryVerdict = .warning
      memoryDetail = String(
        localized:
          "\(memory): мало для длинных записей — обрабатывайте встречи до часа и закрывайте другие приложения"
      )
    }
    items.append(
      Item(
        id: "memory", title: String(localized: "Память"), detail: memoryDetail,
        verdict: memoryVerdict)
    )

    let required = requiredBytes + diskReserveBytes
    let requiredText = ProcessMemory.format(UInt64(max(required, 0)))
    if let availableBytes {
      let availableText = ProcessMemory.format(UInt64(max(availableBytes, 0)))
      items.append(
        Item(
          id: "disk",
          title: String(localized: "Место на диске"),
          detail: availableBytes >= required
            ? String(localized: "Свободно \(availableText), нужно около \(requiredText)")
            : String(
              localized:
                "Свободно \(availableText), нужно около \(requiredText): освободите место перед загрузкой моделей"
            ),
          verdict: availableBytes >= required ? .ok : .failure))
    } else {
      items.append(
        Item(
          id: "disk",
          title: String(localized: "Место на диске"),
          detail: String(
            localized: "Не удалось определить свободное место; нужно около \(requiredText)"),
          verdict: .warning))
    }

    items.append(
      Item(
        id: "gpu",
        title: String(localized: "Графический процессор"),
        detail: info.gpuName.map { String(localized: "\($0) (Metal)") }
          ?? String(localized: "Metal недоступен — диаризация пойдёт на CPU медленнее"),
        verdict: info.gpuName == nil ? .warning : .ok))

    return HardwareCheck(items: items)
  }
}
