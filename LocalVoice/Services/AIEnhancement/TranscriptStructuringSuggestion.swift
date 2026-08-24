import Foundation

/// The "✨ Improve" suggestion offered after a long, freeform dictation is pasted:
/// restructure the already-delivered text into a cleaner shape without changing what it says.
enum TranscriptStructuringSuggestion {
    /// Only offer the suggestion once a dictation ran long enough that structure
    /// actually helps. Short dictations rarely benefit and would just add noise.
    static let minimumDictationDuration: TimeInterval = 20

    /// Secondary guard alongside duration: a long recording that transcribed to
    /// very little text (silence, false starts) doesn't need structuring either.
    /// ~20s of normal speech transcribes to roughly 200-250 characters, so this
    /// stays a bit below that rather than requiring an unusually long dictation.
    static let minimumCharacterCount = 250

    static func isEligible(text: String, dictationDuration: TimeInterval) -> Bool {
        dictationDuration >= minimumDictationDuration && text.count >= minimumCharacterCount
    }

    private static let promptID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    private static let promptText = """
        Restructure this text for clarity, without changing what it says.

        # Rules
        - Preserve the original meaning, facts, names, numbers, and intent exactly. Do not add, remove, or reinterpret information.
        - Resolve contradictions, garbled phrasing, and logical inconsistencies introduced by dictation, choosing the interpretation that best fits the surrounding context.
        - If the text expresses multiple distinct ideas, steps, or items, reorganize it into a clear bulleted or numbered list, with short headings only if that genuinely helps. If it is a single continuous thought, keep it as flowing prose instead of forcing a list.
        - Keep the original language and tone. Do not translate.
        - Do not add greetings, sign-offs, or any commentary that was not implied by the source.
        """

    static func makeConfiguration(from base: EnhancementRuntimeConfiguration) -> EnhancementRuntimeConfiguration {
        let prompt = CustomPrompt(
            id: promptID,
            title: String(localized: "Structure"),
            promptText: promptText,
            useSystemInstructions: true
        )
        return base.replacingPrompt(prompt)
    }
}

extension AIEnhancementService {
    /// Runs the same fixed structuring prompt used by the post-dictation "Improve"
    /// suggestion, but against arbitrary text (e.g. from the Services menu) rather
    /// than a just-delivered transcript. Uses whatever AI provider/model the user
    /// currently has connected, regardless of the active Mode's own enhancement setting.
    func structureText(_ text: String) async throws -> String {
        guard let aiService = getAIService() else {
            throw EnhancementError.notConfigured
        }

        let baseConfiguration = ModeRuntimeResolver.currentEnhancementConfiguration(
            enhancementService: self,
            aiService: aiService
        )
        let configuration = TranscriptStructuringSuggestion.makeConfiguration(from: baseConfiguration)

        guard isConfigured(for: configuration) else {
            throw EnhancementError.notConfigured
        }

        let (result, _, _) = try await enhance(text, configuration: configuration)
        return result
    }
}
