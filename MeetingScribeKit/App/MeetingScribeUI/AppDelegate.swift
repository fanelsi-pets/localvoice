import AppKit
import Foundation

/// Делегат приложения: подтверждение выхода при идущей обработке и продолжение работы при закрытом окне
/// (SPEC.md §3.7 п. 8). Подключается из `@main` через `@NSApplicationDelegateAdaptor`; модель отдаётся
/// статически, потому что делегат создаёт SwiftUI, а не приложение.
public final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Модель приложения. Выставляется в `@main` рядом с созданием `AppModel.live()`.
  public static weak var model: AppModel?

  public override init() {
    super.init()
  }

  /// Обработка продолжается при закрытом окне: очередь живёт в `ProcessingCoordinator`, а не во вью.
  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Подтверждение выхода при идущей обработке и ожидание записи библиотеки — логика в модели, чтобы делегат
  /// хоста (ADR-010) отвечал так же.
  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Self.model?.applicationShouldTerminate(sender) ?? .terminateNow
  }
}
