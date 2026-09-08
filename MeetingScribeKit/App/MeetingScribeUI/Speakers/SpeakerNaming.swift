import Core
import Export
import Foundation
import OCR
import Store
import Voices

/// Состояние сопоставления спикера для инспектора (DESIGN.md §4): подтверждено пользователем, присвоено по
/// голосу (≥ 0.70), предложено (0.55…0.70), имя из дорожки Zoom, неизвестно.
nonisolated public enum NamingState: Hashable, Sendable {
  case confirmed
  case assigned(similarity: Double)
  case suggested(similarity: Double?)
  case track
  case unknown(similarity: Double?)

  public var systemImage: String {
    switch self {
    case .confirmed, .assigned, .track: "checkmark.seal"
    case .suggested: "questionmark.circle"
    case .unknown: "person.crop.circle.badge.questionmark"
    }
  }

  public var title: String {
    switch self {
    case .confirmed: String(localized: "Подтверждено")
    case .assigned(let similarity): String(localized: "По голосу · \(Self.percent(similarity))")
    case .suggested(let similarity):
      String(localized: "Предположительно") + (similarity.map { " · \(Self.percent($0))" } ?? "")
    case .track: String(localized: "Дорожка Zoom")
    case .unknown(let similarity):
      String(localized: "Не сопоставлено")
        + (similarity.map { String(localized: " · лучшее сходство \(Self.percent($0))") } ?? "")
    }
  }

  static func percent(_ value: Double) -> String {
    "\(Int((min(max(value, 0), 1) * 100).rounded())) %"
  }
}

/// Имена спикеров (фаза 3, SPEC.md §3.4): сопоставления живут в записи встречи, люди с отпечатками —
/// в библиотеке. Автоматика никогда не переписывает подтверждённое пользователем; подтверждение обновляет
/// профиль человека; переименование человека применяется ко всем встречам, где он сопоставлен.
extension AppModel {

  // MARK: - Чтение

  public func assignment(for speakerID: Int, meetingID: UUID) -> SpeakerAssignment {
    library.meeting(id: meetingID)?.speakerAssignments[speakerID] ?? SpeakerAssignment()
  }

  public func namingState(for speakerID: Int, meetingID: UUID) -> NamingState {
    let assignment = assignment(for: speakerID, meetingID: meetingID)
    if assignment.isConfirmed, assignment.trimmedName != nil { return .confirmed }
    if let similarity = assignment.similarity, assignment.source == .voice,
      assignment.trimmedName != nil
    {
      return .assigned(similarity: similarity)
    }
    if let suggestion = assignment.suggestion {
      return .suggested(similarity: suggestion.similarity)
    }
    if assignment.source == .track, assignment.trimmedName != nil { return .track }
    return .unknown(similarity: assignment.similarity)
  }

  /// Подсказки имён для автодополнения: люди библиотеки, chat.txt, подписи на видео, дорожки —
  /// без дубликатов, по алфавиту.
  public func nameSuggestions(for meetingID: UUID) -> [String] {
    var names = library.people.map(\.name)
    if let transcript = transcripts[meetingID] {
      names += transcript.nameHints.map(\.name)
      names += transcript.tracks.compactMap(\.participantName)
    }
    var seen: Set<String> = []
    return
      names
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
      .sorted { $0.localizedCompare($1) == .orderedAscending }
  }

  /// Имена с видео (список подписей без привязки к спикеру) — для подсказки в инспекторе.
  public func rosterNames(for meetingID: UUID) -> [String] {
    (transcripts[meetingID]?.nameHints ?? [])
      .filter { $0.source == .ocr && $0.speakerID == nil }
      .sorted { $0.count > $1.count }
      .map(\.name)
  }

  /// Спикеры без имени: номер есть, а имени — от пользователя, дорожки Zoom или голосового профиля — нет.
  /// Шапка встречи показывает счётчик, чтобы имена задавали сразу после обработки.
  public func unnamedSpeakerCount(for meetingID: UUID) -> Int {
    speakers(for: meetingID).filter { $0.speakerID != nil && $0.name == nil }.count
  }

