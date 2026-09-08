import CoreGraphics
import Foundation

// Работа с пикселями кадра: развёртка в RGBA8, статистика яркости под подписью, уменьшенные копии.
// Всё синхронно и без Vision — этим пользуются и детектор рамки, и фильтр «тёмная плашка».

/// Развёртка кадра в RGBA8. Строка 0 — верх кадра: `CGBitmapContext` хранит битмап сверху вниз,
/// хотя рисует в системе координат с началом в левом нижнем углу (проверено на пробном кадре).
struct FrameBitmap {
  let width: Int
  let height: Int
  /// RGBA, 4 байта на пиксель, длина `width * height * 4`.
  let pixels: [UInt8]

  init?(_ image: CGImage) {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
    let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    self.width = width
    self.height = height
    self.pixels = buffer
  }

  /// Яркость пикселя 0…1 (Rec. 601 — достаточно для порогов «тёмная плашка» и «жёлтая рамка»).
  func luminance(x: Int, y: Int) -> Double {
    let index = (y * width + x) * 4
    return
      (0.299 * Double(pixels[index]) + 0.587 * Double(pixels[index + 1])
      + 0.114 * Double(pixels[index + 2])) / 255
  }

  /// Статистика яркости в нормализованном прямоугольнике (origin — левый верх).
  /// `bright`/`dark` — доли пикселей ярче 0.75 и темнее 0.35.
  func brightness(in box: CGRect) -> (mean: Double, bright: Double, dark: Double)? {
    let x0 = clamp(Int((box.minX * CGFloat(width)).rounded(.down)), 0, width - 1)
    let x1 = clamp(Int((box.maxX * CGFloat(width)).rounded(.up)), x0 + 1, width)
    let y0 = clamp(Int((box.minY * CGFloat(height)).rounded(.down)), 0, height - 1)
    let y1 = clamp(Int((box.maxY * CGFloat(height)).rounded(.up)), y0 + 1, height)
    var sum = 0.0
    var bright = 0
    var dark = 0
    var count = 0
    for y in y0..<y1 {
      for x in x0..<x1 {
        let value = luminance(x: x, y: y)
        sum += value
        if value > 0.75 { bright += 1 }
        if value < 0.35 { dark += 1 }
        count += 1
      }
    }
    guard count > 0 else { return nil }
    return (sum / Double(count), Double(bright) / Double(count), Double(dark) / Double(count))
  }

  /// Серая уменьшенная копия для сигнатуры кадра: средняя яркость блока, строки сверху вниз.
  /// Считается по уже развёрнутым пикселям (с прореживанием), чтобы не рисовать кадр второй раз.
  func grayscale(width targetWidth: Int, height targetHeight: Int) -> [UInt8] {
    guard targetWidth > 0, targetHeight > 0 else { return [] }
    var result = [UInt8](repeating: 0, count: targetWidth * targetHeight)
    let stepX = max(1, width / targetWidth / 4)
    let stepY = max(1, height / targetHeight / 4)
    for cellY in 0..<targetHeight {
      let y0 = cellY * height / targetHeight
      let y1 = max(y0 + 1, (cellY + 1) * height / targetHeight)
      for cellX in 0..<targetWidth {
        let x0 = cellX * width / targetWidth
        let x1 = max(x0 + 1, (cellX + 1) * width / targetWidth)
        var sum = 0.0
        var count = 0
        for y in stride(from: y0, to: y1, by: stepY) {
          for x in stride(from: x0, to: x1, by: stepX) {
            sum += luminance(x: x, y: y)
            count += 1
          }
        }
        result[cellY * targetWidth + cellX] = UInt8(
          min(255, max(0, (sum / Double(max(count, 1)) * 255).rounded())))
      }
    }
    return result
  }

  private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
    min(max(value, low), max(low, high))
  }
}

enum FrameImage {
  /// Вырезка (в пикселях исходника) с увеличением: подписи Zoom мелкие, Vision точнее на увеличенной копии.
  static func upscaled(_ image: CGImage, crop: CGRect?, factor: Int) -> CGImage? {
    let source: CGImage
    if let crop {
      let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
      let rect = crop.integral.intersection(bounds)
      guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
        return nil
      }
      source = cropped
    } else {
      source = image
    }
    guard factor > 1 else { return source }
    let width = source.width * factor
    let height = source.height * factor
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}
