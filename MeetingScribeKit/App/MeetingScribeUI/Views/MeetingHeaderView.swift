import Core
import Export
import Store
import SwiftUI

/// Шапка встречи (DESIGN.md §3): название, дата, длительность, проект, движки, фильтр спикера,
/// кнопка «Имена спикеров…» со счётчиком безымянных, кнопка воспроизведения и timeline спикеров
/// с позицией плеера.
struct MeetingHeaderView: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  let transcript: Transcript
  @State private var isRenaming = false
  @State private var draftTitle = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(record.title)
          .font(.title2)
          .onTapGesture(count: 2) {
            draftTitle = record.title
            isRenaming = true
          }
          .accessibilityLabel("Название встречи: \(record.title)")
        StatusBadge(status: record.status)
          .accessibilityIdentifier("meeting.status")
        Spacer()
        // «Создать follow-up» появляется у обработанной встречи, когда есть генератор (ADR-010): промпт с
        // выбранным языком уходит модели, ответ показывается в листе follow-up и сохраняется в проект.
        if let generator = model.activeFollowupGenerator, record.status == .ready {
          Button {
            model.beginFollowupImport(meetingID: record.id, generate: true)
          } label: {
            Label("Создать follow-up", systemImage: "sparkles")
          }
          .buttonStyle(.borderedProminent)
          .disabled(!generator.isAvailable)
          .help(
            generator.unavailableReason
              ?? String(localized: "Отправить транскрипт модели и разобрать её ответ")
          )
          .accessibilityIdentifier("meeting.createFollowup")
        }
        followupMenu
        playButton
      }
      HStack(spacing: 12) {
        Label(meetingDateText(record.date), systemImage: "calendar")
        Label(durationText(record.duration ?? transcript.audio.duration), systemImage: "clock")
        if let project = model.projectName(for: record) {
          Label(project, systemImage: "folder")
        }
        Label(record.engines.title, systemImage: "cpu")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)

      HStack {
        Picker("Спикер", selection: $model.speakerFilter) {
          Text("Все спикеры").tag(Int?.none)
          ForEach(transcript.speakers, id: \.speakerID) { speaker in
            if let id = speaker.speakerID {
              Text(speaker.displayName).tag(Int?.some(id))
            }
          }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("transcript.speakerFilter")
        // Имена задаются после обработки: кнопка ведёт в инспектор «Спикеры», счётчик показывает,
        // скольким спикерам имя ещё нужно; быстрый путь — клик по чипу спикера в транскрипте.
        Button {
          model.showSpeakersInspector()
        } label: {
          Label("Имена спикеров…", systemImage: "person.text.rectangle")
        }
        .labelStyle(.titleAndIcon)
        .help("Назвать спикеров и сохранить их голоса в «Люди»")
        .accessibilityIdentifier("meeting.speakerNames")
        let unnamed = model.unnamedSpeakerCount(for: record.id)
        if unnamed > 0 {
          Text("\(unnamed) спикеров без имени")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("meeting.unnamedSpeakers")
        }
        Spacer()
        if !model.playback.isAvailable, let reason = model.playback.unavailableReason {
          Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(reason)
        }
      }

      SpeakerTimelineView(
        turns: transcript.turns,
        duration: max(record.duration ?? transcript.audio.duration, 1),
        position: model.playback.currentTime)
    }
    .padding([.horizontal, .top])
    .alert("Переименовать встречу", isPresented: $isRenaming) {
      TextField("Название", text: $draftTitle)
      Button("Сохранить") { model.rename(meeting: record.id, to: draftTitle) }
      Button("Отмена", role: .cancel) {}
    }
  }

  /// Цикл follow-up (SPEC.md §3.6) виден прямо в шапке: вставить ответ модели и открыть историю
  /// проекта, где follow-up прошлых встреч лежат по датам.
  private var followupMenu: some View {
    Menu {
      Button("Вставить ответ модели…") { model.beginFollowupImport(meetingID: record.id) }
        .accessibilityIdentifier("meeting.followupPaste")
      Button("История проекта…") {
        if let projectID = record.projectID {
          model.beginFollowupHistory(projectID: projectID)
        }
      }
      .disabled(record.projectID == nil)
      .accessibilityIdentifier("meeting.followupHistory")
    } label: {
      Label("Follow-up", systemImage: "text.badge.checkmark")
    }
    .fixedSize()
    .help(
      "Скопируйте TranscribeFull, получите follow-up у Claude и вставьте ответ сюда; история проекта показывает follow-up прошлых встреч по датам"
    )
    .accessibilityIdentifier("meeting.followupMenu")
  }

  private var playButton: some View {
    Button {
      if model.playback.isPlaying {
        model.playback.pause()
      } else if model.playback.currentTime > 0 {
        model.playback.togglePlayPause()
      } else {
        model.playback.play(from: model.displayRows.first?.start ?? 0)
      }
    } label: {
      Label(
        model.playback.isPlaying ? String(localized: "Пауза") : String(localized: "Воспроизвести"),
        systemImage: model.playback.isPlaying ? "pause.fill" : "play.fill")
    }
    .disabled(!model.playback.isAvailable)
    .accessibilityIdentifier("meeting.play")
  }
}

/// Разметка спикеров по времени: цветные полосы turn'ов и позиция плеера. Это контент встречи, а не хром окна.
struct SpeakerTimelineView: View {
  let turns: [Turn]
  let duration: Double
  let position: Double

  var body: some View {
    Canvas { context, size in
      guard duration > 0 else { return }
      for turn in turns {
        let x = size.width * (turn.start / duration)
        let width = max(size.width * (turn.duration / duration), 1)
        let rect = CGRect(x: x, y: 0, width: width, height: size.height)
        context.fill(Path(rect), with: .color(SpeakerPalette.color(for: turn.speakerID)))
      }
      let markerX = size.width * min(max(position / duration, 0), 1)
      context.stroke(
        Path { path in
          path.move(to: CGPoint(x: markerX, y: 0))
          path.addLine(to: CGPoint(x: markerX, y: size.height))
        }, with: .color(.primary), lineWidth: 2)
    }
    // Полоса разметки — графика фиксированной высоты, а не контрол: высота задаётся содержимым.
    .frame(height: 10)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .accessibilityLabel("Разметка спикеров по времени")
    .accessibilityValue(Timecode.hhmmss(position))
  }
}