  /// Инспектор на вкладке «Спикеры» — из меню, шапки встречи и окна быстрого имени.
  public func showSpeakersInspector() {
    inspectorTab = .speakers
    isInspectorPresented = true
  }

  /// Человек, к которому привязан спикер.
  public func person(for speakerID: Int, meetingID: UUID) -> PersonRecord? {
    assignment(for: speakerID, meetingID: meetingID).personID.flatMap { library.person(id: $0) }
  }

  // MARK: - Автоматика после обработки

  /// Имена после прогона (порядок источников — SPEC.md §3.4): дорожки Zoom → голосовые профили →
  /// подсказки с привязкой к спикеру (OCR). Подтверждённое пользователем не трогается, кроме случая,
  /// когда после повторной обработки голос спикера явно не совпадает с привязанным человеком.
  func applyAutomaticNaming(meetingID: UUID) {
    guard var record = library.meeting(id: meetingID), let transcript = transcripts[meetingID]
    else { return }
    var assignments = record.speakerAssignments
    let thresholds = settings.voiceThresholds
    let space = transcript.embeddingSpace

    // 0. Повторная обработка: номера спикеров между прогонами не стабильны. Подтверждённая привязка
    //    остаётся подтверждённой, только если голос спикера по-прежнему не ниже порога автоприсвоения к
    //    человеку; между порогами она становится предложением, ниже — снимается. Образцы этой встречи у
    //    людей пересобираются по итогу: подтверждённые обновляются новым отпечатком, остальные снимаются —
    //    иначе один прогон дважды входил бы в центроид, а чужой голос попадал бы в профиль.
    var refreshedSamples: [UUID: PersonRecord.VoiceSample] = [:]
    if let space {
      for (speakerID, assignment) in assignments where assignment.isConfirmed {
        guard let personID = assignment.personID,
          let embedding = transcript.embedding(for: speakerID)
        else { continue }
        let sample = PersonRecord.VoiceSample(
          meetingID: meetingID, speakerID: speakerID, vector: embedding.vector, space: space,
          speechSeconds: embedding.speechSeconds)
        guard let profile = library.person(id: personID)?.profile(space: space) else {
          // Профиля в этом пространстве ещё нет — подтверждение даёт первый образец.
          refreshedSamples[personID] = sample
          continue
        }
        let similarity = profile.similarity(to: embedding.vector) ?? 0
        if similarity >= thresholds.autoAssign {
          refreshedSamples[personID] = sample
        } else if similarity >= thresholds.suggest, let name = assignment.trimmedName {
          assignments[speakerID] = SpeakerAssignment(
            similarity: similarity,
            suggestion: SpeakerAssignment.Suggestion(
              name: name, personID: personID, similarity: similarity, source: .voice))
        } else {
          assignments[speakerID] = SpeakerAssignment()
        }
      }
    }
    for index in library.people.indices {
      let personID = library.people[index].id
      let hadSamples = library.people[index].voiceSamples.contains { $0.meetingID == meetingID }
      library.people[index].voiceSamples.removeAll { $0.meetingID == meetingID }
      if let sample = refreshedSamples[personID] {
        library.people[index].voiceSamples.append(sample)
      } else if hadSamples {
        library.people[index].samples.removeAll { $0.meetingID == meetingID }
      }
    }

    // 1. Дорожки Zoom: имя из файла — точное (SPEC.md §2 п. 7), но не подтверждённое пользователем.
    for track in transcript.tracks {
      guard let name = track.participantName?.nilIfEmpty else { continue }
      var assignment = assignments[track.speakerID] ?? SpeakerAssignment()
      guard !assignment.isConfirmed else { continue }
      assignment.name = name
      assignment.source = .track
      assignment.personID = library.person(named: name)?.id
      assignments[track.speakerID] = assignment
    }

    // 2. Голосовые профили того же пространства.
    if let space {
      let matches = VoiceMatcher.match(
        embeddings: transcript.speakerEmbeddings, space: space,
        candidates: library.voiceCandidates(space: space), thresholds: thresholds)
      for match in matches {
        var assignment = assignments[match.speakerID] ?? SpeakerAssignment()
        guard !assignment.isConfirmed else { continue }
        switch match.level {
        case .assigned:
          if assignment.source == .track || assignment.source == .user,
            let currentName = assignment.trimmedName
          {
            // Имя дорожки или введённое пользователем надёжнее голоса: совпало — привязываем человека,
            // нет — только предлагаем, ничего не переписывая.
            if let name = match.name, name.caseInsensitiveCompare(currentName) == .orderedSame {
              assignment.personID = match.personID
              assignment.similarity = match.similarity
            } else if let name = match.name {
              assignment.similarity = match.similarity
              assignment.suggestion = SpeakerAssignment.Suggestion(
                name: name, personID: match.personID, similarity: match.similarity, source: .voice)
            }
          } else {
            assignment.name = match.name
            assignment.personID = match.personID
            assignment.similarity = match.similarity
            assignment.source = .voice
            assignment.suggestion = nil
          }
        case .suggested:
          assignment.similarity = match.similarity
          if let name = match.name,
            name.caseInsensitiveCompare(assignment.trimmedName ?? "") != .orderedSame
          {
            assignment.suggestion = SpeakerAssignment.Suggestion(
              name: name, personID: match.personID, similarity: match.similarity, source: .voice)
          }
          if assignment.source == .voice {
            assignment.name = nil
            assignment.personID = nil
            assignment.source = nil
          }
        case .unknown:
          assignment.similarity = match.similarity
          if assignment.source == .voice {
            assignment.name = nil
            assignment.personID = nil
            assignment.source = nil
          }
          if assignment.suggestion?.source == .voice { assignment.suggestion = nil }
        }
        assignments[match.speakerID] = assignment
      }
    }

    // 3. Подсказки с привязкой к спикеру (голосование по подписям на видео).
    for hint in transcript.nameHints {
      guard let speakerID = hint.speakerID else { continue }
      var assignment = assignments[speakerID] ?? SpeakerAssignment()
      guard !assignment.isConfirmed, assignment.trimmedName == nil, assignment.suggestion == nil
      else { continue }
      assignment.suggestion = SpeakerAssignment.Suggestion(
        name: hint.name, personID: library.person(named: hint.name)?.id, similarity: hint.share,
        source: hint.source == .chat ? .chat : .ocr)
      assignments[speakerID] = assignment
    }

    record.speakerAssignments = assignments
    library.upsert(record)
    saveLibrary()
    if meetingID == selectedMeetingID { refreshRows() }
  }

