import Foundation

// MARK: - Post-paste "Improve" suggestion

extension LocalVoiceEngine {
    /// Called once a normal (non-follow-up, non-auto-send) paste has landed. Offers a
    /// one-tap rewrite for dictations long enough that cleanup and structure actually help.
    func offerImprovementIfEligible(pastedText: String, dictationDuration: TimeInterval) {
        guard TranscriptStructuringSuggestion.isEligible(text: pastedText, dictationDuration: dictationDuration)
        else {
            return
        }
        guard let enhancementService, let aiService = enhancementService.getAIService() else { return }

        let baseConfiguration = ModeRuntimeResolver.currentEnhancementConfiguration(
            enhancementService: enhancementService,
            aiService: aiService
        )
        let structuringConfiguration = TranscriptStructuringSuggestion.makeConfiguration(from: baseConfiguration)
        guard enhancementService.isConfigured(for: structuringConfiguration) else { return }

        NotificationManager.shared.showNotification(
            title: String(localized: "Long dictation — clean it up and structure it?"),
            type: .ai,
            duration: 8.0,
            actionButton: (
                label: String(localized: "Improve"),
                action: { [weak self] in
                    Task { @MainActor in
                        await self?.improvePastedText(pastedText, configuration: structuringConfiguration)
                    }
                }
            )
        )
    }

    private func improvePastedText(_ originalPastedText: String, configuration: EnhancementRuntimeConfiguration) async {
        guard let enhancementService else { return }

        do {
            let (improvedText, _, _) = try await enhancementService.enhance(
                originalPastedText,
                configuration: configuration
            )
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
