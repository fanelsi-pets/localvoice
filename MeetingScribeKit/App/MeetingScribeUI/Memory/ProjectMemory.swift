import Core
import Export
import Foundation
import Store

/// Что из разобранного follow-up пользователь оставил в диалоге и как отредактировал (SPEC.md §3.6).
/// Значение, а не ссылки на вью: модель получает готовый список пунктов с индексами в `ParsedFollowup`.
nonisolated public struct FollowupSelection: Hashable, Sendable {
  /// Один выбранный пункт: номер в разборе и текст после правки пользователем.
  public struct Item: Hashable, Sendable {
    /// Индекс в соответствующем массиве `ParsedFollowup` — из него берутся таймкод и сырой срок.
    public var index: Int
    public var text: String
    /// Ответственный (только у задач).
    public var owner: String?
    /// Срок (только у задач): ISO-день или свободный текст.
    public var due: String?

    public init(index: Int, text: String, owner: String? = nil, due: String? = nil) {
      self.index = index
      self.text = text
      self.owner = owner
      self.due = due
    }
  }

  public var decisions: [Item]
  public var actions: [Item]
  public var questions: [Item]

  public init(decisions: [Item] = [], actions: [Item] = [], questions: [Item] = []) {
    self.decisions = decisions
    self.actions = actions
    self.questions = questions
  }

  public var isEmpty: Bool { decisions.isEmpty && actions.isEmpty && questions.isEmpty }

  /// Всё, что разобрано, без правок — умолчание диалога и удобство тестов.
  public static func all(from parsed: ParsedFollowup) -> FollowupSelection {
    FollowupSelection(
      decisions: parsed.decisions.enumerated().map {
        Item(index: $0.offset, text: $0.element.text)
      },
      actions: parsed.actions.enumerated().map {
        Item(
          index: $0.offset, text: $0.element.text, owner: $0.element.owner,
          due: $0.element.due ?? $0.element.dueText)
      },
      questions: parsed.questions.enumerated().map { Item(index: $0.offset, text: $0.element.text) }
    )
  }
}

/// Итог импорта follow-up для сообщения пользователю.
nonisolated public struct FollowupImportSummary: Hashable, Sendable {
  public var followupID: UUID
  public var decisions: Int
  public var actions: Int
  public var questions: Int
  /// Пункты, которые уже были у этой встречи (повторный импорт того же ответа).
  public var skipped: Int
  /// Текст ответа лежит в истории проекта (новая запись или та же при повторной вставке).
  public var textSaved: Bool

  public init(
    followupID: UUID, decisions: Int, actions: Int, questions: Int, skipped: Int,
    textSaved: Bool = false
  ) {
    self.followupID = followupID
    self.decisions = decisions
    self.actions = actions
    self.questions = questions
    self.skipped = skipped
    self.textSaved = textSaved
  }

  public var isEmpty: Bool { decisions == 0 && actions == 0 && questions == 0 }

  /// «Добавлено: 2 решения, 1 задача, 1 вопрос» — формы числа задают вариации String Catalog (ключи с `%lld`).
  public var message: String {
    var parts: [String] = []
    if decisions > 0 {
      parts.append(
        String(localized: "\(decisions) решений"))
    }
    if actions > 0 {
      parts.append(String(localized: "\(actions) задач"))
    }
    if questions > 0 {
      parts.append(
        String(localized: "\(questions) вопросов"))
    }
    var text =
      parts.isEmpty
      ? (textSaved
        ? String(
          localized:
            "Текст сохранён в истории проекта; решения, задачи и вопросы не распознаны")
        : String(localized: "Ничего не добавлено"))
      : String(localized: "Добавлено: ") + parts.joined(separator: ", ")
    if skipped > 0 {
      text +=
        String(localized: "; пропущено как повтор: \(skipped) пунктов")
    }
    return text
  }
}

