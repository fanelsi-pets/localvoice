#!/usr/bin/env swift

import AppKit

let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("AppStore/Assets/review/LocalVoice-Lifetime-Paywall.png")
let canvas = NSSize(width: 1440, height: 1000)
let outputSize = NSSize(width: 1440, height: 900)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func text(
    _ value: String,
    rect: NSRect,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    foreground: NSColor = .white,
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: foreground,
        .paragraphStyle: paragraph,
    ]
    NSString(string: value).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: attributes
    )
}

func symbol(_ name: String, rect: NSRect, pointSize: CGFloat, tint: NSColor) {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return }
    image.isTemplate = true
    tint.set()
    image.draw(in: rect)
}

guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(outputSize.width),
        pixelsHigh: Int(outputSize.height),
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
    fatalError("Could not create bitmap context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: outputSize.width / canvas.width, y: outputSize.height / canvas.height)

color(0.055, 0.059, 0.072).setFill()
NSRect(origin: .zero, size: canvas).fill()

// Main app window and navigation context.
rounded(
    NSRect(x: 36, y: 36, width: 1368, height: 928),
    radius: 26,
    fill: color(0.09, 0.095, 0.11),
    stroke: color(0.29, 0.30, 0.34)
)
rounded(
    NSRect(x: 36, y: 36, width: 292, height: 928),
    radius: 26,
    fill: color(0.075, 0.078, 0.09)
)
text("LocalVoice - AI", rect: NSRect(x: 82, y: 868, width: 210, height: 34), size: 22, weight: .bold)
text("Private voice typing", rect: NSRect(x: 82, y: 838, width: 210, height: 25), size: 14, foreground: color(0.62, 0.64, 0.69))
text("Dashboard", rect: NSRect(x: 82, y: 760, width: 180, height: 28), size: 17, weight: .semibold)
text("History", rect: NSRect(x: 82, y: 708, width: 180, height: 28), size: 17)
text("AI Models", rect: NSRect(x: 82, y: 656, width: 180, height: 28), size: 17)
text("Settings", rect: NSRect(x: 82, y: 94, width: 180, height: 28), size: 17)

// Dimmed app content behind the purchase sheet.
color(0, 0, 0, 0.48).setFill()
NSRect(x: 328, y: 36, width: 1076, height: 928).fill()

let sheet = NSRect(x: 470, y: 95, width: 790, height: 810)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
shadow.shadowBlurRadius = 44
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
rounded(sheet, radius: 28, fill: color(0.105, 0.11, 0.13))
NSGraphicsContext.restoreGraphicsState()
rounded(sheet, radius: 28, fill: color(0.105, 0.11, 0.13), stroke: color(0.29, 0.31, 0.36))

let accent = color(0.12, 0.51, 1)
rounded(NSRect(x: 811, y: 760, width: 108, height: 108), radius: 26, fill: color(0.09, 0.25, 0.47))
symbol("waveform.badge.mic", rect: NSRect(x: 831, y: 780, width: 68, height: 68), pointSize: 52, tint: accent)

text(
    "Keep speaking. Keep LocalVoice forever.",
    rect: NSRect(x: 535, y: 696, width: 660, height: 50),
    size: 30,
    weight: .bold,
    alignment: .center
)
text(
    "7 days free. Then one lifetime purchase. No subscription.",
    rect: NSRect(x: 550, y: 654, width: 630, height: 35),
    size: 17,
    foreground: color(0.68, 0.70, 0.75),
    alignment: .center
)

let featureBox = NSRect(x: 590, y: 402, width: 550, height: 224)
rounded(featureBox, radius: 20, fill: color(0.14, 0.145, 0.17))
let features = [
    ("mic.fill", "Voice typing in any app"),
    ("lock.shield.fill", "Local models and privacy controls"),
    ("text.badge.checkmark", "History, cleanup, and text improvement"),
    ("infinity", "One purchase. No subscription."),
]
for (index, feature) in features.enumerated() {
    let y = 572 - CGFloat(index) * 49
    symbol(feature.0, rect: NSRect(x: 620, y: y, width: 26, height: 26), pointSize: 19, tint: accent)
    text(feature.1, rect: NSRect(x: 662, y: y - 1, width: 430, height: 28), size: 16, weight: .medium)
}

rounded(NSRect(x: 590, y: 313, width: 550, height: 58), radius: 12, fill: accent)
text(
    "Buy Once for $4.99",
    rect: NSRect(x: 610, y: 328, width: 510, height: 28),
    size: 18,
    weight: .semibold,
    alignment: .center
)
text(
    "Restore Purchase",
    rect: NSRect(x: 590, y: 270, width: 550, height: 28),
    size: 15,
    weight: .medium,
    foreground: color(0.72, 0.78, 0.88),
    alignment: .center
)
text(
    "Payment is charged only when you confirm the purchase with Apple.\nThe 7-day trial does not renew or charge automatically.",
    rect: NSRect(x: 555, y: 178, width: 620, height: 62),
    size: 13,
    foreground: color(0.56, 0.58, 0.64),
    alignment: .center
)

NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
