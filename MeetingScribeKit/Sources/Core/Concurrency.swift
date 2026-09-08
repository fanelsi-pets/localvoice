import Foundation

// Примитивы для адаптеров движков: один экземпляр модели обслуживает много вызовов (в приложении — несколько
// встреч в очереди, предпрослушка), а отмена обязана срабатывать за 2 секунды на любой стадии (SPEC.md §3.7 п. 7),
// в том числе пока вызов ещё ждёт своей очереди или загрузки моделей.

/// Строгая очередь к одному ресурсу: вызовы идут по одному в порядке обращения. Ожидание отменяемо —
/// отменённый ждущий выходит сразу с `CancellationError`, не дожидаясь конца текущего вызова.
public actor SerialGate {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var isBusy = false
  private var waiters: [Waiter] = []

  public init() {}

  /// Занимает ресурс. Бросает `CancellationError`, если задача отменена во время ожидания или к моменту входа.
  public func acquire() async throws {
    if isBusy {
      let id = UUID()
      let granted: Bool = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
          // Пока задача добиралась сюда, ресурс могли освободить — актор реентерабелен.
          if isBusy {
            waiters.append(Waiter(id: id, continuation: continuation))
          } else {
            isBusy = true
            continuation.resume(returning: true)
          }
        }
      } onCancel: {
        Task { await self.withdraw(id) }
      }
      guard granted else { throw CancellationError() }
    } else {
      isBusy = true
    }
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }

  /// Освобождает ресурс и передаёт его первому ждущему.
  public func release() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      waiters.removeFirst().continuation.resume(returning: true)
    }
  }

  private func withdraw(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }

  public var isIdle: Bool { !isBusy && waiters.isEmpty }
  public var waitingCount: Int { waiters.count }
}

/// Одноразовая общая загрузка (моделей) для многих ожидающих: тело выполняется один раз, остальные ждут исхода.
/// Ожидание отменяемо, но отмена одного ждущего не прерывает загрузку для остальных — она доводится до конца
/// и переиспользуется (модель на 1.6 GB не грузится дважды). После ошибки следующий вызов запускает загрузку заново.
public actor SharedLoader {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Result<Void, any Error>, Never>
  }

  private var isLoaded = false
  private var inProgress = false
  private var lastFailure: (any Error)?
  private var waiters: [Waiter] = []

  public init() {}

  public var loaded: Bool { isLoaded }

  /// Выполняет `body` один раз; параллельные и последующие вызовы ждут того же результата.
  public func load(_ body: @escaping @Sendable () async throws -> Void) async throws {
    if isLoaded { return }
    if !inProgress {
      inProgress = true
      lastFailure = nil
      // Несвязанная задача: отмена ждущих её не касается.
      Task {
        let outcome: Result<Void, any Error>
        do {
          try await body()
          outcome = .success(())
        } catch {
          outcome = .failure(error)
        }
        await self.finish(outcome)
      }
    }
    let id = UUID()
    let outcome: Result<Void, any Error> = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<Result<Void, any Error>, Never>) in
        if isLoaded {
          continuation.resume(returning: .success(()))
        } else if !inProgress {
          continuation.resume(returning: .failure(lastFailure ?? CancellationError()))
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.withdraw(id) }
    }
    try outcome.get()
  }

  private func finish(_ outcome: Result<Void, any Error>) {
    inProgress = false
    switch outcome {
    case .success: isLoaded = true
    case .failure(let error): lastFailure = error
    }
    let pending = waiters
    waiters = []
    for waiter in pending {
      waiter.continuation.resume(returning: outcome)
    }
  }

  private func withdraw(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: .failure(CancellationError()))
  }
}
