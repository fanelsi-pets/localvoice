import CoreGraphics
import Foundation

// Дешёвая (без Vision) обработка кадра: где активный спикер и сменилась ли раскладка.
// Вызывается на каждом выбранном кадре, поэтому работает на маске 320 ячеек по ширине.

public enum TileDetector {
  /// Порог «жёлтого» пикселя рамки активного спикера Zoom (жёлтый и жёлто-зелёный).
  /// Значения — гипотеза: в записях пользователя рамки нет (Zoom её не пишет в файл),
  /// проверяется на синтетических кадрах и уточняется на записи, где рамка есть.
  static let yellowRed = 170
  static let yellowGreen = 140
  static let yellowBlue = 110
  static let yellowRedMinusBlue = 90

  /// Ширина маски: рамка в 4 px на кадре 1280 даёт одну ячейку — этого хватает и это быстро.
  static let maskWidth = 320
  /// Размер сигнатуры кадра.
  static let signatureWidth = 32
  static let signatureHeight = 18

  /// Минимальная сторона плитки как доля кадра.
  static let minimumTileFraction = 0.10
  /// Максимальная толщина рамки как доля меньшей стороны кадра: всё, что толще, — заливка, а не рамка.
  static let maximumBorderFraction = 0.05
  /// Какую долю стороны прямоугольника должна закрывать сплошная жёлтая линия.
  static let minimumBorderCoverage = 0.6
  /// Сколько жёлтого допустимо внутри рамки: рамка полая, заливка — нет.
  static let maximumInteriorYellow = 0.10

  /// Плитка, обведённая жёлтой/зелёно-жёлтой рамкой (активный спикер в gallery view):
  /// нормализованный прямоугольник (origin левый верх) или `nil`.
  public static func highlightedTile(in image: CGImage) -> CGRect? {
    guard let bitmap = FrameBitmap(image) else { return nil }
    return highlightedTile(in: bitmap)
  }

  /// То же по уже развёрнутому кадру: проход по видео разворачивает кадр один раз на все проверки.
  static func highlightedTile(in bitmap: FrameBitmap) -> CGRect? {
    highlightedTile(in: yellowMask(bitmap))
  }

  /// Грубая сигнатура кадра для обнаружения смены раскладки: серый 32×18.
  public static func signature(of image: CGImage) -> [UInt8] {
    guard let bitmap = FrameBitmap(image) else { return [] }
    return signature(of: bitmap)
  }

  static func signature(of bitmap: FrameBitmap) -> [UInt8] {
    bitmap.grayscale(width: signatureWidth, height: signatureHeight)
  }

  /// Средняя абсолютная разница сигнатур 0…1; разные размеры — 1 (считаем, что кадр сменился целиком).
  public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard !a.isEmpty, a.count == b.count else { return 1 }
    var sum = 0
    for index in a.indices {
      sum += abs(Int(a[index]) - Int(b[index]))
    }
    return Double(sum) / (255 * Double(a.count))
  }
}

// MARK: - Маска жёлтого

extension TileDetector {
  /// Маска «жёлтых» ячеек. Уменьшаем не цвет, а маску (в ячейке жёлтой считается любая жёлтая точка):
  /// при усреднении цвета рамка толщиной 4 px растворяется в тёмном фоне и перестаёт быть жёлтой.
  struct Mask {
    let width: Int
    let height: Int
    var cells: [Bool]

    subscript(x: Int, y: Int) -> Bool { cells[y * width + x] }
  }

  static func yellowMask(_ bitmap: FrameBitmap) -> Mask {
    let width = min(maskWidth, bitmap.width)
    let height = max(
      1, Int((Double(bitmap.height) * Double(width) / Double(bitmap.width)).rounded()))
    var cells = [Bool](repeating: false, count: width * height)
    // Внутри ячейки смотрим каждый второй пиксель: рамка тоньше 2 px не встречается,
    // а полный перебор 0.9 Мп на каждом кадре записи стоит втрое дороже.
    let stepX = max(1, bitmap.width / width / 2)
    let stepY = max(1, bitmap.height / height / 2)
    for cellY in 0..<height {
      let y0 = cellY * bitmap.height / height
      let y1 = max(y0 + 1, (cellY + 1) * bitmap.height / height)
      for cellX in 0..<width {
        let x0 = cellX * bitmap.width / width
        let x1 = max(x0 + 1, (cellX + 1) * bitmap.width / width)
        var found = false
        for y in stride(from: y0, to: y1, by: stepY) where !found {
          for x in stride(from: x0, to: x1, by: stepX) {
            let index = (y * bitmap.width + x) * 4
            let red = Int(bitmap.pixels[index])
            let green = Int(bitmap.pixels[index + 1])
            let blue = Int(bitmap.pixels[index + 2])
            if red > yellowRed, green > yellowGreen, blue < yellowBlue,
              red - blue > yellowRedMinusBlue
            {
              found = true
              break
            }
          }
        }
        cells[cellY * width + cellX] = found
      }
    }
    return Mask(width: width, height: height, cells: cells)
  }
}

// MARK: - Поиск рамки

