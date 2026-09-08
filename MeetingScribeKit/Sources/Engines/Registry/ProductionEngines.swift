import Core
import Foundation
import Ingest

/// Боевой поставщик движков для приложения. Экземпляры кэшируются на сессию: адаптеры держат загруженную модель
/// (`SharedLoader`), поэтому вторая встреча не грузит Whisper заново (~1 с после компиляции CoreML, но
/// первая загрузка на машине — до 100 с). При смене выбора прежний экземпляр того же рода отпускается,
/// чтобы не держать в памяти две модели Whisper одновременно.
public actor ProductionEngines: EngineProviding {
  private struct AsrKey: Hashable {
    var id: AsrEngineID
    var model: ModelID
  }

  private let modelStore: ModelStore
  private let verbose: Bool
  private var asrCache: [AsrKey: any AsrEngine] = [:]
  private var diarizerCache: [DiarizerID: any Diarizer] = [:]

  public init(modelStore: ModelStore = .standard(), verbose: Bool = false) {
    self.modelStore = modelStore
    self.verbose = verbose
  }

  public nonisolated func decoder() -> any AudioDecoding {
    AudioDecoder()
  }

  public func asr(for selection: EngineSelection) async throws -> any AsrEngine {
    let key = AsrKey(id: selection.asr, model: selection.whisperModel)
    if let cached = asrCache[key] { return cached }
    asrCache.removeAll()
    let engine = EngineFactory.makeAsr(
      selection.asr, model: selection.whisperModel, modelStore: modelStore, verbose: verbose)
    asrCache[key] = engine
    return engine
  }

  public func diarizer(for selection: EngineSelection) async throws -> (any Diarizer)? {
    guard let id = selection.diarizer else { return nil }
    if let cached = diarizerCache[id] { return cached }
    diarizerCache.removeAll()
    let diarizer = EngineFactory.makeDiarizer(id, modelStore: modelStore, verbose: verbose)
    diarizerCache[id] = diarizer
    return diarizer
  }

  /// Отпускает все экземпляры — модели выгружаются из памяти.
  public func releaseAll() {
    asrCache.removeAll()
    diarizerCache.removeAll()
  }
}
