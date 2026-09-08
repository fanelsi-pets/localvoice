import Core
import Export
import Foundation

// Самопроверка на встроенном сэмпле (SPEC.md §2 п. 8, §3.8): тот же `MeetingPipeline`, что и на настоящей
// встрече, только на 20-секундной записи с двумя голосами (ru + uk). Проверяются не буквы транскрипта,
// а признаки жизни всей цепочки: стадии отработали, реплик достаточно, языки не потерялись, ключевые слова
// манифеста нашлись. Тексты сравниваются без регистра и с ё→е — движки пишут «ещё»/«еще» по-разному.

/// Встроенный сэмпл и то, что от него ожидается. Ключевые слова живут в манифесте рядом с аудио,
/// а не в коде: сэмпл можно переснять, не трогая логику.
public struct SelfTestSample: Hashable, Sendable {
  public var url: URL
  public var title: String
  public var expectedSpeakers: Int
  public var expectedLanguages: [Language]
  public var keywords: [String]

  public init(
    url: URL,
    title: String,
    expectedSpeakers: Int,
    expectedLanguages: [Language],
    keywords: [String]
  ) {
    self.url = url
    self.title = title
    self.expectedSpeakers = max(expectedSpeakers, 1)
    self.expectedLanguages = expectedLanguages
    self.keywords = keywords
  }

  /// Языки-кандидаты для маршрутизатора: ожидаемые языки плюс английский (в речи есть термины).
  public var languageCandidates: [Language] {
    var result = expectedLanguages
    if !result.contains(.en) { result.append(.en) }
    return result
  }

  /// Читает манифест (`{"title":…,"expectedSpeakers":2,"expectedLanguages":["ru","uk"],"keywords":[…]}`)
  /// и проверяет, что аудио на месте.
  public static func load(manifest: URL, audio: URL) throws -> SelfTestSample {
    guard FileManager.default.fileExists(atPath: audio.path(percentEncoded: false)) else {
      throw SelfTestError.sampleMissing(audio)
    }
    let data: Data
    do {
      data = try Data(contentsOf: manifest)
    } catch {
      throw SelfTestError.manifestUnreadable(manifest, reason: error.localizedDescription)
    }
    do {
      let decoded = try JSONDecoder().decode(Manifest.self, from: data)
      return SelfTestSample(
        url: audio,
        title: decoded.title,
        expectedSpeakers: decoded.expectedSpeakers,
        expectedLanguages: decoded.expectedLanguages.map { Language(code: $0) },
        keywords: decoded.keywords)
    } catch {
      throw SelfTestError.manifestUnreadable(manifest, reason: error.localizedDescription)
    }
  }

  private struct Manifest: Decodable {
    var title: String
    var expectedSpeakers: Int
    var expectedLanguages: [String]
    var keywords: [String]
  }
}

/// Ошибки самопроверки: до прогона (нет сэмпла) и во время (ошибка пайплайна пробрасывается как есть).
public enum SelfTestError: Error, LocalizedError, Hashable, Sendable {
  case sampleMissing(URL)
  case manifestUnreadable(URL, reason: String)

  public var errorDescription: String? {
    switch self {
    case .sampleMissing(let url):
      String(
        localized:
          "Встроенный сэмпл самопроверки не найден (\(url.lastPathComponent)). Переустановите приложение из DMG."
      )
    case .manifestUnreadable(let url, let reason):
      String(
        localized:
          "Описание сэмпла самопроверки не читается (\(url.lastPathComponent)): \(reason). Переустановите приложение из DMG."
      )
    }
  }
}

/// Итог самопроверки: то, что видит пользователь во вкладке «Диагностика» и что уходит в отчёт о проблеме.
/// Текста реплик, кроме трёх строк предпросмотра, здесь нет — сэмпл встроенный, приватных данных в нём нет.
public struct SelfTestReport: Hashable, Sendable, Codable {
  public var startedAt: Date
  /// Полное время прогона по настенным часам, с.
  public var totalSeconds: Double
  public var timings: [StageTiming]
  public var speakerCount: Int
  public var utteranceCount: Int
  /// Коды языков, найденных в репликах, по алфавиту.
  public var languages: [String]
  public var foundKeywords: [String]
  public var missingKeywords: [String]
  /// До трёх строк вида «[00:00:01] Спикер 1 (ru): текст».
  public var preview: [String]
  public var peakMemoryBytes: UInt64?
  /// «WhisperKit large-v3-turbo + SpeakerKit pyannote».
  public var enginesTitle: String
  public var passed: Bool
  /// Замечания: несовпадение числа спикеров и отсутствие ожидаемого языка — предупреждения, не провал.
  public var problems: [String]

