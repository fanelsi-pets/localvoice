import Core
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

  /// Запускает поток дельт. Клиент передаётся параметром: тест подставляет сессию-заглушку.
  public func start(
    prompt: String,
    configuration: LocalLLMConfiguration,
    client: LocalLLMClient = LocalLLMClient()
  ) {
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
        for try await delta in client.streamChat(prompt: prompt, configuration: configuration) {
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
  /// «Сгенерировать локально»: промпт — тот же TranscribeFull, который пользователь отдал бы внешней
  /// модели (с инструкцией follow-up в конце). Транскрипт уходит только на адрес из настроек.
  public func startFollowupGeneration(meetingID: UUID) {
    guard let configuration = settings.localLLMConfiguration else {
      alert = AppAlert(
        title: String(localized: "Локальная модель не настроена"),
        message:
          String(
            localized:
              "Включите её в «Настройки → Follow-up», укажите адрес сервера (LM Studio или Ollama) и выберите модель."
          ))
      return
    }
    guard let prompt = renderMarkdown(for: meetingID) else {
      alert = AppAlert(
        title: String(localized: "Нечего отправлять"),
        message: String(localized: "У встречи ещё нет транскрипта: обработайте запись и повторите.")
      )
      return
    }
    followupGeneration.start(prompt: prompt, configuration: configuration)
  }
}
