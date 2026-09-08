import Core
import Export
import SwiftUI

/// Список реплик (DESIGN.md §3): таймкод-кнопка, чип спикера, текст с подсветкой поиска, язык, наложение.
/// Строки приходят готовыми значениями из `AppModel.displayRows` — список не пересчитывается на тиках прогресса.
struct TranscriptView: View {
  @Bindable var model: AppModel
  let meetingID: UUID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var editingRowID: Int?
  @State private var editingText = ""

  var body: some View {
    ScrollViewReader { proxy in
      List(model.displayRows, selection: $model.selectedRowID) { row in
        TranscriptRowView(
          model: model,
          meetingID: meetingID,
          row: row,
          isEditing: editingRowID == row.id,
          editingText: $editingText,
          beginEditing: { beginEditing(row) },
          endEditing: { save in
            if save {
              model.updateUtteranceText(meetingID: meetingID, index: row.id, text: editingText)
            }
            editingRowID = nil
          }
        )
        .id(row.id)
      }
      .accessibilityIdentifier("transcript.list")
      .onKeyPress(.space) {
        // Пробел — воспроизвести/пауза, только когда фокус в списке (DESIGN.md §3).
        guard model.playback.isAvailable else { return .ignored }
        model.playback.togglePlayPause()
        return .handled
      }
      .onChange(of: model.scrollTarget) { _, target in
        guard let target else { return }
        if reduceMotion {
          proxy.scrollTo(target, anchor: .center)
        } else {
          withAnimation { proxy.scrollTo(target, anchor: .center) }
        }
        model.clearScrollTarget()
      }
      .overlay {
        if model.displayRows.isEmpty {
          ContentUnavailableView(
            "Ничего не найдено", systemImage: "text.magnifyingglass",
            description: Text("Измените запрос поиска или снимите фильтр по спикеру."))
        }
      }
    }
  }

  private func beginEditing(_ row: TranscriptRow) {
    editingText = row.text
    editingRowID = row.id
  }
}

/// Строка транскрипта. Двойной клик открывает правку текста прямо в строке: Enter сохраняет, Esc отменяет.
/// Клик по чипу спикера открывает окно быстрого имени (`SpeakerNamePopover`).
struct TranscriptRowView: View {
  @Bindable var model: AppModel
  let meetingID: UUID
  let row: TranscriptRow
  let isEditing: Bool
  @Binding var editingText: String
  let beginEditing: () -> Void
  let endEditing: (Bool) -> Void
  @State private var isSplitting = false
  @State private var isNaming = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Button(Timecode.hhmmss(row.start)) {
        model.play(row: row)
      }
      .buttonStyle(.link)
      .monospacedDigit()
      .accessibilityLabel("Воспроизвести с \(Timecode.hhmmss(row.start))")

      speakerChip

      if isEditing {
        TextField("Текст реплики", text: $editingText)
          .textFieldStyle(.roundedBorder)
          .onSubmit { endEditing(true) }
          .onExitCommand { endEditing(false) }
          .accessibilityLabel("Правка реплики")
      } else {
        Text(row.highlightedText)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if model.settings.showLanguageBadges {
        LanguageBadge(language: row.language)
      }
      if model.settings.showOverlapMarkers, row.overlapped {
        OverlapBadge()
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { beginEditing() }
    // Строка — элемент доступности с собственной меткой, но кнопки внутри (таймкод, чип спикера)
    // остаются дочерними элементами: метка на голом `HStack` скрыла бы их от VoiceOver и XCUITest.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("transcript.row.\(row.position)")
    .accessibilityLabel(
      "\(Timecode.hhmmss(row.start)), \(row.speakerName): \(row.text)"
    )
    .contextMenu {
      Button("Скопировать реплику с таймкодом") { model.copyRow(row) }
      Button("Править текст") { beginEditing() }
      Divider()
      Button("Назвать спикера…") { isNaming = true }
        .disabled(row.speakerID == nil)
      Menu("Приписать спикеру…") {
        ForEach(model.speakerChoices(for: meetingID), id: \.id) { speaker in
          Button(speaker.name) {
            model.reassignUtterance(index: row.id, to: speaker.id, meetingID: meetingID)
          }
          .disabled(speaker.id == row.speakerID)
        }
        Divider()
        Button("Новый спикер") {
          model.reassignUtteranceToNewSpeaker(index: row.id, meetingID: meetingID)
        }
        Button("Неизвестный") {
          model.reassignUtterance(index: row.id, to: nil, meetingID: meetingID)
        }
        .disabled(row.speakerID == nil)
      }
      Button("Разделить здесь…") { isSplitting = true }
      Button("Объединить с предыдущей") {
        model.mergeUtteranceWithPrevious(index: row.id, meetingID: meetingID)
      }
      .disabled(row.id == 0)
    }
    .sheet(isPresented: $isSplitting) {
      SplitUtteranceSheet(model: model, meetingID: meetingID, row: row)
    }
  }

  /// Чип спикера — кнопка быстрого имени (DESIGN.md §3); у реплики без спикера («Неизвестный») имени нет.
  @ViewBuilder private var speakerChip: some View {
    if let speakerID = row.speakerID {
      Button {
        isNaming = true
      } label: {
        SpeakerChip(name: row.speakerName, paletteIndex: row.paletteIndex)
      }
      .buttonStyle(.plain)
      .help("Назвать спикера…")
      .accessibilityIdentifier("transcript.speaker.\(row.position)")
      .popover(isPresented: $isNaming, arrowEdge: .bottom) {
        SpeakerNamePopover(model: model, meetingID: meetingID, speakerID: speakerID)
      }
    } else {
      SpeakerChip(name: row.speakerName, paletteIndex: row.paletteIndex)
    }
  }
}