  // MARK: - Подтверждение

  /// «Подтвердить»: имя закрепляется за спикером, человек находится по привязке или по имени (иначе создаётся),
  /// его профиль пополняется отпечатком спикера. Если спикер привязан к человеку, а имя другое — спрашиваем,
  /// переименовать ли человека везде (SPEC.md §3.4: переименование задним числом по запросу).
  public func confirmSpeaker(
    _ speakerID: Int, meetingID: UUID, name rawName: String, asNewPerson: Bool = false
  ) {
    guard library.meeting(id: meetingID) != nil else { return }
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let assignment = assignment(for: speakerID, meetingID: meetingID)

    var person: PersonRecord?
    if !asNewPerson {
      if let personID = assignment.personID, let linked = library.person(id: personID) {
        if linked.name.caseInsensitiveCompare(name) == .orderedSame {
          person = linked
        } else if let other = library.person(named: name) {
          person = other
        } else {
          alert = AppAlert(
            title: String(localized: "Переименовать «\(linked.name)» в «\(name)»?"),
            message:
              String(
                localized:
                  "Спикер привязан к человеку «\(linked.name)». Переименовать его во всех встречах или считать, что здесь говорит другой человек?"
              ),
            kind: .confirmRenamePerson(
              personID: linked.id, newName: name, meetingID: meetingID, speakerID: speakerID))
          return
        }
      } else if let suggestion = assignment.suggestion,
        suggestion.name.caseInsensitiveCompare(name) == .orderedSame,
        let personID = suggestion.personID, let suggested = library.person(id: personID)
      {
        person = suggested
      } else {
        person = library.person(named: name)
      }
    }
    finishConfirmation(speakerID: speakerID, meetingID: meetingID, name: name, person: person)
  }

