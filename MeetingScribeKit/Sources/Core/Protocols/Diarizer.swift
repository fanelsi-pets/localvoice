import Foundation

/// Подсказки диаризатору. Автоопределение числа спикеров ненадёжно (PLAN.md §4): число подаётся извне.
public struct DiarizationHints: Hashable, Codable, Sendable {
  public var minSpeakers: Int?
  public var maxSpeakers: Int?
  public var expectedSpeakers: Int?
  /// Разрешить turn'ам разных спикеров перекрываться (наложение речи). По умолчанию каждый кадр отдаётся одному
  /// спикеру (SpeakerKit: `useExclusiveReconciliation`), и наложения не размечаются — открытый вопрос ADR-002,
  /// решается экспериментом фазы 1 (ADR-003). Флаг влияет только на turn'ы для `Fuser`.
  public var allowOverlappingTurns: Bool

  public init(
    minSpeakers: Int? = nil,
    maxSpeakers: Int? = nil,
    expectedSpeakers: Int? = nil,
    allowOverlappingTurns: Bool = false
  ) {
    self.minSpeakers = minSpeakers
    self.maxSpeakers = maxSpeakers
    self.expectedSpeakers = expectedSpeakers
    self.allowOverlappingTurns = allowOverlappingTurns
  }

  public static let none = DiarizationHints()
}

/// Диаризатор (SPEC.md §3.3). Реализации — акторы в модулях Engines/*.
public protocol Diarizer: Sendable {
  var descriptor: EngineDescriptor { get }

  /// Скачивает (при необходимости) и загружает модели.
  func prepare(progress: ProgressSink?) async throws

  /// Делит запись по голосам. Отмена — через отмену задачи Swift.
  func diarize(_ audio: PCMAudio, hints: DiarizationHints, progress: ProgressSink?) async throws
    -> DiarizationResult
}

extension Diarizer {
  /// Отпечаток голоса одного человека по его речи (SPEC.md §3.4): та же модель эмбеддингов, что и в диаризации,
  /// поэтому вектор лежит в одном пространстве с центроидами `DiarizationResult.embeddings` и сравним с ними.
  /// Реализация по умолчанию — диаризация фрагмента с подсказкой «один спикер»; если движок всё же выделил
  /// несколько кластеров, берётся центроид самого говорящего. `nil` — движок центроидов не отдаёт.
  /// Аудио — уже склеенная речь одного человека (пробы из `LanguageRouter.Probe` или речевые отрезки дорожки).
  public func voiceEmbedding(for audio: PCMAudio, progress: ProgressSink? = nil) async throws
    -> [Float]?
  {
    guard audio.duration >= 1 else { return nil }
    let result = try await diarize(
      audio, hints: DiarizationHints(expectedSpeakers: 1), progress: progress)
    guard !result.embeddings.isEmpty else { return nil }
    let dominant =
      result.speechDistribution.first { result.embeddings[$0.speakerID] != nil }?.speakerID
      ?? result.embeddings.keys.sorted().first
    return dominant.flatMap { result.embeddings[$0] }
  }
}
