import Export
import SwiftUI

/// «Перейти к таймкоду…» ⌘G (DESIGN.md §6): выбирает ближайшую реплику и прокручивает к ней список.
struct GoToTimecodeSheet: View {
  @Bindable var model: AppModel
  @State private var text = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Перейти к таймкоду").font(.title3)
      TextField("ЧЧ:ММ:СС", text: $text)
        .monospacedDigit()
        .onSubmit { go() }
        .accessibilityIdentifier("goto.field")
      HStack {
        Spacer()
        Button("Отмена", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Перейти") { go() }
          .keyboardShortcut(.defaultAction)
          .disabled(Self.seconds(from: text) == nil)
          .accessibilityIdentifier("goto.confirm")
      }
    }
    .padding()
    .frame(minWidth: 320)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("goto.sheet")
  }

  private func go() {
    guard let seconds = Self.seconds(from: text) else { return }
    model.goToTimecode(seconds)
    dismiss()
  }

  /// «01:02:03», «02:03» или «123» — секунды от начала записи.
  static func seconds(from text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(
      separator: ":", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    var total: Double = 0
    for part in parts {
      guard let value = Double(part), value >= 0 else { return nil }
      total = total * 60 + value
    }
    return total
  }
}
