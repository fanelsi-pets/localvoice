import Core
import SwiftUI

/// Компактный статус скачивания моделей в тулбаре (SPEC.md §3.7 п. 10): определённая полоса, байты и
/// кнопка вернуться в онбординг. Виден, пока идёт загрузка или стоит пауза — окно можно закрыть,
/// загрузка продолжится (SPEC.md §3.7 п. 8). Сделан по образцу `ProcessingToolbarStatus`.
struct ModelDownloadStatus: View {
  @Bindable var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let downloads = model.modelDownloads
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        ProgressView(value: downloads.fraction)
          .progressViewStyle(.linear)
          .controlSize(.small)
          .animation(reduceMotion ? nil : .default, value: downloads.fraction)
          .accessibilityIdentifier("download.progress")
          .accessibilityLabel("Прогресс скачивания моделей")
          .accessibilityValue("\(Int(downloads.fraction * 100)) %")
        Text(headline)
          .font(.caption)
          .lineLimit(1)
          .accessibilityIdentifier("download.status")
      }
      .frame(minWidth: 140, maxWidth: 280, alignment: .leading)

      Button("Открыть") {
        model.onboarding.go(to: .models)
        model.onboarding.present()
      }
      .help("Показать шаг загрузки моделей")
      .accessibilityIdentifier("download.open")
    }
  }

  /// «Модели · 412 МБ из 1,64 ГБ» — то же число, что на шаге онбординга.
  private var headline: String {
    let downloads = model.modelDownloads
    let size = ByteText.progress(downloads.bytesCompleted, of: downloads.bytesTotal)
    return downloads.isPaused
      ? String(localized: "Модели · пауза · \(size)") : String(localized: "Модели · \(size)")
  }
}
