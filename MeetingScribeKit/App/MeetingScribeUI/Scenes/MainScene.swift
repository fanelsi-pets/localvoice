import SwiftUI

/// Главное окно приложения (DESIGN.md §2) и меню-бар (§6). Вызывается из `@main` тонкого App-таргета.
public struct MainScene: Scene {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some Scene {
    WindowGroup("MeetingScribe") {
      MainWindow(model: model)
    }
    .commands {
      AppCommands(model: model)
    }
  }
}
