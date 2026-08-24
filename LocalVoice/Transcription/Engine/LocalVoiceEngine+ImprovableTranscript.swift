import Foundation
import os

private let improvableTranscriptLogger = Logger(
    subsystem: "app.localvoice.LocalVoice", category: "ImprovableTranscript")

// MARK: - Post-paste "Improve" suggestion

extension LocalVoiceEngine {
    /// Called once a normal (non-follow-up, non-auto-send) paste has landed. Offers a
    /// one-tap rewrite for dictations long enough that cleanup and structure actually help.
    func offerImprovementIfEligible(pastedText: String, dictationDuration: TimeInterval) {
        improvableTranscriptLogger.notice(
            "Delivered paste: duration=\(dictationDuration, privacy: .public)s chars=\(pastedText.count, privacy: .public)"
        )

        guard TranscriptStructuringSuggestion.isEligible(text: pastedText, dictationDuration: dictationDuration)
        else {
            improvableTranscriptLogger.notice(
                "Not eligible: needs duration>=\(TranscriptStructuringSuggestion.minimumDictationDuration, privacy: .public)s and chars>=\(TranscriptStructuringSuggestion.minimumCharacterCount, privacy: .public)"
            )
            return
        }
        guard let enhancementService, let aiService = enhancementService.getAIService() else {
            improvableTranscriptLogger.notice("No enhancement/AI service available")
            return
        }

        let baseConfiguration = ModeRuntimeResolver.currentEnhancementConfiguration(
            enhancementService: enhancementService,
            aiService: aiService
        )
        let structuringConfiguration = TranscriptStructuringSuggestion.makeConfiguration(from: baseConfiguration)
        guard enhancementService.isConfigured(for: structuringConfiguration) else {
            improvableTranscriptLogger.notice(
                "No configured AI provider for the improve suggestion (provider=\(structuringConfiguration.provider?.rawValue ?? "nil", privacy: .public))"
            )
            return
        }

        improvableTranscriptLogger.notice("Showing improve suggestion")

        NotificationManager.shared.showNotification(
            title: String(localized: "Long dictation — clean it up and structure it?"),
            type: .ai,
            duration: 8.0,
            actionButton: (
                label: String(localized: "Improve"),
                action: { [weak self] in
                    Task { @MainActor in
                        await self?.improvePastedText(pastedText)
                    }
                }
            )
        )
    }

    private func improvePastedText(_ originalPastedText: String) async {
        guard let enhancementService else { return }

        do {
            let improvedText = try await enhancementService.structureText(originalPastedText)
            await CursorPaster.undoLastPasteAndReplace(with: improvedText)
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Improve failed: %@"), errorDescription),
                type: .error
            )
        }
    }
}
