import Core
import Foundation
import Testing

@testable import LocalVoice

@Suite("Azure Speech client (MAI-Transcribe-2)")
struct AzureSpeechClientTests {
    @Test("Endpoint targets the resource region and the fast transcription API version")
    func endpoint() {
        #expect(
            AzureSpeechClient.endpoint(region: "northeurope").absoluteString
                == "https://northeurope.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
        )
    }

    @Test("Definition: MAI model in enhanced mode, style and timestamps, vocabulary capped, no diarization")
    func definition() throws {
        let definition = AzureSpeechClient.definition(
            style: .verbatim, timestamps: .word,
            phrases: Array(repeating: "term", count: 1200) + [" ", ""], locales: ["ru"])
        let enhanced = try #require(definition["enhancedMode"] as? [String: Any])
        #expect(enhanced["model"] as? String == "MAI-Transcribe-2")
        #expect(enhanced["enabled"] as? Bool == true)
        // Внутри enhancedMode: на верхнем уровне API их игнорирует и не отдаёт слова.
        #expect(definition["modelOptions"] == nil)
        let options = try #require(enhanced["modelOptions"] as? [String: String])
        #expect(options["transcribeStyle"] == "verbatim")
        #expect(options["timestamps"] == "word")
        #expect((definition["diarization"] as? [String: Bool])?["enabled"] == false)
        #expect((definition["phraseList"] as? [String: [String]])?["phrases"]?.count == 1000)
        #expect(definition["locales"] as? [String] == ["ru"])

        let plain = AzureSpeechClient.definition(style: .clean, timestamps: .none, phrases: [" "], locales: [])
        #expect(plain["phraseList"] == nil)
        #expect(((plain["enhancedMode"] as? [String: Any])?["modelOptions"] as? [String: String])?["timestamps"] == "none")
        #expect(JSONSerialization.isValidJSONObject(plain))
    }

    @Test("Locales: automatic detection unless a language is forced")
    func locales() {
        #expect(AzureSpeechClient.locales(for: nil).isEmpty)
        #expect(AzureSpeechClient.locales(for: "auto").isEmpty)
        #expect(AzureSpeechClient.locales(for: " RU ") == ["ru"])
    }

    @Test("Multipart body carries the JSON definition and the audio with its MIME type")
    func multipart() {
        let body = AzureSpeechClient.multipartBody(
            definition: Data("{\"a\":1}".utf8), audio: Data([1, 2, 3]), fileName: "clip.flac",
            mimeType: "audio/flac", boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"definition\"\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n\r\n{\"a\":1}\r\n--B\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"audio\"; filename=\"clip.flac\"\r\n"))
        #expect(text.contains("Content-Type: audio/flac\r\n\r\n"))
        #expect(text.hasSuffix("\r\n--B--\r\n"))
    }

    @Test("Response: words in seconds from millisecond offsets, text from combined phrases")
    func parse() throws {
        let json = """
            {"durationMilliseconds": 4000,
             "combinedPhrases": [{"text": "Gotcha.\\nThat makes sense."}],
             "phrases": [
               {"speaker": 0, "offsetMilliseconds": 80, "durationMilliseconds": 339, "text": "Gotcha.", "locale": "en",
                "words": [{"text": "Gotcha.", "offsetMilliseconds": 80, "durationMilliseconds": 339}]},
               {"offsetMilliseconds": 1000, "durationMilliseconds": 900, "text": "That makes sense.",
                "words": [{"text": "That", "offsetMilliseconds": 1000, "durationMilliseconds": 200},
                          {"text": " ", "offsetMilliseconds": 1200, "durationMilliseconds": 10},
                          {"text": "makes", "offsetMilliseconds": 1250, "durationMilliseconds": 250},
                          {"text": "sense.", "offsetMilliseconds": 1500, "durationMilliseconds": 400}]}
             ]}
            """
        let transcript = try AzureSpeechClient.parse(Data(json.utf8))
        #expect(transcript.duration == 4)
        #expect(transcript.text == "Gotcha.\nThat makes sense.")
        #expect(transcript.words.map(\.text) == ["Gotcha.", "That", "makes", "sense."])
        #expect(transcript.words.first?.start == 0.08)
        #expect(abs((transcript.words.first?.end ?? 0) - 0.419) < 0.0001)
        #expect(transcript.words.last?.end == 1.9)
        #expect(AzureSpeechClient.singleLine(transcript.text) == "Gotcha. That makes sense.")
    }

    @Test("Without combined text the phrases are joined; an error body is reported with its message")
    func fallbacks() throws {
        let transcript = try AzureSpeechClient.parse(
            Data(#"{"phrases": [{"text": "Один."}, {"text": "Два."}]}"#.utf8))
        #expect(transcript.text == "Один. Два.")
        #expect(transcript.words.isEmpty)
        #expect(
            AzureSpeechClient.errorMessage(
                from: Data(#"{"error": {"code": "InvalidRequest", "message": "bad audio"}}"#.utf8), statusCode: 400)
                == "bad audio")
        #expect(AzureSpeechClient.errorMessage(from: Data(), statusCode: 503).contains("503"))
    }

    @Test("Meeting words: timestamps pass through, otherwise text is spread evenly over the clip")
    func meetingWords() {
        let timed = AzureSpeechClient.Transcript(
            text: "a b", words: [.init(text: "a", start: 1, end: 1.5), .init(text: "b", start: 2, end: 2.5)],
            duration: 3)
        #expect(AzureMeetingTranscriber.remoteWords(timed, clipDuration: 10).map(\.start) == [1, 2])
        let spread = AzureMeetingTranscriber.remoteWords(
            AzureSpeechClient.Transcript(text: "a b c d", words: [], duration: 0), clipDuration: 8)
        #expect(spread.count == 4)
        #expect(spread.last?.end == 8)
        #expect(AzureMeetingTranscriber.remoteWords(.init(text: "", words: [], duration: 0), clipDuration: 8).isEmpty)
    }

    @Test("Retryable failures: 408, 429 and 5xx; a rejected key and a 400 are final")
    func retryability() {
        func retryable(_ error: any Error) -> Bool? {
            (AzureMeetingTranscriber.mapped(error) as? RemoteTranscriptionError)?.isRetryable
        }
        #expect(retryable(CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: "slow down")) == true)
        #expect(retryable(CloudTranscriptionError.apiRequestFailed(statusCode: 408, message: "timeout")) == true)
        #expect(retryable(CloudTranscriptionError.apiRequestFailed(statusCode: 503, message: "busy")) == true)
        #expect(retryable(CloudTranscriptionError.apiRequestFailed(statusCode: 400, message: "bad")) == false)
        #expect(retryable(CloudTranscriptionError.invalidAPIKey) == false)
        #expect(AzureMeetingTranscriber.mapped(CancellationError()) is CancellationError)
    }

    @Test("An empty key is rejected before any request leaves the app")
    func emptyKeyIsRejected() async {
        let error = await MeetingCloudCredentials.verifyAndSave(key: "   ", region: nil)
        #expect(error != nil)
    }

    @Test("Region: portal spelling is normalized, empty falls back to the default")
    func region() {
        #expect(AzureSpeechSettings.normalized("North Europe") == "northeurope")
        #expect(AzureSpeechSettings.normalized("  West US 2 ") == "westus2")
        #expect(AzureSpeechSettings.normalized("  ") == nil)
        #expect(AzureSpeechSettings.knownRegions.contains(AzureSpeechSettings.defaultRegion))
    }

    @Test("Silent WAV for key checks is a valid 16 kHz mono PCM file")
    func silentWAV() {
        let wav = AzureSpeechClient.silentWAV(seconds: 1)
        #expect(wav.count == 44 + 32_000)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(AzureSpeechClient.mimeType(for: "clip.FLAC") == "audio/flac")
        #expect(AzureSpeechClient.mimeType(for: "clip.wav") == "audio/wav")
    }
}
