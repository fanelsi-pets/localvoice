import AVFoundation
import Core
import CoreGraphics
import Foundation

// Проход по видео: кадры раз в секунду, дешёвый детектор рамки на каждом кадре, OCR всего кадра
// по расписанию и OCR подписи выделенной плитки при смене её положения (SPEC.md §3.4 п. d).

public actor VideoNameScanner {
  /// Распознаватель подписей. Подменяется в тестах, чтобы проверять проход по видео без Vision.
  typealias Recognize = @Sendable (CGImage, CGRect?, OCROptions) async throws -> [RecognizedName]

  /// Сколько кадров запрашивается за раз: `images(for:)` не имеет обратного давления и складывает
  /// готовые кадры в очередь — пачками держим пик памяти в пределах сотни мегабайт.
  static let chunkSize = 32
  static let timescale: CMTimeScale = 600
  /// Допуск на поиск кадра: точный кадр требует полного декодирования GOP (замер: ±0.5 с ≈ 14 мс/кадр).
  static let toleranceSeconds = 0.5
  /// Насколько должна измениться сигнатура кадра, чтобы считать это сменой раскладки.
  static let layoutChangeThreshold = 0.08
  /// Насколько может сместиться рамка, чтобы плитка считалась той же (доля кадра).
  static let tileMoveTolerance = 0.02
  /// Подпись в speaker view засчитывается активному спикеру, если она ниже этой доли высоты кадра.
  static let speakerViewBottom = 2.0 / 3.0
  /// …и прижата к левому краю: подпись Zoom всегда в левом нижнем углу плитки, а текст на слайде —
  /// где угодно (на записи пользователя строка слайда справа внизу давала ложный отрезок в 290 с).
  static let speakerViewLeft = 0.25
  /// Не реже раза в полсекунды работы — событие прогресса (SPEC.md §3.7 п. 4).
  static let progressInterval = Duration.milliseconds(500)

  private let videoURL: URL
  private let options: OCROptions
  private let recognize: Recognize

  public init(videoURL: URL, options: OCROptions = OCROptions()) {
    self.videoURL = videoURL
    self.options = options
    self.recognize = { image, region, options in
      try await NameRecognizer.recognizeNames(in: image, region: region, options: options)
    }
  }

  init(videoURL: URL, options: OCROptions = OCROptions(), recognize: @escaping Recognize) {
    self.videoURL = videoURL
    self.options = options
    self.recognize = recognize
  }

  /// Проходит по видео и собирает список подписей и отрезки активного спикера.
  /// Отмена проверяется между кадрами и бросает `CancellationError`.
  public func scan(progress: ProgressSink?) async throws -> OCRReport {
    let started = ContinuousClock.now
    try Task.checkCancellation()
    let (asset, duration) = try await prepareAsset()
    let generator = makeGenerator(for: asset)
    defer { generator.cancelAllCGImageGeneration() }

    var state = ScanState(sampleInterval: options.sampleIntervalSeconds)
    var framesSampled = 0
    var framesRecognized = 0
    var frameFailure: (any Error)?
    var lastSignature: [UInt8]?
    var lastRosterTime = -Double.greatestFiniteMagnitude
    var tileMemory: (rect: CGRect, name: String)?
    var speakerView: (name: String, validUntil: Double)?
    var lastProgress: ContinuousClock.Instant?

    progress?(
      ProgressEvent(stage: .nameRecognition, fractionOfStage: 0, timecode: 0, pulse: Self.pulse(0)))

    let times = stride(from: 0, to: duration, by: options.sampleIntervalSeconds)
      .map { CMTime(seconds: $0, preferredTimescale: Self.timescale) }
    var index = 0
    while index < times.count {
      try Task.checkCancellation()
      let batch = Array(times[index..<min(index + Self.chunkSize, times.count)])
      index += Self.chunkSize
      for await element in generator.images(for: batch) {
        try Task.checkCancellation()
        // Таймкод кадра — запрошенное время: допуск ±0.5 с делает фактическое время неупорядоченным,
        // а сетка выборки — это то, чем измеряются отрезки активного спикера.
        let time = CMTimeGetSeconds(element.requestedTime)
        let image: CGImage
        do {
          image = try element.image
        } catch {
          frameFailure = error
          continue
        }
        guard time.isFinite else { continue }
        framesSampled += 1

        // Кадр разворачивается в пиксели один раз: и сигнатура, и маска рамки читают ту же развёртку.
        let bitmap = FrameBitmap(image)
        let signature = bitmap.map { TileDetector.signature(of: $0) } ?? []
        let changed =
          lastSignature.map {
            TileDetector.difference($0, signature) > Self.layoutChangeThreshold
          } ?? true
        lastSignature = signature
        let tile = bitmap.flatMap { TileDetector.highlightedTile(in: $0) }

        // OCR всего кадра: по расписанию либо при смене картинки, но не чаще минимального интервала.
        let sinceRoster = time - lastRosterTime
        if sinceRoster >= options.rosterIntervalSeconds
          || (changed && sinceRoster >= options.minimumRosterGapSeconds)
        {
          let names = try await recognize(image, nil, options)
          framesRecognized += 1
          lastRosterTime = time
          state.add(names: names.map(\.text))
          // Speaker view: одна подпись в нижней трети кадра и никакой рамки — это активный спикер.
          if tile == nil, names.count == 1, names[0].box.midY >= Self.speakerViewBottom,
            names[0].box.minX <= Self.speakerViewLeft
          {
            speakerView = (names[0].text, time + options.rosterIntervalSeconds)
          } else {
            speakerView = nil
          }
        }

        if let tile {
          if let memory = tileMemory, Self.isSameTile(memory.rect, tile) {
            state.mark(name: memory.name, at: time)
          } else {
            let names = try await recognize(image, Self.captionRegion(of: tile), options)
            framesRecognized += 1
            // Подпись прожжена в левом нижнем углу плитки — берём самую левую строку вырезки.
            if let caption = names.min(by: { $0.box.minX < $1.box.minX }) {
              tileMemory = (tile, caption.text)
              state.add(names: [caption.text])
              state.mark(name: caption.text, at: time)
            } else {
              tileMemory = nil
              state.breakSpan()
            }
          }
        } else if let current = speakerView, time <= current.validUntil {
          state.mark(name: current.name, at: time)
        } else {
          state.breakSpan()
        }

        let now = ContinuousClock.now
        if lastProgress == nil || now - lastProgress! >= Self.progressInterval {
          lastProgress = now
          progress?(
            ProgressEvent(
              stage: .nameRecognition,
              fractionOfStage: min(max(time / duration, 0), 1),
              timecode: time,
              pulse: Self.pulse(state.distinctNameCount)))
        }
      }
    }
    state.finish()
    // Пустой отчёт вместо ошибки скрыл бы недоступный декодер (в параллельных прогонах
    // AVFoundation отдаёт ошибку на каждый кадр) — молча «ничего не нашли» здесь недопустимо.
    if framesSampled == 0, !times.isEmpty {
      throw OCRError.frameGenerationFailed(
        videoURL,
        reason: frameFailure?.localizedDescription ?? String(localized: "кадры недоступны"))
    }

    let elapsed = Self.seconds(ContinuousClock.now - started)
    progress?(
      ProgressEvent(
        stage: .nameRecognition, fractionOfStage: 1, timecode: duration,
        pulse: Self.pulse(state.distinctNameCount)))
    // Одиночное распознавание — обычно шум; если проход был всего один, показывать нечего кроме него.
    let minimumCount = framesRecognized >= 2 ? 2 : 1
    return OCRReport(
      roster: state.roster(minimumCount: minimumCount),
      spans: state.spans,
      framesSampled: framesSampled,
      framesRecognized: framesRecognized,
      videoSeconds: duration,
      elapsedSeconds: elapsed)
  }
}

