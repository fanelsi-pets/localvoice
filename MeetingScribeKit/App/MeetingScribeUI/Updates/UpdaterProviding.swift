import Foundation
import Observation

/// Источник обновлений приложения для пункта меню и секции настроек (ADR-009). У самостоятельного
/// MeetingScribe это Sparkle (`SparkleUpdater` в таргете `MeetingScribeSparkle`); у хоста, который встраивает
/// ядро как одну из функций (LocalVoice, ADR-010), — его собственный апдейтер или `NoUpdater`, тогда пункт
/// меню и секция настроек не показываются. Реализации — классы на главном акторе, наблюдаемые SwiftUI.
public protocol UpdaterProviding: AnyObject, Observable {
  /// Лента задана и апдейтер запущен.
  var isAvailable: Bool { get }
  /// Можно ли начать проверку сейчас (на время скачивания и установки — нельзя).
  var canCheckForUpdates: Bool { get }
  /// Проверять автоматически (тумблер в настройках).
  var automaticallyChecksForUpdates: Bool { get set }
  /// Скачивать и ставить без вопросов (тумблер в настройках).
  var automaticallyDownloadsUpdates: Bool { get set }
  /// Когда лента проверялась в последний раз.
  var lastUpdateCheckDate: Date? { get }
  /// «Проверить обновления…».
  func checkForUpdates()
}

/// Апдейтера нет: тесты, CLI-подобные сценарии и хост со своим механизмом обновлений.
@Observable
public final class NoUpdater: UpdaterProviding {
  public let isAvailable = false
  public let canCheckForUpdates = false
  public var automaticallyChecksForUpdates = false
  public var automaticallyDownloadsUpdates = false
  public let lastUpdateCheckDate: Date? = nil

  public init() {}

  public func checkForUpdates() {}
}
