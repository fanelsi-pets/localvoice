import Core
import Export
import Foundation
import Observation
import Store

/// Что уходит в vault: проект открытой встречи (`nil` — встречи без проекта) или вся библиотека.
nonisolated public enum VaultScope: Hashable, Sendable {
  case project(UUID?)
  case library
}

/// Итог экспорта vault: сколько заметок записано и куда.
nonisolated public struct VaultExportSummary: Hashable, Sendable {
  public var fileCount: Int
  /// Корень `vault/` внутри выбранной папки.
  public var root: URL

  public init(fileCount: Int, root: URL) {
    self.fileCount = fileCount
    self.root = root
  }
}

/// Одна заметка к записи: всё, что нужно работнику, — значениями, без обращения к модели.
nonisolated public struct VaultNoteJob: Sendable {
  public var transcript: Transcript
  public var record: MeetingRecord
  public var projectName: String?
  public var note: ObsidianNote
  public var options: TranscribeFullOptions

  public init(
    transcript: Transcript,
    record: MeetingRecord,
    projectName: String?,
    note: ObsidianNote,
    options: TranscribeFullOptions
  ) {
    self.transcript = transcript
    self.record = record
    self.projectName = projectName
    self.note = note
    self.options = options
  }
}

/// Рендер и запись заметок vault вне главного актора: на сотне встреч рендер и файловые операции
/// заняли бы секунды замороженного интерфейса. Помнит занятые пути за прогон: две встречи одного дня
/// с одинаковым названием («Test Room» дважды за день) иначе легли бы в один файл и перезаписали
/// друг друга.
public actor VaultWriter {
  private var used: Set<String> = []

  public init() {}

  /// Пишет заметку и возвращает её URL. Путь — `vault/<проект>/meetings/YYYY-MM-DD-<slug>.md`,
  /// при совпадении — с различителем: время встречи `HH-mm`, иначе `-2`, `-3`…
  @discardableResult
  public func write(_ job: VaultNoteJob, to directory: URL) throws -> URL {
    let display = AppModel.projected(
      job.transcript, record: job.record, projectName: job.projectName)
    let text = ObsidianVaultExporter.render(display, note: job.note, options: job.options)
    let relative = uniquePath(
      ObsidianVaultExporter.relativePath(
        project: job.projectName, transcript: display, timeZone: job.options.timeZone),
      date: job.record.date, timeZone: job.options.timeZone)
    let url = directory.appending(path: relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
    return url
  }

  /// Свободный путь для заметки: занятые за этот прогон получают различитель.
  private func uniquePath(_ relative: String, date: Date?, timeZone: TimeZone) -> String {
    guard used.contains(relative) else {
      used.insert(relative)
      return relative
    }
    let base = relative.hasSuffix(".md") ? String(relative.dropLast(3)) : relative
    var candidates: [String] = []
    if let date {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = timeZone
      formatter.dateFormat = "HH-mm"
      candidates.append("\(base)-\(formatter.string(from: date)).md")
    }
    candidates += (2...99).map { "\(base)-\($0).md" }
    let path = candidates.first { !used.contains($0) } ?? "\(base)-\(UUID().uuidString).md"
    used.insert(path)
    return path
  }
}

/// Прогресс экспорта vault (SPEC.md §3.7, DESIGN.md §3b): определённая полоса «N из M заметок»,
/// пульс с названием встречи, отмена и итог. Живёт в модели, а не во вью: панель можно закрыть,
/// экспорт продолжится.
@Observable
public final class VaultExportController {
  public private(set) var isExporting = false
  public private(set) var total = 0
  public private(set) var completed = 0
  /// Пульс: название встречи, которая пишется прямо сейчас.
  public private(set) var currentTitle = ""
  public private(set) var errorText: String?
  /// Итог удачного прогона («12 заметок в …/vault»).
  public private(set) var finishedText: String?

  @ObservationIgnored var task: Task<Void, Never>?
  /// Номер прогона: отменённый или вытесненный экспорт не должен дописывать состояние следующего.
  @ObservationIgnored private var runID = 0

  public init() {}

  /// Доля 0…1 — определённая полоса, монотонная по числу записанных заметок.
  public var fraction: Double {
    guard total > 0 else { return 0 }
    return min(max(Double(completed) / Double(total), 0), 1)
  }

  /// «3 из 12 заметок» — подпись под полосой.
  public var statusText: String {
    String(localized: "\(completed) из \(total) заметок")
  }

  /// Начинает прогон и возвращает его номер: обновления принимаются только от него.
  func begin(total: Int) -> Int {
    runID += 1
    self.total = total
    completed = 0
    currentTitle = ""
    errorText = nil
    finishedText = nil
    isExporting = true
    return runID
  }

  func startedNote(title: String, run: Int) {
    guard run == runID else { return }
    currentTitle = title
  }

  func finishedNote(run: Int) {
    guard run == runID else { return }
    completed = min(completed + 1, total)
  }

  func finish(_ text: String?, run: Int) {
    guard run == runID else { return }
    finishedText = text
    currentTitle = ""
    isExporting = false
    task = nil
  }

  func fail(_ text: String, run: Int) {
    guard run == runID else { return }
    errorText = text
    currentTitle = ""
    isExporting = false
    task = nil
  }

  /// «Отменить»: текущая заметка дописывается, следующие не начинаются, а её итог уже не считается.
  public func cancel() {
    runID += 1
    task?.cancel()
    task = nil
    isExporting = false
    currentTitle = ""
  }
}

/// Экспорт vault для Obsidian (SPEC.md §3.6): `vault/<проект>/meetings/YYYY-MM-DD-<slug>.md`
/// с frontmatter и телом заметки. Рендер — в `Export`, файлы пишет `VaultWriter` вне главного актора.
extension AppModel {

  /// Область экспорта по текущему выбору: проект открытой встречи, иначе вся библиотека.
  public var vaultScope: VaultScope {
    if let record = selectedMeeting { return .project(record.projectID) }
    return .library
  }

  /// Есть ли что экспортировать: хотя бы одна встреча области с транскриптом.
  public func canExportVault(_ scope: VaultScope) -> Bool {
    !meetings(in: scope).isEmpty
  }

  func meetings(in scope: VaultScope) -> [MeetingRecord] {
    let records: [MeetingRecord] =
      switch scope {
      case .project(let projectID): library.meetings(in: projectID)
      case .library: library.meetingsNewestFirst
      }
    return records.filter { $0.hasTranscript || transcripts[$0.id] != nil }
  }

  /// «Vault для Obsidian…»: в тестовом режиме пишет в папку экспорта без диалога, иначе просит папку.
  public func beginVaultExport(scope: VaultScope) {
    guard !vaultExport.isExporting else { return }
    guard canExportVault(scope) else {
      alert = AppAlert(
        title: String(localized: "Нечего экспортировать"),
        message: String(localized: "В выбранном проекте нет ни одной обработанной встречи."))
      return
    }
    pendingVaultScope = scope
    if let directory = settings.exportDirectoryOverride {
      pendingVaultScope = nil
      startVaultExport(scope: scope, to: directory)
      return
    }
    isVaultFolderPickerPresented = true
  }

  /// Итог выбора папки в `.fileImporter`.
  public func finishVaultFolderSelection(_ result: Result<URL, any Error>) {
    let scope = pendingVaultScope ?? vaultScope
    pendingVaultScope = nil
    switch result {
    case .success(let directory):
      startVaultExport(scope: scope, to: directory)
    case .failure(let error):
      // «Отмена» в панели — не ошибка: сообщать не о чем, область экспорта уже забыта.
      guard !Self.isUserCancelled(error) else { return }
      alert = AppAlert(
        title: String(localized: "Папка не открылась"), message: error.localizedDescription)
    }
  }

  /// Панель выбора папки закрылась: забываем область, если экспорт так и не начался.
  public func forgetPendingVaultScope() {
    guard !vaultExport.isExporting else { return }
    pendingVaultScope = nil
  }

  /// Отмена в панели файлов приходит ошибкой `CocoaError.userCancelled`.
  nonisolated static func isUserCancelled(_ error: any Error) -> Bool {
    let cocoa = error as NSError
    return cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.userCancelled.rawValue
  }

  /// Запускает экспорт задачей: прогресс и отмена — в `vaultExport`.
  func startVaultExport(scope: VaultScope, to directory: URL) {
    vaultExport.task = Task { [weak self] in
      await self?.exportVault(scope: scope, to: directory)
    }
  }

  /// Пишет заметки встреч области в `directory/vault/<проект>/meetings/`. Возвращает итог; о неудаче
  /// сообщает `alert`. Рендер и запись идут в `VaultWriter` — главный актор свободен между заметками.
  @discardableResult
  public func exportVault(scope: VaultScope, to directory: URL) async -> VaultExportSummary? {
    let records = meetings(in: scope)
    let root = directory.appending(path: "vault", directoryHint: .isDirectory)
    let run = vaultExport.begin(total: records.count)
    let writer = VaultWriter()
    var written = 0
    for record in records {
      guard !Task.isCancelled else {
        vaultExport.finish(cancelledText(written: written, total: records.count), run: run)
        return VaultExportSummary(fileCount: written, root: root)
      }
      vaultExport.startedNote(title: record.title, run: run)
      var transcript = transcripts[record.id]
      if transcript == nil {
        do {
          transcript = try await store.loadTranscript(for: record.id)
        } catch {
          return failVaultExport(
            title: String(localized: "Транскрипт не открылся"), record: record, written: written,
            total: records.count, reason: error.localizedDescription, run: run)
        }
      }
      guard let transcript else {
        vaultExport.finishedNote(run: run)
        continue
      }
      let job = VaultNoteJob(
        transcript: transcript,
        record: record,
        projectName: projectName(for: record),
        note: obsidianNote(for: record),
        options: TranscribeFullOptions(
          tenths: settings.tenthsInTimecodes,
          markOverlap: settings.markOverlap,
          includeFollowupPrompt: false,
          processedAt: record.processedAt,
          timeZone: Self.contextTimeZone))
      do {
        try await writer.write(job, to: directory)
      } catch {
        return failVaultExport(
          title: String(localized: "Заметка не сохранилась"), record: record, written: written,
          total: records.count,
          reason: error.localizedDescription, run: run)
      }
      written += 1
      vaultExport.finishedNote(run: run)
    }
    let message = String(localized: "\(written) заметок в \(root.path(percentEncoded: false))")
    vaultExport.finish(message, run: run)
    // Итог — после закрытия панели: алерт, поставленный в тот же оборот, что и закрытие sheet,
    // система показать не успевает. Задержка не влияет на файлы — они уже записаны.
    try? await Task.sleep(for: .milliseconds(100))
    alert = AppAlert(title: String(localized: "Vault экспортирован"), message: message)
    return VaultExportSummary(fileCount: written, root: root)
  }

  /// Неудача записи: пользователь узнаёт, сколько заметок уже на диске и на какой встрече встали.
  private func failVaultExport(
    title: String, record: MeetingRecord, written: Int, total: Int, reason: String, run: Int
  ) -> VaultExportSummary? {
    let message = String(
      localized:
        "Записано \(written) из \(total) заметок, остановились на «\(record.title)»: \(reason)")
    vaultExport.fail(message, run: run)
    alert = AppAlert(title: title, message: message)
    return nil
  }

  private func cancelledText(written: Int, total: Int) -> String {
    String(localized: "Экспорт отменён: записано \(written) из \(total) заметок")
  }

  /// Итоги встречи для заметки: решения, задачи и вопросы именно этой встречи плюс последнее резюме.
  func obsidianNote(for record: MeetingRecord) -> ObsidianNote {
    ObsidianNote(
      decisions: decisions(for: record.id).map {
        ObsidianNote.Decision(text: $0.text, timestamp: $0.timestamp)
      },
      actionItems: actionItems(for: record.id).map {
        ObsidianNote.ActionItem(
          task: $0.text, assignee: $0.owner, due: $0.dueTitle, status: $0.status.rawValue)
      },
      questions: questions(for: record.id).map(\.text),
      summary: library.followups(for: record.id).compactMap(\.summary).last)
  }
}
