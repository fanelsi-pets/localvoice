import Core
import Foundation
import Store
import SwiftUI

/// Где ищет поле поиска (SPEC.md §2 п. 6): по репликам открытой встречи или по всей библиотеке.
nonisolated public enum SearchScope: String, CaseIterable, Hashable, Sendable {
  case meeting
  case library

  public var title: String {
    switch self {
    case .meeting: String(localized: "Встреча")
    case .library: String(localized: "Библиотека")
    }
  }

  /// Подсказка в поле поиска.
  public var prompt: String {
    switch self {
    case .meeting: String(localized: "Поиск по репликам")
    case .library: String(localized: "Поиск по всем встречам, решениям и задачам")
    }
  }
}

/// Строка выдачи поиска по библиотеке: найденное место плюс всё, что нужно показать, — вью не ходит
/// в библиотеку за названиями и именами.
nonisolated public struct LibrarySearchResult: Identifiable, Hashable, Sendable {
  public var hit: SearchHit
  public var meetingTitle: String
  public var meetingDate: Date?
  /// Имя спикера реплики; `nil` — найдено не в репликах.
  public var speakerName: String?
  public var kindTitle: String

  public init(
    hit: SearchHit, meetingTitle: String, meetingDate: Date? = nil, speakerName: String? = nil,
    kindTitle: String
  ) {
    self.hit = hit
    self.meetingTitle = meetingTitle
    self.meetingDate = meetingDate
    self.speakerName = speakerName
    self.kindTitle = kindTitle
  }

  public var id: String { hit.id }

  /// Иконка вида найденного (DESIGN.md §7).
  public var systemImage: String {
    switch hit.kind {
    case .utterance: "text.quote"
    case .decision: "checkmark.seal"
    case .actionItem: "checkmark.square"
    case .question: "questionmark.circle"
    }
  }

  /// Текст с подсветкой найденного — как в строке транскрипта.
  public var highlightedText: AttributedString {
    var attributed = AttributedString(hit.text)
    for range in hit.highlights {
      guard let bounds = Range(range, in: attributed) else { continue }
      attributed[bounds].font = .body.bold()
      attributed[bounds].foregroundColor = .accentColor
    }
    return attributed
  }
}

/// Поиск по библиотеке (SPEC.md §3.6): запрос уходит в FTS5-индекс `LibraryStore`, ввод гасится
/// задержкой, устаревшие ответы отбрасываются.
extension AppModel {

  /// Задержка перед запросом: пользователь печатает быстрее, чем стоит ходить в базу.
  static let searchDebounce: Duration = .milliseconds(150)

  func searchTextChanged() {
    switch searchScope {
    case .meeting: refreshRows()
    case .library: scheduleLibrarySearch()
    }
  }

  func searchScopeChanged() {
    switch searchScope {
    case .meeting:
      librarySearchTask?.cancel()
      librarySearchTask = nil
      libraryResults = []
      isSearchingLibrary = false
      refreshRows()
    case .library:
      scheduleLibrarySearch()
    }
  }

  /// ⌘⇧F — искать по всей библиотеке, курсор в поле поиска.
  public func focusLibrarySearch() {
    searchScope = .library
    focusSearch()
  }

  /// Показывать выдачу вместо экрана встречи.
  public var showsLibraryResults: Bool {
    searchScope == .library && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func scheduleLibrarySearch() {
    librarySearchTask?.cancel()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      librarySearchTask = nil
      libraryResults = []
      isSearchingLibrary = false
      return
    }
    isSearchingLibrary = true
    librarySearchTask = Task { [weak self] in
      try? await Task.sleep(for: AppModel.searchDebounce)
      guard !Task.isCancelled, let self else { return }
      do {
        let hits = try await store.search(query)
        // Ответ мог устареть, пока шёл запрос: применяем только результат текущего запроса.
        guard !Task.isCancelled, self.searchScope == .library,
          self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else { return }
        self.libraryResults = hits.map { self.result(for: $0) }
        self.isSearchingLibrary = false
      } catch {
        guard !Task.isCancelled else { return }
        self.libraryResults = []
        self.isSearchingLibrary = false
        self.alert = AppAlert(
          title: String(localized: "Поиск не выполнился"), message: error.localizedDescription)
      }
    }
  }

  func result(for hit: SearchHit) -> LibrarySearchResult {
    let record = hit.meetingID.flatMap { library.meeting(id: $0) }
    var speakerName: String?
    let kindTitle: String
    switch hit.kind {
    case .utterance(_, _, _, let speakerID):
      kindTitle = String(localized: "Реплика")
      speakerName =
        speakerID.flatMap { record?.speakerNames[$0] }
        ?? SpeakerStats.placeholderName(for: speakerID)
    case .decision: kindTitle = String(localized: "Решение")
    case .actionItem: kindTitle = String(localized: "Задача")
    case .question: kindTitle = String(localized: "Вопрос")
    }
    return LibrarySearchResult(
      hit: hit,
      meetingTitle: record?.title ?? String(localized: "Встреча удалена"),
      meetingDate: record?.date ?? record?.createdAt,
      speakerName: speakerName,
      kindTitle: kindTitle)
  }

  /// Переход по результату: реплика — к строке транскрипта (подсветка запроса остаётся, если он её
  /// не прячет), запись памяти — к встрече с открытым инспектором «Контекст проекта».
  public func open(_ result: LibrarySearchResult) {
    let query = searchText
    switch result.hit.kind {
    case .utterance(let index, let start, _, _):
      guard let meetingID = result.hit.meetingID, library.meeting(id: meetingID) != nil else {
        return
      }
      selectMeeting(meetingID)
      searchScope = .meeting
      // Запрос библиотеки остаётся фильтром встречи только пока он не прячет саму реплику:
      // FTS ищет префиксы слов через AND, а фильтр — подстроку целиком (`revealRow`).
      searchText = query
      guard transcripts[meetingID] != nil else {
        // Транскрипт ещё грузится: переход выполнит `applyPendingNavigation`, когда появятся строки.
        pendingScrollIndex = index
        pendingTimecode = start
        return
      }
      if revealRow(index) {
        selectedRowID = index
        scrollTarget = index
      } else {
        goToTimecode(start)
      }
    case .decision, .actionItem, .question:
      openMemoryRecord(result)
    }
  }

  /// Запись памяти: открываем её встречу, а если встречу удалили — последнюю встречу того же проекта
  /// (инспектор без встречи показал бы «Выберите встречу»). Если встреч у проекта не осталось,
  /// объясняем, где запись живёт.
  private func openMemoryRecord(_ result: LibrarySearchResult) {
    if let meetingID = result.hit.meetingID, library.meeting(id: meetingID) != nil {
      selectMeeting(meetingID)
      searchScope = .meeting
      searchText = ""
      inspectorTab = .projectContext
      isInspectorPresented = true
      return
    }
    let projectID = result.hit.projectID
    let latest =
      projectID
      .map { library.meetings(in: $0) }?
      .max { ($0.date ?? $0.createdAt) < ($1.date ?? $1.createdAt) }
    guard let latest else {
      let name = projectID.flatMap { library.project(id: $0)?.name }
      alert = AppAlert(
        title: String(localized: "Встреча удалена"),
        message: name.map { String(localized: "Запись осталась в памяти проекта «\($0)».") }
          ?? String(localized: "Запись осталась в памяти проекта."))
      return
    }
    selectMeeting(latest.id)
    searchScope = .meeting
    searchText = ""
    inspectorTab = .projectContext
    isInspectorPresented = true
  }
}
