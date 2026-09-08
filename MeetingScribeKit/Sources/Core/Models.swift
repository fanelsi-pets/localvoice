import Foundation

// Все таймкоды — Double, секунды от начала записи. Формат [HH:MM:SS] живёт только в Export.

/// Слово с таймкодами из ASR.
public struct Word: Hashable, Codable, Sendable {
  public var start: Double
  public var end: Double
  public var text: String
  public var probability: Double?

  public init(start: Double, end: Double, text: String, probability: Double? = nil) {
    self.start = start
    self.end = end
    self.text = text
    self.probability = probability
  }

  public var duration: Double { end - start }
}

/// Сегмент распознавания (окно декодирования движка). Таймкоды абсолютные.
public struct Segment: Hashable, Codable, Sendable {
  public var start: Double
  public var end: Double
  public var text: String
  public var language: Language?
  public var words: [Word]
  /// Вероятность отсутствия речи (Whisper); используется фильтром галлюцинаций.
  public var noSpeechProb: Double?
  public var avgLogprob: Double?
  public var compressionRatio: Double?

  public init(
    start: Double,
    end: Double,
    text: String,
    language: Language? = nil,
    words: [Word] = [],
    noSpeechProb: Double? = nil,
    avgLogprob: Double? = nil,
    compressionRatio: Double? = nil
  ) {
    self.start = start
    self.end = end
    self.text = text
    self.language = language
    self.words = words
    self.noSpeechProb = noSpeechProb
    self.avgLogprob = avgLogprob
    self.compressionRatio = compressionRatio
  }

  public var duration: Double { end - start }
}

/// Отрезок речи одного спикера из диаризации.
public struct Turn: Hashable, Codable, Sendable {
  public var start: Double
  public var end: Double
  public var speakerID: Int
  public var confidence: Double?

  public init(start: Double, end: Double, speakerID: Int, confidence: Double? = nil) {
    self.start = start
    self.end = end
    self.speakerID = speakerID
    self.confidence = confidence
  }

  public var duration: Double { end - start }

  /// Длина пересечения с интервалом `[start, end]` (0, если не пересекаются).
  public func overlap(from otherStart: Double, to otherEnd: Double) -> Double {
    max(0, min(end, otherEnd) - max(start, otherStart))
  }
}

/// Результат диаризации (SPEC.md §3.3).
public struct DiarizationResult: Hashable, Codable, Sendable {
  public var turns: [Turn]
  public var speakerCount: Int
  /// Центроиды эмбеддингов по спикерам — сырьё для голосовых профилей (фаза 3).
  public var embeddings: [Int: [Float]]

  public init(turns: [Turn], speakerCount: Int? = nil, embeddings: [Int: [Float]] = [:]) {
    self.turns = turns
    self.speakerCount = speakerCount ?? Set(turns.map(\.speakerID)).count
    self.embeddings = embeddings
  }

  /// Отсортированный список идентификаторов спикеров.
  public var speakerIDs: [Int] { Set(turns.map(\.speakerID)).sorted() }

  /// Суммарная длительность речи спикера.
  public func speechSeconds(for speakerID: Int) -> Double {
    turns.lazy.filter { $0.speakerID == speakerID }.reduce(0) { $0 + $1.duration }
  }

  /// Распределение речи по спикерам, по убыванию.
  public var speechDistribution: [(speakerID: Int, seconds: Double)] {
    speakerIDs.map { ($0, speechSeconds(for: $0)) }.sorted { $0.seconds > $1.seconds }
  }

  /// Перенумеровывает спикеров по первому появлению в записи (`first` — заговорил первым): метки кластеров
  /// у движков произвольны, а «Спикер 1» в транскрипте должен идти первым. Эмбеддинги переносятся вместе с метками.
  public func renumberedByFirstAppearance(startingAt first: Int = 1) -> DiarizationResult {
    var mapping: [Int: Int] = [:]
    let ordered = turns.sorted {
      ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID)
    }
    for turn in ordered where mapping[turn.speakerID] == nil {
      mapping[turn.speakerID] = first + mapping.count
    }
    for speakerID in embeddings.keys.sorted() where mapping[speakerID] == nil {
      mapping[speakerID] = first + mapping.count
    }
    let renumberedTurns = turns.map { turn in
      var copy = turn
      copy.speakerID = mapping[turn.speakerID] ?? turn.speakerID
      return copy
    }
    var renumberedEmbeddings: [Int: [Float]] = [:]
    for (speakerID, vector) in embeddings {
      renumberedEmbeddings[mapping[speakerID] ?? speakerID] = vector
    }
    return DiarizationResult(
      turns: renumberedTurns, speakerCount: speakerCount, embeddings: renumberedEmbeddings)
  }
}

/// Реплика: непрерывная речь одного спикера после сшивки (`Fuser`) — слова одного ASR-сегмента, приписанные
/// спикеру, склеенные с соседними репликами того же спикера и языка через короткие паузы.
public struct Utterance: Hashable, Codable, Sendable {
  public var start: Double
  public var end: Double
  /// `nil` — спикер не определён («Неизвестный»).
  public var speakerID: Int?
  public var language: Language?
  public var text: String
  public var words: [Word]
  /// Реплика лежит на наложении речи нескольких спикеров.
  public var overlapped: Bool

