import Core
import Foundation
import Testing

@testable import LocalVoice

@Suite("Gemini Transcribe client")
struct GeminiTranscribeClientTests {
    @Test("Only the non-live transcribe model is routed to the Interactions API")
    func routing() {
        #expect(GeminiTranscribeClient.isTranscribeModel("gemini-3.5-transcribe"))
        #expect(!GeminiTranscribeClient.isTranscribeModel("gemini-3.5-transcribe-live"))
        #expect(!GeminiTranscribeClient.isTranscribeModel("gemini-3.1-flash-lite"))
    }

    @Test("MIME type follows the recording's extension, WAV by default")
    func mimeTypes() {
        #expect(GeminiTranscribeClient.mimeType(for: "recording.wav") == "audio/wav")
        #expect(GeminiTranscribeClient.mimeType(for: "clip.M4A") == "audio/mp4")
        #expect(GeminiTranscribeClient.mimeType(for: "voice.mp3") == "audio/mp3")
        #expect(GeminiTranscribeClient.mimeType(for: "noext") == "audio/wav")
    }

    @Test("Interaction body: model, audio uri, smart mode, auto language unless forced, vocabulary capped")
    func interactionBody() throws {
        let auto = GeminiTranscribeClient.interactionBody(
            model: "gemini-3.5-transcribe", uri: "https://files/abc", mimeType: "audio/wav", language: nil,
            vocabulary: [" LocalVoice ", "", "Zoom"])
        #expect(auto["model"] as? String == "gemini-3.5-transcribe")
        let input = try #require(auto["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "audio")
        #expect(input[0]["uri"] as? String == "https://files/abc")
        #expect(input[0]["mime_type"] as? String == "audio/wav")
        let config = try #require((auto["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        #expect((config["language_codes"] as? [String]) == [])
        #expect(config["mode"] as? String == "smart")
        #expect((config["custom_vocabulary"] as? [String]) == ["LocalVoice", "Zoom"])
        #expect(JSONSerialization.isValidJSONObject(auto))

        let forced = GeminiTranscribeClient.interactionBody(
            model: "gemini-3.5-transcribe", uri: "u", mimeType: "audio/wav", language: "uk", vocabulary: [])
        let forcedConfig = try #require((forced["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        #expect((forcedConfig["language_codes"] as? [String]) == ["uk-UA"])
        #expect(forcedConfig["custom_vocabulary"] == nil)
    }

    @Test("Transcript comes from output_text, otherwise from the model output steps; errors surface")
    func transcriptParsing() throws {
        let direct = #"{"id":"interactions/1","status":"completed","output_text":"  Привет, мир  ","steps":[]}"#
        #expect(try GeminiTranscribeClient.transcript(from: Data(direct.utf8)) == "Привет, мир")

        let steps = #"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"Перша фраза."},{"type":"audio","text":"ignored"},{"type":"text","text":"Друга."}]}]}"#
        #expect(try GeminiTranscribeClient.transcript(from: Data(steps.utf8)) == "Перша фраза. Друга.")

        #expect(try GeminiTranscribeClient.transcript(from: Data(#"{"status":"completed","steps":[]}"#.utf8)) == "")

        let error = #"{"error":{"code":404,"message":"models/gemini-3.5-transcribe is not found","status":"NOT_FOUND"}}"#
        #expect(throws: CloudTranscriptionError.self) { try GeminiTranscribeClient.transcript(from: Data(error.utf8)) }
    }

    @Test("Uploaded file response is parsed with its state")
    func uploadedFile() throws {
        let json = #"{"file":{"name":"files/abc123","uri":"https://generativelanguage.googleapis.com/v1beta/files/abc123","state":"PROCESSING","mimeType":"audio/wav"}}"#
        let file = try GeminiTranscribeClient.uploadedFile(from: Data(json.utf8))
        #expect(file == GeminiTranscribeClient.UploadedFile(name: "files/abc123", uri: "https://generativelanguage.googleapis.com/v1beta/files/abc123", state: "PROCESSING"))
        #expect(throws: CloudTranscriptionError.self) { try GeminiTranscribeClient.uploadedFile(from: Data("{}".utf8)) }
    }