// MARK: - Подготовка

extension VideoNameScanner {
  private func prepareAsset() async throws -> (AVURLAsset, Double) {
    guard FileManager.default.fileExists(atPath: videoURL.path(percentEncoded: false)) else {
      throw OCRError.videoNotFound(videoURL)
    }
    let asset = AVURLAsset(url: videoURL)
    let tracks: [AVAssetTrack]
    do {
      tracks = try await asset.loadTracks(withMediaType: .video)
    } catch {
      // AVFoundation на отменённой задаче бросает свою ошибку — наружу отмена всегда одна и та же.
      if Task.isCancelled { throw CancellationError() }
      throw OCRError.frameGenerationFailed(videoURL, reason: error.localizedDescription)
    }
    try Task.checkCancellation()
    guard let track = tracks.first else { throw OCRError.noVideoTrack(videoURL) }
    var duration = 0.0
    if let assetDuration = try? await asset.load(.duration) {
      let seconds = CMTimeGetSeconds(assetDuration)
      if seconds.isFinite, seconds > 0 { duration = seconds }
    }
    if duration == 0, let range = try? await track.load(.timeRange) {
      let seconds = CMTimeGetSeconds(range.end)
      if seconds.isFinite, seconds > 0 { duration = seconds }
    }
    guard duration > 0 else { throw OCRError.unknownDuration(videoURL) }
    return (asset, duration)
  }

  private func makeGenerator(for asset: AVURLAsset) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // maximumSize — ограничивающий прямоугольник, картинка не увеличивается; запас по высоте нужен,
    // чтобы решающей была ширина и на вертикальном видео.
    generator.maximumSize = CGSize(
      width: options.maximumFrameWidth, height: options.maximumFrameWidth * 4)
    let tolerance = CMTime(seconds: Self.toleranceSeconds, preferredTimescale: Self.timescale)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    return generator
  }

  static func pulse(_ names: Int) -> String { String(localized: "найдено имён: \(names)") }

  static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  /// Та же плитка, если все стороны сместились не больше допуска.
  static func isSameTile(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= tileMoveTolerance && abs(a.minY - b.minY) <= tileMoveTolerance
      && abs(a.maxX - b.maxX) <= tileMoveTolerance && abs(a.maxY - b.maxY) <= tileMoveTolerance
  }

  /// Полоса с подписью: низ плитки с небольшим запасом наружу (рамка рисуется поверх подписи).
  static func captionRegion(of tile: CGRect) -> CGRect {
    let margin = 0.01
    let height = min(max(tile.height * 0.28, 0.06), tile.height)
    let x = max(0, tile.minX - margin)
    let width = min(tile.width + 2 * margin, 1 - x)
    let y = min(max(tile.maxY - height, 0), 1 - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
