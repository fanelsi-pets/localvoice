import Foundation
import Testing

@testable import LocalVoice

@Suite("Local-only network blocker")
struct LocalOnlyNetworkBlockerTests {
    private func blocked(_ url: String) -> Bool {
        LocalOnlyNetworkBlocker.canInit(with: URLRequest(url: URL(string: url)!))
    }

    @Test("Cloud providers the app integrates are allowed, anything else is blocked")
    func allowlist() {
        #expect(!blocked("https://generativelanguage.googleapis.com/v1beta/interactions"))
        #expect(!blocked("https://api.openai.com/v1/models"))
        #expect(!blocked("https://northeurope.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe"))
        #expect(!blocked("https://localvoice-speech.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe"))
        #expect(!blocked("https://huggingface.co/argmaxinc/whisperkit-coreml"))
        #expect(blocked("https://example.com/"))
        #expect(blocked("https://api.cognitive.microsoft.com.evil.example/"))
        #expect(blocked("wss://generativelanguage.googleapis.com.example/ws"))
        #expect(!blocked("file:///tmp/a.wav"))
    }
}
