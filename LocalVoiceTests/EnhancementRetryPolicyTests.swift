import Foundation
import Testing

@testable import LocalVoice

@Suite("Enhancement retry policy")
struct EnhancementRetryPolicyTests {
    @Test("Provider detail is taken from a JSON error body (Gemini / OpenAI shapes)")
    func detailFromJSON() {
        let gemini = #"{"error": {"code": 503, "message": "The model is overloaded. Please try again later.", "status": "UNAVAILABLE"}}"#
        #expect(EnhancementRetryPolicy.providerDetail(from: gemini) == "UNAVAILABLE: The model is overloaded. Please try again later.")
        let openAI = #"{"error": {"message": "Rate limit reached", "type": "rate_limit_error"}}"#
        #expect(EnhancementRetryPolicy.providerDetail(from: openAI) == "rate_limit_error: Rate limit reached")
        #expect(EnhancementRetryPolicy.providerDetail(from: #"{"error": "overloaded"}"#) == "overloaded")
    }

    @Test("Plain bodies are trimmed and capped, empty bodies give no detail")
    func detailFromPlainText() {
        #expect(EnhancementRetryPolicy.providerDetail(from: "  <html>Bad gateway</html>\n") == "<html>Bad gateway</html>")
        #expect(EnhancementRetryPolicy.providerDetail(from: "   ") == nil)
        let long = String(repeating: "x", count: 500)
        #expect(EnhancementRetryPolicy.providerDetail(from: long, limit: 50)?.count == 50)
    }

    @Test("Suggested retry delay is parsed from provider hints")
    func suggestedDelay() {
        #expect(EnhancementRetryPolicy.suggestedRetryDelay(in: "Please retry in 23.4s.") == 23.4)
        #expect(EnhancementRetryPolicy.suggestedRetryDelay(in: #"RESOURCE_EXHAUSTED: quota exceeded, "retryDelay": "12s""#) == 12)
        #expect(EnhancementRetryPolicy.suggestedRetryDelay(in: "Retry after 5 seconds") == 5)
        #expect(EnhancementRetryPolicy.suggestedRetryDelay(in: "The model is overloaded.") == nil)
        #expect(EnhancementRetryPolicy.suggestedRetryDelay(in: nil) == nil)
    }

    @Test("Delays are clamped to the maximum and the schedule is ascending")
    func clampAndSchedule() {
        #expect(EnhancementRetryPolicy.clampedDelay(120) == EnhancementRetryPolicy.maximumDelay)
        #expect(EnhancementRetryPolicy.clampedDelay(-1) == 0)
        let delays = EnhancementRetryPolicy.defaultDelays
        #expect(delays == delays.sorted())
        #expect(delays.reduce(0, +) <= EnhancementRetryPolicy.maximumDelay)
    }

    @Test("Error descriptions carry the provider detail")
    func descriptionsWithDetail() {
        let server = EnhancementError.serverError(detail: "UNAVAILABLE: The model is overloaded.")
        #expect(server.errorDescription?.hasSuffix("(UNAVAILABLE: The model is overloaded.)") == true)
        let plain = EnhancementError.serverError(detail: nil)
        #expect(plain.errorDescription?.contains("(") == false)
        let limited = EnhancementError.rateLimitExceeded(detail: "quota")
        #expect(limited.errorDescription?.hasSuffix("(quota)") == true)
    }
}
