import Foundation

/// Клиент OpenAI-совместимого сервера на этой машине (SPEC.md §3.6). Никаких ключей, заголовков авторизации и
/// телеметрии: единственный адрес, к которому идёт обращение, — `configuration.normalizedBaseURL`, и он
/// проверяется `LocalHostPolicy` до открытия соединения.
public struct LocalLLMClient: Sendable {
  /// Системное сообщение короткое: формат ответа задаёт промпт follow-up, а не настройки клиента.
  public static let systemPrompt = """
    Ты помощник, который делает follow-up рабочих встреч. Отвечай по-русски, строго соблюдай формат из \
    инструкции пользователя.
    """

  /// Список моделей нужен интерактивно (экран настроек), поэтому ждём недолго.
  private static let modelsTimeout: TimeInterval = 15
  /// Потолок на чтение непотокового ответа: follow-up по часовой встрече — это единицы килобайт.
  private static let bodyLimitBytes = 4 * 1024 * 1024

  /// Перенаправления проверяются тем же правилом, что и исходный адрес (см. `LocalOnlyRedirects`).
  private static let redirects = LocalOnlyRedirects()

  private let session: URLSession

  public init(session: URLSession = LocalLLMClient.defaultSession) {
    self.session = session
  }

  /// Сессия по умолчанию: одна на процесс, соединения переиспользуются.
  public static let defaultSession = makeSession()

  /// Собственная сессия вместо `URLSession.shared`: та уважает системный HTTP-прокси и PAC (тело
  /// запроса с транскриптом ушло бы на прокси-хост, а сам PAC-файл скачивался бы из сети) и делит
  /// кэш и cookies со всем процессом. Здесь прокси отключён явно, кэша и cookies нет.
  public static func makeSession() -> URLSession {
    URLSession(configuration: sessionConfiguration())
  }

