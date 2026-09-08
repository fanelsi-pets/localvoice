import Foundation
import LLMkit
import MeetingScribeUI

/// Follow-up for a processed meeting through Gemini with the user's own API key (free tier) — the same
/// `AIService` and key that power text improvement. The core builds the prompt (structure, rules, the
/// `meeting-followup` block) and parses the answer; this class only makes the request.
@MainActor
final class GeminiFollowupGenerator: FollowupGenerating {
    private let aiService: AIService
    /// Long transcripts take a while to read and to write a full follow-up for.
    private let timeout: TimeInterval = 300

    init(aiService: AIService) {
        self.aiService = aiService
    }

    var title: String { "Gemini · \(aiService.selectedModel(for: .gemini))" }

    var isAvailable: Bool {
        APIKeyManager.shared.hasAPIKey(forProvider: AIProvider.gemini.rawValue)
    }

    var unavailableReason: String? {
        isAvailable ? nil : String(localized: "Add a Gemini API key in AI Models to generate follow-ups.")
    }

    func generate(prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let text = try await aiService.completeChat(
                        provider: .gemini,
                        modelName: nil,
                        messages: [ChatMessage.user(prompt)],
                        systemPrompt: nil,
                        timeout: timeout
                    )
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