    // MARK: - Режим встреч: слова с таймкодами

    @Test("Meeting mode: verbatim mode object with word timestamps, vocabulary dropped")
    func timedInteractionBody() throws {
        let body = GeminiTranscribeClient.interactionBody(
            model: "gemini-3.5-transcribe", uri: "https://files/clip", mimeType: "audio/flac", language: nil,
            vocabulary: ["LocalVoice"], wordTimestamps: true)
        let config = try #require((body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        let mode = try #require(config["mode"] as? [String: Any])
        #expect(mode["type"] as? String == "verbatim")
        #expect((mode["timestamp_granularities"] as? [String]) == ["word"])
        // Словарь несовместим со словными таймкодами — API отклонил бы запрос.
        #expect(config["custom_vocabulary"] == nil)
        #expect((config["language_codes"] as? [String])?.isEmpty == true)
    }

    @Test("Word annotations are parsed with speakers and second offsets, sorted by time")
    func timedWords() throws {
        let json = """
        {"status":"completed","output_text":"Привет світ","steps":[{"type":"model_output","content":[{"type":"text","text":"Привет світ","annotations":[
        {"type":"word_info","text":"світ","speaker":"spk_2","start_offset":"0.500s","end_offset":"0.850s"},
        {"type":"word_info","text":"Привет","speaker":"spk_1","start_offset":"0.100s","end_offset":"0.450s"},
        {"type":"other","text":"ignored"}]}]}]}
        """
        let words = try GeminiTranscribeClient.words(from: Data(json.utf8), clipDuration: 900)
        #expect(words.count == 2)
        #expect(words[0] == GeminiTranscribeClient.TimedWord(text: "Привет", start: 0.1, end: 0.45, speaker: "spk_1"))
        #expect(words[1].text == "світ")
        #expect(words[1].speaker == "spk_2")
    }

    @Test("Without annotations the chunk text is spread over the clip instead of being lost")
    func timedWordsFallback() throws {
        let json = #"{"status":"completed","output_text":"одне два три чотири","steps":[]}"#
        let words = try GeminiTranscribeClient.words(from: Data(json.utf8), clipDuration: 8)
        #expect(words.count == 4)
        #expect(words.first?.text == "одне")
        #expect(words.first?.start == 0)
        #expect(words.last?.end == 8)
        #expect(words.allSatisfy { $0.speaker == nil })

        let error = #"{"error":{"code":429,"message":"quota"}}"#
        #expect(throws: CloudTranscriptionError.self) {
            try GeminiTranscribeClient.words(from: Data(error.utf8), clipDuration: 8)
        }
    }

    @Test("Offsets come as protobuf durations")
    func offsets() {
        #expect(GeminiTranscribeClient.offsetSeconds("0.450s") == 0.45)
        #expect(GeminiTranscribeClient.offsetSeconds("12s") == 12)
        #expect(GeminiTranscribeClient.offsetSeconds(1.5) == 1.5)
        #expect(GeminiTranscribeClient.offsetSeconds("nonsense") == nil)
        #expect(GeminiTranscribeClient.offsetSeconds(nil) == nil)
    }

    @Test("Provider failures: 429 and 5xx are retryable, a missing model is not")
    func retryClassification() {
        let overloaded = GeminiMeetingTranscriber.mapped(
            CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: "quota"))
        #expect((overloaded as? RemoteTranscriptionError)?.isRetryable == true)
        let missing = GeminiMeetingTranscriber.mapped(
            CloudTranscriptionError.apiRequestFailed(statusCode: 404, message: "not found"))
        #expect((missing as? RemoteTranscriptionError)?.isRetryable == false)
        let network = GeminiMeetingTranscriber.mapped(CloudTranscriptionError.networkError(URLError(.timedOut)))
        #expect((network as? RemoteTranscriptionError)?.isRetryable == true)
    }
}