  /// Ответ на вопрос о переименовании: человек переименовывается во всех встречах, затем подтверждение.
  public func renamePersonEverywhereAndConfirm(
    personID: UUID, newName: String, meetingID: UUID, speakerID: Int
  ) {
    renamePerson(personID, to: newName)
    guard let person = library.person(id: personID) else { return }
    finishConfirmation(speakerID: speakerID, meetingID: meetingID, name: newName, person: person)
  }

  /// «Это новый человек»: предложение и привязка отбрасываются, создаётся человек с введённым именем.
  public func markAsNewPerson(_ speakerID: Int, meetingID: UUID, name: String) {
    confirmSpeaker(speakerID, meetingID: meetingID, name: name, asNewPerson: true)
  }

  /// Принять предложение (жёлтый `questionmark.circle`).
  public func acceptSuggestion(_ speakerID: Int, meetingID: UUID) {
    guard let suggestion = assignment(for: speakerID, meetingID: meetingID).suggestion else {
      return
    }
    confirmSpeaker(speakerID, meetingID: meetingID, name: suggestion.name)
  }

  public func dismissSuggestion(_ speakerID: Int, meetingID: UUID) {
    guard var record = library.meeting(id: meetingID),
      var assignment = record.speakerAssignments[speakerID]
    else { return }
    assignment.suggestion = nil
    record.speakerAssignments[speakerID] = assignment
    library.upsert(record)
    saveLibrary()
  }

  private func finishConfirmation(
    speakerID: Int, meetingID: UUID, name: String, person existing: PersonRecord?
  ) {
    guard var record = library.meeting(id: meetingID) else { return }
    var person = existing ?? PersonRecord(name: name)
    let previousPersonID = record.speakerAssignments[speakerID]?.personID
    // Спикер был привязан к другому человеку — его образец уходит из прежнего профиля.
    if let previousPersonID, previousPersonID != person.id,
      var previous = library.person(id: previousPersonID)
    {
      previous.removeSamples(meetingID: meetingID, speakerID: speakerID)
      library.upsert(previous)
    }
    if let transcript = transcripts[meetingID] {
      if let embedding = transcript.embedding(for: speakerID), let space = transcript.embeddingSpace
      {
        person.setVoiceSample(
          PersonRecord.VoiceSample(
            meetingID: meetingID, speakerID: speakerID, vector: embedding.vector, space: space,
            speechSeconds: embedding.speechSeconds))
      }
      person.samples.removeAll { $0.meetingID == meetingID && $0.speakerID == speakerID }
      for utterance in samples(forSpeaker: speakerID, meetingID: meetingID) {
        person.samples.append(
          PersonRecord.SampleRef(
            meetingID: meetingID, speakerID: speakerID, start: utterance.start, end: utterance.end))
      }
    }
    person.updatedAt = Date()
    library.upsert(person)

    var assignment = record.speakerAssignments[speakerID] ?? SpeakerAssignment()
    assignment.name = name
    assignment.personID = person.id
    assignment.source = .user
    assignment.isConfirmed = true
    assignment.suggestion = nil
    record.speakerAssignments[speakerID] = assignment
    library.upsert(record)
    saveLibrary()
    if meetingID == selectedMeetingID { refreshRows() }
  }

