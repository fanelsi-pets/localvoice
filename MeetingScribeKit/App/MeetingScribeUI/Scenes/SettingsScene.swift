import SwiftUI

/// Окно Settings (DESIGN.md §5): вкладки Общие, Движки и модели, Языки, Диагностика.
public struct SettingsScene: Scene {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some Scene {
    Settings {
      SettingsView(model: model)
    }
  }
}
