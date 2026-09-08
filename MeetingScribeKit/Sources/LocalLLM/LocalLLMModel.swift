import Foundation

/// Модель, которую предлагает локальный сервер (`id` из `GET {base}/models`).
public struct LocalLLMModel: Hashable, Sendable, Identifiable, Codable {
  public var id: String

  public init(id: String) {
    self.id = id
  }
}
