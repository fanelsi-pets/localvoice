import Core
import SwiftUI

/// Компактный прогресс в тулбаре открытой встречи (DESIGN.md §3b): полоса, стадия с прогнозом, пульс,
/// сторож и отмена. Идентификаторы отличаются от карточных, чтобы UI-тест не находил два элемента сразу.
struct ProcessingToolbarStatus: View {
  @Bindable var model: AppModel
  let progress: MeetingProgressModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        ProgressView(value: progress.barValue)
          .progressViewStyle(.linear)
          .controlSize(.small)
          .animation(reduceMotion ? nil : .default, value: progress.barValue)
          .accessibilityIdentifier("toolbar.progress")
          .accessibilityLabel("Прогресс обработки")
          .accessibilityValue("\(progress.percent) %")
        Text(progress.headline)
          .font(.caption)
          .lineLimit(1)
          .accessibilityIdentifier("toolbar.line1")
        Text(progress.line2)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
          .accessibilityIdentifier("toolbar.line2")
        if let healthText = progress.healthText {
          Text(healthText)
            .font(.caption)
            .foregroundStyle(progress.showsStuckAction ? .red : .orange)
            .lineLimit(1)
        }
      }
      // Ограничение ширины, а не фиксированный размер: тулбар не должен растягиваться под длинную фразу.
      .frame(minWidth: 160, maxWidth: 320, alignment: .leading)

      if progress.showsStuckAction {
        Button("Отменить и собрать отчёт") {
          model.cancelAndCollectReport(progress.meetingID)
        }
        .accessibilityIdentifier("toolbar.report")
      }
      Button {
        model.cancel(progress.meetingID)
      } label: {
        Label("Отменить обработку", systemImage: "xmark.circle")
      }
      .accessibilityIdentifier("toolbar.cancel")
    }
  }
}
