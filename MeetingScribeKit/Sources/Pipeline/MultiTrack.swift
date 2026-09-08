import Core
import Foundation
import Ingest
import Voices

// Раздельные дорожки Zoom (SPEC.md §2 п. 7, §3.1): в папке записи есть `Audio Record/` с файлом на участника.
// Дорожки выровнены по началу записи (таймкод дорожки = таймкод встречи), на дорожке говорит один человек,
// остальное — цифровая тишина. Значит, диаризация не нужна: спикер известен из имени файла, отрезки речи даёт
// `SpeechActivityDetector`, а диаризатор нужен только ради отпечатка голоса (SPEC.md §3.4).

/// Одна раздельная дорожка на входе пайплайна.
public struct TrackInput: Hashable, Sendable {
  public var url: URL
  /// Имя участника из имени файла дорожки (сверенное с `chat.txt`); `nil` — не разобрано.
  public var participantName: String?

  public init(url: URL, participantName: String?) {
    self.url = url
    self.participantName = participantName
  }
}

/// Что обрабатывает пайплайн: общий файл или раздельные дорожки участников.
public enum PipelineInput: Hashable, Sendable {
  case file(URL)
  /// Раздельные дорожки Zoom; `mix` — общий трек (или видео) для сведений о файле (`AudioInfo.fileName`,
  /// `sourceURL`) и воспроизведения; `nil` — берётся первая дорожка.
  case tracks([TrackInput], mix: URL?)
}

/// Состояние одной дорожки внутри прогона: кэш аудио, речь, клипы для ASR, язык, отпечаток голоса.
struct TrackRun {
  /// Спикер дорожки — её номер с 1: «Спикер 1» и без диаризации нумеруется так же, как с ней.
  var speakerID: Int
  var input: TrackInput
  var decoded: DecodedAudio?
  var turns: [Turn] = []
  var clips: [ClosedRange<Double>] = []
  var language: Language?
  var embedding: [Float]?

  var url: URL { input.url }
  var fileName: String { input.url.lastPathComponent }
  var participantName: String? { input.participantName }
  var duration: Double { decoded?.duration ?? 0 }
  var speechSeconds: Double { SpeechActivityDetector.speechSeconds(turns) }
  /// Секунды, которые уйдут в ASR: клипы шире отрезков речи (склейка пауз и минимум 1.2 с).
  var clipSeconds: Double { clips.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

  var info: TrackInfo {
    TrackInfo(
      speakerID: speakerID, fileName: fileName, participantName: participantName,
      speechSeconds: speechSeconds)
  }

  /// Название дорожки для пульса: имя участника, иначе имя файла.
  var title: String { participantName ?? fileName }
}

/// Чистые части режима дорожек: план прогресса, проба голоса, сборка транскрипта и пометка наложений.
/// Вынесены из актора, чтобы их можно было проверять тестами отдельно от прогона.
enum MultiTrack {
  /// Допуск сравнения секунд.
  private static let epsilon = 1e-9

  // MARK: - План прогресса

  /// План прогресса для дорожек (ADR-004): длительность встречи — максимум по дорожкам, но декодируется
  /// каждая дорожка целиком, отрезки речи ищутся на каждой, а распознаётся только речь (клипы), поэтому
  /// стоимость стадий считается не от одной длительности, как в `ProgressPlan.standard`.
  /// `speechSeconds` до детектора речи неизвестны: их место занимает длительность встречи — суммарная речь
  /// всех дорожек примерно равна ей, если участники не говорят одновременно.
  static func plan(
    meetingSeconds: Double,
    trackCount: Int,
    speechSeconds: Double,
    voiceSampleSeconds: Double,
    asrRate: Double
  ) -> ProgressPlan {
    let seconds = max(meetingSeconds, 1)
    let count = Double(max(trackCount, 1))
    let standard = ProgressPlan.standard(audioSeconds: seconds, asrRate: asrRate)
    var rates = standard.rates
    var fixed = standard.fixedSeconds
    rates[.decoding] = (standard.rates[.decoding] ?? 0.001) * count
    // Детектор речи — один проход по сэмплам дорожки, вдвое дешевле декодирования.
    rates[.diarization] = 0.0005 * count
    rates[.transcription] = asrRate * max(speechSeconds, 0) / seconds
    // Отпечаток голоса — диаризация пробы (до `voiceSampleSeconds`) на каждую дорожку.
    fixed[.diarization] = voiceSampleSeconds > 0 ? 0.01 * voiceSampleSeconds * count : 0
    return ProgressPlan(audioSeconds: seconds, rates: rates, fixedSeconds: fixed)
  }

