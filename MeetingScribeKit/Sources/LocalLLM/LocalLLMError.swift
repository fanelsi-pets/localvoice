import Foundation

/// Ошибки локальной модели (SPEC.md §3.6). Тексты объясняют, что случилось и что сделать (docs/DESIGN.md §1).
/// Публичные вызовы `LocalLLMClient` бросают только эти ошибки: сетевые и системные заворачиваются в `network`.
public enum LocalLLMError: Error, LocalizedError, Hashable, Sendable {
  /// Адрес не разобран: нет схемы или хоста, либо схема не http/https.
  case invalidURL(String)
  /// Адрес ведёт за пределы этого Mac и локальной сети — транскрипт туда не уходит.
  case notLocalHost(String)
  /// Сервер ответил кодом вне 2xx; тело обрезано до `bodyLimit` символов.
  case badStatus(Int, body: String)
  /// Ответ пришёл, но это не OpenAI-совместимый JSON/SSE.
  case badResponse(String)
  /// Соединение не состоялось или оборвалось.
  case network(String)
  /// Модель ответила пустым текстом.
  case emptyAnswer
  /// Отмена пользователем или отмена задачи.
  case cancelled

  /// Сколько символов тела ответа попадает в ошибку: достаточно, чтобы понять причину, и не тащит транскрипт в лог.
  public static let bodyLimit = 300

  public var errorDescription: String? {
    switch self {
    case .invalidURL(let text):
      String(
        localized: """
          Адрес локальной модели «\(text)» не распознан. Укажите адрес вида http://localhost:1234/v1 \
          (LM Studio) или http://localhost:11434/v1 (Ollama).
          """)
    case .notLocalHost(let host):
      String(
        localized: """
          MeetingScribe отправляет транскрипты только на локальные адреса (localhost, .local, частная сеть): \
          \(host). Запустите модель на этом Mac и укажите её адрес.
          """)
    case .badStatus(let code, let body):
      Self.statusDescription(code: code, body: body)
    case .badResponse(let details):
      String(
        localized: """
          Не удалось разобрать ответ локальной модели: \(details). Убедитесь, что по этому адресу работает \
          OpenAI-совместимый сервер (LM Studio или Ollama), а не другое приложение.
          """)
    case .network(let reason):
      String(
        localized: """
          Не удалось связаться с локальной моделью: \(reason). Проверьте, что LM Studio или Ollama запущены \
          и слушают указанный адрес.
          """)
    case .emptyAnswer:
      String(
        localized: """
          Локальная модель вернула пустой ответ. Попробуйте ещё раз или выберите другую модель — возможно, \
          встреча не поместилась в контекст.
          """)
    case .cancelled:
      String(localized: "Генерация follow-up отменена.")
    }
  }

  private static func statusDescription(code: Int, body: String) -> String {
    let tail = body.isEmpty ? "" : String(localized: " Ответ сервера: \(body)")
    switch code {
    case 300..<400:
      return String(
        localized: """
          Сервер по этому адресу попытался перенаправить запрос на другой адрес (\(code)). \
          MeetingScribe не выходит за пределы локальной сети, поэтому перенаправление не выполнено: \
          укажите прямой адрес локальной модели (http://localhost:1234/v1).\(tail)
          """)
    case 400:
      return String(
        localized: """
          Локальный сервер отклонил запрос (400). Чаще всего дело в имени модели: выберите модель из списка \
          в настройках.\(tail)
          """)
    case 401, 403:
      return String(
        localized: """
          Локальный сервер требует ключ (\(code)). MeetingScribe не отправляет ключи и токены — отключите \
          проверку ключа на сервере.\(tail)
          """)
    case 404:
      return String(
        localized: """
          Локальный сервер ответил «404 — не найдено». Проверьте путь /v1 в адресе (http://localhost:1234/v1) \
          и имя модели: в LM Studio модель должна быть загружена, в Ollama — скачана (ollama pull).\(tail)
          """)
    case 413:
      return String(
        localized: """
          Запрос слишком велик (413). Сократите контекст встречи или выберите модель с большим окном \
          контекста.\(tail)
          """)
    case 500...599:
      return String(
        localized: """
          Локальный сервер вернул ошибку \(code). Посмотрите его журнал (LM Studio → Developer Logs, \
          Ollama → вывод `ollama serve`) и попробуйте другую модель.\(tail)
          """)
    default:
      return String(localized: "Локальный сервер ответил кодом \(code).\(tail)")
    }
  }

  /// Обрезает тело ответа для сообщения об ошибке.
  static func shortBody(_ text: String) -> String {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.count > bodyLimit else { return clean }
    return String(clean.prefix(bodyLimit)) + "…"
  }

  /// Приводит любую ошибку к `LocalLLMError`: свои — как есть, отмену — в `cancelled`, остальное — в `network`.
  static func wrap(_ error: any Error) -> LocalLLMError {
    if let known = error as? LocalLLMError { return known }
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError { return from(urlError) }
    return .network(error.localizedDescription)
  }

  private static func from(_ error: URLError) -> LocalLLMError {
    switch error.code {
    case .cancelled:
      return .cancelled
    case .cannotConnectToHost:
      return .network(
        String(
          localized:
            "подключение отклонено (connection refused) — сервер не запущен или занят другой порт"))
    case .cannotFindHost:
      return .network(String(localized: "хост не найден"))
    case .timedOut:
      return .network(String(localized: "сервер не ответил за отведённое время"))
    case .networkConnectionLost:
      return .network(String(localized: "соединение разорвано во время ответа"))
    case .unsupportedURL, .badURL:
      return .invalidURL(error.failingURL?.absoluteString ?? error.localizedDescription)
    case .secureConnectionFailed, .serverCertificateUntrusted:
      return .network(
        String(
          localized:
            "не удалось установить защищённое соединение — попробуйте http:// вместо https://"))
    default:
      return .network(error.localizedDescription)
    }
  }
}
