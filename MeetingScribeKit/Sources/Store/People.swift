import Core
import Foundation
import Voices

// Люди и сопоставления спикеров (фаза 3, SPEC.md §3.4): хранилище `People` с голосовыми профилями
// в индексе библиотеки, а привязка спикера встречи к человеку — в записи встречи.

/// Человек с голосовым профилем (SPEC.md §3.4: центроид, накопительное среднее, число образцов, примеры аудио).
/// Профиль — производная от образцов: центроид пересчитывается как среднее векторов образцов одного
/// пространства, поэтому образец можно убрать (удалена встреча, спикер переприсвоен другому человеку)
/// без искажения среднего.
public struct PersonRecord: Identifiable, Hashable, Codable, Sendable {
  /// Отпечаток голоса из одной встречи: один образец на пару (встреча, спикер).
  public struct VoiceSample: Hashable, Codable, Sendable {
    public var meetingID: UUID
    public var speakerID: Int
    public var vector: [Float]
    /// Пространство эмбеддингов (`Transcript.embeddingSpace`): движок и модель диаризатора.
    public var space: String
    public var speechSeconds: Double
    public var addedAt: Date

    public init(
      meetingID: UUID, speakerID: Int, vector: [Float], space: String, speechSeconds: Double,
      addedAt: Date = Date()
    ) {
      self.meetingID = meetingID
      self.speakerID = speakerID
      self.vector = vector
      self.space = space
      self.speechSeconds = speechSeconds
      self.addedAt = addedAt
    }
  }

  /// Ссылка на фрагмент речи в обработанной встрече — для прослушивания из раздела «Люди».
  public struct SampleRef: Hashable, Codable, Sendable {
    public var meetingID: UUID
    public var speakerID: Int
    public var start: Double
    public var end: Double

    public init(meetingID: UUID, speakerID: Int, start: Double, end: Double) {
      self.meetingID = meetingID
      self.speakerID = speakerID
      self.start = start
      self.end = end
    }
  }

  public var id: UUID
  public var name: String
  /// Отпечатки по встречам; пусто — человек создан по имени без голоса (движок без эмбеддингов,
  /// спикер выделен вручную).
  public var voiceSamples: [VoiceSample]
  /// Фрагменты для прослушивания (до трёх на встречу).
  public var samples: [SampleRef]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), name: String, voiceSamples: [VoiceSample] = [], samples: [SampleRef] = [],
    createdAt: Date = Date(), updatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.voiceSamples = voiceSamples
    self.samples = samples
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  /// Пространства, в которых у человека есть отпечатки.
  public var spaces: [String] {
    var seen: Set<String> = []
    return voiceSamples.map(\.space).filter { seen.insert($0).inserted }
  }

  /// Центроид по образцам пространства `space`: среднее векторов (накопительное среднее SPEC.md §3.4).
  public func profile(space: String) -> VoiceProfile? {
    let vectors = voiceSamples.filter { $0.space == space && !$0.vector.isEmpty }
    guard let first = vectors.first else { return nil }
    let dimension = first.vector.count
    let usable = vectors.filter { $0.vector.count == dimension }
    var sum = [Double](repeating: 0, count: dimension)
    for sample in usable {
      for index in 0..<dimension { sum[index] += Double(sample.vector[index]) }
    }
    let count = Double(usable.count)
    return VoiceProfile(
      centroid: sum.map { Float($0 / count) }, space: space, sampleCount: usable.count,
      speechSeconds: usable.reduce(0) { $0 + $1.speechSeconds })
  }

  /// Кандидат для `VoiceMatcher` в пространстве `space`; nil — отпечатков там нет.
  public func candidate(space: String) -> VoiceCandidate? {
    profile(space: space).map { VoiceCandidate(personID: id, name: name, profile: $0) }
  }

  /// Число встреч, по которым накоплен голос.
  public var sampleCount: Int { voiceSamples.count }

  /// Добавляет или заменяет отпечаток пары (встреча, спикер): повторное подтверждение не смещает среднее.
  public mutating func setVoiceSample(_ sample: VoiceSample) {
    voiceSamples.removeAll { $0.meetingID == sample.meetingID && $0.speakerID == sample.speakerID }
    voiceSamples.append(sample)
    updatedAt = sample.addedAt
  }

  /// Убирает отпечаток и фрагменты пары (встреча, спикер).
  public mutating func removeSamples(meetingID: UUID, speakerID: Int? = nil) {
    voiceSamples.removeAll {
      $0.meetingID == meetingID && (speakerID == nil || $0.speakerID == speakerID)
    }
    samples.removeAll {
      $0.meetingID == meetingID && (speakerID == nil || $0.speakerID == speakerID)
    }
  }
}

/// Сопоставление спикера встречи с именем и человеком. Имя в `name` — то, что показывается и экспортируется;
/// предложение (`suggestion`) не применяется, пока пользователь его не подтвердит (DESIGN.md §4).
public struct SpeakerAssignment: Hashable, Codable, Sendable {
  /// Откуда взялось имя. Пользовательская метка защищена архитектурно: автоматика её не переписывает.
  public enum Source: String, Codable, Sendable, CaseIterable {
    case user
    /// Автоприсвоение по голосовому профилю (сходство ≥ порога).
    case voice
    /// Имя файла раздельной дорожки Zoom.
    case track
    case chat
    case ocr
  }

  /// Предложение с подтверждением (сходство между порогами) или подсказка другого источника.
  public struct Suggestion: Hashable, Codable, Sendable {
    public var name: String
    public var personID: UUID?
    public var similarity: Double?
    public var source: Source

    public init(name: String, personID: UUID? = nil, similarity: Double? = nil, source: Source) {
      self.name = name
      self.personID = personID
      self.similarity = similarity
      self.source = source
    }
  }

  public var name: String?
  public var personID: UUID?
  /// Сходство с профилем человека (cosine), если сопоставление было по голосу.
  public var similarity: Double?
  public var source: Source?
  /// Пользователь подтвердил имя: профиль обновлён, автоматика запись не трогает.
  public var isConfirmed: Bool
  public var suggestion: Suggestion?

  public init(
    name: String? = nil, personID: UUID? = nil, similarity: Double? = nil, source: Source? = nil,
    isConfirmed: Bool = false, suggestion: Suggestion? = nil
  ) {
    self.name = name
    self.personID = personID
    self.similarity = similarity
    self.source = source
    self.isConfirmed = isConfirmed
    self.suggestion = suggestion
  }

  /// Имя, заданное или подтверждённое пользователем.
  public static func user(_ name: String, personID: UUID? = nil) -> SpeakerAssignment {
    SpeakerAssignment(name: name, personID: personID, source: .user, isConfirmed: true)
  }

  /// Непустое имя без пробелов по краям; `nil` — имени нет.
  public var trimmedName: String? {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }
    return name
  }
}

extension SpeakerAssignment {
  /// Словарь с целочисленными ключами в JSON — объект со строковыми ключами (как `speakerNames` в фазе 2).
  static func decodeMap(from container: KeyedDecodingContainer<MeetingRecord.CodingKeys>)
    throws -> [Int: SpeakerAssignment]
  {
    let raw =
      try container.decodeIfPresent(
        [String: SpeakerAssignment].self, forKey: .speakerAssignments) ?? [:]
    return Dictionary(
      uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
  }

  static func encodeMap(
    _ map: [Int: SpeakerAssignment],
    into container: inout KeyedEncodingContainer<MeetingRecord.CodingKeys>
  ) throws {
    let raw = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
    try container.encode(raw, forKey: .speakerAssignments)
  }
}
