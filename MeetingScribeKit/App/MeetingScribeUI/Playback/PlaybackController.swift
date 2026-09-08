import AVFoundation
import Core
import Foundation
import Observation
import Store

/// Воспроизведение записи встречи (DESIGN.md §3): клик по таймкоду играет фрагмент, пробел — play/pause,
/// позиция плеера видна на timeline. Источник — исходный файл пользователя; если его нет (переместили,
/// внешний диск), играем кэш `audio16k.wav` из папки встречи.
///
/// Колбэки AVFoundation приходят с очереди наблюдателя: наблюдатели вешаются на `.main`, значение
/// переносится в состояние через `MainActor.assumeIsolated` — так интерфейс не читает поля из другого потока.
@Observable
public final class PlaybackController {
  /// Текущая позиция, с.
  public private(set) var currentTime: Double = 0
  public private(set) var isPlaying = false
  /// Есть ли что играть: файл найден и открыт.
  public private(set) var isAvailable = false
  /// Почему играть нечего — показывается вместо кнопки.
  public private(set) var unavailableReason: String?
  /// Встреча, для которой загружен плеер.
  public private(set) var meetingID: UUID?
  /// Длительность записи по плееру, с (0 — ещё не известна).
  public private(set) var duration: Double = 0

  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var boundaryObserver: Any?
  @ObservationIgnored private var url: URL?
  /// Открытый доступ к исходнику по закладке (песочница хоста, ADR-010) — закрывается в `unload()`.
  @ObservationIgnored private var sourceAccess: SourceAccess?

  public init() {}

  // Отдельного `deinit` нет: наблюдатели живут внутри `AVPlayer`, и вместе с ним освобождаются;
  // явная очистка — в `unload()` (смена встречи или удаление записи).

  /// Готовит плеер для встречи: исходный файл, иначе кэш `audio16k.wav`, иначе — недоступно с причиной.
  /// Ничего не делает, если та же встреча уже загружена. `sourceAccess` открывает доступ к исходнику по
  /// закладке в песочнице хоста (ADR-010) — вызывается только когда плеер действительно загружается.
  public func load(
    record: MeetingRecord, cachedAudio: URL?, sourceAccess: () -> SourceAccess? = { nil }
  ) {
    guard meetingID != record.id else { return }
    unload()
    meetingID = record.id
    self.sourceAccess = sourceAccess()
    let candidates = [record.sourceURL, cachedAudio].compactMap { $0 }
    guard
      let url = candidates.first(where: {
        FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
      })
    else {
      isAvailable = false
      unavailableReason =
        String(
          localized:
            "Файл записи не найден: \(record.sourceURL.path(percentEncoded: false)). Верните файл на место или импортируйте запись заново."
        )
      return
    }
    self.url = url
    let player = AVPlayer(url: url)
    self.player = player
    isAvailable = true
    unavailableReason = nil
    duration = record.duration ?? 0
    observeTime(of: player)
  }

  /// Играет фрагмент `[from, to)`; `to == nil` — до конца записи.
  public func play(from start: Double, to end: Double? = nil) {
    guard let player else { return }
    removeBoundaryObserver()
    let time = CMTime(seconds: max(start, 0), preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    currentTime = max(start, 0)
    if let end, end > start {
      let stop = CMTime(seconds: end, preferredTimescale: 600)
      boundaryObserver = player.addBoundaryTimeObserver(
        forTimes: [NSValue(time: stop)], queue: .main
      ) { [self] in
        MainActor.assumeIsolated {
          self.pause()
          self.removeBoundaryObserver()
        }
      }
    }
    player.play()
    isPlaying = true
  }

  public func togglePlayPause() {
    guard let player else { return }
    if isPlaying {
      pause()
    } else {
      player.play()
      isPlaying = true
    }
  }

  public func pause() {
    player?.pause()
    isPlaying = false
  }

  /// Отпускает плеер (смена встречи, удаление записи).
  public func unload() {
    pause()
    removeBoundaryObserver()
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    timeObserver = nil
    player = nil
    url = nil
    sourceAccess?.end()
    sourceAccess = nil
    meetingID = nil
    currentTime = 0
    duration = 0
    isAvailable = false
    unavailableReason = nil
  }

  // MARK: - Внутреннее

  private func observeTime(of player: AVPlayer) {
    let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.currentTime = CMTimeGetSeconds(time)
        if self.duration <= 0, let item = player.currentItem {
          let itemDuration = CMTimeGetSeconds(item.duration)
          if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
        }
        if player.timeControlStatus == .paused, self.isPlaying { self.isPlaying = false }
      }
    }
  }

  private func removeBoundaryObserver() {
    if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
    boundaryObserver = nil
  }
}
