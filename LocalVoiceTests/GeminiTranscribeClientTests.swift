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
}
