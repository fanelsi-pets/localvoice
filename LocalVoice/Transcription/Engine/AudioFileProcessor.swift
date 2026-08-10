import AVFoundation
import Foundation
import os

class AudioProcessor {
    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "AudioProcessor")

    struct AudioFormat {
        static let targetSampleRate: Double = 16000.0
        static let targetChannels: UInt32 = 1
        static let targetBitDepth: UInt32 = 16
    }

    enum AudioProcessingError: LocalizedError {
        case invalidAudioFile
        case conversionFailed
        case exportFailed
        case unsupportedFormat
        case sampleExtractionFailed

        var errorDescription: String? {
            switch self {
            case .invalidAudioFile:
                return String(localized: "The audio file is invalid or corrupted")
            case .conversionFailed:
                return String(localized: "Failed to convert the audio format")
            case .exportFailed:
                return String(localized: "Failed to export the processed audio")
            case .unsupportedFormat:
                return String(localized: "The audio format is not supported")
            case .sampleExtractionFailed:
                return String(localized: "Failed to extract audio samples")
            }
        }
    }

    func processAudioToSamples(_ url: URL) async throws -> [Float] {
        do {
            return try readUsingAudioFile(url)
        } catch {
            // AVAudioFile can choke on some container/codec combinations that
            // the media stack can otherwise play (e.g. avfaudio error -50 on
            // certain mp4/m4a meeting recordings, issue #799). AVAssetReader
            // is a more resilient fallback for media containers and delivers
            // target LPCM directly, avoiding manual seeking and conversion.
            logger.warning(
                "AVAudioFile pipeline failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error, privacy: .public). Falling back to AVAssetReader."
            )
            return try await readUsingAssetReader(url)
        }
    }

    private func readUsingAudioFile(_ url: URL) throws -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            throw AudioProcessingError.invalidAudioFile
        }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        let totalFrames = audioFile.length

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: false
        )

        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }

        // Keep peak memory bounded for long meeting recordings and provide regular
        // cancellation points. Five million source frames are roughly 104 seconds
        // at 48 kHz, rather than allocating one enormous buffer for most of a call.
        let chunkSize: AVAudioFrameCount = 5_000_000
        var allSamples: [Float] = []
        let estimatedOutputFrames = Double(totalFrames) * AudioFormat.targetSampleRate / sampleRate
        if estimatedOutputFrames.isFinite,
            estimatedOutputFrames > 0,
            estimatedOutputFrames <= Double(4 * 60 * 60) * AudioFormat.targetSampleRate
        {
            allSamples.reserveCapacity(Int(estimatedOutputFrames.rounded(.up)))
        }
        var currentFrame: AVAudioFramePosition = 0

        while currentFrame < totalFrames {
            try Task.checkCancellation()
            let remainingFrames = totalFrames - currentFrame
            let framesToRead = min(chunkSize, AVAudioFrameCount(remainingFrames))

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw AudioProcessingError.conversionFailed
            }

            // Reads are already sequential. Seeking an AVAudioFile backed by an
            // AAC track inside some MP4/Zoom containers raises an Objective-C
            // NSException instead of a catchable Swift error and aborts the app.
            // Avoiding the redundant setter lets `read` fail normally so the
            // caller can use the resilient AVAssetReader fallback.
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)

            if sampleRate == AudioFormat.targetSampleRate && channels == AudioFormat.targetChannels {
                let chunkSamples = convertToWhisperFormat(inputBuffer)
                allSamples.append(contentsOf: chunkSamples)
            } else {
                guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
                    throw AudioProcessingError.conversionFailed
                }

                let ratio = AudioFormat.targetSampleRate / sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount)
                else {
                    throw AudioProcessingError.conversionFailed
                }

                var error: NSError?
                let status = converter.convert(
                    to: outputBuffer,
                    error: &error,
                    withInputFrom: { inNumPackets, outStatus in
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                )

                if error != nil {
                    throw AudioProcessingError.conversionFailed
                }

                if status == .error {
                    throw AudioProcessingError.conversionFailed
                }

                let chunkSamples = convertToWhisperFormat(outputBuffer)
                allSamples.append(contentsOf: chunkSamples)
            }

            currentFrame += AVAudioFramePosition(framesToRead)
            try Task.checkCancellation()
        }

        // Normalize once across the complete recording. Normalizing each chunk
        // independently changes the relative loudness between quiet and loud
        // sections and can alter the standard file-transcription result when a
        // recording spans more than one chunk.
        try normalizeSamples(&allSamples)
        return allSamples
    }

    private func readUsingAssetReader(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        // Match the legacy behavior of processing one stream by using the
        // primary audio track rather than attempting to mix multiple tracks.
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingError.invalidAudioFile
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.targetSampleRate,
            AVNumberOfChannelsKey: AudioFormat.targetChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw AudioProcessingError.conversionFailed
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? AudioProcessingError.sampleExtractionFailed
        }

        var samples: [Float] = []
        // Reserve the final PCM size up front. Repeated Array growth briefly kept
        // both the old and new buffers alive and pushed a 63-minute Zoom file to
        // ~735 MB RSS even though its final Float payload is ~243 MB.
        if let duration = try? await asset.load(.duration) {
            let estimatedSamples = duration.seconds * AudioFormat.targetSampleRate
            if estimatedSamples.isFinite,
                estimatedSamples > 0,
                estimatedSamples <= Double(4 * 60 * 60) * AudioFormat.targetSampleRate
            {
                samples.reserveCapacity(Int(estimatedSamples.rounded(.up)))
            }
        }
        do {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try validateAssetReaderOutputFormat(sampleBuffer)

                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount >= MemoryLayout<Float>.size else { continue }

                var chunk = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                let status = chunk.withUnsafeMutableBytes { destination in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: destination.count,
                        destination: destination.baseAddress!
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw AudioProcessingError.sampleExtractionFailed
                }
                samples.append(contentsOf: chunk)
            }
        } catch {
            reader.cancelReading()
            throw error
        }

        if reader.status == .failed {
            throw reader.error ?? AudioProcessingError.sampleExtractionFailed
        }
        if reader.status == .cancelled {
            throw CancellationError()
        }
        guard !samples.isEmpty else {
            throw AudioProcessingError.sampleExtractionFailed
        }

        // Keep the fallback output in the same globally normalized Float range
        // as the primary AVAudioFile path.
        try normalizeSamples(&samples)
        return samples
    }

    private func validateAssetReaderOutputFormat(_ sampleBuffer: CMSampleBuffer) throws {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw AudioProcessingError.sampleExtractionFailed
        }

        let format = streamDescription.pointee
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        guard
            format.mFormatID == kAudioFormatLinearPCM,
            abs(format.mSampleRate - AudioFormat.targetSampleRate) < 1.0,
            format.mChannelsPerFrame == AudioFormat.targetChannels,
            format.mBitsPerChannel == 32,
            isFloat,
            !isBigEndian,
            // Interleaving only changes the byte layout for multi-channel
            // audio; mono is identical either way, so don't reject it.
            format.mChannelsPerFrame == 1 || !isNonInterleaved
        else {
            throw AudioProcessingError.conversionFailed
        }
    }

    private func convertToWhisperFormat(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var samples = Array(repeating: Float(0), count: frameLength)

        if channelCount == 1 {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        } else {
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                samples[frame] = sum / Float(channelCount)
            }
        }

        return samples
    }

    private func normalizeSamples(_ samples: inout [Float]) throws {
        var maxSample: Float = 0
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 65_536) {
                try Task.checkCancellation()
            }
            maxSample = max(maxSample, abs(sample))
        }

        guard maxSample > 0 else { return }

        for index in samples.indices {
            if index.isMultiple(of: 65_536) {
                try Task.checkCancellation()
            }
            samples[index] /= maxSample
        }
    }

    func saveSamplesAsWav(samples: [Float], to url: URL) throws {
        try Task.checkCancellation()
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: true
        )

        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        // Write in bounded chunks. A one-hour meeting contains about 61 million
        // Float samples. Allocating a full Int16 array and a full AVAudioPCMBuffer
        // alongside it added another ~240 MB on top of the Whisper sample array.
        // The chunked writer keeps that conversion overhead near 1 MB regardless
        // of the source video size.
        let chunkCapacity: AVAudioFrameCount = 262_144
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let count = min(Int(chunkCapacity), samples.count - offset)
            guard
                let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkCapacity),
                let destination = buffer.int16ChannelData?[0]
            else {
                throw AudioProcessingError.conversionFailed
            }

            samples.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }
                for index in 0..<count {
                    let sample = sourceBase[offset + index]
                    destination[index] = Int16(
                        max(-1.0, min(1.0, sample)) * Float(Int16.max)
                    )
                }
            }

            buffer.frameLength = AVAudioFrameCount(count)
            try audioFile.write(from: buffer)
            offset += count
        }
    }
}
