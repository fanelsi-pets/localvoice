import Foundation

/// Аудио в рабочем формате движков: mono, 16 kHz, Float32 в диапазоне [-1, 1].
public struct PCMAudio: Sendable {
  public static let sampleRate = 16_000

  public var samples: [Float]

  public init(samples: [Float]) {
    self.samples = samples
  }

  public var sampleCount: Int { samples.count }

  public var duration: Double { Self.seconds(forSampleIndex: samples.count) }

  public var isEmpty: Bool { samples.isEmpty }

  public static func sampleIndex(forSeconds seconds: Double) -> Int {
    Int((seconds * Double(sampleRate)).rounded())
  }

  public static func seconds(forSampleIndex index: Int) -> Double {
    Double(index) / Double(sampleRate)
  }

  /// Вырезает интервал `[start, end]` секунд; границы обрезаются по длине аудио.
  public func slice(from start: Double, to end: Double) -> PCMAudio {
    let lower = min(max(Self.sampleIndex(forSeconds: start), 0), samples.count)
    let upper = min(max(Self.sampleIndex(forSeconds: end), lower), samples.count)
    return PCMAudio(samples: Array(samples[lower..<upper]))
  }

  public func slice(_ turn: Turn) -> PCMAudio {
    slice(from: turn.start, to: turn.end)
  }

  /// Склейка нескольких кусков (например, пробных фрагментов речи одного спикера).
  public static func concatenate(_ parts: [PCMAudio]) -> PCMAudio {
    var samples: [Float] = []
    samples.reserveCapacity(parts.reduce(0) { $0 + $1.samples.count })
    for part in parts {
      samples.append(contentsOf: part.samples)
    }
    return PCMAudio(samples: samples)
  }
}
