import SwiftUI

/// Точки входа для приложения-хоста, в котором встречи — одна из функций (LocalVoice, ADR-010): корневой вью
/// окна встреч, команды меню и настройки ядра. Самостоятельный MeetingScribe использует `MainScene` и
/// `SettingsScene`; хост собирает свою сцену (`Window`) сам, потому что окном, активацией и строкой состояния
/// управляет он.
public struct MeetingsRootView: View {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    MainWindow(model: model)
  }
}

/// Команды меню ядра (DESIGN.md §6): импорт, обработка, экспорт, follow-up, поиск, переходы.
public struct MeetingsCommands: Commands {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some Commands {
    AppCommands(model: model)
  }
}

/// Настройки ядра (DESIGN.md §5) — для страницы настроек хоста.
public struct MeetingsSettingsView: View {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    SettingsView(model: model)
  }
}

/// Готовая сцена окна встреч для хоста: одно окно с идентификатором `id`, открывается через
/// `openWindow(id:)`; команды меню подключены.
public struct MeetingsWindowScene: Scene {
  private let model: AppModel
  private let id: String

  public init(model: AppModel, id: String = "meetings") {
    self.model = model
    self.id = id
  }

  public var body: some Scene {
    Window(Text("Встречи"), id: id) {
      MeetingsRootView(model: model)
    }
    .commands {
      MeetingsCommands(model: model)
    }
  }
}

/// Компактный статус текущей обработки (полоса, стадия, прогноз, пульс, «Отменить» — DESIGN.md §3b) для
/// страницы или строки состояния хоста; пусто, если обработки нет.
public struct MeetingsProcessingStatus: View {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    if let progress = model.toolbarProgress, !progress.isFinished {
      ProcessingToolbarStatus(model: model, progress: progress)
    }
  }
}

/// Приём перетащенных записей и папок Zoom на вью хоста: открывает диалог импорта ядра.
public enum MeetingsDrop {
  public static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
    DropSupport.handle(providers, model: model)
  }
}
