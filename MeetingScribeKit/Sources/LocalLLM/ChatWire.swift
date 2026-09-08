import Foundation

// Формат OpenAI Chat Completions в минимальном объёме: что отправляем и что умеем прочитать.
// LM Studio и Ollama отдают один и тот же контракт, поэтому движко-специфичного кода здесь нет.

/// Тело запроса `POST {base}/chat/completions`.
struct ChatRequestBody: Encodable {
  struct Message: Encodable, Hashable {
    let role: String
    let content: String
  }

  let model: String
  let messages: [Message]
  let stream: Bool
  let temperature: Double
  let maxTokens: Int?

  enum CodingKeys: String, CodingKey {
    case model, messages, stream, temperature
    case maxTokens = "max_tokens"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encode(stream, forKey: .stream)
    try container.encode(temperature, forKey: .temperature)
    // Ключа `max_tokens: null` быть не должно: часть серверов принимает его за 0 и обрывает ответ.
    try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
  }
}

/// Ответ `chat/completions` — и потоковый кусок (`delta`), и обычный (`message`).
struct ChatResponseChunk: Decodable {
  struct Choice: Decodable {
    struct Content: Decodable {
      let content: String?
    }

    let delta: Content?
    let message: Content?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case delta, message
      case finishReason = "finish_reason"
    }
  }

  let choices: [Choice]?
  let error: APIErrorPayload?

  /// Текст первого варианта: в потоке — `delta.content`, в обычном ответе — `message.content`.
  var text: String? {
    guard let choice = choices?.first else { return nil }
    return choice.delta?.content ?? choice.message?.content
  }

  /// Сервер объявил, что вариант завершён.
  var isFinished: Bool {
    guard let reason = choices?.first?.finishReason else { return false }
    return !reason.isEmpty
  }
}

/// Ответ `GET {base}/models`.
struct ModelsResponse: Decodable {
  let data: [LocalLLMModel]?
  /// Часть серверов отдаёт список под ключом `models` — принимаем и такой ответ.
  let models: [LocalLLMModel]?
  let error: APIErrorPayload?
}

/// `{"error": {"message": "…"}}` или `{"error": "…"}` — встречаются оба вида.
struct APIErrorPayload: Decodable {
  let message: String

  private enum CodingKeys: String, CodingKey {
    case message
  }

  init(from decoder: any Decoder) throws {
    if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self)
    {
      message = text
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    message =
      (try? container.decode(String.self, forKey: .message))
      ?? String(localized: "сервер не пояснил причину")
  }
}

/// Разбор события потока SSE (`text/event-stream`).
enum ServerSentEvent {
  /// Что делать с очередным событием.
  enum Outcome: Hashable {
    /// Служебное событие: комментарий `:`, пустая строка, `event:`/`id:`/`retry:`, неизвестный JSON.
    case ignore
    /// Текстовая дельта.
    case delta(String)
    /// `data: [DONE]` или `finish_reason` — поток закончился.
    case done(String?)
  }

  static let doneMarker = "[DONE]"

  /// Терпимый разбор: неизвестные поля и нечитаемые куски пропускаются, ошибкой считается только явный `error`
  /// от сервера — иначе редкий keep-alive ломал бы генерацию, которая шла минуту.
  static func parse(event: String, decoder: JSONDecoder = JSONDecoder()) throws(LocalLLMError)
    -> Outcome
  {
    let payload = event.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else { return .ignore }
    if payload == doneMarker { return .done(nil) }
    guard let data = payload.data(using: .utf8),
      let chunk = try? decoder.decode(ChatResponseChunk.self, from: data)
    else {
      return .ignore
    }
    if let error = chunk.error { throw .badResponse(error.message) }
    let text = chunk.text.flatMap { $0.isEmpty ? nil : $0 }
    return chunk.isFinished ? .done(text) : (text.map { Outcome.delta($0) } ?? .ignore)
  }
}

/// Сборка событий SSE из строк потока.
///
/// По спецификации несколько строк `data:` подряд — это одно событие: их значения склеиваются через
/// `\n` и отдаются на пустой строке-разделителе. Разбирать такие строки по отдельности нельзя —
/// получается обрывок JSON, и кусок ответа модели молча пропадает.
///
/// Пустая строка приходит не всегда: `AsyncLineSequence` её не отдаёт. Поэтому событие считается
/// собранным ещё и тогда, когда накопленный текст стал целым JSON-объектом (это и есть обычный
/// однострочный случай), а остаток отдаёт `finish()` в конце потока.
struct ServerSentEventReader {
  /// Значения `data:` незакрытого события.
  private var pending: [String] = []
  /// Столько строк в одном событии не бывает: буфер сбрасывается, чтобы мусор не съел весь ответ.
  private static let lineLimit = 64

  /// Очередная строка потока; `nil` — событие ещё не собрано.
  mutating func append(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return finish() }
    guard !trimmed.hasPrefix(":"), trimmed.hasPrefix("data:") else { return nil }
    let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    guard !payload.isEmpty else { return nil }
    if payload == ServerSentEvent.doneMarker {
      pending.removeAll()
      return payload
    }
    pending.append(String(payload))
    let event = pending.joined(separator: "\n")
    if Self.isCompleteObject(event) {
      pending.removeAll()
      return event
    }
    // Строка целая сама по себе — значит, в буфере остался обрывок события, которое сервер не дописал.
    if pending.count > 1, Self.isCompleteObject(String(payload)) {
      pending.removeAll()
      return String(payload)
    }
    if pending.count >= Self.lineLimit { pending.removeAll() }
    return nil
  }

  /// Конец потока (или разделитель): последнее событие без пустой строки тоже надо разобрать.
  mutating func finish() -> String? {
    guard !pending.isEmpty else { return nil }
    defer { pending.removeAll() }
    return pending.joined(separator: "\n")
  }

  private static func isCompleteObject(_ text: String) -> Bool {
    guard text.hasPrefix("{") else { return false }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
  }
}
