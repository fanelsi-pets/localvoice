#!/usr/bin/env swift

import AppKit
import AVFoundation
import CoreVideo

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appendingPathComponent("AppStore/Assets/video")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let silentURL = outputDirectory.appendingPathComponent("LocalVoice-App-Preview-silent.mp4")
let audioURL = outputDirectory.appendingPathComponent("hello-world-stereo.aiff")
let fullAudioURL = outputDirectory.appendingPathComponent("LocalVoice-App-Preview-audio.caf")
let finalURL = outputDirectory.appendingPathComponent("LocalVoice-App-Preview-en.mp4")

for url in [silentURL, fullAudioURL, finalURL] where FileManager.default.fileExists(atPath: url.path) {
    try FileManager.default.removeItem(at: url)
}

let width = 1920
let height = 1080
let fps: Int32 = 30
let durationSeconds = 16
let frameCount = durationSeconds * Int(fps)

let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mp4)
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 11_000_000,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
    ]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
)
guard writer.canAdd(input) else { fatalError("Cannot add video input") }
writer.add(input)
guard writer.startWriting() else { fatalError(writer.error?.localizedDescription ?? "Could not start writer") }
writer.startSession(atSourceTime: .zero)

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawText(
    _ text: String,
    in rect: CGRect,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    NSString(string: text).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
}

func drawWaveform(context: CGContext, time: Double, rect: CGRect) {
    context.saveGState()
    context.addPath(roundedPath(rect, radius: rect.height / 2))
    context.clip()

    let centerY = rect.midY
    context.setLineWidth(2.4)
    context.setLineCap(.round)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)

    let sampleCount = 190
    let spacing = rect.width / CGFloat(sampleCount - 1)
    let scroll = time * 34
    let path = CGMutablePath()
    for index in 0..<sampleCount {
        let x = rect.minX + CGFloat(index) * spacing
        let phase = Double(index) * 0.47 + scroll
        let burstA = exp(-pow((Double(index) - 58 - sin(time) * 12) / 18, 2))
        let burstB = exp(-pow((Double(index) - 138 - cos(time * 0.7) * 18) / 15, 2))
        let carrier = sin(phase * 1.7) * 0.62 + sin(phase * 3.9) * 0.24 + sin(phase * 0.51) * 0.14
        let amplitude = 5 + (burstA * 42 + burstB * 55) * (0.72 + 0.28 * sin(time * 5 + Double(index)))
        let y = centerY + CGFloat(carrier * amplitude)
        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    context.addPath(path)
    context.strokePath()
    context.restoreGState()
}

func drawMicrophone(context: CGContext, center: CGPoint) {
    context.saveGState()
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.addPath(roundedPath(CGRect(x: center.x - 12, y: center.y - 23, width: 24, height: 40), radius: 12))
    context.strokePath()
    context.move(to: CGPoint(x: center.x - 22, y: center.y - 3))
    context.addCurve(
        to: CGPoint(x: center.x + 22, y: center.y - 3),
        control1: CGPoint(x: center.x - 21, y: center.y - 29),
        control2: CGPoint(x: center.x + 21, y: center.y - 29)
    )
    context.strokePath()
    context.move(to: CGPoint(x: center.x, y: center.y - 29))
    context.addLine(to: CGPoint(x: center.x, y: center.y - 39))
    context.move(to: CGPoint(x: center.x - 13, y: center.y - 39))
    context.addLine(to: CGPoint(x: center.x + 13, y: center.y - 39))
    context.strokePath()
    context.restoreGState()
}

