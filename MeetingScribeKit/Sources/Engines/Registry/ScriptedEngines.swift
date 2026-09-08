import Core
import Foundation
import Ingest

/// Сценарные движки для UI-тестов и превью: детерминированные, без моделей и сети, декодер настоящий
/// (UI-тест подаёт реальный WAV, стадия подготовки аудио должна быть настоящей).
/// Включаются launch-аргументом `-MSFakeEngines YES` (только DEBUG-сборка приложения).
///
/// Сценарий: 3 спикера чередуются turn'ами по 6 с; второй спикер говорит по-украински (роутер языков
/// получает два языка и зовёт распознавание клипами, как на реальной записи); распознавание отдаёт
/// сегмент на каждые ~4 с аудио с фразой из фиксированного списка и растягивается на `asrWorkSeconds`,
/// чтобы прогресс, пульс, лента и отмена были видны в интерфейсе.
public struct ScriptedEngines: EngineProviding {
  /// Параметры сценария. Значения по умолчанию рассчитаны на минутную запись UI-теста (~7 с работы).
  public struct Configuration: Hashable, Sendable {
    /// Сколько спикеров размечает диаризатор (перекрывается подсказкой `DiarizationHints.expectedSpeakers`).
    public var speakerCount: Int
    /// Длительность turn'а одного спикера, с.
    public var turnSeconds: Double
    /// Сколько секунд занимает распознавание всего файла; вызов с клипами берёт свою долю.
    public var asrWorkSeconds: Double
    /// Сколько занимает «загрузка моделей» (три события прогресса).
    public var prepareSeconds: Double

    public init(
      speakerCount: Int = 3,
      turnSeconds: Double = 6,
      asrWorkSeconds: Double = 5,
      prepareSeconds: Double = 0.6
    ) {
      self.speakerCount = max(speakerCount, 1)
      self.turnSeconds = max(turnSeconds, 0.5)
      self.asrWorkSeconds = max(asrWorkSeconds, 0)
      self.prepareSeconds = max(prepareSeconds, 0)
    }

    public static let demo = Configuration()
  }

  public let configuration: Configuration

  public init(configuration: Configuration = .demo) {
    self.configuration = configuration
  }

  public func decoder() -> any AudioDecoding {
    AudioDecoder()
  }

  public func asr(for selection: EngineSelection) async throws -> any AsrEngine {
    ScriptedAsrEngine(configuration: configuration)
  }

  public func diarizer(for selection: EngineSelection) async throws -> (any Diarizer)? {
    guard selection.diarizer != nil else { return nil }
    return ScriptedDiarizer(configuration: configuration)
  }
}

/// Реплики сценария. Фразы стабильны: по ним проверяются экспорт и лента в UI-тестах.
///
/// Первые фразы каждого языка повторяют встроенный сэмпл самопроверки (`selftest-sample.wav`,
/// SPEC.md §2 п. 8): короткий прогон под сценарными движками должен давать те же ключевые слова,
/// что и настоящие движки, иначе самопроверка в UI-тесте онбординга «не прошла бы» без причины.
public enum ScriptedScript {
  public static let russian: [String] = [
    "Коллеги, начнём встречу и согласуем дедлайн по MVP.",
    "Обновим roadmap до конца квартала.",
    "Фиксируем релиз на пятнадцатое число и пишем follow-up в проект.",
    "Давайте начнём с итогов недели.",
    "Нужно посчитать юнит-экономику до пятницы.",
    "Я подготовлю драфт презентации.",
    "Мы согласовали сроки с подрядчиком.",
    "Кто берёт на себя интеграцию с биллингом?",
    "Тогда переносим релиз на следующий спринт.",
  ]

  public static let ukrainian: [String] = [
    "Я підготую документ до четверга.",
    "Я підготувала оцінку: на бекенд потрібен тиждень.",
    "Добре, я надішлю нотатки сьогодні ввечері.",
    "Треба узгодити бюджет з командою.",
    "Ми вже перевірили дані по клієнтах.",
    "Додам коментарі до презентації сьогодні.",
  ]

  public static let english: [String] = [
    "Let us align on the roadmap first.",
    "I will share the numbers after the call.",
    "We need one more review before release.",
  ]

