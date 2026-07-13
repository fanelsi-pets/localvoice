import SwiftUI

struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let setupKind: OnboardingTranscriptionSetupKind
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isSetupReady: Bool
    let onSelectSetupKind: (OnboardingTranscriptionSetupKind) -> Void
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    @EnvironmentObject private var whisperModelManager: WhisperModelManager

    private var isLocalDownloading: Bool {
        !whisperModelManager.downloadProgress.isEmpty
    }

    var body: some View {
        OnboardingStepScreen(
            stage: .model,
            contentMaxWidth: contentMaxWidth
        ) {
            OnboardingTranscriptionSetupCard(
                setupKind: setupKind,
                providerOptions: providerOptions,
                selectedProviderKey: $selectedProviderKey,
                onSelectSetupKind: onSelectSetupKind,
                onVerificationChanged: onVerificationChanged
            )
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isSetupReady && !(setupKind == .local && isLocalDownloading),
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
    }
}
