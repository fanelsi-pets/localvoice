import Core
import Foundation

// Экспорт TranscribeFull (SPEC.md §3.5): шапка, участники, контекст проекта, транскрипт с таймкодами
// и готовый промпт для follow-up (SPEC.md §3.6). Формат зафиксирован golden-файлом
// Tests/ExportTests/Golden/TranscribeFull_fixture.md.

/// Контекст проекта из предыдущих встреч (SPEC.md §3.6): открытые сущности библиотеки встреч,
/// которые попадают в шапку следующего экспорта. `nil` в опциях — секция опускается целиком.
///
/// Структура хранит данные, а не готовые строки: форматирование дат и таймкодов — дело рендера
/// (`options.timeZone`, `Timecode`), источник решения подставляет вызывающий (`sourceFileName`).
public struct ProjectContext: Hashable, Sendable {
  /// Решение прошлой встречи: `- [2026-08-14] текст (источник: TranscribeFull_2026-08-14.md, 00:41:12)`.
  public struct Decision: Hashable, Sendable {
    public var text: String
    /// Дата встречи, на которой решение принято; `nil` — дата не показывается.
    public var meetingDate: Date?
    /// Таймкод реплики в секундах от начала той записи.
    public var timestamp: Double?
    /// Имя файла экспорта той встречи («TranscribeFull_2026-08-14.md»); задаёт вызывающий.
    public var sourceFileName: String?

    public init(
      text: String, meetingDate: Date? = nil, timestamp: Double? = nil,
      sourceFileName: String? = nil
    ) {
      self.text = text
      self.meetingDate = meetingDate
      self.timestamp = timestamp
      self.sourceFileName = sourceFileName
    }
  }

  /// Открытая задача: `- [ ] текст — Имя, до 2026-09-10`.
  public struct Action: Hashable, Sendable {
    public var text: String
    /// Ответственный, если назван в разговоре.
    public var owner: String?
    /// Срок ISO-днём («2026-09-10»); строка, потому что дня без времени в `Date` нет.
    public var due: String?

    public init(text: String, owner: String? = nil, due: String? = nil) {
      self.text = text
      self.owner = owner
      self.due = due
    }
  }

  /// Открытый вопрос: `- текст` (SPEC.md §3.5). Дата встречи хранится для библиотеки, в шапку не идёт.
  public struct Question: Hashable, Sendable {
    public var text: String
    public var meetingDate: Date?

    public init(text: String, meetingDate: Date? = nil) {
      self.text = text
      self.meetingDate = meetingDate
    }
  }

  public var decisions: [Decision]
  public var actions: [Action]
  public var questions: [Question]

  public init(decisions: [Decision] = [], actions: [Action] = [], questions: [Question] = []) {
    self.decisions = decisions
    self.actions = actions
    self.questions = questions
  }

  public var isEmpty: Bool { decisions.isEmpty && actions.isEmpty && questions.isEmpty }
}

public struct TranscribeFullOptions: Sendable {
  /// Таймкоды с десятыми долями.
  public var tenths: Bool
  /// Помечать реплики на наложении речи.
  public var markOverlap: Bool
  public var includeFollowupPrompt: Bool
  public var projectContext: ProjectContext?
  /// Дата обработки в шапке; `nil` — `transcript.createdAt`.
  public var processedAt: Date?
  public var timeZone: TimeZone

  public init(
    tenths: Bool = false,
    markOverlap: Bool = false,
    includeFollowupPrompt: Bool = true,
    projectContext: ProjectContext? = nil,
    processedAt: Date? = nil,
    timeZone: TimeZone = .current
  ) {
    self.tenths = tenths
    self.markOverlap = markOverlap
    self.includeFollowupPrompt = includeFollowupPrompt
    self.projectContext = projectContext
    self.processedAt = processedAt
    self.timeZone = timeZone
  }
}

