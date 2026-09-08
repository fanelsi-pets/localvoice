import AVFoundation
import Core
import Foundation

/// Чтение и запись WAV mono 16 kHz Float32 — формат кэша `audio16k.wav`.
public enum WAVFile {
  /// Настройки файла кэша: LPCM Float32, 16 kHz, mono.
  public static var settings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: Double(PCMAudio.sampleRate),
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  public static func processingFormat() -> AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: Double(PCMAudio.sampleRate), channels: 1,
      interleaved: false)!
  }

  /// Открывает файл на запись (перезаписывает существующий). Кадры дописываются через `append`.
  public static func open(forWriting url: URL) throws -> AVAudioFile {
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
  }

  /// Дописывает сэмплы в открытый файл блоками, не создавая большого буфера.
  public static func append(
    _ samples: ArraySlice<Float>, to file: AVAudioFile, chunkFrames: Int = 1 << 16
  ) throws {
    let format = processingFormat()
    var offset = samples.startIndex
    while offset < samples.endIndex {
      let count = min(chunkFrames, samples.endIndex - offset)
      guard
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
      else {
        throw IngestError.decodingFailed(
          file.url, reason: String(localized: "не удалось выделить аудиобуфер"))
      }
      buffer.frameLength = AVAudioFrameCount(count)
      samples[offset..<(offset + count)].withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress!, count: count)
      }
      try file.write(from: buffer)
      offset += count
    }
  }

  public static func write(_ audio: PCMAudio, to url: URL) throws {
    let file = try open(forWriting: url)
    try append(audio.samples[...], to: file)
  }

  /// Читает файл целиком в память блоками (без двойного буфера).
  public static func read(_ url: URL, chunkFrames: Int = 1 << 18) throws -> PCMAudio {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.channelCount == 1,
      file.processingFormat.sampleRate == Double(PCMAudio.sampleRate)
    else {
      throw IngestError.decodingFailed(
        url,
        reason:
          String(
            localized:
              "ожидался WAV mono 16 kHz, получено \(Int(file.processingFormat.sampleRate)) Hz, каналов: \(file.processingFormat.channelCount)"
          )
      )
    }
    let total = Int(file.length)
    var samples: [Float] = []
    samples.reserveCapacity(total)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunkFrames))
    else {
      throw IngestError.decodingFailed(
        url, reason: String(localized: "не удалось выделить аудиобуфер"))
    }
    while samples.count < total {
      try file.read(
        into: buffer, frameCount: AVAudioFrameCount(min(chunkFrames, total - samples.count)))
      let frames = Int(buffer.frameLength)
      if frames == 0 { break }
      samples.append(
        contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: frames))
    }
    return PCMAudio(samples: samples)
  }
}
