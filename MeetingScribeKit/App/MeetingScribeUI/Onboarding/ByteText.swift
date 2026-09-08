import Foundation

/// Байты словами для интерфейса: «412 МБ», «1,64 ГБ», «35 МБ/с» (SPEC.md §3.7 п. 10 — прогресс
/// скачивания в мегабайтах и процентах). Единицы десятичные — так же считает Hugging Face, и число
/// совпадает с ожидаемым объёмом модели. Разделитель дробной части — по локали интерфейса.
nonisolated public enum ByteText {
  public static func short(_ bytes: Int64) -> String {
    let value = Double(max(bytes, 0))
    if value >= 1_000_000_000 {
      return fractional(value / 1_000_000_000, unit: String(localized: "ГБ"))
    }
    if value >= 1_000_000 { return String(localized: "\(Int((value / 1_000_000).rounded())) МБ") }
    if value >= 1_000 { return String(localized: "\(Int((value / 1_000).rounded())) КБ") }
    return String(localized: "\(Int(value)) Б")
  }

  /// «412 МБ из 1,64 ГБ».
  public static func progress(_ completed: Int64, of total: Int64) -> String {
    String(localized: "\(short(completed)) из \(short(total))")
  }

  /// «35 МБ/с»; `nil` — скорость ещё не измерена.
  public static func speed(_ bytesPerSecond: Double?) -> String? {
    guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }
    return String(localized: "\(short(Int64(bytesPerSecond)))/с")
  }

  /// Разделитель дробной части — по локали интерфейса («1,64 ГБ» / «1.64 GB»).
  private static func fractional(_ value: Double, unit: String) -> String {
    value.formatted(.number.precision(.fractionLength(2))) + " " + unit
  }
}
