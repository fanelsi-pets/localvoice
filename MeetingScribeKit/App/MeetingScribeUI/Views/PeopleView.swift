import Core
import Export
import Store
import SwiftUI

/// Раздел «Люди» (DESIGN.md §2): голосовые профили — имя, число образцов, встречи, прослушивание;
/// переименование применяется ко всем встречам (SPEC.md §3.4).
struct PeopleView: View {
  @Bindable var model: AppModel
  @State private var renaming: PersonRecord?
  @State private var draftName = ""

  var body: some View {
    if model.library.people.isEmpty {
      ContentUnavailableView(
        "Людей пока нет", systemImage: "person.wave.2",
        description: Text(
          "Подтвердите имя спикера в инспекторе встречи — его голос сохранится в профиль, и на следующих встречах он будет узнан автоматически."
        ))
    } else {
      List {
        ForEach(model.library.peopleByName) { person in
          PersonRow(model: model, person: person) {
            draftName = person.name
            renaming = person
          }
        }
      }
      .accessibilityIdentifier("people.list")
      .alert("Переименовать человека", isPresented: renamingBinding) {
        TextField("Имя", text: $draftName)
        Button("Переименовать во всех встречах") {
          if let person = renaming { model.renamePerson(person.id, to: draftName) }
          renaming = nil
        }
        Button("Отмена", role: .cancel) { renaming = nil }
      } message: {
        Text("Новое имя подставится во все встречи, где этот человек говорил.")
      }
    }
  }

  private var renamingBinding: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }
}

struct PersonRow: View {
  @Bindable var model: AppModel
  let person: PersonRecord
  let rename: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(person.name, systemImage: "person.crop.circle")
          .font(.headline)
        Spacer()
        Button("Переименовать…") { rename() }
          .accessibilityIdentifier("person.rename.\(person.id.uuidString)")
        Button("Удалить…", role: .destructive) { model.requestDelete(person: person.id) }
      }
      HStack(spacing: 12) {
        Label(samplesText, systemImage: "waveform")
        Label(spacesText, systemImage: "cpu")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      let meetings = model.meetings(with: person.id)
      if !meetings.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(meetings) { meeting in
            Button {
              model.selectMeeting(meeting.id)
            } label: {
              Label(
                "\(meeting.title) · \(meetingDateText(meeting.date))", systemImage: "calendar")
            }
            .buttonStyle(.link)
            .font(.callout)
          }
        }
      }
      if !person.samples.isEmpty {
        HStack {
          Text("Послушать:").font(.caption).foregroundStyle(.secondary)
          ForEach(Array(person.samples.prefix(3).enumerated()), id: \.offset) { index, sample in
            Button {
              model.playSample(sample)
            } label: {
              Label(Timecode.hhmmss(sample.start), systemImage: "play.circle")
            }
            .buttonStyle(.link)
            .monospacedDigit()
            .font(.caption)
            .accessibilityLabel("Прослушать образец \(index + 1)")
          }
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("person.\(person.id.uuidString)")
  }

  private var samplesText: String {
    let count = person.sampleCount
    guard count > 0 else { return String(localized: "голос не сохранён") }
    return String(localized: "\(count) образцов голоса")
  }

  private var spacesText: String {
    person.spaces.isEmpty ? "—" : person.spaces.joined(separator: ", ")
  }
}
