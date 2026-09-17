import Core
import FluidAudioAdapter
import Foundation
import ParakeetAdapter
import RemoteAdapter
import SpeakerKitAdapter
import WhisperKitAdapter

/// Единственная точка, знающая все адаптеры. Выбор движка в Settings и CLI идёт через идентификаторы из Core.
public enum EngineFactory {
  public static let defaultAsr: AsrEngineID = .whisperkit
  public static let defaultDiarizer: DiarizerID = .speakerkit
  public static let defaultWhisperModel: ModelID = .whisperLargeV3Turbo

  /// `remotes` — облачные провайдеры приложения-хоста по движку (ADR-010); облачный режим без своего
  /// провайдера недоступен.
  public static func makeAsr(
    _ id: AsrEngineID,
    model: ModelID? = nil,
    modelStore: ModelStore,
    remotes: [AsrEngineID: any RemoteTranscribing] = [:],
    verbose: Bool = false
  ) throws -> any AsrEngine {
    switch id {
    case .whisperkit:
      return WhisperKitEngine(
        modelStore: modelStore, model: model ?? defaultWhisperModel, verbose: verbose)
    case .parakeet:
      return ParakeetEngine(modelStore: modelStore)
    case .gemini, .azure:
      guard let remote = remotes[id] else {
        throw EngineError.modelUnavailable(
          String(
            localized: "облачное распознавание доступно только в приложении с ключом провайдера"))
      }
      return RemoteAsrEngine(client: remote)
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
    // Облако: локальных моделей распознавания нет, качать нечего.
    case .gemini, .azure: break
    }
    switch diarizer {
    case .speakerkit?: models.append(.speakerKitPyannote)
    case .fluidaudio?: models.append(.fluidDiarizer)
    case nil: break
    }
    return models
  }
}
