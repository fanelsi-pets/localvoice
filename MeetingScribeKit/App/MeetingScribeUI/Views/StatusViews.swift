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

/// Индикатор места обработки (DESIGN.md §1, §9): замок — всё на этом Mac, облако — речь распознаёт
/// провайдер, а голоса, имена и память проекта всё равно остаются здесь.
struct ProcessingPlaceBadge: View {
  var isCloud: Bool

  var body: some View {
    Image(systemName: isCloud ? "cloud" : "lock.laptopcomputer")
      .foregroundStyle(.secondary)
      .help(
        isCloud
          ? Text("Распознавание в облаке; голоса, имена и память проекта — на этом Mac")
          : Text("Обработка на этом Mac: записи никуда не отправляются")
      )
      .accessibilityLabel(
        isCloud ? Text("Распознавание в облаке") : Text("Обработка на этом Mac"))
  }
}

/// Индикатор для того, что считается только здесь: экспорт, vault, разбор follow-up.
struct LocalProcessingBadge: View {
  var body: some View { ProcessingPlaceBadge(isCloud: false) }
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