  public init(
    start: Double,
    end: Double,
    speakerID: Int?,
    language: Language? = nil,
    text: String,
    words: [Word] = [],
    overlapped: Bool = false
  ) {
    self.start = start
    self.end = end
    self.speakerID = speakerID
    self.language = language
    self.text = text
    self.words = words
    self.overlapped = overlapped
  }

  public var duration: Double { end - start }
}

/// Сводка по спикеру для экспорта и интерфейса.
public struct SpeakerStats: Hashable, Codable, Sendable {
  public var speakerID: Int?
  public var name: String?
  public var speechSeconds: Double
  public var utteranceCount: Int
  public var language: Language?

  public init(
    speakerID: Int?,
    name: String? = nil,
    speechSeconds: Double,
    utteranceCount: Int,
    language: Language? = nil
  ) {
    self.speakerID = speakerID
    self.name = name
    self.speechSeconds = speechSeconds
    self.utteranceCount = utteranceCount
    self.language = language
  }

  /// Имя для экспорта и интерфейса: подтверждённое имя, иначе «Спикер N» (нумерация с 1 по первому появлению);
  /// реплика без спикера — «Неизвестный».
  public var displayName: String { name ?? Self.placeholderName(for: speakerID) }

  public static func placeholderName(for speakerID: Int?) -> String {
    speakerID.map { "Спикер \($0)" } ?? "Неизвестный"
  }

  /// Строит сводку по репликам: время речи, число реплик и язык каждого спикера. Язык берётся из
  /// `languages` (итог маршрутизации по спикеру), иначе — преобладающий по длительности реплик.
  public static func summarize(_ utterances: [Utterance], languages: [SpeakerLanguage] = [])
    -> [SpeakerStats]
  {
    let routed = Dictionary(languages.map { ($0.speakerID, $0.language) }) { first, _ in first }
    var seconds: [Int?: Double] = [:]
    var counts: [Int?: Int] = [:]
    var languages: [Int?: [Language: Double]] = [:]
    for utterance in utterances {
      seconds[utterance.speakerID, default: 0] += utterance.duration
      counts[utterance.speakerID, default: 0] += 1
      if let language = utterance.language {
        languages[utterance.speakerID, default: [:]][language, default: 0] += utterance.duration
      }
    }
    return seconds.keys
      .sorted { ($0 ?? Int.max) < ($1 ?? Int.max) }
      .map { id in
        SpeakerStats(
          speakerID: id,
          speechSeconds: seconds[id] ?? 0,
          utteranceCount: counts[id] ?? 0,
          language: id.flatMap { routed[$0] } ?? languages[id]?.max { $0.value < $1.value }?.key
        )
      }
  }
}

/// Сведения о встрече для шапки экспорта (SPEC.md §3.5): из имени папки Zoom, диалога импорта или CLI.
public struct MeetingInfo: Hashable, Codable, Sendable {
  public var title: String?
  /// Дата и время встречи (не обработки).
  public var date: Date?
  public var project: String?

  public init(title: String? = nil, date: Date? = nil, project: String? = nil) {
    self.title = title
    self.date = date
    self.project = project
  }
}

/// Сведения об исходной записи.
public struct AudioInfo: Hashable, Codable, Sendable {
  public var sourceURL: URL?
  public var fileName: String
  public var duration: Double
  public var sampleRate: Int

  public init(
    sourceURL: URL?, fileName: String, duration: Double, sampleRate: Int = PCMAudio.sampleRate
  ) {
    self.sourceURL = sourceURL
    self.fileName = fileName
    self.duration = duration
    self.sampleRate = sampleRate
  }
}

/// Идентификация движка и модели для отчётов и экспорта.
public struct EngineDescriptor: Hashable, Codable, Sendable {
  public var name: String
  public var model: String?
  public var version: String?

  public init(name: String, model: String? = nil, version: String? = nil) {
    self.name = name
    self.model = model
    self.version = version
  }

  public var summary: String {
    [name, model].compactMap { $0 }.joined(separator: " ")
  }
}

public struct EngineInfo: Hashable, Codable, Sendable {
  public var asr: EngineDescriptor
  public var diarizer: EngineDescriptor?

  public init(asr: EngineDescriptor, diarizer: EngineDescriptor?) {
    self.asr = asr
    self.diarizer = diarizer
  }
}

/// Фактическое время стадии; `audioSeconds` позволяет считать кратность реального времени.
public struct StageTiming: Hashable, Codable, Sendable {
  public var stage: Stage
  public var seconds: Double
  public var audioSeconds: Double?

  public init(stage: Stage, seconds: Double, audioSeconds: Double? = nil) {
    self.stage = stage
    self.seconds = seconds
    self.audioSeconds = audioSeconds
  }

  /// Во сколько раз быстрее реального времени (nil, если неприменимо).
  public var realtimeFactor: Double? {
    guard let audioSeconds, seconds > 0 else { return nil }
    return audioSeconds / seconds
  }
}

