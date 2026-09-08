import Foundation

/// Форматирование таймкодов. Внутри модели — Double-секунды; строки `[HH:MM:SS]` живут только здесь.
public enum Timecode {
  /// `01:02:03`.
  public static func hhmmss(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded(.down))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
  }

  /// `01:02:03.4` — опция «с десятыми долями».
  public static func hhmmssTenths(_ seconds: Double) -> String {
    let clamped = max(seconds, 0)
    let tenths = Int((clamped * 10).rounded(.down)) % 10
    return hhmmss(clamped) + ".\(tenths)"
  }

  /// `[01:02:03]` — префикс реплики в TranscribeFull.
  public static func bracketed(_ seconds: Double, tenths: Bool = false) -> String {
    "[" + (tenths ? hhmmssTenths(seconds) : hhmmss(seconds)) + "]"
  }

  /// Длительность для шапки и таблиц: `1 ч 25 мин`, `4 мин 12 с`, `38 с`.
  public static func humanDuration(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainder = total % 60
    if hours > 0 { return "\(hours) ч \(minutes) мин" }
    if minutes > 0 { return "\(minutes) мин \(remainder) с" }
    return "\(remainder) с"
  }

  /// Разбор таймкода из текста ответа модели: `HH:MM:SS`, `H:MM:SS`, `MM:SS`, `M:SS` с необязательными
  /// десятыми/сотыми (`00:41:12.5`), в обрамлении `[…]`/`(…)` и с пробелами. Минуты и секунды ≥ 60,
  /// отрицательные значения и любой мусор — `nil` (обратная операция к `bracketed`).
  public static func seconds(from text: String) -> Double? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = trimmed.first, let last = trimmed.last,
      (first == "[" && last == "]") || (first == "(" && last == ")")
    {
      trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(
        in: .whitespacesAndNewlines)
    }
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    // Дробная часть допустима только у секунд: «00:41:12.5», «41:12,25».
    let secondsPart = parts[parts.count - 1]
    let secondsPieces = secondsPart.split(
      separator: secondsPart.contains(",") ? "," : ".", omittingEmptySubsequences: false)
    guard secondsPieces.count <= 2,
      let seconds = integer(secondsPieces[0], digits: 1...2, limit: 59)
    else { return nil }
    var fraction = 0.0
    if secondsPieces.count == 2 {
      let digits = String(secondsPieces[1])
      guard (1...3).contains(digits.count), digits.allSatisfy(\.isNumber),
        let value = Double(digits)
      else { return nil }
      fraction = value / pow(10, Double(digits.count))
    }

    guard let minutes = integer(parts[parts.count - 2], digits: 1...2, limit: 59) else {
      return nil
    }
    var total = Double(minutes * 60 + seconds) + fraction
    if parts.count == 3 {
      guard let hours = integer(parts[0], digits: 1...3, limit: 999) else { return nil }
      total += Double(hours * 3600)
    }
    return total
  }

  /// Целое из группы таймкода: только цифры, допустимая длина и верхняя граница.
  private static func integer(
    _ text: some StringProtocol, digits: ClosedRange<Int>, limit: Int
  ) -> Int? {
    guard digits.contains(text.count), text.allSatisfy(\.isNumber), let value = Int(text),
      value <= limit
    else { return nil }
    return value
  }
}