  /// Фразы языка вызова; неизвестный язык — русский (основной язык встреч проекта).
  public static func phrases(for language: Language?) -> [String] {
    switch language {
    case .uk?: ukrainian
    case .en?: english
    default: russian
    }
  }
}

/// Сценарное распознавание: сегмент на каждые ~4 с аудио, пульс и лента по ходу, отмена — `EngineError.cancelled`.
public actor ScriptedAsrEngine: AsrEngine {
  /// Один сегмент на столько секунд аудио.
  static let segmentSeconds: Double = 4
  /// Сколько «думает» определение языка одного спикера.
  static let detectionSeconds: Double = 0.2

  public nonisolated let descriptor = EngineDescriptor(
    name: "Scripted", model: "demo", version: "0")
  public nonisolated let supportsLanguageSelection = true

  private let configuration: ScriptedEngines.Configuration
  /// Номер вызова определения языка: второй спикер сценария — украиноязычный.
  private var detectionCalls = 0
  /// Сквозной счётчик фраз: соседние сегменты никогда не повторяются (иначе фильтр галлюцинаций их отбросит).
  private var phraseIndex = 0

  public init(configuration: ScriptedEngines.Configuration = .demo) {
    self.configuration = configuration
  }

  /// Долю стадии подготовки двигает диаризатор (доля стадии монотонна: единица от ASR обнулила бы сценарий).
  public func prepare(progress: ProgressSink?) async throws {
    progress?(
      ProgressEvent(
        stage: .modelDownload, fractionOfStage: 0, pulse: "Подготовка сценарного распознавания"))
    try await pause(configuration.prepareSeconds / 3)
  }

  public func detectLanguage(_ audio: PCMAudio) async throws -> LanguageDetection {
    detectionCalls += 1
    try await pause(Self.detectionSeconds)
    // Второй спикер записи говорит по-украински: роутер даёт два языка и зовёт распознавание клипами.
    if detectionCalls == 2 {
      return LanguageDetection(language: .uk, probabilities: [.uk: 0.9, .ru: 0.1])
    }
    return LanguageDetection(language: .ru, probabilities: [.ru: 0.9, .uk: 0.1])
  }

  public func transcribe(
    _ audio: PCMAudio, options: AsrOptions, progress: ProgressSink?, discovered: SegmentSink?
  ) async throws -> [Segment] {
    let duration = max(audio.duration, 0)
    let clips = options.clips.isEmpty ? [0...duration] : options.clips
    let slots = Self.slots(in: clips, offset: options.timeOffset)
    // Работа вызова пропорциональна доле запрошенных секунд: весь файл — ровно `asrWorkSeconds`.
    let requested = options.requestedSeconds(audioDuration: duration)
    let work = duration > 0 ? configuration.asrWorkSeconds * (requested / duration) : 0
    let perSlot = slots.isEmpty ? 0 : work / Double(slots.count)
    let phrases = ScriptedScript.phrases(for: options.language)

    var result: [Segment] = []
    result.reserveCapacity(slots.count)
    for slot in slots {
      try await pause(perSlot)
      let phrase = phrases[phraseIndex % phrases.count]
      phraseIndex += 1
      let segment = Self.segment(
        start: slot.lowerBound, end: slot.upperBound, phrase: phrase, language: options.language)
      result.append(segment)
      // Сначала лента (при отмене уже отданные сегменты остаются у вызывающего), затем пульс прогресса.
      discovered?([segment])
      progress?(
        .audio(
          .transcription, processed: segment.end, total: duration, timecode: segment.end,
          pulse: phrase))
    }
    return result
  }

  /// Границы сегментов внутри клипов вызова: примерно по `segmentSeconds` секунд, не меньше одного на клип.
  static func slots(in clips: [ClosedRange<Double>], offset: Double) -> [ClosedRange<Double>] {
    var slots: [ClosedRange<Double>] = []
    for clip in clips {
      let length = clip.upperBound - clip.lowerBound
      guard length > 0.05 else { continue }
      let count = max(1, Int((length / segmentSeconds).rounded()))
      let step = length / Double(count)
      for index in 0..<count {
        let start = clip.lowerBound + Double(index) * step + offset
        slots.append(start...(start + step))
      }
    }
    return slots.sorted { $0.lowerBound < $1.lowerBound }
  }

  /// Слова распределены по длительности равномерно; метрики — как у нормальной речи, чтобы фильтр не отбрасывал.
  static func segment(start: Double, end: Double, phrase: String, language: Language?) -> Segment {
    let texts = phrase.split(separator: " ").map(String.init)
    let step = texts.isEmpty ? 0 : (end - start) / Double(texts.count)
    let words = texts.enumerated().map { index, text in
      Word(
        start: start + Double(index) * step, end: start + Double(index + 1) * step, text: text,
        probability: 0.9)
    }
    return Segment(
      start: start, end: end, text: texts.joined(separator: " "), language: language, words: words,
      noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.2)
  }

  /// Пауза, уважающая отмену: адаптеры движков превращают отмену задачи в `EngineError.cancelled`.
  private func pause(_ seconds: Double) async throws {
    if Task.isCancelled { throw EngineError.cancelled }
    guard seconds > 0 else { return }
    do {
      try await Task.sleep(for: .seconds(seconds))
    } catch {
      throw EngineError.cancelled
    }
  }
}

