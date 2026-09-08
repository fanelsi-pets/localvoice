import Core
import Foundation
import LocalLLM

/// Генератор follow-up (SPEC.md §3.6): локальная модель ядра или провайдер приложения-хоста
/// (LocalVoice — Gemini с ключом пользователя, ADR-010). Кнопка «Создать follow-up» появляется, когда
/// генератор есть; недоступный генератор показывает причину.
public protocol FollowupGenerating: AnyObject {
  /// Название для кнопки: «локальная модель», «Gemini».
  var title: String { get }
  var isAvailable: Bool { get }
  /// Почему недоступен — подсказка пользователю (нет ключа, не настроен адрес).
  var unavailableReason: String? { get }
  /// Куски ответа по мере появления; провайдер без потока отдаёт весь текст одним куском.
  func generate(prompt: String) -> AsyncThrowingStream<String, any Error>
}

/// Ошибки генератора, общие для ядра и хоста.
public enum FollowupGeneratorError: Error, LocalizedError {
  case notConfigured

  public var errorDescription: String? {
    switch self {
    case .notConfigured: String(localized: "Генератор follow-up не настроен")
    }
  }
}

/// Локальная модель через OpenAI-совместимый endpoint (LM Studio, Ollama) — генератор ядра.
public final class LocalLLMFollowupGenerator: FollowupGenerating {
  private let configuration: LocalLLMConfiguration?
  private let client: LocalLLMClient

  public init(configuration: LocalLLMConfiguration?, client: LocalLLMClient = LocalLLMClient()) {
    self.configuration = configuration
    self.client = client
  }

  public var title: String { String(localized: "локальная модель") }

  public var isAvailable: Bool { configuration != nil }

  public var unavailableReason: String? {
    isAvailable
      ? nil
      : String(
        localized:
          "Включите её в «Настройки → Follow-up», укажите адрес сервера (LM Studio или Ollama) и выберите модель."
      )
  }

  public func generate(prompt: String) -> AsyncThrowingStream<String, any Error> {
    guard let configuration else {
      return AsyncThrowingStream { $0.finish(throwing: FollowupGeneratorError.notConfigured) }
    }
    return client.streamChat(prompt: prompt, configuration: configuration)
  }
}