  public init(
    startedAt: Date,
    totalSeconds: Double,
    timings: [StageTiming],
    speakerCount: Int,
    utteranceCount: Int,
    languages: [String],
    foundKeywords: [String],
    missingKeywords: [String],
    preview: [String],
    peakMemoryBytes: UInt64?,
    enginesTitle: String,
    passed: Bool,
    problems: [String]
  ) {
    self.startedAt = startedAt
    self.totalSeconds = totalSeconds
    self.timings = timings
    self.speakerCount = speakerCount
    self.utteranceCount = utteranceCount
    self.languages = languages
    self.foundKeywords = foundKeywords
    self.missingKeywords = missingKeywords
    self.preview = preview
    self.peakMemoryBytes = peakMemoryBytes
    self.enginesTitle = enginesTitle
    self.passed = passed
    self.problems = problems
  }

  /// Строка итога для онбординга и вкладки диагностики.
  public var summary: String {
    let speakers =
      String(localized: "\(speakerCount) спикеров")
    let utterances =
      String(localized: "\(utteranceCount) реплик")
    let languagesText =
      languages.isEmpty ? String(localized: "язык не определён") : languages.joined(separator: "/")
    let time = String(format: "%.0f с", totalSeconds)
    if passed {
      return String(
        localized: "Всё работает: \(speakers), \(utterances), \(languagesText), \(time)")
    }
    return String(
      localized: "Проверка не прошла: \(speakers), \(utterances), \(languagesText), \(time)")
  }

  /// Ключевые слова: сколько нашли из скольких («5 из 7»).
  public var keywordSummary: String {
    let total = foundKeywords.count + missingKeywords.count
    return String(localized: "\(foundKeywords.count) из \(total)")
  }
}

