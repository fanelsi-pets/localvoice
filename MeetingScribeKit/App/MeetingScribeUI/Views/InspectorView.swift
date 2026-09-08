import Core
import Export
import Store
import SwiftUI

/// Инспектор (DESIGN.md §2, §4): спикеры, сведения о прогоне, контекст проекта.
struct InspectorView: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Раздел", selection: $model.inspectorTab) {
        ForEach(InspectorTab.allCases, id: \.self) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityIdentifier("inspector.tabs")

      if let record = model.selectedMeeting {
        switch model.inspectorTab {
        case .speakers:
          SpeakersInspector(model: model, record: record)
        case .details:
          DetailsInspector(model: model, record: record)
        case .projectContext:
          ProjectContextInspector(model: model, record: record)
        }
      } else {
        ContentUnavailableView(
          "Выберите встречу", systemImage: "sidebar.left",
          description: Text(
            "Спикеры, сведения и контекст проекта появятся после выбора встречи."))
      }
      Spacer(minLength: 0)
    }
    .padding()
  }
}

/// Сведения о прогоне: файл, стадии, память, отброшенное фильтром.
struct DetailsInspector: View {
  @Bindable var model: AppModel
  let record: MeetingRecord

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        row(String(localized: "Файл"), record.sourceURL.lastPathComponent)
        if record.isMultiTrack {
          row(String(localized: "Раздельные дорожки"), "\(record.trackURLs.count)")
        }
        Button("Показать в Finder") { model.revealInFinder(record.sourceURL) }
          .accessibilityIdentifier("details.reveal")
        row(String(localized: "Дата встречи"), meetingDateText(record.date))
        row(String(localized: "Длительность"), durationText(record.duration))
        row(String(localized: "Движки"), record.engines.title)
        if let processed = record.processedAt {
          row(String(localized: "Обработано"), meetingDateText(processed))
        }
        if let seconds = record.processingSeconds {
          row(String(localized: "Время обработки"), ProgressPresentation.stageDuration(seconds))
        }
        if let transcript = model.transcripts[record.id] {
          Divider()
          Text("Стадии").font(.headline)
          ForEach(transcript.timings, id: \.stage) { timing in
            HStack {
              Text(timing.stage.title)
              Spacer()
              Text(ProgressPresentation.stageDuration(timing.seconds))
                .monospacedDigit()
              if let factor = timing.realtimeFactor {
                Text(String(format: "×%.0f", factor))
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
              }
            }
            .font(.caption)
          }
          if let peak = transcript.peakMemoryBytes {
            row(String(localized: "Пик памяти"), ProcessMemory.format(peak))
          }
          row(String(localized: "Отброшено фильтром"), "\(transcript.diagnostics.dropped.count)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inspector.details")
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).multilineTextAlignment(.trailing)
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }
}