/// Встроенный промпт для внешней модели: просит вернуть блок ```meeting-followup (SPEC.md §3.6).
/// Формат блока разбирает парсер follow-up (фаза 4), поэтому текст описывает поля буквально.
public enum FollowupPrompt {
  public static let text = """
    Выше — полная расшифровка рабочей встречи с таймкодами и именами участников.

    Разбери её и ответь по-русски:
    1. Краткое резюме встречи: 5–7 предложений о том, что обсуждали и к чему пришли.
    2. Принятые решения — списком, у каждого таймкод реплики, в которой решение прозвучало.
    3. Задачи — списком: что сделать, кто ответственный и к какому сроку (только если это названо \
    в разговоре, не додумывай).
    4. Открытые вопросы — то, что осталось без ответа.

    В конце ответа ОБЯЗАТЕЛЬНО добавь блок ровно в таком виде — его читает программа, поэтому внутри \
    должен быть только JSON:

    ```meeting-followup
    {"decisions":[{"text":"...","timestamp":"00:41:12"}],
     "actions":[{"text":"...","owner":"Имя","due":"2026-09-10"}],
     "questions":[{"text":"..."}],
     "summary":"..."}
    ```

    Поля блока:
    - decisions[].text — формулировка решения; decisions[].timestamp — таймкод реплики из транскрипта \
    в формате HH:MM:SS.
    - actions[].text — что нужно сделать; actions[].owner — имя участника из раздела «Участники» \
    или null; actions[].due — срок в формате ISO (ГГГГ-ММ-ДД) или null.
    - questions[].text — вопрос, оставшийся без ответа.
    - summary — то же резюме одной строкой.

    Если решений, задач или вопросов не было, оставь соответствующий массив пустым. Ничего, кроме JSON, \
    внутри блока не пиши.
    """
}

