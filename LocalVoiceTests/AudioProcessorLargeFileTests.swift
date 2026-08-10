import AVFoundation
import Testing
@testable import LocalVoice

struct AudioProcessorLargeFileTests {
    @Test func writesMultiChunkMeetingWavWithoutChangingFrameCount() throws {
        let chunkSize = 262_144
        let sampleCount = chunkSize * 2 + 137
        var samples = [Float](repeating: 0, count: sampleCount)
        for index in samples.indices {
            samples[index] = Float((index % 2_000) - 1_000) / 1_000
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoice-large-wav-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try AudioProcessor().saveSamplesAsWav(samples: samples, to: outputURL)

        let file = try AVAudioFile(forReading: outputURL)
        #expect(file.length == AVAudioFramePosition(sampleCount))
        #expect(abs(file.fileFormat.sampleRate - AudioProcessor.AudioFormat.targetSampleRate) < 0.1)
        #expect(file.fileFormat.channelCount == AudioProcessor.AudioFormat.targetChannels)
    }
}
