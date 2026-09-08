import SwiftUI

/// Прогресс экспорта vault (DESIGN.md §3b, SPEC.md §3.7): определённая полоса «N из M заметок»,
/// пульс с названием встречи и отмена. Показывается там же, откуда экспорт запущен, — итог приходит
/// обычным сообщением.
struct VaultExportSheet: View {
  @Bindable var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Экспорт vault для Obsidian").font(.title3)
      ProgressView(value: model.vaultExport.fraction) {
        Text(model.vaultExport.statusText)
          .monospacedDigit()
      }
      .progressViewStyle(.linear)
      .animation(reduceMotion ? nil : .default, value: model.vaultExport.fraction)
      .accessibilityIdentifier("vault.progress")
      .accessibilityLabel("Прогресс экспорта vault")
      .accessibilityValue(model.vaultExport.statusText)
      Text(pulse)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("vault.pulse")
      if let error = model.vaultExport.errorText {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .accessibilityIdentifier("vault.error")
      }
      HStack {
        LocalProcessingBadge()
        Spacer()
        Button("Отменить", role: .cancel) { model.vaultExport.cancel() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("vault.cancel")
          .accessibilityLabel("Отменить экспорт vault")
      }
    }
    .padding()
    .frame(minWidth: 420)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("vault.sheet")
  }

  private var pulse: String {
    let title = model.vaultExport.currentTitle
    return title.isEmpty
      ? String(localized: "Готовлю заметки…") : String(localized: "Пишу «\(title)»")
  }
}
