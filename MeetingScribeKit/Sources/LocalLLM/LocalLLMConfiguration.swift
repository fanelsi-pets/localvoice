import Foundation

/// Настройки локальной модели (SPEC.md §3.6: «локальная LLM через OpenAI-совместимый endpoint… по умолчанию
/// выключено»). Ключей и токенов здесь нет и не будет: локальные серверы их не требуют.
public struct LocalLLMConfiguration: Hashable, Sendable {
  /// Адрес в том виде, как его ввёл пользователь: «http://localhost:1234/v1» или «http://localhost:1234».
  public var baseURL: URL
  /// Идентификатор модели у сервера (`id` из `/v1/models`).
  public var model: String
  /// Низкая температура: follow-up — это структурированный пересказ, а не сочинение.
  public var temperature: Double
  /// Потолок ответа; `nil` — не ограничивать (решает сервер).
  public var maxTokens: Int?
  /// Локальная модель на 30B думает долго — ждём до конца, отмена у пользователя всегда под рукой.
  public var requestTimeout: Duration

  public init(
    baseURL: URL,
    model: String,
    temperature: Double = 0.2,
    maxTokens: Int? = 4096,
    requestTimeout: Duration = .seconds(600)
  ) {
    self.baseURL = baseURL
    self.model = model
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.requestTimeout = requestTimeout
  }

  /// LM Studio: Developer → Start Server слушает 1234.
  public static let lmStudioDefaultURL = URL(string: "http://localhost:1234/v1")!
  /// Ollama: `ollama serve` слушает 11434, OpenAI-совместимый слой — на том же `/v1`.
  public static let ollamaDefaultURL = URL(string: "http://localhost:11434/v1")!

  /// Базовый URL, к которому дописываются `chat/completions` и `models`.
  ///
  /// Правила (проверяются тестами `LocalLLMConfigurationTests`):
  /// - путь пуст или «/» → подставляется `/v1` («http://localhost:1234» → «http://localhost:1234/v1»);
  /// - хвостовой «/» убирается («…/v1/» → «…/v1»), `/v1` не дублируется;
  /// - **свой путь пользователя не переписывается**: «…/api» остаётся «…/api». За обратным прокси
  ///   OpenAI-совместимый API монтируют куда угодно, и молча дописанный `/v1` дал бы 404 по адресу, которого
  ///   пользователь не видел. Если путь всё же неверен, сервер ответит 404, а `LocalLLMError.badStatus`
  ///   прямо попросит проверить `/v1`;
  /// - строка запроса и фрагмент отбрасываются: у базового адреса их не бывает, а `appending(path:)` их ломает.
  public var normalizedBaseURL: URL { Self.normalized(baseURL) }

  static func normalized(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
      return url
    }
    components.query = nil
    components.fragment = nil
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path.isEmpty ? "/v1" : path
    return components.url ?? url
  }
}
