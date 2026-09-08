import Core
import Export
import Store
import SwiftUI

/// «Разделить по диапазону…» (DESIGN.md §4): реплики спикера между двумя таймкодами уходят новому спикеру.
struct SplitSpeakerSheet: View {
  @Bindable var model: AppModel
  let meetingID: UUID
  let speakerID: Int
  let speakerName: String
  @State private var startText = ""
  @State private var endText = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Разделить «\(speakerName)» по диапазону").font(.title3)
      Text(
        "Реплики спикера от начала до конца диапазона получат нового спикера — так исправляется случай, когда диаризация склеила двух людей в одного."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      Form {
        TextField("Начало (ЧЧ:ММ:СС)", text: $startText).monospacedDigit()
          .accessibilityIdentifier("split.start")
        TextField("Конец (ЧЧ:ММ:СС)", text: $endText).monospacedDigit()
          .accessibilityIdentifier("split.end")
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Отмена", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Разделить") { split() }
          .keyboardShortcut(.defaultAction)
          .disabled(range == nil)
          .accessibilityIdentifier("split.confirm")
      }
    }
    .padding()
    .frame(minWidth: 380)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("split.sheet")
  }

  private var range: ClosedRange<Double>? {
    guard let start = GoToTimecodeSheet.seconds(from: startText),
      let end = GoToTimecodeSheet.seconds(from: endText), end > start
    else { return nil }
    return start...end
  }

  private func split() {
    guard let range else { return }
    model.splitSpeaker(speakerID, range: range, meetingID: meetingID)
    dismiss()
  }
}

/// «Разделить здесь»: реплика делится перед выбранным словом (DESIGN.md §3).
struct SplitUtteranceSheet: View {
  @Bindable var model: AppModel
  let meetingID: UUID
  let row: TranscriptRow
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Разделить реплику").font(.title3)
      Text("Нажмите слово, с которого начнётся новая реплика.")
        .font(.callout)
        .foregroundStyle(.secondary)
      if words.count < 2 {
        ContentUnavailableView(
          "Реплику не разделить", systemImage: "text.word.spacing",
          description: Text("У реплики нет таймкодов слов или она состоит из одного слова."))
      } else {
        ScrollView {
          WrappingWords(words: words.map(\.text)) { index in
            guard index > 0 else { return }
            model.splitUtterance(index: row.id, beforeWord: index, meetingID: meetingID)
            dismiss()
          }
        }
        .frame(maxHeight: 240)
      }
      HStack {
        Spacer()
        Button("Отмена", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding()
    .frame(minWidth: 420)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("splitUtterance.sheet")
  }

  private var words: [Word] {
    model.transcripts[meetingID]?.utterances.indices.contains(row.id) == true
      ? model.transcripts[meetingID]!.utterances[row.id].words : []
  }
}

/// Слова реплики кнопками в несколько строк: стандартные `Button`, раскладка — `Layout` без хардкода размеров.
struct WrappingWords: View {
  let words: [String]
  let onSelect: (Int) -> Void

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(Array(words.enumerated()), id: \.offset) { index, word in
        Button(word) { onSelect(index) }
          .buttonStyle(.bordered)
          .disabled(index == 0)
          .accessibilityLabel(
            index == 0
              ? String(localized: "Первое слово: \(word)")
              : String(localized: "Разделить перед словом \(word)"))
      }
    }
  }
}

/// Простая перетекающая раскладка: элементы идут строкой и переносятся по ширине контейнера.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 400
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > width, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: width, height: y + rowHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX, x > bounds.minX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

/// «Переназначить спикера…» ⌘⇧S (DESIGN.md §6): выбранная реплика → другой спикер, новый или неизвестный.
struct ReassignSpeakerSheet: View {
  @Bindable var model: AppModel
  let meetingID: UUID
  let row: TranscriptRow
  @State private var choice: Choice = .existing(1)
  @Environment(\.dismiss) private var dismiss

  enum Choice: Hashable {
    case existing(Int)
    case new
    case unknown
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Переназначить спикера").font(.title3)
      Text("\(Timecode.hhmmss(row.start)) · \(row.text)")
        .font(.callout)
        .lineLimit(2)
        .foregroundStyle(.secondary)
      Picker("Спикер", selection: $choice) {
        ForEach(model.speakerChoices(for: meetingID), id: \.id) { speaker in
          Text(speaker.name).tag(Choice.existing(speaker.id))
        }
        Text("Новый спикер").tag(Choice.new)
        Text("Неизвестный").tag(Choice.unknown)
      }
      .accessibilityIdentifier("reassign.picker")
      HStack {
        Spacer()
        Button("Отмена", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Переназначить") { apply() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("reassign.confirm")
      }
    }
    .padding()
    .frame(minWidth: 380)
    .onAppear {
      if let current = row.speakerID { choice = .existing(current) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reassign.sheet")
  }

  private func apply() {
    switch choice {
    case .existing(let id): model.reassignUtterance(index: row.id, to: id, meetingID: meetingID)
    case .new: model.reassignUtteranceToNewSpeaker(index: row.id, meetingID: meetingID)
    case .unknown: model.reassignUtterance(index: row.id, to: nil, meetingID: meetingID)
    }
    dismiss()
  }
}
