import Core
import CoreGraphics
import Foundation
import Vision

// Распознавание подписей участников: Vision `RecognizeTextRequest` (новый Swift-интерфейс, macOS 15+)
// плюс фильтры, отделяющие подпись от текста слайдов при демонстрации экрана.

public enum NameRecognizer {
  /// Ширина, к которой стремимся перед распознаванием: подписи мелкие, Vision точнее на увеличенной копии.
  static let recognitionTargetWidth = 2600
  /// Потолок стороны изображения: выше растёт время, а не качество.
  static let recognitionMaximumWidth = 4096
  /// Средняя яркость под строкой, выше которой это не плашка Zoom (замер на кадрах пользователя:
  /// подписи 0.29…0.43, текст слайдов и браузера 0.56…0.93).
  static let maximumPlateLuminance = 0.55
  /// Доля тёмных пикселей под строкой у подписи (замер: 0.47…0.66 против ≤ 0.30 у слайдов).
  static let minimumPlateDarkFraction = 0.25
  /// Максимальная высота строки как доля высоты КАДРА. Подпись Zoom — мелкий системный шрифт
  /// (замер на записи 85 мин: 0.0116…0.0196), заголовки слайдов крупнее (0.023…0.102).
  /// Без верхней границы в список имён попадают «Регулярный Альянс» и «Тест-драйв».
  static let maximumTextHeightFraction = 0.03

  /// Распознаёт подписи на кадре или в его части.
  ///
  /// `region` — нормализованный прямоугольник (origin левый верх); вырезка увеличивается в 2–3 раза,
  /// потому что плашки мелкие (11–13 px на кадре 720p). Возвращаются только строки, похожие на имя
  /// (`canonicalName`), с боксами в координатах ИСХОДНОГО кадра.
  public static func recognizeNames(
    in image: CGImage, region: CGRect? = nil, options: OCROptions = OCROptions()
  ) async throws -> [RecognizedName] {
    let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    let area = (region ?? full).intersection(full)
    guard image.width > 0, image.height > 0, area.width > 0.005, area.height > 0.005 else {
      return []
    }
    let crop = CGRect(
      x: area.minX * Double(image.width),
      y: area.minY * Double(image.height),
      width: area.width * Double(image.width),
      height: area.height * Double(image.height))
    let factor = upscaleFactor(forWidth: Int(crop.width.rounded()))
    guard
      let prepared = FrameImage.upscaled(
        image, crop: region == nil ? nil : crop, factor: factor)
    else {
      throw OCRError.recognitionFailed(
        reason: String(localized: "не удалось подготовить кадр к распознаванию"))
    }

    var request = RecognizeTextRequest()
    // Быстрый режим физически не умеет кириллицу (docs/research/05-names-zoom-ocr-voices.md).
    request.recognitionLevel = .accurate
    // Имена собственные языковая коррекция только портит; по этой же причине не передаём customWords —
    // словарь учитывается лишь при включённой коррекции. Подсказки применяются нечётким сравнением.
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = false
    request.recognitionLanguages = options.languages.map { Locale.Language(identifier: $0) }
    request.minimumTextHeightFraction = options.minimumTextHeightFraction

    let observations: [RecognizedTextObservation]
    do {
      observations = try await request.perform(on: prepared)
    } catch {
      throw OCRError.recognitionFailed(reason: error.localizedDescription)
    }
    guard !observations.isEmpty else { return [] }

    // Развёртка исходного кадра нужна только для проверки плашки — делаем её лениво.
    var bitmap: FrameBitmap?
    var names: [RecognizedName] = []
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first,
        let name = canonicalName(candidate.string, hints: options.nameHints)
      else { continue }
      // Vision отдаёт нормализованный прямоугольник с началом в левом НИЖНЕМ углу вырезки.
      let local = observation.boundingBox.verticallyFlipped().cgRect
      let box = CGRect(
        x: area.minX + local.minX * area.width,
        y: area.minY + local.minY * area.height,
        width: local.width * area.width,
        height: local.height * area.height)
      guard box.height <= Self.maximumTextHeightFraction else { continue }
      if options.requiresDarkCaptionPlate {
        if bitmap == nil { bitmap = FrameBitmap(image) }
        guard let plate = bitmap?.brightness(in: box), plate.mean < maximumPlateLuminance,
          plate.dark >= minimumPlateDarkFraction
        else { continue }
      }
      names.append(
        RecognizedName(text: name, confidence: Double(candidate.confidence), box: box))
    }
    return names
  }

  static func upscaleFactor(forWidth width: Int) -> Int {
    guard width > 0 else { return 1 }
    var factor = min(3, max(2, recognitionTargetWidth / width))
    while factor > 1, width * factor > recognitionMaximumWidth { factor -= 1 }
    return factor
  }
}

// MARK: - Похоже ли на имя

extension NameRecognizer {
  /// Служебные строки интерфейса Zoom, которые попадают в кадр рядом с подписями.
  static let serviceStrings: Set<String> = [
    "recording", "recording in progress", "mute", "unmute", "mute all", "share", "share screen",
    "stop share", "start video", "stop video", "participants", "chat", "reactions", "view",
    "gallery view", "speaker view", "everyone", "host", "co-host", "cohost", "me", "you", "guest",
    "leave", "leave meeting", "end", "end meeting", "more", "raise hand", "screen sharing",
    "запись", "идет запись", "идёт запись", "все", "вы", "я", "участники", "чат", "реакции", "вид",
    "демонстрация экрана", "выйти", "гость", "организатор", "хозяин", "ведущий", "хост",
    "запис", "учасники", "вийти", "організатор",
  ]