public enum TranscribeFullExporter {
  /// Полный Markdown по структуре SPEC.md §3.5.
  public static func render(_ transcript: Transcript, options: TranscribeFullOptions = .init())
    -> String
  {
    var lines: [String] = []
    lines.append("# TranscribeFull — \(transcript.displayTitle)")
    lines.append(datesLine(transcript, options: options))
    lines.append(sourceLine(transcript))
    lines.append("")
    lines.append("## Участники")
    lines.append(contentsOf: participantLines(transcript))
    if let context = options.projectContext {
      lines.append("")
      let formatter = dateFormatter(options.timeZone)
      lines.append("## Контекст проекта (из предыдущих встреч)")
      lines.append("### Принятые решения")
      lines.append(
        contentsOf: bullets(
          context.decisions.map { line(for: $0, formatter: formatter) }, marker: "- "))
      lines.append("### Открытые задачи")
      lines.append(contentsOf: bullets(context.actions.map(line(for:)), marker: "- [ ] "))
      lines.append("### Открытые вопросы")
      lines.append(contentsOf: bullets(context.questions.map(\.text), marker: "- "))
    }
    lines.append("")
    lines.append("## Транскрипт")
    lines.append(contentsOf: transcriptLines(transcript, options: options))
    if options.includeFollowupPrompt {
      lines.append("")
      lines.append("## Инструкция для follow-up (для внешней модели)")
      lines.append(FollowupPrompt.text)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// `TranscribeFull_<YYYY-MM-DD>.md` — по дате встречи, иначе по дате обработки.
  public static func fileName(for transcript: Transcript, timeZone: TimeZone = .current) -> String {
    fileName(forDate: transcript.meeting.date ?? transcript.createdAt, timeZone: timeZone)
  }

  /// То же имя по одной дате: контекст проекта ссылается на экспорт прошлой встречи, транскрипта
  /// которой под рукой может уже не быть (`ProjectContext.Decision.sourceFileName`).
  public static func fileName(forDate date: Date, timeZone: TimeZone = .current) -> String {
    "TranscribeFull_\(dateFormatter(timeZone).string(from: date)).md"
  }

  // MARK: - Шапка

  private static func datesLine(_ transcript: Transcript, options: TranscribeFullOptions) -> String
  {
    let formatter = dateFormatter(options.timeZone)
    let meetingDate = transcript.meeting.date.map(formatter.string(from:)) ?? placeholder
    let processedDate = formatter.string(from: options.processedAt ?? transcript.createdAt)
    return "Дата встречи: \(meetingDate) · Дата обработки: \(processedDate) "
      + "· Длительность: \(Timecode.hhmmss(transcript.audio.duration))"
  }

  private static func sourceLine(_ transcript: Transcript) -> String {
    let project = nonEmpty(transcript.meeting.project) ?? placeholder
    let engines = [
      transcript.engines.asr.summary, transcript.engines.diarizer?.summary ?? placeholder,
    ]
    return "Проект: \(project) · Движки: \(engines.joined(separator: ", ")) "
      + "· Файл: \(transcript.audio.fileName)"
  }

  // MARK: - Участники

  /// «- Спикер 1 (32 мин, 41 реплика, uk)» в порядке номеров спикеров; «Неизвестный» — последним.
  static func participantLines(_ transcript: Transcript) -> [String] {
    let routed = Dictionary(
      transcript.speakerLanguages.map { ($0.speakerID, $0.language) },
      uniquingKeysWith: { first, _ in first })
    let speakers = transcript.speakers.sorted {
      ($0.speakerID ?? Int.max) < ($1.speakerID ?? Int.max)
    }
    guard !speakers.isEmpty else { return ["- \(placeholder)"] }
    return speakers.map { speaker in
      let language = speaker.speakerID.flatMap { routed[$0] } ?? speaker.language
      let facts = [
        speechTime(speaker.speechSeconds),
        "\(speaker.utteranceCount) "
          + ProgressPhrasing.plural(speaker.utteranceCount, "реплика", "реплики", "реплик"),
        language.flatMap { $0.isKnown ? $0.code : nil } ?? placeholder,
      ]
      return "- \(speaker.displayName) (\(facts.joined(separator: ", ")))"
    }
  }

  /// Время речи округлённо: «32 мин», а короче минуты — «48 с».
  private static func speechTime(_ seconds: Double) -> String {
    let seconds = max(seconds, 0)
    if seconds.rounded() < 60 { return "\(Int(seconds.rounded())) с" }
    return "\(Int((seconds / 60).rounded())) мин"
  }

  // MARK: - Транскрипт

  static func transcriptLines(_ transcript: Transcript, options: TranscribeFullOptions)
    -> [String]
  {
    let names = Dictionary(
      transcript.speakers.map { ($0.speakerID, $0.displayName) },
      uniquingKeysWith: { first, _ in first })
    return transcript.utterances.map { utterance in
      let name =
        names[utterance.speakerID] ?? SpeakerStats.placeholderName(for: utterance.speakerID)
      let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let mark = options.markOverlap && utterance.overlapped ? " [наложение]" : ""
      return
        "\(Timecode.bracketed(utterance.start, tenths: options.tenths)) \(name): \(text)\(mark)"
    }
  }

  // MARK: - Контекст проекта

  /// `[2026-08-14] текст (источник: TranscribeFull_2026-08-14.md, 00:41:12)` — дата и скобка
  /// появляются только при наличии данных; пустой текст даёт пустую строку (пункт пропускается).
  private static func line(for decision: ProjectContext.Decision, formatter: DateFormatter)
    -> String
  {
    guard let text = nonEmpty(decision.text) else { return "" }
    let date = decision.meetingDate.map { "[\(formatter.string(from: $0))] " } ?? ""
    let source = nonEmpty(decision.sourceFileName).map { "источник: \($0)" }
    let timecode = decision.timestamp.map(Timecode.hhmmss)
    let reference = [source, timecode].compactMap { $0 }.joined(separator: ", ")
    return date + text + (reference.isEmpty ? "" : " (\(reference))")
  }

  /// `текст — Имя, до 2026-09-10`; маркер `- [ ] ` добавляет `bullets`.
  private static func line(for action: ProjectContext.Action) -> String {
    guard let text = nonEmpty(action.text) else { return "" }
    let owner = nonEmpty(action.owner)
    let due = nonEmpty(action.due).map { "до \($0)" }
    let tail = [owner, due].compactMap { $0 }.joined(separator: ", ")
    return tail.isEmpty ? text : "\(text) — \(tail)"
  }

  // MARK: - Общее

  static let placeholder = "—"

  private static func bullets(_ items: [String], marker: String) -> [String] {
    let items = items.compactMap(nonEmpty)
    guard !items.isEmpty else { return ["- \(placeholder)"] }
    return items.map { marker + $0 }
  }

  static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  static func dateFormatter(_ timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}
