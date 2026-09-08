import SwiftUI

/// Цвета спикеров (DESIGN.md §7): фиксированная палитра системных цветов, стабильная по номеру спикера.
/// Цвет всегда дублируется именем — VoiceOver и режим повышенной контрастности не должны терять смысл.
nonisolated public enum SpeakerPalette {
  /// Порядок зафиксирован: blue, green, orange, purple, teal, pink, indigo, brown, mint, cyan.
  public static let colors: [Color] = [
    .blue, .green, .orange, .purple, .teal, .pink, .indigo, .brown, .mint, .cyan,
  ]

  /// Индекс в палитре по номеру спикера (нумерация с 1); `nil` — реплика без спикера, индекса нет.
  public static func index(for speakerID: Int?) -> Int? {
    guard let speakerID else { return nil }
    let zeroBased = speakerID - 1
    let count = colors.count
    return ((zeroBased % count) + count) % count
  }

  /// Цвет по номеру спикера; «Неизвестный» — вторичный системный цвет.
  public static func color(for speakerID: Int?) -> Color {
    guard let index = index(for: speakerID) else { return .secondary }
    return colors[index]
  }

  /// Цвет по уже посчитанному индексу палитры (строки транскрипта носят индекс с собой).
  public static func color(paletteIndex: Int?) -> Color {
    guard let paletteIndex, colors.indices.contains(paletteIndex) else { return .secondary }
    return colors[paletteIndex]
  }
}
