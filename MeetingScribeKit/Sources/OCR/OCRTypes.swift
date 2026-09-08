import Core
import CoreGraphics
import Foundation

// Подписи участников на видеокадрах как необязательный источник имён (SPEC.md §3.4 п. d, фаза 3).
// Модуль ничего не знает о движках ASR и диаризации: на вход — файл видео, на выход — список имён
// и отрезки, где известен активный спикер; связывание со спикерами — `NameVoting` по репликам.

/// Параметры прохода по видео и распознавания подписей.
///
/// Умолчания подобраны на реальных записях Zoom этой машины (кадр 1280×720, подпись белым по тёмной
/// полупрозрачной плашке в левом нижнем углу плитки, высота букв 11–13 px = 0.015…0.018 высоты кадра):
/// точный режим Vision обязателен для кириллицы, порог высоты текста занижен относительно системного
/// 1/32 (docs/research/05-names-zoom-ocr-voices.md, раздел «Распознавание подписей на видео»).
public struct OCROptions: Hashable, Sendable {
  /// Шаг выборки кадров, с.
  public var sampleIntervalSeconds: Double
  /// Ширина кадра, к которой приводит `AVAssetImageGenerator` (по ней же считается стоимость прохода).
  public var maximumFrameWidth: Int
  /// OCR всего кадра — не реже, чем раз в столько секунд (roster), и всякий раз, когда «сигнатура»
  /// кадра сильно изменилась.
  public var rosterIntervalSeconds: Double
  /// Минимальный интервал между двумя OCR всего кадра при частой смене картинки (демонстрация экрана), с.
  public var minimumRosterGapSeconds: Double
  /// Минимальная высота строки как доля высоты подаваемого изображения. Системное умолчание 1/32
  /// (22.5 px на кадре 720p) отсекает подписи Zoom целиком.
  public var minimumTextHeightFraction: Float
  /// Языки распознавания в порядке приоритета (идентификаторы BCP-47).
  public var languages: [String]
  /// Подсказки (имена из chat.txt/людей): используются для нечёткого сопоставления распознанных строк.
  public var nameHints: [String]
  /// Требовать тёмную плашку под текстом — как у подписей Zoom (белые буквы на полупрозрачном чёрном).
  ///
  /// Замер на кадрах пользователя: у подписей средняя яркость рамки 0.29…0.43 и ≥ 47 % тёмных пикселей,
  /// у текста слайдов и браузера при демонстрации экрана — 0.56…0.93 и ≤ 30 %. Без этой проверки
  /// roster забивается заголовками слайдов («Снижение», «Внедрение»), которые проходят проверку формы
  /// имени. Выключать имеет смысл только для записей со светлой темой подписей.
  public var requiresDarkCaptionPlate: Bool

  public init(
    sampleIntervalSeconds: Double = 1,
    maximumFrameWidth: Int = 1280,
    rosterIntervalSeconds: Double = 30,
    minimumRosterGapSeconds: Double = 5,
    minimumTextHeightFraction: Float = 0.008,
    languages: [String] = ["uk-UA", "ru-RU", "en-US"],
    nameHints: [String] = [],
    requiresDarkCaptionPlate: Bool = true
  ) {
    self.sampleIntervalSeconds = max(sampleIntervalSeconds, 0.05)
    self.maximumFrameWidth = max(maximumFrameWidth, 160)
    self.rosterIntervalSeconds = max(rosterIntervalSeconds, sampleIntervalSeconds)
    self.minimumRosterGapSeconds = max(minimumRosterGapSeconds, 0)
    self.minimumTextHeightFraction = max(minimumTextHeightFraction, 0)
    self.languages = languages
    self.nameHints = nameHints
    self.requiresDarkCaptionPlate = requiresDarkCaptionPlate
  }
}

/// Распознанная подпись: каноническое имя, уверенность Vision и место на кадре.
public struct RecognizedName: Hashable, Sendable {
  public var text: String
  public var confidence: Double
  /// Нормализованный прямоугольник в координатах кадра (origin — левый верх, 0…1).
  public var box: CGRect

  public init(text: String, confidence: Double, box: CGRect) {
    self.text = text
    self.confidence = confidence
    self.box = box
  }
}

/// Отрезок, на котором активный спикер известен по подписи (выделенная плитка или единственная плитка).
public struct ActiveSpeakerSpan: Hashable, Codable, Sendable {
  public var start: Double
  public var end: Double
  public var name: String

  public init(start: Double, end: Double, name: String) {
    self.start = start
    self.end = end
    self.name = name
  }

