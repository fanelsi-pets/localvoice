import Foundation

/// Модуль интерфейса MeetingScribe (фаза 2, ADR-005). SwiftUI-вью и вью-модели живут в пакете, чтобы собираться
/// `swift build` и тестироваться `swift test`; точки входа для тонкого App-таргета — `MainScene` и `SettingsScene`.
/// Весь модуль изолирован на главном акторе по умолчанию (`defaultIsolation(MainActor)`), поэтому Codable-типы
/// здесь не объявляются — записи живут в модуле Store.
nonisolated public enum MeetingScribeUIInfo {
  public static let version = "1.0.3"
}