  // MARK: - Проба голоса

  /// Речь одного человека для отпечатка голоса — отбор `VoiceSampling.probeAudio` (модуль Voices: длинные
  /// отрезки первыми, куски из середины, до `targetSeconds` всего и до `perTurnCap` с одного отрезка).
  /// `nil` — речи нет или собранная проба короче секунды (диаризатор такую не примет).
  static func voiceProbe(
    speakerID: Int, turns: [Turn], audio: PCMAudio, targetSeconds: Double, perTurnCap: Double = 12
  ) -> PCMAudio? {
    guard targetSeconds > 0,
      let sampled = VoiceSampling.probeAudio(
        for: speakerID, turns: turns, audio: audio, targetSeconds: targetSeconds,
        perTurnCap: perTurnCap)
    else { return nil }
    return sampled.duration >= 1 ? sampled : nil
  }

  // MARK: - Регионы языка

  /// Регионы языка в режиме дорожек — клипы каждой дорожки с её языком и спикером. В отличие от общего трека
  /// регионы разных дорожек пересекаются: дорожки идут параллельными слоями одного таймлайна.
  static func regions(_ tracks: [TrackRun]) -> [LanguageRegion] {
    tracks
      .flatMap { track in
        track.clips.map {
          LanguageRegion(
            start: $0.lowerBound, end: $0.upperBound, language: track.language,
            speakerIDs: [track.speakerID])
        }
      }
      .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  // MARK: - Сборка транскрипта

  /// Фильтр галлюцинаций и сшивка **по каждой дорожке отдельно**, затем слияние реплик по времени.
  /// Отдельно — принципиально: сшивка общим списком отдала бы слово на наложении речи чужой дорожке
  /// (SPEC.md §3.3). Спикер реплики — дорожка: он известен точно, а не по перекрытию с отрезком речи.
  /// Функция чистая и используется и для полного прогона, и для частичного результата при отмене.
  static func assemble(
    tracks: [TrackRun],
    segmentsByTrack: [Int: [Segment]],
    mix: URL?,
    duration: Double,
    configuration: PipelineConfiguration,
    engines: EngineInfo,
    speakerLanguages: [SpeakerLanguage],
    regions: [LanguageRegion],
    timings: [StageTiming],
    createdAt: Date
  ) -> (transcript: Transcript, report: HallucinationFilter.Report) {
    var kept: [Segment] = []
    var dropped: [DroppedSegment] = []
    var noSpeechEvidence: [Segment] = []
    var utterances: [Utterance] = []

    for track in tracks {
      let segments = segmentsByTrack[track.speakerID] ?? []
      guard !segments.isEmpty else { continue }
      let report = HallucinationFilter.filter(
        segments, turns: track.turns.isEmpty ? nil : track.turns, options: configuration.filter)
      kept.append(contentsOf: report.kept)
      dropped.append(contentsOf: report.dropped)
      noSpeechEvidence.append(contentsOf: report.noSpeechEvidence)
      let fused = Fuser.fuse(
        segments: report.kept, turns: track.turns, options: configuration.fuser)
      utterances += fused.map { utterance in
        var copy = utterance
        // Дорожка — один участник: слова, не попавшие в отрезки речи (края фраз), тоже принадлежат ему.
        copy.speakerID = track.speakerID
        return copy
      }
    }

    utterances = markOverlaps(
      utterances.sorted {
        ($0.start, $0.end, $0.speakerID ?? Int.max) < ($1.start, $1.end, $1.speakerID ?? Int.max)
      },
      minimumShare: configuration.fuser.overlapShare)

    var speakers = SpeakerStats.summarize(utterances, languages: speakerLanguages)
    let names = Dictionary(
      tracks.compactMap { track in track.participantName.map { (track.speakerID, $0) } },
      uniquingKeysWith: { first, _ in first })
    for index in speakers.indices {
      guard let id = speakers[index].speakerID, let name = names[id] else { continue }
      speakers[index].name = name
    }

    let reference = mix ?? tracks.first?.url
    var meeting = configuration.meeting
    if let reference {
      meeting = meeting.filling(missingFrom: MeetingInfo.inferred(from: reference))
    }
    meeting.date = meeting.date.map(MeetingPipeline.wholeSeconds)

    let transcript = Transcript(
      createdAt: createdAt,
      meeting: meeting,
      audio: AudioInfo(
        sourceURL: reference, fileName: reference?.lastPathComponent ?? "—", duration: duration),
      engines: engines,
      utterances: utterances,
      turns: tracks.flatMap(\.turns).sorted {
        ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID)
      },
      speakers: speakers,
      speakerLanguages: speakerLanguages,
      timings: timings,
      peakMemoryBytes: ProcessMemory.snapshot()?.peakResidentBytes,
      diagnostics: TranscriptDiagnostics(
        dropped: dropped.sorted {
          ($0.segment.start, $0.segment.end) < ($1.segment.start, $1.segment.end)
        },
        regions: regions,
        noSpeechEvidence: noSpeechEvidence),
      speakerEmbeddings: tracks.compactMap { track in
        track.embedding.map {
          SpeakerEmbedding(
            speakerID: track.speakerID, vector: $0, speechSeconds: track.speechSeconds)
        }
      },
      tracks: tracks.map(\.info),
      nameHints: nameHints(tracks: tracks, configured: configuration.nameHints))
    let report = HallucinationFilter.Report(
      kept: kept.sorted { ($0.start, $0.end) < ($1.start, $1.end) },
      dropped: transcript.diagnostics.dropped,
      noSpeechEvidence: noSpeechEvidence)
    return (transcript, report)
  }

