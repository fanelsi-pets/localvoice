import Core
import Foundation

// Накопитель прохода по видео: список подписей (roster) и отрезки активного спикера.
// Вынесен из актора отдельно, чтобы правила склейки проверялись тестами без видео и Vision.

struct ScanState {
  /// Шаг выборки кадров: кадр представляет отрезок `[t, t + sampleInterval)`.
  let sampleInterval: Double
  /// Разрыв, который ещё склеивается в один отрезок (пропущенный или нераспознанный кадр).
  let maximumGap: Double

  /// Ключ имени → написание → сколько раз это написание встречалось.
  private var variants: [String: [String: Int]] = [:]
  /// Ключ имени → в скольких OCR-проходах имя встретилось.
  private var counts: [String: Int] = [:]
  private(set) var spans: [ActiveSpeakerSpan] = []
  private var open: ActiveSpeakerSpan?

  init(sampleInterval: Double) {
    self.sampleInterval = max(sampleInterval, 0.05)
    self.maximumGap = self.sampleInterval * 2
  }

  var distinctNameCount: Int { counts.count }

  /// Один OCR-проход: имя засчитывается один раз, сколько бы строк с ним ни распозналось.
  mutating func add(names: [String]) {
    for name in Set(names) {
      let key = key(for: name)
      counts[key, default: 0] += 1
      variants[key, default: [:]][name, default: 0] += 1
    }
  }

  /// Активный спикер на кадре `t`: продлевает текущий отрезок или начинает новый.
  mutating func mark(name: String, at time: Double) {
    let end = time + sampleInterval
    if var current = open, current.name == name, time - current.end <= maximumGap {
      current.end = max(current.end, end)
      open = current
    } else {
      breakSpan()
      open = ActiveSpeakerSpan(start: time, end: end, name: name)
    }
  }

  /// Активный спикер неизвестен: текущий отрезок закрывается.
  mutating func breakSpan() {
    if let open { spans.append(open) }
    open = nil
  }

  mutating func finish() { breakSpan() }

  /// Список подписей: имя показывается, если встретилось не реже `minimumCount` раз,
  /// но `count` остаётся честным. Написание — самое частое из склеенных вариантов.
  func roster(minimumCount: Int) -> [NameHint] {
    counts.compactMap { key, count -> NameHint? in
      guard count >= minimumCount, let spellings = variants[key] else { return nil }
      let name = spellings.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? key
      return NameHint(name: name, source: .ocr, count: count)
    }
    .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
  }

  /// Ключ имени с учётом ошибок OCR: близкие написания («Лван Минин» и «Иван Минин») и обрезанные
  /// подписи («Антон Воро» вместо «Антон Воронков») идут в один ключ.
  private func key(for name: String) -> String {
    let normalized = NameMatching.normalized(name)
    if counts[normalized] != nil { return normalized }
    var best: (key: String, score: Double)?
    for existing in counts.keys {
      let score = NameMatching.similarity(normalized, existing)
      guard score >= NameMatching.mergeThreshold || NameMatching.isTruncation(normalized, existing)
      else { continue }
      if best == nil || score > best!.score { best = (existing, score) }
    }
    return best?.key ?? normalized
  }
}
