import AVFoundation
import Core
import Foundation

/// Запись куска аудио во временный файл для отправки провайдеру.
///
/// Формат — FLAC, моно 16 kHz: сжатие без потерь (вдвое меньше WAV, два часа ≈ 60 МБ вместо 230) и
/// `audio/flac` прямо назван в списке форматов Gemini 3.5 Transcribe. Потери кодека не должны мешать
/// сравнению облака с локальным WhisperKit. Если FLAC записать не вышло — WAV 16 бит: лучше медленная
/// выгрузка, чем сорванная обработка.
enum RemoteAudioClip {
  struct Written: Sendable {
    var url: URL
    var mimeType: String
  }

  static func write(_ audio: PCMAudio, into directory: URL, name: String) throws -> Written {
    guard !audio.isEmpty else {
      throw EngineError.invalidAudio(String(localized: "пустой фрагмент аудио"))
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let url = directory.appendingPathComponent("\(name).flac")
      try write(
        audio, to: url,
        settings: [
          AVFormatIDKey: kAudioFormatFLAC,
          AVSampleRateKey: Double(PCMAudio.sampleRate),
          AVNumberOfChannelsKey: 1,
          AVEncoderBitDepthHintKey: 16,
        ])
      return Written(url: url, mimeType: "audio/flac")
    } catch {
      let url = directory.appendingPathComponent("\(name).wav")
      do {
        try write(
          audio, to: url,
          settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(PCMAudio.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
          ])
        return Written(url: url, mimeType: "audio/wav")
      } catch {
        throw EngineError.invalidAudio(
          String(localized: "не удалось записать кусок аудио: \(error.localizedDescription)"))
      }
    }
  }

  /// Пишет Float32-отсчёты блоками: буфер на весь кусок держал бы лишние сотни мегабайт.
  private static func write(_ audio: PCMAudio, to url: URL, settings: [String: Any]) throws {
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = file.processingFormat
    let blockSize = 16_384
    var offset = 0
    while offset < audio.samples.count {
      let count = min(blockSize, audio.samples.count - offset)
      guard
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
        let channel = buffer.floatChannelData?[0]
      else {
        throw EngineError.invalidAudio(String(localized: "не удалось создать буфер аудио"))
      }
      audio.samples.withUnsafeBufferPointer { source in
        channel.update(from: source.baseAddress! + offset, count: count)
      }
      buffer.frameLength = AVAudioFrameCount(count)
      try file.write(from: buffer)
      offset += count
    }
  }
}
