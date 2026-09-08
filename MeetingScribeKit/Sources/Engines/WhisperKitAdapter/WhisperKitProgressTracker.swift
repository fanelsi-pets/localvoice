import Core
import Foundation
import Synchronization
import WhisperKit

/// Состояние прогресса одного вызова распознавания.
///
/// Зачем отдельный объект (CLAUDE.md, SPEC.md §3.7):
/// - `WhisperKit.progress` живёт только внутри одного вызова и обнуляется — секунды обработанного аудио копим сами
///   по готовым сегментам из `segmentCallback`;
/// - секунды не должны уменьшаться, а колбэки приходят из нескольких воркеров разом — держим максимум под `Mutex`;
/// - пульс — таймкод и текст **одного** сегмента: токенный колбэк отдаёт фразу одного воркера, а накопленные
///   секунды относятся к другому, такая пара вводила бы в заблуждение;
/// - `Task.isCancelled` внутри `@Sendable`-колбэка относится к чужой задаче, поэтому отмену храним флагом,
///   который выставляет `withTaskCancellationHandler`.
final class WhisperKitProgressTracker: Sendable {
  private struct State {
    var processedAudioSeconds: Double = 0
    var lastLivenessAt: Double = -.greatestFiniteMagnitude
    var isCancelled = false
  }

  let totalAudioSeconds: Double
  /// Смещение куска относительно начала записи: таймкод в событии всегда абсолютный.
  let timeOffset: Double
  /// Минимальный интервал между событиями живости: токенный колбэк декодера зовётся на каждый токен.
  let livenessInterval: Double

  private let state = Mutex(State())

  init(totalAudioSeconds: Double, timeOffset: Double = 0, livenessInterval: Double = 0.25) {
    self.totalAudioSeconds = max(0, totalAudioSeconds)
    self.timeOffset = timeOffset
    self.livenessInterval = livenessInterval
  }

  // MARK: - Отмена

  var isCancelled: Bool { state.withLock { $0.isCancelled } }

  func cancel() { state.withLock { $0.isCancelled = true } }

  // MARK: - События

  /// Событие по концам найденных сегментов (секунды от начала переданного куска), без пульса.
  func event(forSegmentEnds ends: [Double]) -> ProgressEvent? {
    guard let maximum = ends.max() else { return nil }
    return event(
      processed: advance(to: maximum), timecode: timeOffset + max(maximum, 0), pulse: nil)
  }

  /// Событие по найденным сегментам: секунды — максимум концов (монотонно), пульс — текст сегмента
  /// с наибольшим концом и его абсолютный таймкод (согласованная пара, SPEC.md §3.7 п. 4).
  func event(for segments: [TranscriptionSegment]) -> ProgressEvent? {
    guard let last = segments.max(by: { $0.end < $1.end }) else { return nil }
    let end = Double(last.end)
    let text = WhisperKitMapping.cleanText(last.text)
    return event(
      processed: advance(to: end), timecode: timeOffset + max(end, 0),
      pulse: text.isEmpty ? nil : text)
  }

  /// Живость по токенному колбэку: секунды и таймкод — последние известные, текста нет (см. заголовок).
  func livenessEvent(now: Double = Date().timeIntervalSinceReferenceDate) -> ProgressEvent? {
    let processed = state.withLock { state -> Double? in
      guard now - state.lastLivenessAt >= livenessInterval else { return nil }
      state.lastLivenessAt = now
      return state.processedAudioSeconds
    }
    guard let processed else { return nil }
    return event(processed: processed, timecode: timeOffset + processed, pulse: nil)
  }

  /// Завершающее событие: стадия закрыта целиком.
  func completionEvent() -> ProgressEvent {
    let processed = state.withLock { state -> Double in
      state.processedAudioSeconds = max(state.processedAudioSeconds, totalAudioSeconds)
      return state.processedAudioSeconds
    }
    return event(processed: processed, timecode: timeOffset + processed, pulse: nil)
  }

  private func advance(to end: Double) -> Double {
    state.withLock { state -> Double in
      let clamped = totalAudioSeconds > 0 ? min(max(end, 0), totalAudioSeconds) : max(end, 0)
      state.processedAudioSeconds = max(state.processedAudioSeconds, clamped)
      return state.processedAudioSeconds
    }
  }

  private func event(processed: Double, timecode: Double, pulse: String?) -> ProgressEvent {
    ProgressEvent(
      stage: .transcription,
      processedAudioSeconds: processed,
      totalAudioSeconds: totalAudioSeconds > 0 ? totalAudioSeconds : nil,
      timecode: timecode,
      pulse: pulse
    )
  }
}
