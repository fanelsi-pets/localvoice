import Foundation

/// Поставщик зависимостей пайплайна для приложения: декодер и движки по выбору пользователя.
/// Боевая реализация (`ProductionEngines` в модуле Engines) кэширует экземпляры на сессию, чтобы модели
/// грузились один раз; сценарная (`ScriptedEngines`) даёт детерминированные фейки для UI-тестов и превью;
/// тесты вью-моделей подставляют фейки из TestSupport через замыкания.
public protocol EngineProviding: Sendable {
  /// Потоковый декодер записи (SPEC.md §3.1).
  func decoder() -> any AudioDecoding

  /// Движок распознавания по выбору; модели не грузит — это делает `AsrEngine.prepare` внутри пайплайна.
  func asr(for selection: EngineSelection) async throws -> any AsrEngine

  /// Диаризатор по выбору; `nil` — обработка без диаризации.
  func diarizer(for selection: EngineSelection) async throws -> (any Diarizer)?
}

/// Поставщик из замыканий — для тестов и превью.
public struct ClosureEngineProvider: EngineProviding {
  private let makeDecoder: @Sendable () -> any AudioDecoding
  private let makeAsr: @Sendable (EngineSelection) async throws -> any AsrEngine
  private let makeDiarizer: @Sendable (EngineSelection) async throws -> (any Diarizer)?

  public init(
    decoder: @escaping @Sendable () -> any AudioDecoding,
    asr: @escaping @Sendable (EngineSelection) async throws -> any AsrEngine,
    diarizer: @escaping @Sendable (EngineSelection) async throws -> (any Diarizer)?
  ) {
    self.makeDecoder = decoder
    self.makeAsr = asr
    self.makeDiarizer = diarizer
  }

  public func decoder() -> any AudioDecoding { makeDecoder() }

  public func asr(for selection: EngineSelection) async throws -> any AsrEngine {
    try await makeAsr(selection)
  }

  public func diarizer(for selection: EngineSelection) async throws -> (any Diarizer)? {
    try await makeDiarizer(selection)
  }
}
