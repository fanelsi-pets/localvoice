import Core
import Export
import Foundation
import LocalLLM
import Observation

/// Генерация follow-up локальной моделью (SPEC.md §3.6). Признаки живости — растущий текст ответа,
/// счётчик символов и прошедшее время (SPEC.md §3.7 п. 4): сколько всего напишет модель, неизвестно,
/// поэтому определённой полосы здесь быть не может, а неопределённая «крутилка» запрещена.
/// Живёт в `AppModel`, а не во вью: диалог можно закрыть, генерация продолжится.
@Observable
public final class FollowupGenerationController {
  public private(set) var isRunning = false
  /// Накопленный ответ модели.
  public private(set) var text = ""
  /// «0:42» — прошедшее время, обновляется раз в секунду.
  public private(set) var elapsedText = "0:00"
  public private(set) var characterCount = 0
  public private(set) var errorText: String?
  /// Генерация закончилась сама (не отменена и без ошибки) — диалогу пора разобрать ответ.
  public private(set) var finishedText: String?

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var ticker: Task<Void, Never>?

  public init() {}

  /// Локальная модель: клиент передаётся параметром — тест подставляет сессию-заглушку.
  public func start(
    prompt: String,
    configuration: LocalLLMConfiguration,
    client: LocalLLMClient = LocalLLMClient()
  ) {
    start(
      prompt: prompt,
      generator: LocalLLMFollowupGenerator(configuration: configuration, client: client))
  }

  /// Запускает поток кусков ответа генератора — локальной модели или провайдера хоста (ADR-010).
  public func start(prompt: String, generator: any FollowupGenerating) {
    guard !isRunning else { return }
    isRunning = true
    text = ""
    characterCount = 0
    errorText = nil
    finishedText = nil
    elapsedText = "0:00"

    let started = ContinuousClock.now
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, self.isRunning, !Task.isCancelled else { return }
        let elapsed = Double((ContinuousClock.now - started).components.seconds)
        self.elapsedText = ProgressPresentation.elapsed(elapsed)
      }
    }

    task = Task { [weak self] in
      do {
        for try await delta in generator.generate(prompt: prompt) {
          guard let self, !Task.isCancelled else { return }
          self.text += delta
          self.characterCount = self.text.count
        }
        guard let self, !Task.isCancelled else { return }
        if self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          self.errorText = LocalLLMError.emptyAnswer.localizedDescription
        } else {
          self.finishedText = self.text
        }
      } catch is CancellationError {
        // Отмена пользователем: уже собранный текст остаётся в поле, сообщения об ошибке нет.
      } catch LocalLLMError.cancelled {
      } catch {
        self?.errorText = error.localizedDescription
      }
      self?.finish()
    }
  }

  /// «Отменить»: поток обрывается, набранный текст остаётся пользователю.
  public func cancel() {
    task?.cancel()
    task = nil
    finish()
  }

  /// Забыть последний ответ (диалог закрылся или текст уже разобран).
  public func reset() {
    cancel()
    text = ""
    characterCount = 0
    errorText = nil
    finishedText = nil
    elapsedText = "0:00"
  }

  private func finish() {
    ticker?.cancel()
    ticker = nil
    isRunning = false
  }

  /// «Генерация · прошло 0:42 · 1 234 символа» — строка живости для диалога.
  public var statusText: String {
    String(localized: "Генерация · прошло \(elapsedText) · \(characterCount) символов")
  }
}

extension AppModel {
  /// Генератор для кнопок «Создать follow-up»: провайдер хоста, если задан (LocalVoice — Gemini, ADR-010),
  /// иначе локальная модель, если включена в настройках; `nil` — кнопок нет.
  public var activeFollowupGenerator: (any FollowupGenerating)? {
    if let followupGenerator { return followupGenerator }
    guard settings.localLLMEnabled else { return nil }
    return LocalLLMFollowupGenerator(configuration: settings.localLLMConfiguration)
  }

  /// «Создать follow-up»: промпт — инструкция владельца проекта на выбранном языке
  /// (`FollowupGenerationPrompt`) плюс TranscribeFull без собственной инструкции экспорта. Транскрипт
  /// уходит только выбранному генератору.
  public func startFollowupGeneration(meetingID: UUID) {
    // Без генератора хоста и с выключенной локальной моделью запуск (⌘-команда, тест) объясняет, что включить.
    let generator =
      activeFollowupGenerator
      ?? LocalLLMFollowupGenerator(configuration: settings.localLLMConfiguration)
    guard generator.isAvailable else {
      alert = AppAlert(
        title: generator is LocalLLMFollowupGenerator
          ? String(localized: "Локальная модель не настроена")
          : String(localized: "Генератор недоступен"),
        message: generator.unavailableReason)
      return
    }
    guard let transcript = renderMarkdown(for: meetingID, includeFollowupPrompt: false) else {
      alert = AppAlert(
        title: String(localized: "Нечего отправлять"),
        message: String(localized: "У встречи ещё нет транскрипта: обработайте запись и повторите.")
      )
      return
    }
    let prompt = FollowupGenerationPrompt.render(
      language: settings.followupLanguage, transcript: transcript)
    followupGeneration.start(prompt: prompt, generator: generator)
  }
}
