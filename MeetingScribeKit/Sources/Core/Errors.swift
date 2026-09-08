import Foundation

/// Ошибки ингеста. Тексты объясняют, что случилось и что сделать (docs/DESIGN.md §1).
public enum IngestError: Error, LocalizedError, Hashable, Sendable {
  case fileNotFound(URL)
  case noAudioTrack(URL)
  case unsupportedContainer(URL, reason: String)
  case decodingFailed(URL, reason: String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .fileNotFound(let url):
      String(
        localized: "Файл не найден: \(url.path). Проверьте, что запись не перемещена и не удалена.")
    case .noAudioTrack(let url):
      String(
        localized:
          "Файл «\(url.lastPathComponent)» не содержит аудиодорожки. Экспортируйте запись из Zoom заново или выберите audio*.m4a."
      )
    case .unsupportedContainer(let url, let reason):
      String(
        localized:
          "Формат файла «\(url.lastPathComponent)» не поддерживается (\(reason)). Конвертируйте запись в MP4 или M4A."
      )
    case .decodingFailed(let url, let reason):
      String(localized: "Не удалось декодировать «\(url.lastPathComponent)»: \(reason).")
    case .cancelled:
      String(localized: "Подготовка аудио отменена.")
    }
  }
}

/// Ошибки движков распознавания и диаризации.
public enum EngineError: Error, LocalizedError, Hashable, Sendable {
  case modelUnavailable(String)
  case notPrepared(String)
  case unsupported(String)
  case invalidAudio(String)
  case inferenceFailed(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .modelUnavailable(let details):
      String(
        localized: "Модель недоступна: \(details). Скачайте модели в Settings → Движки и модели.")
    case .notPrepared(let engine):
      String(localized: "Движок \(engine) не подготовлен: модели не загружены.")
    case .unsupported(let details):
      String(localized: "Операция не поддерживается: \(details).")
    case .invalidAudio(let details):
      String(localized: "Некорректное аудио: \(details).")
    case .inferenceFailed(let details):
      String(localized: "Ошибка распознавания: \(details).")
    case .cancelled:
      String(localized: "Обработка отменена.")
    }
  }
}

/// Ошибки хранилища моделей.
public enum ModelStoreError: Error, LocalizedError, Hashable, Sendable {
  case cannotCreateDirectory(URL, reason: String)
  case importFailed(String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .cannotCreateDirectory(let url, let reason):
      String(localized: "Не удалось создать папку моделей \(url.path): \(reason).")
    case .importFailed(let name, let reason):
      String(localized: "Не удалось импортировать модель \(name): \(reason).")
    }
  }
}