/// Строка истории follow-up проекта: запись с названием и датой встречи и числом добавленных пунктов.
nonisolated public struct FollowupTimelineEntry: Identifiable, Hashable, Sendable {
  public var followup: FollowupRecord
  public var meetingTitle: String
  /// Дата встречи (без неё — дата импорта записи); `nil` — встреча удалена.
  public var meetingDate: Date?
  public var decisions: Int
  public var actions: Int
  public var questions: Int

  public init(
    followup: FollowupRecord, meetingTitle: String, meetingDate: Date?, decisions: Int,
    actions: Int, questions: Int
  ) {
    self.followup = followup
    self.meetingTitle = meetingTitle
    self.meetingDate = meetingDate
    self.decisions = decisions
    self.actions = actions
    self.questions = questions
  }

  public var id: UUID { followup.id }
  public var meetingID: UUID { followup.meetingID }

  /// «3 решения · 2 задачи · 1 вопрос», без пунктов — «только текст».
  public var countsText: String {
    var parts: [String] = []
    if decisions > 0 { parts.append(String(localized: "\(decisions) решений")) }
    if actions > 0 { parts.append(String(localized: "\(actions) задач")) }
    if questions > 0 { parts.append(String(localized: "\(questions) вопросов")) }
    return parts.isEmpty ? String(localized: "только текст") : parts.joined(separator: " · ")
  }
}

/// Память проекта (фаза 4, SPEC.md §3.6): решения, задачи и вопросы прошлых встреч попадают в шапку
/// следующего экспорта, а импорт follow-up превращает ответ модели в записи библиотеки. Всё пишется
/// в тот же снимок `library` и сохраняется обычным `saveLibrary()` (`LibraryStore` пишет разницу).
extension AppModel {

  // MARK: - Контекст проекта

  /// Часовой пояс контекста: имя файла-источника и даты строк считаются в одном поясе с экспортом
  /// (`TranscribeFullOptions.timeZone`), иначе `[2026-08-14]` и `TranscribeFull_2026-08-15.md`
  /// разъехались бы на границе суток.
  nonisolated public static let contextTimeZone: TimeZone = .current

  /// Контекст предыдущих встреч проекта: решения, открытые задачи и вопросы. `nil` — встреча без
  /// проекта или контекст пуст (тогда секция в экспорте опускается).
  public func projectContext(for meetingID: UUID) -> ProjectContext? {
    guard let record = library.meeting(id: meetingID), let projectID = record.projectID else {
      return nil
    }
    let previous = previousMeetingIDs(before: record, in: projectID)
    func isEarlier(_ item: some MemoryRecord) -> Bool {
      isInContext(item, of: record, previous: previous)
    }

    let context = ProjectContext(
      decisions: library.decisions(in: projectID).filter(isEarlier).map { decision in
        ProjectContext.Decision(
          text: decision.text,
          meetingDate: decision.meetingDate,
          timestamp: decision.timestamp,
          sourceFileName: decision.meetingDate.map {
            TranscribeFullExporter.fileName(forDate: $0, timeZone: Self.contextTimeZone)
          })
      },
      actions: library.openActionItems(in: projectID).filter(isEarlier).map { item in
        ProjectContext.Action(text: item.text, owner: item.owner, due: item.dueTitle)
      },
      questions: library.openQuestions(in: projectID).filter(isEarlier).map { question in
        ProjectContext.Question(text: question.text, meetingDate: question.meetingDate)
      })
    return context.isEmpty ? nil : context
  }

  /// Записи памяти проекта, которые попадут в контекст экспорта этой встречи. Инспектор помечает
  /// остальные («позже этой встречи»): в шапку следующего TranscribeFull они не пойдут.
  public func contextItemIDs(forMeeting meetingID: UUID) -> Set<UUID> {
    guard let record = library.meeting(id: meetingID), let projectID = record.projectID else {
      return []
    }
    let previous = previousMeetingIDs(before: record, in: projectID)
    var ids: Set<UUID> = []
    for item in library.decisions(in: projectID)
    where isInContext(item, of: record, previous: previous) {
      ids.insert(item.id)
    }
    for item in library.actionItems(in: projectID)
    where isInContext(item, of: record, previous: previous) {
      ids.insert(item.id)
    }
    for item in library.questions(in: projectID)
    where isInContext(item, of: record, previous: previous) {
      ids.insert(item.id)
    }
    return ids
  }

  /// Встречи проекта раньше указанной: по дате встречи, при равной — по времени добавления.
  func previousMeetingIDs(before record: MeetingRecord, in projectID: UUID) -> Set<UUID> {
    let anchor = record.date ?? record.createdAt
    return Set(
      library.meetings(in: projectID)
        .filter { other in
          guard other.id != record.id else { return false }
          let date = other.date ?? other.createdAt
          if date != anchor { return date < anchor }
          return other.createdAt < record.createdAt
        }
        .map(\.id))
  }