func renderFrame(_ frame: Int, into buffer: CVPixelBuffer) {
    let time = Double(frame) / Double(fps)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard
        let baseAddress = CVPixelBufferGetBaseAddress(buffer),
        let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    else { fatalError("Could not create frame context") }

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let background = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.025, green: 0.03, blue: 0.055, alpha: 1), 0),
        (NSColor(calibratedRed: 0.055, green: 0.07, blue: 0.13, alpha: 1), 1)
    )!
    background.draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: -15)

    let windowRect = CGRect(x: 110, y: 90, width: 1700, height: 900)
    NSColor(calibratedRed: 0.105, green: 0.11, blue: 0.135, alpha: 1).setFill()
    NSBezierPath(roundedRect: windowRect, xRadius: 30, yRadius: 30).fill()
    NSColor.white.withAlphaComponent(0.13).setStroke()
    let windowBorder = NSBezierPath(roundedRect: windowRect, xRadius: 30, yRadius: 30)
    windowBorder.lineWidth = 2
    windowBorder.stroke()

    for (x, color) in [
        (155.0, NSColor(calibratedRed: 1, green: 0.32, blue: 0.32, alpha: 1)),
        (199.0, NSColor(calibratedRed: 1, green: 0.76, blue: 0.16, alpha: 1)),
        (243.0, NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.35, alpha: 1))
    ] {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: 943, width: 24, height: 24)).fill()
    }

    drawText(
        "Untitled",
        in: CGRect(x: 690, y: 920, width: 540, height: 48),
        size: 28,
        weight: .semibold,
        color: NSColor.white.withAlphaComponent(0.74),
        alignment: .center
    )

    let entryRect = CGRect(x: 240, y: 250, width: 1440, height: 560)
    NSColor(calibratedRed: 0.075, green: 0.08, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: entryRect, xRadius: 24, yRadius: 24).fill()
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let entryBorder = NSBezierPath(roundedRect: entryRect, xRadius: 24, yRadius: 24)
    entryBorder.lineWidth = 2
    entryBorder.stroke()

    if time < 2.2 {
        drawText(
            "Click here and speak naturally…",
            in: CGRect(x: 310, y: 680, width: 1200, height: 60),
            size: 38,
            weight: .regular,
            color: NSColor.white.withAlphaComponent(0.28)
        )
    } else if time >= 10 {
        let reveal = min(11, max(0, Int((time - 10) * 7)))
        let full = Array("Hello World")
        let visible = String(full.prefix(reveal))
        drawText(
            visible,
            in: CGRect(x: 310, y: 650, width: 1200, height: 100),
            size: 58,
            weight: .medium,
            color: NSColor.white.withAlphaComponent(min(1, (time - 10) * 2))
        )
        if Int(time * 2) % 2 == 0 {
            let prefix = String(full.prefix(reveal)) as NSString
            let width = prefix.size(withAttributes: [.font: NSFont.systemFont(ofSize: 58, weight: .medium)]).width
            NSColor(calibratedRed: 0.25, green: 0.62, blue: 1, alpha: 1).setFill()
            NSRect(x: 310 + width + 3, y: 653, width: 4, height: 66).fill()
        }
    }

    if time >= 2.2 && time < 9.7 {
        let appear = min(1, (time - 2.2) * 4)
        let disappear = min(1, max(0, (9.7 - time) * 4))
        let scale = 0.92 + 0.08 * min(appear, disappear)
        let pillWidth: CGFloat = 730 * scale
        let pillHeight: CGFloat = 116 * scale
        let pill = CGRect(x: (CGFloat(width) - pillWidth) / 2, y: 135, width: pillWidth, height: pillHeight)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 34, color: NSColor.black.withAlphaComponent(0.65).cgColor)
        NSColor.black.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
        context.restoreGState()

        let stopCenter = CGPoint(x: pill.minX + 62 * scale, y: pill.midY)
        NSColor(calibratedRed: 1, green: 0.22, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: stopCenter.x - 35 * scale, y: stopCenter.y - 35 * scale, width: 70 * scale, height: 70 * scale)).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: stopCenter.x - 11 * scale, y: stopCenter.y - 11 * scale, width: 22 * scale, height: 22 * scale), xRadius: 5, yRadius: 5).fill()

        drawWaveform(
            context: context,
            time: time,
            rect: CGRect(x: pill.minX + 120 * scale, y: pill.midY - 42 * scale, width: 500 * scale, height: 84 * scale)
        )
        drawMicrophone(context: context, center: CGPoint(x: pill.maxX - 58 * scale, y: pill.midY + 6 * scale))
    }

    if time >= 12.1 {
        let alpha = min(1, (time - 12.1) * 2)
        drawText(
            "Voice → clean text in one shortcut",
            in: CGRect(x: 420, y: 136, width: 1080, height: 52),
            size: 28,
            weight: .semibold,
            color: NSColor(calibratedRed: 0.40, green: 0.72, blue: 1, alpha: alpha),
            alignment: .center
        )
    }

    NSGraphicsContext.restoreGraphicsState()
}

for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.002)
    }
    guard let pool = adaptor.pixelBufferPool else { fatalError("Missing pixel buffer pool") }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    guard let buffer = pixelBuffer else { fatalError("Could not create pixel buffer") }
    renderFrame(frame, into: buffer)
    let time = CMTime(value: CMTimeValue(frame), timescale: fps)
    guard adaptor.append(buffer, withPresentationTime: time) else {
        fatalError(writer.error?.localizedDescription ?? "Could not append frame")
    }
}

input.markAsFinished()
let finishSemaphore = DispatchSemaphore(value: 0)
writer.finishWriting { finishSemaphore.signal() }
finishSemaphore.wait()
guard writer.status == .completed else {
    fatalError(writer.error?.localizedDescription ?? "Video writer did not finish")
}

let sourceAudioFile = try AVAudioFile(forReading: audioURL)
let audioFormat = sourceAudioFile.processingFormat
guard audioFormat.channelCount == 2, Int(audioFormat.sampleRate) == 48_000 else {
    fatalError("Preview narration must be stereo 48 kHz")
}
let sourceFrameCount = AVAudioFrameCount(sourceAudioFile.length)
guard let sourceAudioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: sourceFrameCount) else {
    fatalError("Could not allocate narration buffer")
}
try sourceAudioFile.read(into: sourceAudioBuffer)

