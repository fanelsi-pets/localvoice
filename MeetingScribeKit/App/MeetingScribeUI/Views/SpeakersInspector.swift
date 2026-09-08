import Core
import Export
import Store
import SwiftUI

/// Inspector «Спикеры» (DESIGN.md §4): имя с подсказками, уверенность сопоставления, время речи,
/// образцы для прослушивания; действия — подтвердить, это новый человек, объединить, разделить.
struct SpeakersInspector: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  @State private var splitting: SpeakerStats?

  var body: some View {
    let speakers = model.speakers(for: record.id)
    if speakers.isEmpty {
      ContentUnavailableView(
        "Спикеров пока нет", systemImage: "person.2",
        description: Text("Список появится после разделения записи по голосам."))
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          NameScanSection(model: model, record: record)
          let silentTracks = (model.transcripts[record.id]?.tracks ?? [])
            .filter { $0.speechSeconds <= 0 }
          if !silentTracks.isEmpty {
            Label(
              "Дорожки без речи: "
                + silentTracks.map { $0.participantName ?? $0.fileName }.joined(separator: ", ")
                + String(localized: " — участник молчал или его микрофон был слишком тихим"),
              systemImage: "waveform.slash"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("speakers.silentTracks")
          }
          let roster = model.rosterNames(for: record.id)
          if !roster.isEmpty {
            Text("На видео: \(roster.joined(separator: ", "))")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .accessibilityIdentifier("speakers.roster")
          }
          ForEach(speakers, id: \.speakerID) { speaker in
            SpeakerInspectorRow(
              model: model, record: record, speaker: speaker,
              others: speakers.filter { $0.speakerID != nil && $0.speakerID != speaker.speakerID },
              split: { splitting = speaker })
            Divider()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("inspector.speakers")
      .sheet(item: $splitting) { speaker in
        if let id = speaker.speakerID {
          SplitSpeakerSheet(
            model: model, meetingID: record.id, speakerID: id, speakerName: speaker.displayName)
        }
      }
    }
  }
}

extension SpeakerStats: Identifiable {
  public var id: Int { speakerID ?? -1 }
}

/// Одна карточка спикера в инспекторе.
struct SpeakerInspectorRow: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  let speaker: SpeakerStats
  let others: [SpeakerStats]
  let split: () -> Void
  @State private var draftName = ""

  private var speakerID: Int? { speaker.speakerID }
  private var idText: String { speakerID.map(String.init) ?? "unknown" }

  var body: some View {
    let state =
      speakerID.map { model.namingState(for: $0, meetingID: record.id) }
      ?? .unknown(similarity: nil)
    let assignment =
      speakerID.map { model.assignment(for: $0, meetingID: record.id) } ?? SpeakerAssignment()
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: "circle.fill")
          .foregroundStyle(SpeakerPalette.color(for: speakerID))
          .accessibilityHidden(true)
        TextField(SpeakerStats.placeholderName(for: speakerID), text: $draftName)
          .textFieldStyle(.roundedBorder)
          .onSubmit { submit() }
          .accessibilityLabel("Имя спикера \(SpeakerStats.placeholderName(for: speakerID))")
          .accessibilityIdentifier("speaker.name.\(idText)")
          .disabled(speakerID == nil)
        suggestionsMenu
        Image(systemName: state.systemImage)
          .foregroundStyle(stateColor(state))
          .help(state.title)
          .accessibilityLabel(state.title)
          .accessibilityIdentifier("speaker.state.\(idText)")
      }
      confidence(state, assignment: assignment)
      HStack(spacing: 10) {
        Label(Timecode.humanDuration(speaker.speechSeconds), systemImage: "clock")
        Label("\(speaker.utteranceCount)", systemImage: "text.bubble")
        if let language = languageText {
          Label(language, systemImage: "character.bubble")
        }
        if let track = model.transcripts[record.id]?.tracks.first(where: {
          $0.speakerID == speakerID
        }) {
          Label(track.fileName, systemImage: "waveform.badge.mic")
            .lineLimit(1)
            .help("Раздельная дорожка Zoom: \(track.fileName)")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)

      if let suggestion = assignment.suggestion, let speakerID {
        HStack {
          Label(
            "Похоже на \(suggestion.name)"
              + (suggestion.similarity.map { " · \(NamingState.percent($0))" } ?? "")
              + " · \(sourceTitle(suggestion.source))",
            systemImage: "questionmark.circle"
          )
          .foregroundStyle(.orange)
          .lineLimit(2)
          Spacer()
          Button("Принять") { model.acceptSuggestion(speakerID, meetingID: record.id) }
            .accessibilityIdentifier("speaker.accept.\(idText)")
          Button("Отклонить") { model.dismissSuggestion(speakerID, meetingID: record.id) }
        }
        .font(.callout)
      }

      samples
      actions(state)
    }
    .onAppear { draftName = storedName }
    .onChange(of: storedName) { _, newValue in draftName = newValue }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("speaker.row.\(idText)")
  }

  // MARK: - Части

  /// Подсказки имён (DESIGN.md §4: автодополнение из «Люди» и chat.txt/OCR) — стандартное меню у поля.
  @ViewBuilder private var suggestionsMenu: some View {
    let names = model.nameSuggestions(for: record.id)
    if !names.isEmpty, speakerID != nil {
      Menu {
        ForEach(names, id: \.self) { name in
          Button(name) {
            draftName = name
            submit()
          }
        }
      } label: {
        Image(systemName: "chevron.down.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Подсказки: люди, чат, подписи на видео")
      .accessibilityLabel("Подсказки имён")
      .accessibilityIdentifier("speaker.suggestions.\(idText)")
    }
  }

  /// Уверенность сопоставления (DESIGN.md §4): линейная полоса и процент, когда голос сопоставлялся;
  /// иначе — словесное состояние.
  @ViewBuilder private func confidence(_ state: NamingState, assignment: SpeakerAssignment)
    -> some View
  {
    let similarity: Double? =
      switch state {
      case .assigned(let value): value
      case .confirmed: assignment.similarity
      default: nil
      }
    if let similarity {
      HStack(spacing: 8) {
        ProgressView(value: min(max(similarity, 0), 1))
          .progressViewStyle(.linear)
          .controlSize(.small)
          .accessibilityLabel("Уверенность сопоставления")
          .accessibilityValue(NamingState.percent(similarity))
        Text(NamingState.percent(similarity))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    } else {
      Text(state.title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var samples: some View {
    let samples = model.samples(forSpeaker: speakerID, meetingID: record.id)
    if !samples.isEmpty {
      HStack {
        ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
          Button {
            model.playback.play(from: sample.start, to: sample.end)
          } label: {
            Label(Timecode.hhmmss(sample.start), systemImage: "play.circle")
          }
          .buttonStyle(.link)
          .monospacedDigit()
          .accessibilityLabel("Прослушать образец \(index + 1) с \(Timecode.hhmmss(sample.start))")
        }
      }
      .font(.caption)
    }
  }

  @ViewBuilder private func actions(_ state: NamingState) -> some View {
    if let speakerID {
      HStack {
        Button("Подтвердить") {
          model.confirmSpeaker(speakerID, meetingID: record.id, name: draftName)
        }
        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || state == .confirmed)
        .help("Закрепить имя и сохранить голос в профиль человека")
        .accessibilityIdentifier("speaker.confirm.\(idText)")
        Button("Это новый человек") {
          model.markAsNewPerson(speakerID, meetingID: record.id, name: draftName)
        }
        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
        .help("Не тот, кого предложила программа: создать нового человека с этим именем")
        .accessibilityIdentifier("speaker.newPerson.\(idText)")
        Menu("Объединить с…") {
          ForEach(others) { other in
            if let target = other.speakerID {
              Button(other.displayName) {
                model.requestMergeSpeakers(speakerID, into: target, meetingID: record.id)
              }
            }
          }
        }
        .fixedSize()
        .disabled(others.isEmpty)
        .accessibilityIdentifier("speaker.merge.\(idText)")
        Button("Разделить по диапазону…") { split() }
          .accessibilityIdentifier("speaker.split.\(idText)")
      }
      .controlSize(.small)
    }
  }

  // MARK: - Вспомогательное

  private var storedName: String {
    speakerID.flatMap { record.speakerAssignments[$0]?.trimmedName } ?? ""
  }

  private var languageText: String? {
    let routed = speakerID.flatMap { id in
      model.transcripts[record.id]?.speakerLanguages.first { $0.speakerID == id }?.language
    }
    let language = routed ?? speaker.language
    guard let language, language.isKnown else { return nil }
    return language.code
  }

  private func submit() {
    guard let speakerID else { return }
    model.setSpeakerName(draftName, for: speakerID, meetingID: record.id)
  }

  private func stateColor(_ state: NamingState) -> Color {
    switch state {
    case .confirmed, .assigned, .track: .green
    case .suggested: .yellow
    case .unknown: .secondary
    }
  }

  private func sourceTitle(_ source: SpeakerAssignment.Source) -> String {
    switch source {
    case .voice: String(localized: "по голосу")
    case .track: String(localized: "дорожка Zoom")
    case .chat: String(localized: "из чата")
    case .ocr: String(localized: "подпись на видео")
    case .user: String(localized: "вы")
    }
  }
}