  /// Имя без подтверждения (ввод в поле без «Подтвердить»): применяется к транскрипту и экспорту,
  /// профиль не трогается. Пустое имя снимает присвоение.
  public func setSpeakerName(_ name: String, for speakerID: Int, meetingID: UUID) {
    guard var record = library.meeting(id: meetingID) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var assignment = record.speakerAssignments[speakerID] ?? SpeakerAssignment()
    if trimmed.isEmpty {
      assignment.name = nil
      assignment.personID = nil
      assignment.source = nil
      assignment.isConfirmed = false
    } else if assignment.trimmedName != trimmed {
      assignment.name = trimmed
      assignment.source = .user
      assignment.isConfirmed = false
      assignment.personID = library.person(named: trimmed)?.id
    }
    record.speakerAssignments[speakerID] = assignment
    library.upsert(record)
    saveLibrary()
    if meetingID == selectedMeetingID { refreshRows() }
  }

  // MARK: - Люди

  /// Переименование человека применяется ко всем встречам, где он сопоставлен (SPEC.md §3.4).
  public func renamePerson(_ id: UUID, to rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, var person = library.person(id: id), person.name != name else { return }
    person.name = name
    person.updatedAt = Date()
    library.upsert(person)
    for var record in library.meetings {
      var changed = false
      for (speakerID, assignment) in record.speakerAssignments {
        var updated = assignment
        var touched = false
        if assignment.personID == id, assignment.name != name {
          updated.name = name
          touched = true
        }
        if assignment.suggestion?.personID == id, assignment.suggestion?.name != name {
          updated.suggestion?.name = name
          touched = true
        }
        if touched {
          record.speakerAssignments[speakerID] = updated
          changed = true
        }
      }
      if changed { library.upsert(record) }
    }
    saveLibrary()
    refreshRows()
  }

  public func requestDelete(person id: UUID) {
    guard let person = library.person(id: id) else { return }
    alert = AppAlert(
      title: String(localized: "Удалить «\(person.name)» из списка людей?"),
      message: String(
        localized: "Голосовой профиль будет удалён; имена в уже обработанных встречах останутся."),
      kind: .confirmDeletePerson(id))
  }

  public func deletePerson(_ id: UUID) {
    library.removePerson(id: id)
    saveLibrary()
    refreshRows()
  }

  /// Встречи, где человек говорил, новые сверху.
  public func meetings(with personID: UUID) -> [MeetingRecord] {
    library.meetings(with: personID)
  }

  /// Прослушать фрагмент человека: открыть встречу и сыграть отрезок.
  public func playSample(_ sample: PersonRecord.SampleRef) {
    guard library.meeting(id: sample.meetingID) != nil else { return }
    if selectedMeetingID != sample.meetingID { selectMeeting(sample.meetingID) }
    playback.play(from: sample.start, to: sample.end)
  }

  /// Экспорт профилей (Settings → Люди и голоса): JSON списка людей.
  public func peopleJSON() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(library.people) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  public func savePeopleJSON() {
    guard let text = peopleJSON() else { return }
    peopleExportRequest = ExportRequest(
      document: TranscriptDocument(text: text, format: .json), format: .json,
      defaultFilename: "MeetingScribe-people.json")
  }