  /// Идёт ли запись памяти в контекст встречи `record` (SPEC.md §3.6): своя встреча исключается,
  /// живая чужая — судится по списку предыдущих встреч **этого** проекта, а встреча, уехавшая
  /// в другой проект или удалённая, — по дате, снятой в запись при импорте (иначе перенос встречи
  /// молча выбросил бы её решения из контекста старого проекта).
  func isInContext(_ item: some MemoryRecord, of record: MeetingRecord, previous: Set<UUID>) -> Bool
  {
    if let itemMeetingID = item.meetingID {
      if itemMeetingID == record.id { return false }
      if let other = library.meeting(id: itemMeetingID), other.projectID == record.projectID {
        return previous.contains(itemMeetingID)
      }
    }
    let anchor = record.date ?? record.createdAt
    let date = item.meetingDate ?? item.createdAt
    if date != anchor { return date < anchor }
    // Тот же день: встречу-источник уже удалили, порядок восстанавливаем по времени добавления.
    return item.createdAt < record.createdAt
  }

  /// Записи памяти встречи (для инспектора и заметки Obsidian), в порядке импорта.
  public func decisions(for meetingID: UUID) -> [DecisionRecord] {
    library.decisions.filter { $0.meetingID == meetingID }.sorted(by: Self.byImportOrder)
  }

  public func actionItems(for meetingID: UUID) -> [ActionItemRecord] {
    library.actionItems.filter { $0.meetingID == meetingID }.sorted(by: Self.byImportOrder)
  }

  public func questions(for meetingID: UUID) -> [QuestionRecord] {
    library.questions.filter { $0.meetingID == meetingID }.sorted(by: Self.byImportOrder)
  }

  static func byImportOrder(_ lhs: some MemoryRecord, _ rhs: some MemoryRecord) -> Bool {
    (lhs.createdAt, lhs.order, lhs.id.uuidString) < (rhs.createdAt, rhs.order, rhs.id.uuidString)
  }

  // MARK: - Импорт follow-up

  /// Открывает диалог «Импорт follow-up» для встречи (⌘⇧I и кнопка в инспекторе).
  public func beginFollowupImport(meetingID: UUID, generate: Bool = false) {
    followupStartsGeneration = generate
    followupImportMeetingID = meetingID
  }

  /// Встреча, для которой можно импортировать follow-up: открытая, с транскриптом.
  public var canImportFollowup: Bool {
    guard let id = selectedMeetingID else { return false }
    return transcripts[id] != nil || library.meeting(id: id)?.hasTranscript == true
  }

