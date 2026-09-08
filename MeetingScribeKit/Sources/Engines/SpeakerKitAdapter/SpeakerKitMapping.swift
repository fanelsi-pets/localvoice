import Core
import Foundation
import SpeakerKit

/// Перевод результатов SpeakerKit в модели Core. Чистые функции: тестируются без загрузки моделей.
///
/// Внутри модуля имена `Diarizer` и `DiarizationResult` есть и в Core, и в SpeakerKit — Core-типы квалифицируем.
enum SpeakerKitMapping {
  /// Отрезки речи одного спикера.
  ///
  /// Сегменты без единственного спикера (`noMatch`, `multiple`) пропускаем: `Turn` требует конкретного `speakerID`,
  /// а наложения речи размечает `Fuser`. Никакой другой постобработки нет — осколки и склейки это фаза 1,
  /// цифры должны совпадать с сырым выводом в docs/BENCH-2026-09-02.md.
  static func turns(_ segments: [SpeakerSegment]) -> [Turn] {
    segments
      .compactMap { segment -> Turn? in
        guard let speakerID = segment.speaker.speakerId else { return nil }
        return Turn(
          start: Double(segment.startTime),
          end: Double(segment.endTime),
          speakerID: speakerID
        )
      }
      .sorted { ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID) }
  }

  /// Подсказки в параметры pyannote.
  ///
  /// `minSpeakers`/`maxSpeakers` SpeakerKit не поддерживает: у `PyannoteDiarizationOptions` есть только точное
  /// `numberOfSpeakers` (PyannoteConfig.swift:129–156). Диапазон игнорируем осознанно.
  /// `allowOverlappingTurns` выключает эксклюзивное присвоение: без него кадр может принадлежать нескольким
  /// спикерам (PyannoteDiarizer.swift:343), и turn'ы перекрываются — наложения размечает `Fuser`.
  static func options(for hints: DiarizationHints) -> PyannoteDiarizationOptions {
    PyannoteDiarizationOptions(
      numberOfSpeakers: hints.expectedSpeakers,
      useExclusiveReconciliation: !hints.allowOverlappingTurns,
      centroidSource: .finalAssignment
    )
  }
}