/// Сценарная диаризация: чередующиеся turn'ы спикеров и прогресс в четыре шага.
public actor ScriptedDiarizer: Diarizer {
  /// Доли стадии подготовки моделей и общая длительность разметки.
  static let prepareFractions: [Double] = [0.3, 0.6, 1]
  static let diarizeSeconds: Double = 0.8
  static let diarizeSteps = 4

  public nonisolated let descriptor = EngineDescriptor(
    name: "Scripted", model: "demo", version: "0")

  private let configuration: ScriptedEngines.Configuration

  public init(configuration: ScriptedEngines.Configuration = .demo) {
    self.configuration = configuration
  }

  public func prepare(progress: ProgressSink?) async throws {
    let step = configuration.prepareSeconds / Double(Self.prepareFractions.count)
    for fraction in Self.prepareFractions {
      try await pause(step)
      progress?(.fraction(.modelDownload, fraction, pulse: "Загрузка сценарных моделей"))
    }
  }

  public func diarize(_ audio: PCMAudio, hints: DiarizationHints, progress: ProgressSink?)
    async throws -> DiarizationResult
  {
    let duration = max(audio.duration, 0)
    // Подсказка пользователя из диалога импорта важнее умолчания сценария.
    let speakerCount = max(hints.expectedSpeakers ?? configuration.speakerCount, 1)
    let step = Self.diarizeSeconds / Double(Self.diarizeSteps)
    for index in 1...Self.diarizeSteps {
      try await pause(step)
      progress?(
        .fraction(
          .diarization, Double(index) / Double(Self.diarizeSteps),
          pulse: "спикеров: \(speakerCount)"))
    }
    return DiarizationResult(
      turns: Self.turns(
        duration: duration, turnSeconds: configuration.turnSeconds, speakerCount: speakerCount),
      embeddings: Self.embeddings(speakerCount: speakerCount))
  }

  /// Детерминированные отпечатки голосов (фаза 3): у каждого спикера сценария свой почти ортогональный вектор,
  /// одинаковый от прогона к прогону, — вторая встреча на тех же движках узнаёт людей по профилям
  /// (SPEC.md §7 п. 5), а разные спикеры не путаются (cosine ≈ 0.1).
  static func embeddings(speakerCount: Int) -> [Int: [Float]] {
    let dimension = 16
    var result: [Int: [Float]] = [:]
    for speaker in 0..<speakerCount {
      var vector = [Float](repeating: 0.1, count: dimension)
      vector[speaker % dimension] = 1
      vector[(speaker + 5) % dimension] = 0.3
      result[speaker] = vector
    }
    return result
  }

  static func turns(duration: Double, turnSeconds: Double, speakerCount: Int) -> [Turn] {
    var turns: [Turn] = []
    var start = 0.0
    var index = 0
    while start < duration - 0.01 {
      let end = min(start + turnSeconds, duration)
      turns.append(Turn(start: start, end: end, speakerID: index % speakerCount, confidence: 0.9))
      start = end
      index += 1
    }
    return turns
  }

  private func pause(_ seconds: Double) async throws {
    if Task.isCancelled { throw EngineError.cancelled }
    guard seconds > 0 else { return }
    do {
      try await Task.sleep(for: .seconds(seconds))
    } catch {
      throw EngineError.cancelled
    }
  }
}
