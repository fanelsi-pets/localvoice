import Core
import Export
import Store
import SwiftUI

/// Бейдж статуса встречи (DESIGN.md §3b): текст — `MeetingStatus.title`, цвет дублируется словом.
struct StatusBadge: View {
  let status: MeetingStatus

  var body: some View {
    // Метка доступности намеренно не переопределяется: текст бейджа — это и есть статус
    // (`MeetingStatus.title`), по нему же ориентируется UI-тест.
    Text(status.title)
      .font(.caption)
      .foregroundStyle(color)
      .help("Статус обработки встречи")
  }

  private var color: Color {
    switch status {
    case .ready: .green
    case .failed: .red
    case .processing, .queued: .accentColor
    case .cancelled, .interrupted: .orange
    case .imported: .secondary
    }
  }
}

/// Чип спикера: цветная точка из палитры плюс имя — цвет никогда не остаётся единственным признаком (DESIGN.md §8).
struct SpeakerChip: View {
  let name: String
  let paletteIndex: Int?

  var body: some View {
    Label {
      Text(name)
    } icon: {
      Image(systemName: "circle.fill")
        .foregroundStyle(SpeakerPalette.color(paletteIndex: paletteIndex))
    }
    .labelStyle(.titleAndIcon)
    .font(.callout)
    .accessibilityLabel("Спикер: \(name)")
  }
}

/// Бейдж языка реплики (ru/uk/en).
struct LanguageBadge: View {
  let language: Language?

  var body: some View {
    if let language, language.isKnown {
      Text(language.code)
        .font(.caption2)
        .monospaced()
        .foregroundStyle(.secondary)
        .accessibilityLabel("Язык: \(language.code)")
    }
  }
}

/// Маркер наложения речи.
struct OverlapBadge: View {
  var body: some View {
    Image(systemName: "waveform.badge.exclamationmark")
      .foregroundStyle(.orange)
      .help("Речь наложилась на другого спикера")
      .accessibilityLabel("Наложение речи")
  }
}

/// Индикатор приватности: вся обработка идёт на этом Mac (DESIGN.md §1, §9).
struct LocalProcessingBadge: View {
  var body: some View {
    Image(systemName: "lock.laptopcomputer")
      .foregroundStyle(.secondary)
      .help("Обработка на этом Mac: записи никуда не отправляются")
      .accessibilityLabel("Обработка на этом Mac")
  }
}

/// Длительность записи для строк и шапок.
func durationText(_ seconds: Double?) -> String {
  guard let seconds, seconds > 0 else { return "—" }
  return Timecode.humanDuration(seconds)
}

/// Дата встречи в системном формате.
func meetingDateText(_ date: Date?) -> String {
  guard let date else { return String(localized: "Дата неизвестна") }
  return date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
}
