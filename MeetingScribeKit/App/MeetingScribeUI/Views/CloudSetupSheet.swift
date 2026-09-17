import Core
import SwiftUI

/// Экран ввода ключа облачного провайдера перед первой облачной обработкой (ADR-010): тексты даёт хост
/// (`RemoteSetupRequest`), ядро рисует поле, показывает ответ провайдера и ставит ждущие встречи в очередь.
/// Альтернатива — обработать на этом Mac: отказ от облака не должен упираться в отсутствие ключа.
struct CloudSetupSheet: View {
  @Bindable var model: AppModel
  let prompt: CloudSetupPrompt

  @State private var value = ""
  @State private var errorText: String?
  @State private var isChecking = false
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(prompt.request.title)
        .font(.title3)
      Text(prompt.request.explanation)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        SecureField(prompt.request.fieldTitle, text: $value)
          .focused($isFieldFocused)
          .onSubmit(save)
          .disabled(isChecking)
          .accessibilityIdentifier("cloudSetup.field")
        if let footnote = prompt.request.footnote {
          Text(footnote)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if isChecking {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Проверяю ключ у провайдера…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityIdentifier("cloudSetup.checking")
        } else if let errorText {
          Label(errorText, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("cloudSetup.error")
        }
      }
      .formStyle(.grouped)
      HStack {
        Button("Обработать на этом Mac") { model.processCloudSetupLocally() }
          .disabled(isChecking)
          .accessibilityIdentifier("cloudSetup.local")
        Spacer()
        Button("Позже", role: .cancel) { model.dismissCloudSetup() }
          .keyboardShortcut(.cancelAction)
          .disabled(isChecking)
          .accessibilityIdentifier("cloudSetup.later")
        Button("Проверить и продолжить", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(isChecking || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("cloudSetup.save")
      }
    }
    .padding()
    .frame(minWidth: 460)
    .onAppear { isFieldFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("cloudSetup.sheet")
  }

  /// Проверка идёт у провайдера (у Azure — запрос на секунду тишины): ответ показываем как есть.
  private func save() {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !isChecking else { return }
    isChecking = true
    errorText = nil
    Task {
      let failure = await model.completeCloudSetup(key)
      isChecking = false
      errorText = failure
    }
  }
}