  /// Частицы фамилий, которые пишутся со строчной буквы.
  static let particles: Set<String> = [
    "de", "van", "der", "von", "da", "di", "del", "della", "du", "dos", "la", "le", "bin", "ibn",
    "al", "оглы", "кызы",
  ]

  /// Символы, которые допустимы внутри слова имени.
  static let nameSymbols = Set("-'’ʼ.`")

  /// Мусор по краям строки: маркеры списков, кавычки, знаки препинания, значок микрофона.
  static let trimmed = Set(" \t\u{00A0}•·|:,;*\"'“”«»—–-…()[]{}<>/\\_+~^&#@!?")

  /// Похоже ли на имя человека. Возвращает каноническое написание или `nil`.
  ///
  /// Правила: 1–4 слова из букв (латиница/кириллица, дефис, апостроф, точка для инициалов), длина 2…40,
  /// каждое слово с заглавной (кроме частиц вроде «van»), есть хотя бы одна строчная буква,
  /// служебные строки Zoom отсекаются,
  /// «Иван Минин (Host)» → «Иван Минин». Нечёткое сопоставление с `hints` (нормализованное расстояние
  /// Левенштейна ≥ 0.8) возвращает подсказку в её написании — так исправляются ошибки OCR на мелком тексте
  /// («Лван Минин» → «Иван Минин»).
  public static func canonicalName(_ text: String, hints: [String] = []) -> String? {
    let cleaned = clean(text)
    guard !cleaned.isEmpty else { return nil }
    guard !serviceStrings.contains(NameMatching.normalized(cleaned)) else { return nil }
    if let hint = NameMatching.bestMatch(for: cleaned, in: hints) { return hint }
    guard looksLikeName(cleaned) else { return nil }
    return cleaned
  }

  /// Убирает мусор по краям, служебные суффиксы в скобках и лишние пробелы.
  static func clean(_ text: String) -> String {
    var value = text.replacingOccurrences(of: "\u{00A0}", with: " ")
    value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    // «Иван Минин (Host)», «Anna (Ecommerce)» — суффикс в скобках к имени не относится.
    var guardCounter = 0
    while value.hasSuffix(")"), let open = value.lastIndex(of: "("), guardCounter < 2 {
      value = String(value[value.startIndex..<open]).trimmingCharacters(in: .whitespaces)
      guardCounter += 1
    }
    while let first = value.first, trimmed.contains(first) { value.removeFirst() }
    while let last = value.last, trimmed.contains(last) { value.removeLast() }
    return value
  }

  static func looksLikeName(_ text: String) -> Bool {
    guard text.count >= 2, text.count <= 40 else { return false }
    // Подпись — это то, что человек ввёл в профиле Zoom («Иван Минин»); заголовки слайдов часто
    // набраны капслоком («ЕБУНЯЧИМ КЕШБЕКОМ»). Имя капслоком выручит подсказка из chat.txt.
    guard text.contains(where: \.isLowercase) else { return false }
    let words = text.split(separator: " ")
    guard (1...4).contains(words.count) else { return false }
    if words.count == 1, text.count < 3 { return false }
    var capitalized = 0
    for word in words {
      guard isNameWord(word) else { return false }
      if word.first?.isUppercase == true {
        capitalized += 1
      } else if !particles.contains(word.lowercased()) {
        return false
      }
    }
    return capitalized >= 1
  }

  private static func isNameWord(_ word: Substring) -> Bool {
    guard !word.isEmpty, word.count <= 24 else { return false }
    var letters = 0
    for character in word {
      if character.isLetter {
        letters += 1
      } else if !nameSymbols.contains(character) {
        return false
      }
    }
    return letters > 0
  }
}

// MARK: - Нечёткое сопоставление

/// Сравнение распознанной строки с подсказками (chat.txt, люди) и склейка вариантов написания.
enum NameMatching {
  /// Порог сопоставления с подсказкой: 0.8 нормализованного расстояния Левенштейна.
  static let hintThreshold = 0.8
  /// Порог склейки двух распознанных написаний одного имени между собой (строже, чем для подсказок).
  static let mergeThreshold = 0.85

  /// Приведение к сравнимому виду: строчные буквы, без знаков, ё → е, і → и.
  static func normalized(_ text: String) -> String {
    let folded = text.lowercased().replacingOccurrences(of: "ё", with: "е")
      .replacingOccurrences(of: "і", with: "и")
    let kept = folded.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
  }

  /// Нормализованное сходство 0…1 (1 — совпадение).
  static func similarity(_ a: String, _ b: String) -> Double {
    let left = Array(normalized(a))
    let right = Array(normalized(b))
    guard !left.isEmpty, !right.isEmpty else { return left.isEmpty && right.isEmpty ? 1 : 0 }
    let distance = levenshtein(left, right)
    return 1 - Double(distance) / Double(max(left.count, right.count))
  }

  static func bestMatch(for text: String, in hints: [String], threshold: Double = hintThreshold)
    -> String?
  {
    var best: (hint: String, score: Double)?
    for hint in hints {
      let score = similarity(text, hint)
      guard score >= threshold else { continue }
      if best == nil || score > best!.score { best = (hint, score) }
    }
    return best?.hint
  }

  /// Одна строка — обрезанное начало другой: подпись у края плитки часто теряет хвост
  /// («Антон Воро» вместо «Антон Воронков»). Общая часть должна быть не короче 6 символов и 60 % длинной строки.
  static func isTruncation(_ a: String, _ b: String) -> Bool {
    let short = a.count <= b.count ? a : b
    let long = a.count <= b.count ? b : a
    guard short.count >= 6, Double(short.count) / Double(long.count) >= 0.6 else { return false }
    return long.hasPrefix(short)
  }

  static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }
}