extension TileDetector {
  /// Полоса подряд идущих строк (или столбцов) с длинными жёлтыми пробегами.
  private struct Band {
    var start: Int
    var end: Int
    var thickness: Int { end - start }
  }

  static func highlightedTile(in mask: Mask) -> CGRect? {
    let width = mask.width
    let height = mask.height
    guard width > 2, height > 2 else { return nil }
    let minimumWidth = max(3, Int(Double(width) * minimumTileFraction))
    let minimumHeight = max(3, Int(Double(height) * minimumTileFraction))
    let maximumThickness = max(2, Int(Double(min(width, height)) * maximumBorderFraction))

    let rowBands = bands(
      count: height, limit: maximumThickness,
      isLine: { y in longestRun(in: mask, along: .row(y), from: 0, to: width) >= minimumWidth })
    let columnBands = bands(
      count: width, limit: maximumThickness,
      isLine: { x in longestRun(in: mask, along: .column(x), from: 0, to: height) >= minimumHeight }
    )
    guard let top = rowBands.first, let bottom = rowBands.last, top.start < bottom.start,
      let left = columnBands.first, let right = columnBands.last, left.start < right.start
    else { return nil }

    let rect = (x0: left.start, y0: top.start, x1: right.end, y1: bottom.end)
    let tileWidth = rect.x1 - rect.x0
    let tileHeight = rect.y1 - rect.y0
    guard tileWidth >= minimumWidth, tileHeight >= minimumHeight else { return nil }

    // Линии должны идти вдоль сторон прямоугольника, а не быть случайными пятнами в разных местах.
    let horizontal = Double(tileWidth) * minimumBorderCoverage
    let vertical = Double(tileHeight) * minimumBorderCoverage
    let covered =
      coverage(mask, band: top, orientation: .horizontal, from: rect.x0, to: rect.x1) >= horizontal
      && coverage(mask, band: bottom, orientation: .horizontal, from: rect.x0, to: rect.x1)
        >= horizontal
      && coverage(mask, band: left, orientation: .vertical, from: rect.y0, to: rect.y1) >= vertical
      && coverage(mask, band: right, orientation: .vertical, from: rect.y0, to: rect.y1) >= vertical
    guard covered else { return nil }

    // Рамка полая: внутри жёлтого почти нет (иначе это сплошная заливка или жёлтая картинка).
    let inset =
      max(top.thickness, bottom.thickness, left.thickness, right.thickness) + 1
    let inner = (
      x0: rect.x0 + inset, y0: rect.y0 + inset, x1: rect.x1 - inset, y1: rect.y1 - inset
    )
    guard inner.x1 - inner.x0 >= 2, inner.y1 - inner.y0 >= 2 else { return nil }
    var yellow = 0
    for y in inner.y0..<inner.y1 {
      for x in inner.x0..<inner.x1 where mask[x, y] {
        yellow += 1
      }
    }
    let area = Double((inner.x1 - inner.x0) * (inner.y1 - inner.y0))
    guard Double(yellow) / area < maximumInteriorYellow else { return nil }

    return CGRect(
      x: Double(rect.x0) / Double(width),
      y: Double(rect.y0) / Double(height),
      width: Double(tileWidth) / Double(width),
      height: Double(tileHeight) / Double(height))
  }

  private enum Line {
    case row(Int)
    case column(Int)
  }

  private enum Orientation {
    case horizontal
    case vertical
  }

  /// Самый длинный пробег жёлтого вдоль строки или столбца; разрывы в одну ячейку не считаются разрывом
  /// (рамка может прерваться на границе ячеек маски).
  private static func longestRun(in mask: Mask, along line: Line, from: Int, to: Int) -> Int {
    var best = 0
    var current = 0
    var gap = 0
    for index in from..<to {
      let filled: Bool
      switch line {
      case .row(let y): filled = mask[index, y]
      case .column(let x): filled = mask[x, index]
      }
      if filled {
        current += gap + 1
        gap = 0
        best = max(best, current)
      } else if current > 0, gap == 0 {
        gap = 1
      } else {
        current = 0
        gap = 0
      }
    }
    return best
  }

  /// Полосы подряд идущих линий; слишком толстые полосы (заливка) отбрасываются.
  private static func bands(count: Int, limit: Int, isLine: (Int) -> Bool) -> [Band] {
    var result: [Band] = []
    var start: Int?
    for index in 0..<count {
      if isLine(index) {
        if start == nil { start = index }
      } else if let begin = start {
        result.append(Band(start: begin, end: index))
        start = nil
      }
    }
    if let begin = start { result.append(Band(start: begin, end: count)) }
    return result.filter { $0.thickness <= limit }
  }

  /// Самый длинный пробег внутри полосы, ограниченный сторонами прямоугольника.
  private static func coverage(
    _ mask: Mask, band: Band, orientation: Orientation, from: Int, to: Int
  ) -> Double {
    var best = 0
    for index in band.start..<band.end {
      let line: Line = orientation == .horizontal ? .row(index) : .column(index)
      best = max(best, longestRun(in: mask, along: line, from: from, to: to))
    }
    return Double(best)
  }
}
