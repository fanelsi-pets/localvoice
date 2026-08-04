#!/usr/bin/env swift

import AppKit
import AVFoundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let videoURL = root.appendingPathComponent("AppStore/Assets/video/LocalVoice-App-Preview-en.mp4")
let asset = AVURLAsset(url: videoURL)

guard let videoTrack = asset.tracks(withMediaType: .video).first else {
    fatalError("Missing video track")
}

let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
let size = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
let audioTrack = asset.tracks(withMediaType: .audio).first

print("file=\(videoURL.path)")
print("duration=\(String(format: "%.3f", asset.duration.seconds))")
print("dimensions=\(Int(size.width))x\(Int(size.height))")
print("fps=\(String(format: "%.2f", videoTrack.nominalFrameRate))")
print("estimated_video_bitrate=\(Int(videoTrack.estimatedDataRate))")
print("has_audio=\(audioTrack != nil)")
if let audioTrack {
    print("estimated_audio_bitrate=\(Int(audioTrack.estimatedDataRate))")
    if let description = audioTrack.formatDescriptions.first,
       let format = CMAudioFormatDescriptionGetStreamBasicDescription(description as! CMAudioFormatDescription)?.pointee {
        print("audio_channels=\(format.mChannelsPerFrame)")
        print("audio_sample_rate=\(Int(format.mSampleRate))")
    }
}

let thumbnailsDirectory = root.appendingPathComponent("AppStore/Assets/video/frames")
try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 1280, height: 720)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

for second in [1.0, 4.0, 6.0, 11.2, 14.0] {
    let image = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
        fatalError("Could not encode thumbnail")
    }
    let destination = thumbnailsDirectory.appendingPathComponent(String(format: "%04.1f.jpg", second))
    try data.write(to: destination, options: .atomic)
    print("thumbnail=\(destination.path)")
}
