import Core
import Export
import Store
import SwiftUI

/// Средняя колонка: экран встречи, список всех встреч, «Люди» или пустое состояние (DESIGN.md §2, §3, §3b).
struct MeetingContentView: View {
  @Bindable var model: AppModel

  var body: some View {
    if model.showsLibraryResults {
      // Поиск по библиотеке занимает всю среднюю колонку: выдача ведёт к репликам разных встреч.
      LibrarySearchView(model: model)
    } else {
      selectionContent
    }
  }

  @ViewBuilder private var selectionContent: some View {
    switch model.selection {
    case .meeting(let id):
      if let record = model.library.meeting(id: id) {
        MeetingScreen(model: model, record: record)
      } else {
        EmptyStateView(model: model)
      }
    case .people:
      PeopleView(model: model)
    case .allMeetings:
      AllMeetingsView(model: model)
    case nil:
      EmptyStateView(model: model)
    }
  }
}

/// Экран одной встречи: карточка обработки, транскрипт, ошибка или приглашение обработать.
struct MeetingScreen: View {
  @Bindable var model: AppModel
  let record: MeetingRecord

  var body: some View {
    let transcript = model.displayTranscript(for: record.id)
    let progress = model.coordinator.progress(for: record.id)
    // Пока прогон не закончился, экран встречи — карточка обработки: статус записи и модель прогресса
    // приходят разными сообщениями координатора, поэтому учитываем оба признака.
    let isWorking = record.status.isActive || (progress.map { !$0.isFinished } ?? false)
    if isWorking, transcript == nil {
      if let progress {
        ProcessingCardView(model: model, record: record, progress: progress)
      } else {
        ProgressPlaceholderView(model: model, record: record)
      }
    } else if let transcript {
      VStack(spacing: 0) {
        MeetingHeaderView(model: model, record: record, transcript: transcript)
        if case .failed(let stage, let message) = record.status {
          FailureBanner(model: model, record: record, stage: stage, message: message)
        }
        if record.status == .cancelled || record.status == .interrupted {
          PartialBanner(model: model, record: record)
        }
        TranscriptView(model: model, meetingID: record.id)
      }
    } else if record.hasTranscript {
      // Чтение transcript.json занимает доли секунды — здесь крутилка уместна (SPEC.md §3.7).
      VStack(spacing: 8) {
        ProgressView()
        Text("Открываю транскрипт…").foregroundStyle(.secondary)
      }
    } else {
      switch record.status {
      case .failed(let stage, let message):
        FailureView(model: model, record: record, stage: stage, message: message)
      case .cancelled, .interrupted:
        NotFinishedView(model: model, record: record)
      default:
        NotProcessedView(model: model, record: record)
      }
    }
  }
}

/// Встреча в очереди, модели прогресса ещё нет (координатор только принял задачу).
struct ProgressPlaceholderView: View {
  @Bindable var model: AppModel
  let record: MeetingRecord

  var body: some View {
    VStack(spacing: 12) {
      Text(record.title).font(.title2)
      StatusBadge(status: record.status)
        .accessibilityIdentifier("meeting.status")
      ProgressView(value: 0)
        .progressViewStyle(.linear)
        .accessibilityIdentifier("processing.progress")
        .accessibilityLabel("Прогресс обработки")
        .accessibilityValue("0 %")
      Text("В очереди")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("processing.line1")
      Button("Отменить", systemImage: "xmark.circle") { model.cancel(record.id) }
        .accessibilityIdentifier("processing.cancel")
    }
    .padding()
  }
}

/// Встреча импортирована, но не обработана.
struct NotProcessedView: View {
  @Bindable var model: AppModel
  let record: MeetingRecord

  var body: some View {
    ContentUnavailableView {
      Label(record.title, systemImage: "waveform")
    } description: {
      VStack(spacing: 4) {
        StatusBadge(status: record.status)
          .accessibilityIdentifier("meeting.status")
        Text(record.sourceURL.lastPathComponent)
        Text("\(meetingDateText(record.date)) · \(durationText(record.duration))")
          .foregroundStyle(.secondary)
      }
    } actions: {
      Button("Обработать", systemImage: "play.fill") { model.process(record.id) }
        .accessibilityIdentifier("process.button.content")
    }
  }
}

/// Ошибка обработки: стадия, причина и повтор (DESIGN.md §3b).
struct FailureView: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  let stage: Stage?
  let message: String

  var body: some View {
    ContentUnavailableView {
      Label(
        stage?.title ?? String(localized: "Обработка не удалась"),
        systemImage: "exclamationmark.triangle")
    } description: {
      VStack(spacing: 4) {
        StatusBadge(status: record.status)
          .accessibilityIdentifier("meeting.status")
        Text(message)
      }
    } actions: {
      Button("Повторить обработку", systemImage: "arrow.clockwise") { model.process(record.id) }
        .accessibilityIdentifier("process.button.content")
    }
  }
}

/// Отменённая или прерванная встреча без транскрипта.
struct NotFinishedView: View {
  @Bindable var model: AppModel
  let record: MeetingRecord

  var body: some View {
    ContentUnavailableView {
      Label(record.title, systemImage: "pause.circle")
    } description: {
      VStack(spacing: 4) {
        StatusBadge(status: record.status)
          .accessibilityIdentifier("meeting.status")
        Text(
          "Обработка не была доведена до конца. Повтор начнётся с начала: подготовка аудио занимает секунды, дольше всего — распознавание."
        )
      }
    } actions: {
      Button("Повторить обработку", systemImage: "arrow.clockwise") { model.process(record.id) }
        .accessibilityIdentifier("process.button.content")
    }
  }
}

/// Полоса над транскриптом: ошибка стадии с повтором.
struct FailureBanner: View {
  @Bindable var model: AppModel
  let record: MeetingRecord
  let stage: Stage?
  let message: String

  var body: some View {
    HStack {
      Label(
        "\(stage?.title ?? String(localized: "Обработка")): \(message)",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.red)
      .lineLimit(2)
      Spacer()
      Button("Повторить обработку") { model.process(record.id) }
    }
    .font(.callout)
    .padding(.horizontal)
    .padding(.vertical, 6)
  }
}

/// Полоса над частичным транскриптом: обработка была отменена или прервана.
struct PartialBanner: View {
  @Bindable var model: AppModel
  let record: MeetingRecord

  var body: some View {
    HStack {
      Label(
        record.isPartialTranscript
          ? "Показан частичный транскрипт: обработка была прервана"
          : "Обработка была прервана",
        systemImage: "pause.circle"
      )
      .foregroundStyle(.orange)
      Spacer()
      Button("Повторить обработку") { model.process(record.id) }
    }
    .font(.callout)
    .padding(.horizontal)
    .padding(.vertical, 6)
  }
}

/// «Все встречи»: плоский список библиотеки, новые сверху.
struct AllMeetingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    if model.library.meetings.isEmpty {
      EmptyStateView(model: model)
    } else {
      List {
        ForEach(model.library.meetingsNewestFirst) { record in
          Button {
            model.selectMeeting(record.id)
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(record.title)
                Text(meetingDateText(record.date))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(durationText(record.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
              StatusBadge(status: record.status)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .accessibilityIdentifier("allMeetings.list")
    }
  }
}