  public var duration: Double { max(0, end - start) }

  /// Длина пересечения с интервалом `[start, end]` (0, если не пересекаются).
  public func overlap(from otherStart: Double, to otherEnd: Double) -> Double {
    max(0, min(end, otherEnd) - max(start, otherStart))
  }
}

/// Итог прохода по видео: список подписей за всю запись и отрезки с известным активным спикером.
public struct OCRReport: Hashable, Codable, Sendable {
  /// Список подписей за всё видео: source `.ocr`, `count` — в скольких OCR-проходах имя встретилось.
  public var roster: [NameHint]
  /// Отрезки, где известен активный спикер (выделенная рамкой плитка или единственная плитка speaker view).
  public var spans: [ActiveSpeakerSpan]
  public var framesSampled: Int
  public var framesRecognized: Int
  public var videoSeconds: Double
  public var elapsedSeconds: Double

  public init(
    roster: [NameHint] = [],
    spans: [ActiveSpeakerSpan] = [],
    framesSampled: Int = 0,
    framesRecognized: Int = 0,
    videoSeconds: Double = 0,
    elapsedSeconds: Double = 0
  ) {
    self.roster = roster
    self.spans = spans
    self.framesSampled = framesSampled
    self.framesRecognized = framesRecognized
    self.videoSeconds = videoSeconds
    self.elapsedSeconds = elapsedSeconds
  }

  /// Суммарная длительность отрезков с известным активным спикером, с.
  public var coveredSeconds: Double { spans.reduce(0) { $0 + $1.duration } }

  /// Отчёт для человека (CLI и диагностика). Таймкоды `[HH:MM:SS]` живут только в `Sources/Export`,
  /// поэтому здесь — секунды.
  public static func describe(_ report: OCRReport) -> String {
    var lines: [String] = []
    let speed =
      report.elapsedSeconds > 0
      ? String(format: " (%.0f× реального времени)", report.videoSeconds / report.elapsedSeconds)
      : ""
    lines.append(
      String(
        format: "Подписи на видео: кадров %d, OCR-проходов %d, видео %.0f с, работа %.1f с%@",
        report.framesSampled, report.framesRecognized, report.videoSeconds, report.elapsedSeconds,
        speed))

    if report.roster.isEmpty {
      lines.append(String(localized: "Подписи: не найдены"))
    } else {
      lines.append(String(localized: "Подписи (имя — проходов):"))
      for hint in report.roster {
        lines.append("  \(hint.name) — \(hint.count)")
      }
    }

    if report.spans.isEmpty {
      lines.append(String(localized: "Активный спикер: рамка не найдена, только список имён"))
    } else {
      lines.append(
        String(
          format: "Активный спикер: отрезков %d, %.0f с из %.0f с",
          report.spans.count, report.coveredSeconds, report.videoSeconds))
      var seconds: [String: Double] = [:]
      var counts: [String: Int] = [:]
      for span in report.spans {
        seconds[span.name, default: 0] += span.duration
        counts[span.name, default: 0] += 1
      }
      for (name, total) in seconds.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
        lines.append(String(format: "  %@ — %d отрезков, %.0f с", name, counts[name] ?? 0, total))
      }
    }
    return lines.joined(separator: "\n")
  }
}

/// Ошибки распознавания подписей. Тексты объясняют, что случилось и что делать (docs/DESIGN.md §1).
public enum OCRError: Error, LocalizedError, Hashable, Sendable {
  case videoNotFound(URL)
  case noVideoTrack(URL)
  case unknownDuration(URL)
  case frameGenerationFailed(URL, reason: String)
  case recognitionFailed(reason: String)

  public var errorDescription: String? {
    switch self {
    case .videoNotFound(let url):
      String(
        localized:
          "Видео не найдено: \(url.path). Подписи участников распознаются только по файлу video*.mp4."
      )
    case .noVideoTrack(let url):
      String(
        localized:
          "Файл «\(url.lastPathComponent)» без видеодорожки: подписи участников распознать нечем.")
    case .unknownDuration(let url):
      String(
        localized:
          "Не удалось определить длительность «\(url.lastPathComponent)»: пропустите распознавание подписей."
      )
    case .frameGenerationFailed(let url, let reason):
      String(localized: "Не удалось получить кадры из «\(url.lastPathComponent)»: \(reason).")
    case .recognitionFailed(let reason):
      String(localized: "Ошибка распознавания текста на кадре: \(reason).")
    }
  }
}
