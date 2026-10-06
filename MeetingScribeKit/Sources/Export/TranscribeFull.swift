import Core
import Foundation

// Экспорт TranscribeFull (SPEC.md §3.5): шапка, участники, транскрипт с таймкодами и готовый промпт
// для follow-up (SPEC.md §3.6). Формат зафиксирован golden-файлом
// Tests/ExportTests/Golden/TranscribeFull_fixture.md.

public struct TranscribeFullOptions: Sendable {
  /// Таймкоды с десятыми долями.
  public var tenths: Bool
  /// Помечать реплики на наложении речи.
  public var markOverlap: Bool
  public var includeFollowupPrompt: Bool
  /// Язык follow-up, который просит инструкция в конце экспорта.
  public var followupLanguage: FollowupLanguage
  /// Дата обработки в шапке; `nil` — `transcript.createdAt`.
  public var processedAt: Date?
  public var timeZone: TimeZone

  public init(
    tenths: Bool = false,
    markOverlap: Bool = false,
    includeFollowupPrompt: Bool = true,
    followupLanguage: FollowupLanguage = .ru,
    processedAt: Date? = nil,
    timeZone: TimeZone = .current
  ) {
    self.tenths = tenths
    self.markOverlap = markOverlap
    self.includeFollowupPrompt = includeFollowupPrompt
    self.followupLanguage = followupLanguage
    self.processedAt = processedAt
    self.timeZone = timeZone
  }
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
    lines.append("")
    lines.append("## Транскрипт")
    lines.append(contentsOf: transcriptLines(transcript, options: options))
    if options.includeFollowupPrompt {
      lines.append("")
      lines.append("## Инструкция для follow-up (для внешней модели)")
      lines.append(FollowupGenerationPrompt.instruction(options.followupLanguage))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// `TranscribeFull_<YYYY-MM-DD>.md` — по дате встречи, иначе по дате обработки.
  public static func fileName(for transcript: Transcript, timeZone: TimeZone = .current) -> String {
    fileName(forDate: transcript.meeting.date ?? transcript.createdAt, timeZone: timeZone)
  }

  /// То же имя по одной дате.
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

  // MARK: - Общее

  static let placeholder = "—"

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