  /// Подсказки имён: переданные (`chat.txt`, OCR) плюс имя каждой дорожки; повторы одного источника
  /// с тем же именем и спикером схлопываются — дорожки могли прийти в подсказках и снаружи.
  static func nameHints(tracks: [TrackRun], configured: [NameHint]) -> [NameHint] {
    var result: [NameHint] = []
    var seen: Set<[String]> = []
    for hint in configured
      + tracks.compactMap({ track in
        track.participantName.map {
          NameHint(name: $0, source: .track, speakerID: track.speakerID)
        }
      })
    {
      let key = [hint.name, hint.source.rawValue, hint.speakerID.map(String.init) ?? "—"]
      guard seen.insert(key).inserted else { continue }
      result.append(hint)
    }
    return result
  }

  // MARK: - Наложения речи

  /// Наложение речи (SPEC.md §3.3): реплика пересекается с репликой другой дорожки не меньше чем на
  /// `minimumShare` своей длительности. На общем треке наложения ищет `Fuser` по turn'ам диаризации,
  /// а на дорожках он их увидеть не может — turn'ы каждой дорожки принадлежат одному спикеру.
  /// Вход отсортирован по началу; поиск ограничен окном в самую длинную реплику, поэтому проход линейный.
  static func markOverlaps(_ utterances: [Utterance], minimumShare: Double) -> [Utterance] {
    guard utterances.count > 1, minimumShare > 0 else { return utterances }
    var result = utterances
    let window = utterances.map(\.duration).max() ?? 0

    for index in result.indices {
      let current = result[index]
      let needed = max(current.duration, 0) * minimumShare
      guard needed > epsilon else { continue }
      var isOverlapped = current.overlapped

      var back = index - 1
      while !isOverlapped, back >= 0, current.start - result[back].start <= window + epsilon {
        if overlaps(result[back], current, atLeast: needed) { isOverlapped = true }
        back -= 1
      }
      var forward = index + 1
      while !isOverlapped, forward < result.count, result[forward].start < current.end {
        if overlaps(result[forward], current, atLeast: needed) { isOverlapped = true }
        forward += 1
      }
      result[index].overlapped = isOverlapped
    }
    return result
  }

  private static func overlaps(_ first: Utterance, _ second: Utterance, atLeast seconds: Double)
    -> Bool
  {
    guard first.speakerID != second.speakerID else { return false }
    return min(first.end, second.end) - max(first.start, second.start) >= seconds - epsilon
  }
}