/// Полный результат обработки записи — то, что сохраняется и экспортируется.
public struct Transcript: Hashable, Codable, Sendable {
  /// 2 — фаза 1: `meeting`, `speakerLanguages`, `diagnostics`; 3 — фаза 3: `speakerEmbeddings`, `tracks`,
  /// `nameHints`. Старые файлы читаются (поля по умолчанию).
  public static let currentSchemaVersion = 3

  public var schemaVersion: Int
  public var createdAt: Date
  public var meeting: MeetingInfo
  public var audio: AudioInfo
  public var engines: EngineInfo
  public var speakers: [SpeakerStats]
  /// Язык каждого спикера по итогам маршрутизации (пусто — один язык на файл или движок без языка).
  public var speakerLanguages: [SpeakerLanguage]
  public var utterances: [Utterance]
  public var turns: [Turn]
  public var timings: [StageTiming]
  public var peakMemoryBytes: UInt64?
  public var diagnostics: TranscriptDiagnostics
  /// Отпечатки голосов спикеров за прогон — сырьё для профилей (фаза 3, SPEC.md §3.4); пусто — движок их не отдал.
  public var speakerEmbeddings: [SpeakerEmbedding]
  /// Раздельные дорожки Zoom, если запись обработана по дорожкам; пусто — общий трек.
  public var tracks: [TrackInfo]
  /// Подсказки имён из дорожек, chat.txt и OCR.
  public var nameHints: [NameHint]

  public init(
    createdAt: Date = Date(),
    meeting: MeetingInfo = MeetingInfo(),
    audio: AudioInfo,
    engines: EngineInfo,
    utterances: [Utterance],
    turns: [Turn] = [],
    speakers: [SpeakerStats]? = nil,
    speakerLanguages: [SpeakerLanguage] = [],
    timings: [StageTiming] = [],
    peakMemoryBytes: UInt64? = nil,
    diagnostics: TranscriptDiagnostics = .empty,
    speakerEmbeddings: [SpeakerEmbedding] = [],
    tracks: [TrackInfo] = [],
    nameHints: [NameHint] = []
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.createdAt = createdAt
    self.meeting = meeting
    self.audio = audio
    self.engines = engines
    self.utterances = utterances
    self.turns = turns
    self.speakerLanguages = speakerLanguages
    self.speakers = speakers ?? SpeakerStats.summarize(utterances, languages: speakerLanguages)
    self.timings = timings
    self.peakMemoryBytes = peakMemoryBytes
    self.diagnostics = diagnostics
    self.speakerEmbeddings = speakerEmbeddings
    self.tracks = tracks
    self.nameHints = nameHints
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    meeting = try container.decodeIfPresent(MeetingInfo.self, forKey: .meeting) ?? MeetingInfo()
    audio = try container.decode(AudioInfo.self, forKey: .audio)
    engines = try container.decode(EngineInfo.self, forKey: .engines)
    speakers = try container.decode([SpeakerStats].self, forKey: .speakers)
    speakerLanguages =
      try container.decodeIfPresent([SpeakerLanguage].self, forKey: .speakerLanguages) ?? []
    utterances = try container.decode([Utterance].self, forKey: .utterances)
    turns = try container.decode([Turn].self, forKey: .turns)
    timings = try container.decode([StageTiming].self, forKey: .timings)
    peakMemoryBytes = try container.decodeIfPresent(UInt64.self, forKey: .peakMemoryBytes)
    diagnostics =
      try container.decodeIfPresent(TranscriptDiagnostics.self, forKey: .diagnostics) ?? .empty
    speakerEmbeddings =
      try container.decodeIfPresent([SpeakerEmbedding].self, forKey: .speakerEmbeddings) ?? []
    tracks = try container.decodeIfPresent([TrackInfo].self, forKey: .tracks) ?? []
    nameHints = try container.decodeIfPresent([NameHint].self, forKey: .nameHints) ?? []
  }

  /// Название встречи для заголовков: явное, иначе имя файла без расширения.
  public var displayTitle: String {
    if let title = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      return title
    }
    return (audio.fileName as NSString).deletingPathExtension
  }

  /// Проверка монотонности таймкодов реплик (критерий SPEC.md §7 п. 8).
  public var hasMonotonicTimecodes: Bool {
    zip(utterances, utterances.dropFirst()).allSatisfy { $0.start <= $1.start }
  }
}

extension Transcript {
  /// Транскрипт с именами спикеров пользователя (`MeetingRecord.speakerNames`): единая проекция для списка,
  /// копирования и сохранения — так «Скопировать» и «Сохранить» идентичны по построению (SPEC.md §7 п. 6).
  /// Пустые имена игнорируются, остальные поля не меняются.
  public func applyingSpeakerNames(_ names: [Int: String]) -> Transcript {
    guard !names.isEmpty else { return self }
    var copy = self
    copy.speakers = speakers.map { speaker in
      guard let id = speaker.speakerID,
        let name = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
      else { return speaker }
      var renamed = speaker
      renamed.name = name
      return renamed
    }
    return copy
  }
}