  /// Записывает выбранные пункты ответа модели в память проекта. `nil` — встречи нет или она вне
  /// проекта (об этом сообщает `alert`: без проекта записи негде хранить).
  @discardableResult
  public func importFollowup(
    _ parsed: ParsedFollowup,
    meetingID: UUID,
    source: FollowupSource = .pasted,
    rawText: String? = nil,
    include: FollowupSelection
  ) -> FollowupImportSummary? {
    guard let record = library.meeting(id: meetingID) else { return nil }
    guard let projectID = record.projectID else {
      alert = AppAlert(
        title: String(localized: "Встреча не в проекте"),
        message:
          String(
            localized:
              "Решения и задачи хранятся в проекте: он объединяет встречи и даёт контекст следующим экспортам. Выберите проект в диалоге импорта follow-up или переместите встречу в проект из боковой панели."
          ))
      return nil
    }
    let meetingDate = record.date ?? record.createdAt
    // Тот же текст у той же встречи — повторная вставка одного ответа: запись истории не удваивается,
    // новые пункты (если появились) привязываются к ней.
    let text = Self.cleaned(rawText)
    let existing = text.flatMap { text in
      library.followups(for: meetingID).first { Self.cleaned($0.rawText) == text }
    }
    let followup = FollowupRecord(
      id: existing?.id ?? UUID(),
      projectID: projectID,
      meetingID: meetingID,
      importedAt: existing?.importedAt ?? Date(),
      source: source,
      method: parsed.method.rawValue,
      summary: parsed.summary ?? existing?.summary,
      rawText: rawText)

    // Повтором считается тот же текст в том же роде записей этой встречи: повторный импорт одного
    // ответа модели ничего не удваивает, а вопрос, дословно повторяющий задачу, остаётся вопросом.
    var knownDecisions = Set(decisions(for: meetingID).map(\.text).map(Self.duplicateKey))
    var knownActions = Set(actionItems(for: meetingID).map(\.text).map(Self.duplicateKey))
    var knownQuestions = Set(questions(for: meetingID).map(\.text).map(Self.duplicateKey))
    var skipped = 0

    var addedDecisions = 0
    for (order, item) in include.decisions.enumerated() {
      guard let text = Self.cleaned(item.text) else { continue }
      guard knownDecisions.insert(Self.duplicateKey(text)).inserted else {
        skipped += 1
        continue
      }
      let parsedDecision =
        parsed.decisions.indices.contains(item.index)
        ? parsed.decisions[item.index] : nil
      library.upsert(
        DecisionRecord(
          projectID: projectID,
          meetingID: meetingID,
          followupID: followup.id,
          text: text,
          timestamp: parsedDecision?.timestamp,
          meetingDate: meetingDate,
          order: order))
      addedDecisions += 1
    }

    var addedActions = 0
    for (order, item) in include.actions.enumerated() {
      guard let text = Self.cleaned(item.text) else { continue }
      guard knownActions.insert(Self.duplicateKey(text)).inserted else {
        skipped += 1
        continue
      }
      let owner = Self.cleaned(item.owner)
      let due = Self.cleaned(item.due)
      library.upsert(
        ActionItemRecord(
          projectID: projectID,
          meetingID: meetingID,
          followupID: followup.id,
          text: text,
          owner: owner,
          ownerPersonID: owner.flatMap { library.person(named: $0)?.id },
          due: Self.isoDay(due),
          dueText: Self.isoDay(due) == nil ? due : nil,
          meetingDate: meetingDate,
          order: order))
      addedActions += 1
    }

    var addedQuestions = 0
    for (order, item) in include.questions.enumerated() {
      guard let text = Self.cleaned(item.text) else { continue }
      guard knownQuestions.insert(Self.duplicateKey(text)).inserted else {
        skipped += 1
        continue
      }
      library.upsert(
        QuestionRecord(
          projectID: projectID,
          meetingID: meetingID,
          followupID: followup.id,
          text: text,
          meetingDate: meetingDate,
          order: order))
      addedQuestions += 1
    }

    // Текст ответа — это и есть история проекта: новый текст записывается всегда, повторная
    // вставка того же текста переиспользует запись, а без текста (локальная модель, тест) запись
    // появляется только если что-то принесла или есть резюме.
    let addedAnything = addedDecisions + addedActions + addedQuestions > 0
    let textSaved = text != nil
    if existing != nil {
      if addedAnything || (followup.summary != nil && existing?.summary == nil) {
        library.upsert(followup)
      }
    } else if textSaved || addedAnything || Self.cleaned(parsed.summary) != nil {
      library.upsert(followup)
    }
    saveLibrary()
    return FollowupImportSummary(
      followupID: followup.id, decisions: addedDecisions, actions: addedActions,
      questions: addedQuestions, skipped: skipped, textSaved: textSaved)
  }

  // MARK: - История follow-up

  /// Follow-up проекта по хронологии встреч: дата встречи, затем время сохранения. Так follow-up
  /// прошлой и текущей встречи стоят рядом и сравниваются по датам и названиям.
  public func followupTimeline(projectID: UUID) -> [FollowupTimelineEntry] {
    library.followups(in: projectID)
      .map { followup in
        let meeting = library.meeting(id: followup.meetingID)
        return FollowupTimelineEntry(
          followup: followup,
          meetingTitle: meeting?.title ?? String(localized: "встреча удалена"),
          meetingDate: meeting.map { $0.date ?? $0.createdAt },
          decisions: library.decisions.filter { $0.followupID == followup.id }.count,
          actions: library.actionItems.filter { $0.followupID == followup.id }.count,
          questions: library.questions.filter { $0.followupID == followup.id }.count)
      }
      .sorted { lhs, rhs in
        (lhs.meetingDate ?? lhs.followup.importedAt, lhs.followup.importedAt, lhs.id.uuidString)
          < (rhs.meetingDate ?? rhs.followup.importedAt, rhs.followup.importedAt, rhs.id.uuidString)
      }
  }

  /// Открывает историю follow-up проекта; `followupID` — какую запись показать первой.
  public func beginFollowupHistory(projectID: UUID, selecting followupID: UUID? = nil) {
    followupHistorySelectedID = followupID
    followupHistoryProjectID = projectID
  }

  /// История доступна, когда открытая встреча лежит в проекте.
  public var canShowFollowupHistory: Bool {
    selectedMeeting?.projectID != nil
  }

