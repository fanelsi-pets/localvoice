import Core
import Export
import Store
import SwiftUI

/// Карточка встречи во время обработки (DESIGN.md §3b): крупная определённая полоса, стадия с прогнозом,
/// пульс, список стадий с фактическим временем и лента уже распознанных реплик — главный признак живости.
struct ProcessingCardView: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  let progress: MeetingProgressModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      bar
      stages
      feed
    }
    .padding()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("processing.card")
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(record.title).font(.title2)
        Text(meetingDateText(record.date)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      StatusBadge(status: record.status)
        .accessibilityIdentifier("meeting.status")
    }
  }

  private var bar: some View {
    VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: progress.barValue) {
        if progress.isModelDownload {
          Text("Подготовка моделей")
        }
      }
      .progressViewStyle(.linear)
      .animation(reduceMotion ? nil : .default, value: progress.barValue)
      .accessibilityIdentifier("processing.progress")
      .accessibilityLabel("Прогресс обработки")
      .accessibilityValue(
        progress.isModelDownload
          ? "\(progress.percent) % · подготовка моделей" : "\(progress.percent) %")

      Text(line1)
        .font(.headline)
        .lineLimit(1)
        .accessibilityIdentifier("processing.line1")
      Text(progress.line2)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
        .accessibilityIdentifier("processing.line2")
      if let healthText = progress.healthText {
        HStack {
          Text(healthText)
            .font(.callout)
            .foregroundStyle(progress.showsStuckAction ? .red : .orange)
          if progress.showsStuckAction {
            Button("Отменить и собрать отчёт") {
              model.cancelAndCollectReport(record.id)
            }
            .accessibilityIdentifier("processing.report")
          }
        }
      }
      HStack {
        Button("Отменить", systemImage: "xmark.circle") {
          model.cancel(record.id)
        }
        .accessibilityIdentifier("processing.cancel")
        .accessibilityLabel("Отменить обработку")
        LocalProcessingBadge()
      }
    }
  }

  private var line1: String {
    if let position = progress.queuePosition, progress.barValue == 0 {
      return String(localized: "В очереди · \(position)")
    }
    return progress.line1
  }

  private var stages: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(progress.stageChecks) { check in
        HStack(spacing: 8) {
          Image(systemName: icon(for: check.state))
            .foregroundStyle(color(for: check.state))
          Text(check.stage.title)
            .foregroundStyle(check.state == .pending ? .secondary : .primary)
          Spacer()
          if let seconds = check.seconds {
            Text(ProgressPresentation.stageDuration(seconds))
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          } else if check.state == .skipped {
            Text("пропущено").font(.caption).foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.stage.title): \(stateTitle(check.state))")
      }
    }
  }

  @ViewBuilder private var feed: some View {
    if !progress.feed.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Лента распознанного — до фильтра и сшивки")
          .font(.caption)
          .foregroundStyle(.secondary)
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
              ForEach(progress.feed) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(Timecode.hhmmss(line.start))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                  if let speakerID = line.speakerID {
                    SpeakerChip(
                      name: SpeakerStats.placeholderName(for: speakerID),
                      paletteIndex: SpeakerPalette.index(for: speakerID))
                  }
                  Text(line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  LanguageBadge(language: line.language)
                }
                .id(line.id)
              }
            }
          }
          .onChange(of: progress.feed.last?.id) { _, last in
            guard let last else { return }
            proxy.scrollTo(last, anchor: .bottom)
          }
        }
      }
    }
  }

  private func icon(for state: StageCheck.State) -> String {
    switch state {
    case .done: "checkmark.circle.fill"
    case .active: "circle.dotted"
    case .pending: "circle"
    case .skipped: "minus.circle"
    }
  }

  private func color(for state: StageCheck.State) -> Color {
    switch state {
    case .done: .green
    case .active: .accentColor
    case .pending, .skipped: .secondary
    }
  }

  private func stateTitle(_ state: StageCheck.State) -> String {
    switch state {
    case .done: String(localized: "готово")
    case .active: String(localized: "идёт")
    case .pending: String(localized: "ожидает")
    case .skipped: String(localized: "пропущено")
    }
  }
}