/// Прогон встроенного сэмпла через боевой пайплайн. Живёт в акторе: движки тяжёлые, главный поток свободен;
/// прогресс — в `ProgressReporter` вызывающего (те же стадии, что у обычной встречи, включая «Подготовку
/// моделей» — первая загрузка Whisper компилирует CoreML до ~100 с).
public actor SelfTestRunner {
  private let engines: any EngineProviding
  private let selection: EngineSelection

  public init(engines: any EngineProviding, selection: EngineSelection) {
    self.engines = engines
    self.selection = selection
  }

  public func run(
    sample: SelfTestSample,
    cacheDirectory: URL,
    reporter: ProgressReporter,
    discovered: SegmentSink? = nil
  ) async throws -> SelfTestReport {
    let startedAt = Date()
    let asr = try await engines.asr(for: selection)
    let diarizer: (any Diarizer)? =
      selection.diarizer == nil ? nil : try await engines.diarizer(for: selection)
    let pipeline = MeetingPipeline(decoder: engines.decoder(), asr: asr, diarizer: diarizer)

    var configuration = PipelineConfiguration(
      hints: DiarizationHints(expectedSpeakers: sample.expectedSpeakers),
      skipDiarization: selection.diarizer == nil,
      language: .perSpeaker,
      meeting: MeetingInfo(title: sample.title),
      // Экспорт не нужен: отчёт собирается из транскрипта.
      export: ExportOptions(formats: []),
      asrRate: selection.asrRate)
    configuration.router.candidates = sample.languageCandidates
    // Отпечатки голосов самопроверке не нужны — они бы только тратили время на коротком сэмпле.
    configuration.voiceSampleSeconds = 0

    let result = try await pipeline.run(
      input: .file(sample.url),
      cacheDirectory: cacheDirectory,
      configuration: configuration,
      reporter: reporter,
      discovered: discovered)

    return Self.report(
      for: result.transcript, sample: sample, startedAt: startedAt,
      totalSeconds: Date().timeIntervalSince(startedAt))
  }

  // MARK: - Разбор итога

  /// Сборка отчёта из транскрипта: вынесено отдельно, чтобы проверялось тестами без прогона пайплайна.
  static func report(
    for transcript: Transcript, sample: SelfTestSample, startedAt: Date, totalSeconds: Double
  ) -> SelfTestReport {
    let utterances = transcript.utterances
    let speakerCount = transcript.speakers.filter { $0.speakerID != nil }.count
    let languages = Self.languages(in: transcript)
    let haystack = normalized(utterances.map(\.text).joined(separator: " "))
    var found: [String] = []
    var missing: [String] = []
    for keyword in sample.keywords {
      let needle = normalized(keyword)
      if !needle.isEmpty, haystack.contains(needle) {
        found.append(keyword)
      } else {
        missing.append(keyword)
      }
    }

    var problems: [String] = []
    var passed = true
    if utterances.count < 2 {
      passed = false
      problems.append(
        String(
          localized:
            "Распознано \(utterances.count) реплик — сэмпл должен дать хотя бы две. Проверьте, что модели скачаны полностью."
        ))
    }
    if !sample.keywords.isEmpty, found.count * 2 < sample.keywords.count {
      passed = false
      problems.append(
        String(
          localized:
            "Из ожидаемых слов найдено только \(found.count) из \(sample.keywords.count) (нет: \(missing.prefix(5).joined(separator: ", "))). Похоже, распознавание работает плохо — проверьте файлы моделей на вкладке «Диагностика»."
        ))
    }
    // Предупреждения: они не проваливают проверку — на коротком сэмпле диаризатор имеет право ошибиться.
    if speakerCount != sample.expectedSpeakers {
      problems.append(
        String(
          localized:
            "Спикеров найдено \(speakerCount), ожидалось \(sample.expectedSpeakers) — разделение по голосам на коротком сэмпле бывает неточным; на настоящей встрече проверьте панель «Спикеры»."
        ))
    }
    for language in sample.expectedLanguages where !languages.contains(language.code) {
      problems.append(
        String(
          localized:
            "В транскрипте нет речи на языке «\(language.code)» — если встречи бывают на этом языке, включите его в настройках («Языки»)."
        ))
    }

    return SelfTestReport(
      startedAt: startedAt,
      totalSeconds: totalSeconds,
      timings: transcript.timings,
      speakerCount: speakerCount,
      utteranceCount: utterances.count,
      languages: languages,
      foundKeywords: found,
      missingKeywords: missing,
      preview: preview(for: transcript),
      peakMemoryBytes: transcript.peakMemoryBytes ?? ProcessMemory.snapshot()?.peakResidentBytes,
      enginesTitle: enginesTitle(for: transcript.engines),
      passed: passed,
      problems: problems)
  }

  /// Коды языков реплик (языки спикеров — как запасной источник, если у реплик языка нет).
  static func languages(in transcript: Transcript) -> [String] {
    var codes = Set(transcript.utterances.compactMap { $0.language }.filter(\.isKnown).map(\.code))
    if codes.isEmpty {
      codes = Set(transcript.speakerLanguages.map(\.language).filter(\.isKnown).map(\.code))
    }
    return codes.sorted()
  }

  /// До трёх строк «[00:00:01] Спикер 1 (ru): текст».
  static func preview(for transcript: Transcript, limit: Int = 3) -> [String] {
    let names = Dictionary(
      transcript.speakers.compactMap { stats in stats.speakerID.map { ($0, stats.displayName) } },
      uniquingKeysWith: { first, _ in first })
    return transcript.utterances.prefix(limit).map { utterance in
      let name =
        utterance.speakerID.flatMap { names[$0] }
        ?? SpeakerStats.placeholderName(for: utterance.speakerID)
      let language = utterance.language.map { " (\($0.code))" } ?? ""
      return "\(Timecode.bracketed(utterance.start)) \(name)\(language): \(utterance.text)"
    }
  }

  static func enginesTitle(for engines: EngineInfo) -> String {
    [engines.asr.summary, engines.diarizer?.summary].compactMap { $0 }.joined(separator: " + ")
  }

  /// Сравнение без регистра и без разницы «ё»/«е»; лишние пробелы схлопываются.
  public static func normalized(_ text: String) -> String {
    text.lowercased()
      .replacingOccurrences(of: "ё", with: "е")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