  /// Импорт из диалога: записи, открытый инспектор «Контекст проекта» и сообщение с итогом.
  @discardableResult
  public func finishFollowupImport(
    _ parsed: ParsedFollowup,
    meetingID: UUID,
    source: FollowupSource = .pasted,
    rawText: String? = nil,
    include: FollowupSelection
  ) -> FollowupImportSummary? {
    guard
      let summary = importFollowup(
        parsed, meetingID: meetingID, source: source, rawText: rawText, include: include)
    else { return nil }
    followupImportMeetingID = nil
    followupStartsGeneration = false
    if selectedMeetingID != meetingID { selectMeeting(meetingID) }
    inspectorTab = .projectContext
    isInspectorPresented = true
    alert = AppAlert(title: String(localized: "Follow-up добавлен"), message: summary.message)
    return summary
  }

  /// Отменяет импорт целиком: акт и всё, что он принёс.
  public func removeFollowupImport(_ followupID: UUID) {
    library.removeImport(followupID: followupID)
    saveLibrary()
  }

  // MARK: - Правка записей памяти

  public func setActionItemDone(_ id: UUID, _ done: Bool) {
    guard var item = library.actionItem(id: id), item.isOpen == done else { return }
    item.status = done ? .done : .open
    item.completedAt = done ? Date() : nil
    library.upsert(item)
    saveLibrary()
  }

  public func setQuestionAnswered(_ id: UUID, _ answered: Bool) {
    guard var question = library.question(id: id), question.isOpen == answered else { return }
    question.status = answered ? .answered : .open
    question.answeredAt = answered ? Date() : nil
    library.upsert(question)
    saveLibrary()
  }

  public func updateDecision(_ id: UUID, text: String) {
    guard var decision = library.decision(id: id), let text = Self.cleaned(text),
      decision.text != text
    else { return }
    decision.text = text
    library.upsert(decision)
    saveLibrary()
  }

  public func updateActionItem(_ id: UUID, text: String) {
    guard var item = library.actionItem(id: id), let text = Self.cleaned(text), item.text != text
    else { return }
    item.text = text
    library.upsert(item)
    saveLibrary()
  }

  public func updateActionItem(_ id: UUID, owner: String?, due: String?) {
    guard var item = library.actionItem(id: id) else { return }
    let owner = Self.cleaned(owner)
    let due = Self.cleaned(due)
    item.owner = owner
    item.ownerPersonID = owner.flatMap { library.person(named: $0)?.id }
    item.due = Self.isoDay(due)
    item.dueText = item.due == nil ? due : nil
    library.upsert(item)
    saveLibrary()
  }

  public func updateQuestion(_ id: UUID, text: String) {
    guard var question = library.question(id: id), let text = Self.cleaned(text),
      question.text != text
    else { return }
    question.text = text
    library.upsert(question)
    saveLibrary()
  }

  public func deleteDecision(_ id: UUID) {
    library.removeDecision(id: id)
    saveLibrary()
  }

  public func deleteActionItem(_ id: UUID) {
    library.removeActionItem(id: id)
    saveLibrary()
  }

  public func deleteQuestion(_ id: UUID) {
    library.removeQuestion(id: id)
    saveLibrary()
  }

  // MARK: - Переход к реплике

  /// «Перейти к реплике» из записи памяти: встреча выбирается, транскрипт может ещё грузиться —
  /// тогда переход откладывается до появления строк (`refreshRows`).
  public func open(decision id: UUID) {
    guard let decision = library.decision(id: id) else { return }
    open(meetingID: decision.meetingID, timecode: decision.timestamp)
  }

  public func open(meetingID: UUID?, timecode: Double?) {
    guard let meetingID, library.meeting(id: meetingID) != nil else { return }
    if selectedMeetingID != meetingID { selectMeeting(meetingID) }
    guard let timecode else { return }
    if displayRows.isEmpty {
      pendingTimecode = timecode
    } else {
      goToTimecode(timecode)
    }
  }

  // MARK: - Общее

  /// Текст без пробелов по краям; пустой — `nil`.
  static func cleaned(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return text
  }

  /// Ключ сравнения на повтор: регистр, пробелы и знаки препинания по краям не считаются различием.
  static func duplicateKey(_ text: String) -> String {
    text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!? "))
  }

  /// «2026-09-10» — день ISO 8601; всё остальное остаётся сырым текстом срока.
  static func isoDay(_ text: String?) -> String? {
    guard let text, text.count == 10 else { return nil }
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.allSatisfy(\.isNumber) }), let month = Int(parts[1]),
      let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    return text
  }
}
