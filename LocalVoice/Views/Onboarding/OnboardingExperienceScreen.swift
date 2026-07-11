import SwiftUI

struct OnboardingExperienceScreen: View {
    let step: OnboardingExperienceStep
    let isInIntroPhase: Bool
    let shortcutAction: ShortcutAction
    let hasShortcut: Bool
    @Binding var text: String
    let isLastStep: Bool
    let isReady: Bool
    let isComplete: Bool
    let onBackFromIntro: () -> Void
    let onContinueIntro: () -> Void
    let onBackFromPractice: () -> Void
    let onAdvance: () -> Void
    let onShortcutChanged: () -> Void
    let onAppear: () -> Void
    @State private var transcriptPulse = false

    var body: some View {
        Group {
            if isInIntroPhase {
                introScreen
                    .transition(.opacity)
            } else {
                practiceScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isInIntroPhase)
        .onAppear(perform: onAppear)
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionCompleted)) { notification in
            guard !isInIntroPhase,
                let transcription = notification.object as? Transcription
            else { return }

            let result = (transcription.enhancedText?.isEmpty == false)
                ? transcription.enhancedText ?? transcription.text
                : transcription.text
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            withAnimation(.easeOut(duration: 0.22)) {
                text = result
                transcriptPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                    transcriptPulse = false
                }
            }
        }
    }

    private var introScreen: some View {
        OnboardingStepScreen(
            systemImage: systemImage,
            title: step.title,
            subtitle: step.subtitle,
            contentMaxWidth: 560,
            showsHeader: true
        ) {
            OnboardingExperienceIntroCard(
                step: step,
                shortcutAction: shortcutAction,
                hasShortcut: hasShortcut,
                onShortcutChanged: onShortcutChanged
            )
            .id(step.id)
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: hasShortcut,
                onLeading: onBackFromIntro,
                onPrimary: onContinueIntro
            )
        }
    }

    private var practiceScreen: some View {
        OnboardingStepScreen(
            systemImage: systemImage,
            title: step.title,
            subtitle: step.subtitle,
            contentMaxWidth: 700,
            showsHeader: true
        ) {
            OnboardingExperienceCard(
                step: step,
                shortcutAction: shortcutAction,
                hasShortcut: hasShortcut,
                text: $text,
                onShortcutChanged: onShortcutChanged
            )
            .scaleEffect(transcriptPulse ? 1.018 : 1)
            .shadow(
                color: transcriptPulse ? AppTheme.Accent.primary.opacity(0.24) : .clear,
                radius: transcriptPulse ? 18 : 0
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.72), value: transcriptPulse)
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: isLastStep ? "Continue" : "Next",
                isPrimaryEnabled: isReady && isComplete,
                onLeading: onBackFromPractice,
                onPrimary: onAdvance
            )
        }
    }

    private var systemImage: String {
        step.systemImage
    }
}
