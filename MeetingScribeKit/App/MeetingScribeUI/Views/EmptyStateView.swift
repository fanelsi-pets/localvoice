import SwiftUI
import UniformTypeIdentifiers

/// Пустое состояние (DESIGN.md §2): зона для перетаскивания записи, кнопка «Открыть…» и подсказка
/// про опцию Zoom с раздельными дорожками.
struct EmptyStateView: View {
  @Bindable var model: AppModel
  @State private var isTargeted = false

  var body: some View {
    ContentUnavailableView {
      Label("Перетащите запись Zoom или папку записи", systemImage: "waveform")
    } description: {
      VStack(spacing: 8) {
        Text("Подойдёт `video*.mp4`, `audio*.m4a` или папка записи целиком.")
        // Одним литералом: склейка `+` даёт String, а не ключ каталога, и подсказка не переводится.
        Text(
          "Точнее всего имена спикеров получаются, если в Zoom включена опция Settings → Recording → «Record a separate audio file for each participant»."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
    } actions: {
      VStack(spacing: 12) {
        Button("Открыть…") { model.isFileImporterPresented = true }
          .accessibilityIdentifier("import.button.empty")
        LocalProcessingBadge()
      }
    }
    .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
      DropSupport.handle(providers, model: model)
    }
    .overlay {
      if isTargeted {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
          .padding()
          .allowsHitTesting(false)
      }
    }
  }
}

/// Разбор перетаскивания: провайдеры отдают file URL с произвольного потока, импорт запускается на главном.
enum DropSupport {
  static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
    let usable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
    guard !usable.isEmpty else { return false }
    Task {
      var urls: [URL] = []
      for provider in usable {
        if let url = await provider.fileURL() { urls.append(url) }
      }
      guard !urls.isEmpty else { return }
      model.importURLs(urls)
    }
    return true
  }
}

extension NSItemProvider {
  /// URL файла из провайдера перетаскивания. Метод изолирован на главном акторе (провайдер не `Sendable`),
  /// колбэк приходит с произвольного потока и переносит только `URL`.
  func fileURL() async -> URL? {
    await withCheckedContinuation { continuation in
      _ = loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url)
      }
    }
  }
}
