import Foundation

// Имена спикеров (SPEC.md §3.4): отпечатки голоса из диаризации, подсказки имён из дорожек Zoom, chat.txt
// и OCR, сведения о раздельных дорожках. Файл — общий контракт модулей Voices, Ingest, OCR, Pipeline и Store.

/// Отпечаток голоса спикера — центроид эмбеддингов диаризатора за прогон (SPEC.md §3.4, ADR-002).
/// Пространство векторов принадлежит движку: сравнивать можно только отпечатки одного движка и модели
/// (`Transcript.engines.diarizer`), поэтому профиль человека хранит идентификатор пространства.
public struct SpeakerEmbedding: Hashable, Codable, Sendable {
  public var speakerID: Int
  public var vector: [Float]
  /// Сколько секунд речи спикера легло в отпечаток (вес при объединении спикеров и обновлении профиля).
  public var speechSeconds: Double

  public init(speakerID: Int, vector: [Float], speechSeconds: Double) {
    self.speakerID = speakerID
    self.vector = vector
    self.speechSeconds = speechSeconds
  }
}

/// Подсказка имени участника из дополнительного источника (SPEC.md §3.4: дорожки Zoom, chat.txt,
/// подписи на видео, cloud-VTT). Подсказка — не присвоение: имя предлагается в инспекторе.
public struct NameHint: Hashable, Codable, Sendable {
  public enum Source: String, Codable, Sendable, CaseIterable {
    /// Имя файла дорожки `Audio Record/audio<Имя><цифры>.m4a`.
    case track
    /// Автор сообщения в `chat.txt`.
    case chat
    /// Подпись на видеокадре (Vision OCR).
    case ocr
    /// Подпись `Имя:` в `audio_transcript.vtt` cloud-записи.
    case vtt
  }

  public var name: String
  public var source: Source
  /// Сколько раз имя встретилось: сообщений в чате, кадров с подписью.
  public var count: Int
  /// Спикер, к которому источник привязывает имя (дорожка — точно, OCR — по голосованию); `nil` — только список.
  public var speakerID: Int?
  /// Доля голосов за имя у спикера (OCR), 0…1; `nil` — источник не голосует.
  public var share: Double?

  public init(
    name: String, source: Source, count: Int = 1, speakerID: Int? = nil, share: Double? = nil
  ) {
    self.name = name
    self.source = source
    self.count = count
    self.speakerID = speakerID
    self.share = share
  }
}

/// Раздельная дорожка участника Zoom (SPEC.md §2 п. 7): один спикер на дорожку, имя — из имени файла.
public struct TrackInfo: Hashable, Codable, Sendable {
  public var speakerID: Int
  public var fileName: String
  /// Имя участника из имени файла (сверенное с chat.txt); `nil` — не разобрано.
  public var participantName: String?
  /// Секунд речи на дорожке по детектору речевой активности.
  public var speechSeconds: Double

  public init(speakerID: Int, fileName: String, participantName: String?, speechSeconds: Double) {
    self.speakerID = speakerID
    self.fileName = fileName
    self.participantName = participantName
    self.speechSeconds = speechSeconds
  }
}

extension Transcript {
  /// Отпечаток спикера, если диаризатор его отдал.
  public func embedding(for speakerID: Int) -> SpeakerEmbedding? {
    speakerEmbeddings.first { $0.speakerID == speakerID }
  }

  /// Идентификатор пространства эмбеддингов: движок и модель диаризатора (`nil` — отпечатков нет).
  public var embeddingSpace: String? {
    guard !speakerEmbeddings.isEmpty, let diarizer = engines.diarizer else { return nil }
    return diarizer.summary
  }
}
