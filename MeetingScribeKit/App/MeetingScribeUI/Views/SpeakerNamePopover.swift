import Core
import Store
import SwiftUI

/// Быстрое имя спикера из транскрипта (DESIGN.md §3): клик по чипу «Спикер N» открывает это окно.
/// Enter и закрытие окна применяют имя к встрече и экспорту — как поле инспектора (`setSpeakerName`);
/// «Подтвердить» вдобавок сохраняет голос в профиль человека (`confirmSpeaker`, SPEC.md §3.4).
struct SpeakerNamePopover: View {
  @Bindable var model: AppModel
  let meetingID: UUID
  let speakerID: Int
  @State private var draftName = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Имя спикера").font(.headline)
      HStack {
        Image(systemName: "circle.fill")
          .foregroundStyle(SpeakerPalette.color(for: speakerID))
          .accessibilityHidden(true)
        TextField(SpeakerStats.placeholderName(for: speakerID), text: $draftName)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            apply()
            dismiss()
          }
          .accessibilityLabel("Имя спикера \(SpeakerStats.placeholderName(for: speakerID))")
          .accessibilityIdentifier("speakerPopover.name")
        suggestionsMenu
      }
      Text(model.namingState(for: speakerID, meetingID: meetingID).title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("speakerPopover.state")
      Text("Имя применится к этой встрече и экспорту; «Подтвердить» также сохранит голос в «Люди».")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Показать спикеров в инспекторе") {
          apply()
          model.showSpeakersInspector()
          dismiss()
        }
        .buttonStyle(.link)
        .font(.caption)
        .accessibilityIdentifier("speakerPopover.inspector")
        Spacer()
        Button("Подтвердить") {
          model.confirmSpeaker(speakerID, meetingID: meetingID, name: draftName)
          dismiss()
        }
        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
        .help("Закрепить имя и сохранить голос в профиль человека")
        .accessibilityIdentifier("speakerPopover.confirm")
      }
    }
    .padding()
    .frame(width: 360)
    .onAppear { draftName = storedName }
    // Закрытие кликом мимо окна тоже сохраняет набранное — как поле формы при потере фокуса.
    .onDisappear { apply() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("speakerPopover")
  }

  /// Подсказки имён (люди, chat.txt, подписи на видео) — то же меню, что у поля в инспекторе.
  @ViewBuilder private var suggestionsMenu: some View {
    let names = model.nameSuggestions(for: meetingID)
    if !names.isEmpty {
      Menu {
        ForEach(names, id: \.self) { name in
          Button(name) {
            draftName = name
            apply()
          }
        }
      } label: {
        Image(systemName: "chevron.down.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Подсказки: люди, чат, подписи на видео")
      .accessibilityLabel("Подсказки имён")
      .accessibilityIdentifier("speakerPopover.suggestions")
    }
  }

  private var storedName: String {
    model.library.meeting(id: meetingID)?.speakerAssignments[speakerID]?.trimmedName ?? ""
  }

  /// Имя без подтверждения; пустое поле снимает имя. Ничего не делает, если текст не менялся.
  private func apply() {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != storedName else { return }
    model.setSpeakerName(trimmed, for: speakerID, meetingID: meetingID)
  }
}
