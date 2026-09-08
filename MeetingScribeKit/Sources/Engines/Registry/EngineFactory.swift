import Core
import FluidAudioAdapter
import Foundation
import ParakeetAdapter
import SpeakerKitAdapter
import WhisperKitAdapter

/// Единственная точка, знающая все адаптеры. Выбор движка в Settings и CLI идёт через идентификаторы из Core.
public enum EngineFactory {
  public static let defaultAsr: AsrEngineID = .whisperkit
  public static let defaultDiarizer: DiarizerID = .speakerkit
  public static let defaultWhisperModel: ModelID = .whisperLargeV3Turbo

  public static func makeAsr(
    _ id: AsrEngineID,
    model: ModelID? = nil,
    modelStore: ModelStore,
    verbose: Bool = false
  ) -> any AsrEngine {
    switch id {
    case .whisperkit:
      WhisperKitEngine(
        modelStore: modelStore, model: model ?? defaultWhisperModel, verbose: verbose)
    case .parakeet:
      ParakeetEngine(modelStore: modelStore)
    }
  }

  public static func makeDiarizer(
    _ id: DiarizerID,
    modelStore: ModelStore,
    verbose: Bool = false
  ) -> any Diarizer {
    switch id {
    case .speakerkit:
      SpeakerKitDiarizer(modelStore: modelStore, verbose: verbose)
    case .fluidaudio:
      FluidAudioDiarizer(modelStore: modelStore)
    }
  }

  /// Модели, нужные выбранной паре движков (для `models download` и онбординга).
  public static func requiredModels(asr: AsrEngineID, whisperModel: ModelID?, diarizer: DiarizerID?)
    -> [ModelID]
  {
    var models: [ModelID] = []
    switch asr {
    case .whisperkit:
      models.append(contentsOf: [whisperModel ?? defaultWhisperModel, .whisperTokenizer])
    case .parakeet: models.append(.parakeetTDTv3)
    }
    switch diarizer {
    case .speakerkit?: models.append(.speakerKitPyannote)
    case .fluidaudio?: models.append(.fluidDiarizer)
    case nil: break
    }
    return models
  }
}
