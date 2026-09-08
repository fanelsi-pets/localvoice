import Core
import Foundation

// SRT с именами спикеров (SPEC.md §3.5). Формат зафиксирован golden-файлом
// Tests/ExportTests/Golden/fixture.srt.

public enum SRTExporter {
  /// Один cue на реплику; длинные реплики режутся по словам на куски не длиннее `maxCueSeconds`
  /// и `maxCueCharacters`.
  public static func render(
    _ transcript: Transcript, maxCueSeconds: Double = 7, maxCueCharacters: Int = 120
  ) -> String {
    let names = Dictionary(
      transcript.speakers.map { ($0.speakerID, $0.displayName) },
      uniquingKeysWith: { first, _ in first })
    var blocks: [String] = []
    for utterance in transcript.utterances {
      let name =
        names[utterance.speakerID] ?? SpeakerStats.placeholderName(for: utterance.speakerID)
      for cue in cues(
        for: utterance, maxCueSeconds: maxCueSeconds, maxCueCharacters: maxCueCharacters)
      {
        blocks.append(
          "\(blocks.count + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n"
            + "\(name): \(cue.text)")
      }
    }
    return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
  }

  /// Кусок реплики для одного субтитра.
  struct Cue: Hashable {
    var start: Double
    var end: Double
    var text: String
  }

  /// Реплика целиком, если укладывается в лимиты; иначе — куски по словам: cue заканчивается словом,
  /// после которого лимит был бы превышен. Реплика без слов не режется (SPEC.md §3.5).
  static func cues(for utterance: Utterance, maxCueSeconds: Double, maxCueCharacters: Int) -> [Cue]
  {
    let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let whole = Cue(start: utterance.start, end: utterance.end, text: text)
    let words = utterance.words.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !words.isEmpty else { return [whole] }

    var chunks: [[Word]] = []
    var current: [Word] = []
    for word in words {
      guard let first = current.first else {
        current = [word]
        continue
      }
      let candidate = current + [word]
      let tooLong = word.end - first.start > maxCueSeconds
      let tooWide = Fuser.joinText(candidate).count > maxCueCharacters
      if tooLong || tooWide {
        chunks.append(current)
        current = [word]
      } else {
        current = candidate
      }
    }
    if !current.isEmpty { chunks.append(current) }
    guard chunks.count > 1 else { return [whole] }
    return chunks.map { chunk in
      Cue(
        start: chunk.first?.start ?? utterance.start,
        end: chunk.map(\.end).max() ?? utterance.end,
        text: Fuser.joinText(chunk))
    }
  }

  /// `HH:MM:SS,mmm`. Миллисекунды округляются: 3723.456 — это 01:02:03,456, а не …,455 (двоичная дробь).
  public static func timestamp(_ seconds: Double) -> String {
    let clamped = max(seconds, 0)
    var whole = clamped.rounded(.down)
    var milliseconds = Int(((clamped - whole) * 1000).rounded())
    if milliseconds >= 1000 {
      milliseconds -= 1000
      whole += 1
    }
    return Timecode.hhmmss(whole) + String(format: ",%03d", milliseconds)
  }
}