  /// Импорт профилей: люди с тем же `id` заменяются, остальные добавляются.
  public func importPeople(from url: URL) {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let people = try decoder.decode([PersonRecord].self, from: Data(contentsOf: url))
      for person in people { library.upsert(person) }
      saveLibrary()
      alert = AppAlert(
        title: String(localized: "Профили импортированы"),
        message:
          String(localized: "\(people.count) человек")
      )
    } catch {
      alert = AppAlert(
        title: String(localized: "Файл профилей не прочитался"), message: error.localizedDescription
      )
    }
  }

  // MARK: - Объединение и разделение спикеров

  public func requestMergeSpeakers(_ source: Int, into target: Int, meetingID: UUID) {
    guard source != target, let transcript = displayTranscript(for: meetingID) else { return }
    let name = { (id: Int) in
      transcript.speakers.first { $0.speakerID == id }?.displayName
        ?? SpeakerStats.placeholderName(for: id)
    }
    alert = AppAlert(
      title: String(localized: "Объединить «\(name(source))» со «\(name(target))»?"),
      message: String(
        localized:
          "Все реплики «\(name(source))» перейдут к «\(name(target))». Отменить это нельзя."),
      kind: .confirmMergeSpeakers(source: source, target: target, meetingID: meetingID))
  }

  /// Объединяет спикеров: реплики, turn'ы и отпечатки — в транскрипте (`Transcript.mergeSpeaker`),
  /// сопоставление и образцы людей — в библиотеке.
  public func mergeSpeakers(_ source: Int, into targetID: Int, meetingID: UUID) {
    guard source != targetID, var transcript = transcripts[meetingID],
      var record = library.meeting(id: meetingID)
    else { return }
    transcript.mergeSpeaker(source, into: targetID)
    let sourceAssignment = record.speakerAssignments.removeValue(forKey: source)
    if record.speakerAssignments[targetID]?.trimmedName == nil, let sourceAssignment {
      record.speakerAssignments[targetID] = sourceAssignment
    }
    for var person in library.people
    where person.voiceSamples.contains(where: {
      $0.meetingID == meetingID && $0.speakerID == source
    })
      || person.samples.contains(where: { $0.meetingID == meetingID && $0.speakerID == source })
    {
      person.removeSamples(meetingID: meetingID, speakerID: source)
      library.upsert(person)
    }
    // Отпечаток цели стал взвешенным средним двух голосов — образец подтверждённого человека обновляется.
    if let target = record.speakerAssignments[targetID], target.isConfirmed,
      let personID = target.personID, var person = library.person(id: personID),
      let embedding = transcript.embedding(for: targetID), let space = transcript.embeddingSpace
    {
      person.setVoiceSample(
        PersonRecord.VoiceSample(
          meetingID: meetingID, speakerID: targetID, vector: embedding.vector, space: space,
          speechSeconds: embedding.speechSeconds))
      library.upsert(person)
    }
    if speakerFilter == source { speakerFilter = nil }
    library.upsert(record)
    saveLibrary()
    commitTranscript(transcript, for: meetingID)
  }

  /// Разделяет спикера по диапазону: реплики внутри уходят новому спикеру (без имени и отпечатка).
  @discardableResult
  public func splitSpeaker(_ speakerID: Int, range: ClosedRange<Double>, meetingID: UUID) -> Int? {
    guard var transcript = transcripts[meetingID] else { return nil }
    guard let newID = transcript.splitSpeaker(speakerID, range: range) else {
      alert = AppAlert(
        title: String(localized: "Нечего разделять"),
        message:
          String(
            localized:
              "В диапазоне \(Timecode.hhmmss(range.lowerBound))–\(Timecode.hhmmss(range.upperBound)) нет реплик этого спикера."
          )
      )
      return nil
    }
    commitTranscript(transcript, for: meetingID)
    return newID
  }

  // MARK: - Правки реплик (DESIGN.md §3, контекстное меню)

  /// «Приписать спикеру…»: `nil` — неизвестный.
  public func reassignUtterance(index: Int, to speakerID: Int?, meetingID: UUID) {
    guard var transcript = transcripts[meetingID],
      transcript.reassignUtterance(at: index, to: speakerID)
    else { return }
    commitTranscript(transcript, for: meetingID)
  }

  /// «Приписать новому спикеру»: реплика получает следующий свободный номер.
  @discardableResult
  public func reassignUtteranceToNewSpeaker(index: Int, meetingID: UUID) -> Int? {
    guard var transcript = transcripts[meetingID] else { return nil }
    let newID = transcript.nextSpeakerID
    guard transcript.reassignUtterance(at: index, to: newID) else { return nil }
    commitTranscript(transcript, for: meetingID)
    return newID
  }

  public func mergeUtteranceWithPrevious(index: Int, meetingID: UUID) {
    guard var transcript = transcripts[meetingID],
      transcript.mergeUtteranceWithPrevious(at: index)
    else { return }
    if selectedRowID == index { selectedRowID = index - 1 }
    commitTranscript(transcript, for: meetingID)
  }

  public func splitUtterance(index: Int, beforeWord wordIndex: Int, meetingID: UUID) {
    guard var transcript = transcripts[meetingID],
      transcript.splitUtterance(at: index, beforeWord: wordIndex)
    else { return }
    commitTranscript(transcript, for: meetingID)
  }

  /// Спикеры для меню «Приписать спикеру…»: номер и имя.
  public func speakerChoices(for meetingID: UUID) -> [(id: Int, name: String)] {
    (displayTranscript(for: meetingID)?.speakers ?? []).compactMap { speaker in
      speaker.speakerID.map { ($0, speaker.displayName) }
    }
    .sorted { $0.id < $1.id }
  }

  // MARK: - Подписи на видео (OCR)

  /// «Найти имена на видео»: сканирует `record.videoURL`, итог — в `Transcript.nameHints` (прежние
  /// подсказки OCR заменяются), затем автоматика подставляет предложения спикерам без имени.
  public func scanVideoForNames(meetingID: UUID) {
    guard let record = library.meeting(id: meetingID), let videoURL = record.videoURL,
      let transcript = transcripts[meetingID]
    else { return }
    nameScanSummaryMeetingID = meetingID
    nameScan.start(
      meetingID: meetingID, videoURL: videoURL, utterances: transcript.utterances,
      hints: nameSuggestions(for: meetingID),
      sourceAccess: { [sourceBookmarks] in sourceBookmarks.access(for: meetingID) }
    ) { [weak self] _, hints in
      guard let self, var current = transcripts[meetingID] else { return }
      current.nameHints.removeAll { $0.source == .ocr }
      current.nameHints.append(contentsOf: hints)
      transcripts[meetingID] = current
      commitTranscript(current, for: meetingID)
      // Прежние предложения с видео уступают место новым (проход мог идти с другими подсказками).
      if var record = library.meeting(id: meetingID) {
        for speakerID in record.speakerAssignments.keys
        where record.speakerAssignments[speakerID]?.suggestion?.source == .ocr {
          record.speakerAssignments[speakerID]?.suggestion = nil
        }
        library.upsert(record)
      }
      applyAutomaticNaming(meetingID: meetingID)
    }
  }

  // MARK: - Сохранение транскрипта

  /// Транскрипт после правки: кэш, строки списка, запись на диск в фоне (ошибка — предупреждение).
  func commitTranscript(_ transcript: Transcript, for meetingID: UUID) {
    transcripts[meetingID] = transcript
    if var record = library.meeting(id: meetingID) {
      record.utteranceCount = transcript.utterances.count
      record.speakerCount = transcript.speakers.filter { $0.speakerID != nil }.count
      library.upsert(record)
      saveLibrary()
    }
    if meetingID == selectedMeetingID { refreshRows() }
    // Записи одной встречи идут по цепочке: две задачи к актору могли бы прийти в обратном порядке,
    // и на диске остался бы предпоследний снимок (так же, как `saveLibrary`).
    let snapshot = transcript
    let previous = transcriptSaveTasks[meetingID]
    transcriptSaveTasks[meetingID] = Task { [weak self] in
      _ = await previous?.result
      do {
        try await self?.store.saveTranscript(snapshot, for: meetingID)
      } catch {
        self?.alert = AppAlert(
          title: String(localized: "Правка не сохранилась"), message: error.localizedDescription)
      }
    }
  }
}