let totalAudioFrames = AVAudioFrameCount(Double(durationSeconds) * audioFormat.sampleRate)
guard let fullAudioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: totalAudioFrames) else {
    fatalError("Could not allocate preview audio buffer")
}
fullAudioBuffer.frameLength = totalAudioFrames
if let channels = fullAudioBuffer.floatChannelData {
    for channel in 0..<Int(audioFormat.channelCount) {
        channels[channel].initialize(repeating: 0, count: Int(totalAudioFrames))
    }
}
let narrationOffset = Int(5.2 * audioFormat.sampleRate)
if let sourceChannels = sourceAudioBuffer.floatChannelData,
   let destinationChannels = fullAudioBuffer.floatChannelData {
    let copyCount = min(Int(sourceAudioBuffer.frameLength), Int(totalAudioFrames) - narrationOffset)
    for channel in 0..<Int(audioFormat.channelCount) {
        destinationChannels[channel].advanced(by: narrationOffset).assign(
            from: sourceChannels[channel],
            count: copyCount
        )
    }
}
let fullAudioFile = try AVAudioFile(
    forWriting: fullAudioURL,
    settings: audioFormat.settings,
    commonFormat: .pcmFormatFloat32,
    interleaved: false
)
try fullAudioFile.write(from: fullAudioBuffer)

let silentAsset = AVURLAsset(url: silentURL)
let fullAudioAsset = AVURLAsset(url: fullAudioURL)
guard
    let sourceVideoTrack = silentAsset.tracks(withMediaType: .video).first,
    let sourceAudioTrack = fullAudioAsset.tracks(withMediaType: .audio).first,
    let rawVideoFormatHint = sourceVideoTrack.formatDescriptions.first
else { fatalError("Missing source tracks") }
let videoFormatHint = rawVideoFormatHint as! CMFormatDescription

let muxWriter = try AVAssetWriter(outputURL: finalURL, fileType: .mp4)
let passthroughVideoInput = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: nil,
    sourceFormatHint: videoFormatHint
)
passthroughVideoInput.expectsMediaDataInRealTime = false
let encodedAudioInput = AVAssetWriterInput(
    mediaType: .audio,
    outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 256_000
    ]
)
encodedAudioInput.expectsMediaDataInRealTime = false
guard muxWriter.canAdd(passthroughVideoInput), muxWriter.canAdd(encodedAudioInput) else {
    fatalError("Could not add mux inputs")
}
muxWriter.add(passthroughVideoInput)
muxWriter.add(encodedAudioInput)

let reader = try AVAssetReader(asset: silentAsset)
let videoOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: nil)
guard reader.canAdd(videoOutput) else { fatalError("Could not add video reader output") }
reader.add(videoOutput)

let audioReader = try AVAssetReader(asset: fullAudioAsset)
let audioOutput = AVAssetReaderTrackOutput(
    track: sourceAudioTrack,
    outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false
    ]
)
guard audioReader.canAdd(audioOutput) else { fatalError("Could not add audio reader output") }
audioReader.add(audioOutput)

guard muxWriter.startWriting(), reader.startReading(), audioReader.startReading() else {
    fatalError(muxWriter.error?.localizedDescription ?? reader.error?.localizedDescription ?? audioReader.error?.localizedDescription ?? "Could not start muxing")
}
muxWriter.startSession(atSourceTime: .zero)

let muxGroup = DispatchGroup()
let videoQueue = DispatchQueue(label: "app-preview.video")
let audioQueue = DispatchQueue(label: "app-preview.audio")

muxGroup.enter()
passthroughVideoInput.requestMediaDataWhenReady(on: videoQueue) {
    while passthroughVideoInput.isReadyForMoreMediaData {
        guard let sample = videoOutput.copyNextSampleBuffer() else {
            passthroughVideoInput.markAsFinished()
            muxGroup.leave()
            return
        }
        if !passthroughVideoInput.append(sample) {
            passthroughVideoInput.markAsFinished()
            muxGroup.leave()
            return
        }
    }
}

muxGroup.enter()
encodedAudioInput.requestMediaDataWhenReady(on: audioQueue) {
    while encodedAudioInput.isReadyForMoreMediaData {
        guard let sample = audioOutput.copyNextSampleBuffer() else {
            encodedAudioInput.markAsFinished()
            muxGroup.leave()
            return
        }
        if !encodedAudioInput.append(sample) {
            encodedAudioInput.markAsFinished()
            muxGroup.leave()
            return
        }
    }
}

muxGroup.wait()
let muxFinish = DispatchSemaphore(value: 0)
muxWriter.finishWriting { muxFinish.signal() }
muxFinish.wait()
guard muxWriter.status == .completed else {
    fatalError(muxWriter.error?.localizedDescription ?? "Final mux failed")
}

print(finalURL.path)
