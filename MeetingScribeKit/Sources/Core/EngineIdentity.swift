import Foundation

/// Идентификаторы движков для Settings и CLI. Экземпляры создаёт `EngineFactory` в модуле Engines.
public enum AsrEngineID: String, CaseIterable, Codable, Sendable, Hashable {
  case whisperkit
  case parakeet

  public var title: String {
    switch self {
    case .whisperkit: "WhisperKit (Whisper large-v3)"
    case .parakeet: "Parakeet TDT v3 (FluidAudio)"
    }
  }
}

public enum DiarizerID: String, CaseIterable, Codable, Sendable, Hashable {
  case speakerkit
  case fluidaudio

  public var title: String {
    switch self {
    case .speakerkit: "SpeakerKit (pyannote community-1)"
    case .fluidaudio: "FluidAudio VBx"
    }
  }
}

/// Выбор движков для одной обработки: хранится в записи встречи и в Settings; экземпляры даёт `EngineProviding`.
public struct EngineSelection: Hashable, Codable, Sendable {
  public var asr: AsrEngineID
  /// Модель WhisperKit; для Parakeet не используется.
  public var whisperModel: ModelID
  /// `nil` — обработка без диаризации.
  public var diarizer: DiarizerID?

  public init(
    asr: AsrEngineID = .whisperkit,
    whisperModel: ModelID = .whisperLargeV3Turbo,
    diarizer: DiarizerID? = .speakerkit
  ) {
    self.asr = asr
    self.whisperModel = whisperModel
    self.diarizer = diarizer
  }

  /// Точный режим по умолчанию (ADR-002): WhisperKit large-v3 turbo + SpeakerKit.
  public static let accurate = EngineSelection()

  /// Быстрый режим: Parakeet TDT v3 (без выбора языка — второе мнение, не основной путь для смешанной речи).
  public static let fast = EngineSelection(asr: .parakeet, diarizer: .speakerkit)

  /// Ожидаемая стоимость распознавания для плана прогресса — секунд работы на секунду аудио
  /// (замеры фазы 0: turbo 0.05, large-v3 0.12, Parakeet 0.006).
  public var asrRate: Double {
    switch asr {
    case .parakeet: 0.006
    case .whisperkit: whisperModel == .whisperLargeV3 ? 0.12 : 0.05
    }
  }

  /// «WhisperKit large-v3 turbo + SpeakerKit» — для шапки встречи и Settings.
  public var title: String {
    let asrTitle: String =
      switch asr {
      case .whisperkit:
        whisperModel == .whisperLargeV3 ? "WhisperKit large-v3" : "WhisperKit large-v3 turbo"
      case .parakeet: "Parakeet TDT v3"
      }
    let diarizerTitle: String? =
      switch diarizer {
      case .speakerkit?: "SpeakerKit"
      case .fluidaudio?: "FluidAudio VBx"
      case nil: nil
      }
    return [asrTitle, diarizerTitle].compactMap { $0 }.joined(separator: " + ")
  }
}