  static func sessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    // Пустой словарь — это «прокси не использовать»; `nil` означал бы «взять системные настройки».
    configuration.connectionProxyDictionary = [:]
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    // Локальный сервер либо запущен, либо нет: ждать появления сети незачем — лучше сразу ошибка.
    configuration.waitsForConnectivity = false
    return configuration
  }

  /// `GET {base}/models` — список моделей сервера (у LM Studio и Ollama путь одинаковый).
  public func listModels(baseURL: URL) async throws -> [LocalLLMModel] {
    try LocalHostPolicy.validate(baseURL)
    var request = URLRequest(
      url: LocalLLMConfiguration.normalized(baseURL).appending(path: "models"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = Self.modelsTimeout
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false

    do {
      let (data, response) = try await session.data(for: request, delegate: Self.redirects)
      guard let http = response as? HTTPURLResponse else {
        throw LocalLLMError.badResponse(String(localized: "сервер ответил не по HTTP"))
      }
      guard (200..<300).contains(http.statusCode) else {
        throw LocalLLMError.badStatus(
          http.statusCode, body: LocalLLMError.shortBody(String(decoding: data, as: UTF8.self)))
      }
      return try Self.models(from: data)
    } catch {
      throw LocalLLMError.wrap(error)
    }
  }

  /// `POST {base}/chat/completions` со `stream: true`: дельты текста отдаются по мере прихода событий SSE.
  /// Отмена задачи-потребителя обрывает соединение и завершает поток ошибкой `cancelled`.
  ///
  /// Элементы потока приходят из задачи загрузки, то есть вне главного актора: интерфейс обновляется
  /// только после перехода на свою изоляцию.
  public func streamChat(prompt: String, configuration: LocalLLMConfiguration)
    -> AsyncThrowingStream<String, any Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await send(prompt: prompt, configuration: configuration) { delta in
            continuation.yield(delta)
          }
          continuation.finish()
        } catch {
          let failure = Task.isCancelled ? LocalLLMError.cancelled : LocalLLMError.wrap(error)
          continuation.finish(throwing: failure)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Собирает поток в одну строку; `onDelta` получает куски по дороге (для «пульса» в интерфейсе, SPEC.md §3.7).
  ///
  /// `onDelta` вызывается вне главного актора (из задачи, читающей поток), поэтому он `@Sendable`:
  /// состояние интерфейса из него меняют только через свою изоляцию (`MainActor`).
  public func complete(
    prompt: String,
    configuration: LocalLLMConfiguration,
    onDelta: (@Sendable (String) -> Void)? = nil
  ) async throws -> String {
    var answer = ""
    do {
      for try await delta in streamChat(prompt: prompt, configuration: configuration) {
        if Task.isCancelled { throw LocalLLMError.cancelled }
        answer += delta
        onDelta?(delta)
      }
    } catch {
      throw LocalLLMError.wrap(error)
    }
    // Поток AsyncThrowingStream на отмене просто заканчивается — отличаем обрыв от честного конца ответа.
    if Task.isCancelled { throw LocalLLMError.cancelled }
    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalLLMError.emptyAnswer
    }
    return answer
  }

  // MARK: - Запрос и чтение ответа

  private func send(
    prompt: String,
    configuration: LocalLLMConfiguration,
    onDelta: @Sendable (String) -> Void
  ) async throws {
    // Проверка адреса — до соединения: ни одного пакета наружу, даже неудачного.
    try LocalHostPolicy.validate(configuration.baseURL)
    let request = try Self.chatRequest(prompt: prompt, configuration: configuration)
    let (bytes, response) = try await session.bytes(for: request, delegate: Self.redirects)
    guard let http = response as? HTTPURLResponse else {
      throw LocalLLMError.badResponse(String(localized: "сервер ответил не по HTTP"))
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = await Self.collectText(bytes, limit: 8 * 1024)
      throw LocalLLMError.badStatus(http.statusCode, body: LocalLLMError.shortBody(body))
    }

    let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? "")
      .lowercased()
    if contentType.contains("event-stream") {
      try await Self.readEvents(bytes, onDelta: onDelta)
      return
    }
    // Сервер не поддержал стриминг и ответил обычным JSON — отдаём весь текст одной дельтой.
    let body = await Self.collectText(bytes, limit: Self.bodyLimitBytes)
    if Task.isCancelled { throw LocalLLMError.cancelled }
    let answer = try Self.answer(fromBody: body)
    if !answer.isEmpty { onDelta(answer) }
  }

  static func chatRequest(prompt: String, configuration: LocalLLMConfiguration)
    throws(LocalLLMError)
    -> URLRequest
  {
    var request = URLRequest(
      url: configuration.normalizedBaseURL.appending(path: "chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.timeoutInterval = max(1, configuration.requestTimeout.seconds)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false

    let body = ChatRequestBody(
      model: configuration.model,
      messages: [
        .init(role: "system", content: systemPrompt),
        .init(role: "user", content: prompt),
      ],
      stream: true,
      temperature: configuration.temperature,
      maxTokens: configuration.maxTokens)
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw .badResponse(
        String(localized: "не удалось собрать запрос: \(error.localizedDescription)"))
    }
    return request
  }

  /// Читает поток SSE построчно (`bytes.lines` сам склеивает строку, разрезанную между пакетами)
  /// и собирает многострочные события через `ServerSentEventReader`.
  private static func readEvents(
    _ bytes: URLSession.AsyncBytes, onDelta: @Sendable (String) -> Void
  ) async throws {
    // Один декодер на весь поток: событий в ответе тысячи.
    let decoder = JSONDecoder()
    var reader = ServerSentEventReader()
    for try await line in bytes.lines {
      if Task.isCancelled { throw LocalLLMError.cancelled }
      guard let event = reader.append(line) else { continue }
      if try handle(event: event, decoder: decoder, onDelta: onDelta) { return }
    }
    // Последнее событие может прийти без пустой строки в конце потока.
    if let event = reader.finish() {
      _ = try handle(event: event, decoder: decoder, onDelta: onDelta)
    }
  }

  /// `true` — сервер объявил конец ответа.
  private static func handle(
    event: String, decoder: JSONDecoder, onDelta: @Sendable (String) -> Void
  ) throws -> Bool {
    switch try ServerSentEvent.parse(event: event, decoder: decoder) {
    case .ignore:
      return false
    case .delta(let piece):
      onDelta(piece)
      return false
    case .done(let piece):
      if let piece { onDelta(piece) }
      return true
    }
  }

  /// Собирает тело целиком (ошибка сервера или ответ без стриминга). Не бросает: прочитанное нужно показать
  /// в сообщении об ошибке, даже если соединение оборвалось на середине. Лимит считается по байтам потока,
  /// а не по строкам: тело без единого перевода строки не должно съесть всю память.
  private static func collectText(_ bytes: URLSession.AsyncBytes, limit: Int) async -> String {
    var buffer: [UInt8] = []
    buffer.reserveCapacity(min(limit, 64 * 1024))
    do {
      for try await byte in bytes.prefix(limit) {
        if Task.isCancelled { break }
        buffer.append(byte)
      }
    } catch {
      // Оборванное тело: возвращаем то, что успели прочитать.
    }
    return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .newlines)
  }

  /// Ответ без стриминга: обычный JSON, а если сервер всё-таки прислал события — читаем их как поток.
  static func answer(fromBody text: String) throws(LocalLLMError) -> String {
    if let data = text.data(using: .utf8),
      let chunk = try? JSONDecoder().decode(ChatResponseChunk.self, from: data)
    {
      if let error = chunk.error { throw .badResponse(error.message) }
      if chunk.choices != nil { return chunk.text ?? "" }
    }
    var collected = ""
    let decoder = JSONDecoder()
    var reader = ServerSentEventReader()
    var events = text.split(separator: "\n", omittingEmptySubsequences: false)
      .compactMap { reader.append(String($0)) }
    if let tail = reader.finish() { events.append(tail) }
    for event in events {
      switch try ServerSentEvent.parse(event: event, decoder: decoder) {
      case .ignore:
        continue
      case .delta(let piece):
        collected += piece
      case .done(let piece):
        return collected + (piece ?? "")
      }
    }
    guard !collected.isEmpty else {
      throw .badResponse(String(localized: "ответ не похож ни на JSON OpenAI, ни на поток событий"))
    }
    return collected
  }

  static func models(from data: Data) throws(LocalLLMError) -> [LocalLLMModel] {
    let decoder = JSONDecoder()
    if let decoded = try? decoder.decode(ModelsResponse.self, from: data) {
      if let error = decoded.error { throw .badResponse(error.message) }
      if let list = decoded.data ?? decoded.models { return cleaned(list) }
    }
    if let list = try? decoder.decode([LocalLLMModel].self, from: data) { return cleaned(list) }
    throw .badResponse(String(localized: "в ответе нет списка моделей (ожидалось поле data)"))
  }

  private static func cleaned(_ models: [LocalLLMModel]) -> [LocalLLMModel] {
    var seen = Set<String>()
    return models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
  }
}

/// Ответ `3xx` — способ увести транскрипт с этой машины: за локальный адрес не выходим ни при каком редиректе.
/// Возврат `nil` оставляет ответ сервера как есть, и клиент сообщает о нём как о `badStatus`.
private final class LocalOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, LocalHostPolicy.isLocal(url) else { return nil }
    return request
  }
}

extension Duration {
  /// Длительность в секундах для `URLRequest.timeoutInterval`.
  var seconds: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
  }
}
