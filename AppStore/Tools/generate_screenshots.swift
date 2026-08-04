#!/usr/bin/env swift

import AppKit

struct MarketingShot {
    let locale: String
    let index: Int
    let source: String
    let eyebrow: String
    let title: String
    let subtitle: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let raw = root.appendingPathComponent("AppStore/Assets/raw")
let output = root.appendingPathComponent("AppStore/Assets/screenshots")

let shots: [MarketingShot] = [
    .init(locale: "en", index: 1, source: "en-01-overview.png",
          eyebrow: "PRIVATE VOICE TYPING FOR MAC",
          title: "Turn speech into text. Anywhere.",
          subtitle: "One shortcut. Natural voice. Clean text."),
    .init(locale: "en", index: 2, source: "en-02-models.png",
          eyebrow: "YOU CHOOSE WHERE AUDIO IS PROCESSED",
          title: "Local or cloud. You’re in control.",
          subtitle: "Download a multilingual model whenever you want offline transcription."),
    .init(locale: "en", index: 3, source: "en-03-dictionary.png",
          eyebrow: "LESS EDITING AFTER EVERY DICTATION",
          title: "Make every transcript sound like you.",
          subtitle: "Remove filler words and teach LocalVoice your vocabulary."),

    .init(locale: "uk", index: 1, source: "01-overview.png",
          eyebrow: "ПРИВАТНЕ ГОЛОСОВЕ ВВЕДЕННЯ ДЛЯ MAC",
          title: "Перетворюйте голос на текст. Усюди.",
          subtitle: "Одна комбінація клавіш. Природне мовлення. Чистий текст."),
    .init(locale: "uk", index: 2, source: "02-models.png",
          eyebrow: "ВИ ВИРІШУЄТЕ, ДЕ ОБРОБЛЯЄТЬСЯ АУДІО",
          title: "Локально або в хмарі. Вибір за вами.",
          subtitle: "Завантажуйте багатомовні моделі для роботи офлайн."),
    .init(locale: "uk", index: 3, source: "03-dictionary.png",
          eyebrow: "МЕНШЕ РЕДАГУВАННЯ ПІСЛЯ ДИКТУВАННЯ",
          title: "Нехай кожна транскрипція звучить як ви.",
          subtitle: "Прибирайте слова-паразити й додавайте власну лексику."),

    .init(locale: "ru", index: 1, source: "ru-01-overview.png",
          eyebrow: "ПРИВАТНЫЙ ГОЛОСОВОЙ ВВОД ДЛЯ MAC",
          title: "Превращайте голос в текст. Везде.",
          subtitle: "Одно сочетание клавиш. Естественная речь. Чистый текст."),
    .init(locale: "ru", index: 2, source: "ru-02-models.png",
          eyebrow: "ВЫ РЕШАЕТЕ, ГДЕ ОБРАБАТЫВАЕТСЯ АУДИО",
          title: "Локально или в облаке. Выбор за вами.",
          subtitle: "Загружайте многоязычные модели для работы офлайн."),
    .init(locale: "ru", index: 3, source: "ru-03-dictionary.png",
          eyebrow: "МЕНЬШЕ РЕДАКТИРОВАНИЯ ПОСЛЕ ДИКТОВКИ",
          title: "Пусть каждая транскрипция звучит как вы.",
          subtitle: "Убирайте слова-паразиты и добавляйте свою лексику.")
]

let canvasSize = NSSize(width: 2880, height: 1800)

func paragraphStyle(lineSpacing: CGFloat = 0) -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = lineSpacing
    return style
}

func drawText(
    _ value: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    lineSpacing: CGFloat = 0
) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle(lineSpacing: lineSpacing)
    ]
    NSString(string: value).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
}

func saveJPEG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
        throw NSError(domain: "MarketingAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode JPEG"])
    }
    try data.write(to: url, options: .atomic)
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for shot in shots {
    let sourceURL = raw.appendingPathComponent(shot.source)
    guard let sourceImage = NSImage(contentsOf: sourceURL) else {
        throw NSError(domain: "MarketingAssets", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(sourceURL.path)"])
    }

    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width),
            pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw NSError(domain: "MarketingAssets", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap context"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor(calibratedRed: 0.035, green: 0.039, blue: 0.065, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    let gradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.11, green: 0.06, blue: 0.24, alpha: 1), 0),
        (NSColor(calibratedRed: 0.035, green: 0.08, blue: 0.17, alpha: 1), 0.55),
        (NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.06, alpha: 1), 1)
    )!
    gradient.draw(in: NSRect(origin: .zero, size: canvasSize), angle: -12)

    let accentRect = NSRect(x: -220, y: 720, width: 1250, height: 1250)
    let accent = NSGradient(colors: [
        NSColor(calibratedRed: 0.31, green: 0.11, blue: 0.93, alpha: 0.25),
        NSColor(calibratedRed: 0.08, green: 0.48, blue: 1.0, alpha: 0)
    ])!
    accent.draw(in: NSBezierPath(ovalIn: accentRect), relativeCenterPosition: NSPoint(x: -0.25, y: 0.2))

    drawText(
        shot.eyebrow,
        in: NSRect(x: 260, y: 1550, width: 2350, height: 58),
        font: .systemFont(ofSize: 34, weight: .semibold),
        color: NSColor(calibratedRed: 0.36, green: 0.68, blue: 1, alpha: 1)
    )
    drawText(
        shot.title,
        in: NSRect(x: 250, y: 1320, width: 2380, height: 210),
        font: .systemFont(ofSize: 92, weight: .bold),
        color: .white,
        lineSpacing: -2
    )
    drawText(
        shot.subtitle,
        in: NSRect(x: 255, y: 1205, width: 2240, height: 105),
        font: .systemFont(ofSize: 43, weight: .medium),
        color: NSColor(calibratedWhite: 0.82, alpha: 1)
    )

    let appWidth: CGFloat = 2100
    let appHeight = appWidth * sourceImage.size.height / sourceImage.size.width
    let appRect = NSRect(x: 390, y: -500, width: appWidth, height: appHeight)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.68)
    shadow.shadowBlurRadius = 70
    shadow.shadowOffset = NSSize(width: 0, height: -20)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: appRect, xRadius: 34, yRadius: 34).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: appRect, xRadius: 34, yRadius: 34).addClip()
    sourceImage.draw(in: appRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    let border = NSBezierPath(roundedRect: appRect, xRadius: 34, yRadius: 34)
    border.lineWidth = 3
    NSColor.white.withAlphaComponent(0.16).setStroke()
    border.stroke()

    let localeDirectory = output.appendingPathComponent(shot.locale)
    try FileManager.default.createDirectory(at: localeDirectory, withIntermediateDirectories: true)
    let destination = localeDirectory.appendingPathComponent(String(format: "%02d.jpg", shot.index))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try saveJPEG(bitmap, to: destination)
    print(destination.path)
}
