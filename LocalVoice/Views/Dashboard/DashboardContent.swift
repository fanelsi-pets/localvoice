import AppKit
import SwiftUI

struct DashboardContent: View {
    @EnvironmentObject private var engine: LocalVoiceEngine
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @State private var isAccessibilityEnabled = AXIsProcessTrusted()
    @State private var latestTranscript = ""
    @State private var testError: String?
    @State private var isDashboardTestActive = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    LocalVoiceHomeFlow(
                        state: engine.recordingState,
                        modelName: engine.transcriptionModelManager.currentTranscriptionModel?.displayName
                            ?? String(localized: "Choose a model"),
                        latestTranscript: latestTranscript,
                        testError: testError,
                        onToggleRecording: {
                            if engine.recordingState == .idle {
                                latestTranscript = ""
                                testError = nil
                                isDashboardTestActive = true
                            }
                            Task { @MainActor in
                                await recorderUIManager.toggleRecorderPanel(isDashboardTest: true)
                            }
                        },
                        onCopyTranscript: {
                            guard ClipboardManager.copyToClipboard(latestTranscript) else {
                                return false
                            }
                            return ClipboardManager.getClipboardContent() == latestTranscript
                        }
                    )

                    if !isAccessibilityEnabled {
                        AccessibilityReminder(onOpenSettings: openAccessibilitySettings)
                    }
                }
                .frame(maxWidth: 900)
                .frame(minHeight: max(0, geometry.size.height - 56), alignment: .top)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: refreshAccessibilityStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionCompleted)) { notification in
            guard isDashboardTestActive else { return }
            guard let transcription = notification.object as? Transcription else { return }
            isDashboardTestActive = false

            guard transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
                latestTranscript = ""
                testError = transcription.text
                return
            }
            let result = (transcription.enhancedText?.isEmpty == false)
                ? transcription.enhancedText ?? transcription.text
                : transcription.text
            withAnimation(.spring(response: 0.48, dampingFraction: 0.8)) {
                testError = nil
                latestTranscript = result
            }
        }
    }

    private func refreshAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct LocalVoiceHomeFlow: View {
    let state: RecordingState
    let modelName: String
    let latestTranscript: String
    let testError: String?
    let onToggleRecording: () -> Void
    let onCopyTranscript: () -> Bool
    @State private var isPulsing = false
    @State private var copyState: CopyState = .idle

    private enum CopyState {
        case idle
        case copied
        case failed
    }

    private var isActive: Bool { state != .idle }

    private var title: LocalizedStringKey {
        switch state {
        case .idle: return latestTranscript.isEmpty ? "Test your dictation" : "Dictation works"
        case .starting: return "Preparing microphone…"
        case .recording: return "Listening…"
        case .transcribing: return "Creating transcript…"
        case .enhancing: return "Improving the text…"
        case .busy: return "Finishing…"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch state {
        case .idle:
            if testError != nil {
                return "The test transcription failed. Try again."
            }
            return latestTranscript.isEmpty
                ? "Dictate a short phrase to make sure everything works."
                : "Your test transcription is ready to copy."
        case .starting: return "Local Voice is getting ready."
        case .recording: return "Speak naturally. Press the shortcut again when finished."
        case .transcribing: return "Your recording stays in the selected transcription flow."
        case .enhancing: return "Applying your selected text model."
        case .busy: return "Your transcript will be ready in a moment."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(activeColor.opacity(0.14))
                        .frame(width: 82, height: 82)
                        .scaleEffect(isPulsing && isActive ? 1.16 : 1)
                        .opacity(isPulsing && isActive ? 0.2 : 1)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [activeColor, activeColor.opacity(0.68)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)
                        .shadow(color: activeColor.opacity(0.28), radius: 16, y: 7)

                    Image(systemName: state == .recording ? "waveform" : "mic.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: state == .recording)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button(action: onToggleRecording) {
                    Label(
                        state == .recording ? "Stop recording" : "Start dictation",
                        systemImage: state == .recording ? "stop.fill" : "mic.fill"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(activeColor)
                .disabled(state == .transcribing || state == .enhancing || state == .busy)
            }

            HStack(spacing: 10) {
                flowStep("Record", systemImage: "waveform", isComplete: state != .idle)
                flowConnector(isActive: state == .transcribing || state == .enhancing || state == .busy)
                flowStep(
                    "Transcribe",
                    systemImage: "text.bubble",
                    isComplete: state == .transcribing || state == .enhancing || state == .busy
                )
                flowConnector(isActive: state == .enhancing || state == .busy)
                flowStep("Ready", systemImage: "checkmark", isComplete: state == .busy)
            }

            if !latestTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Label("Dictation works", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.Accent.primary)
                        Spacer()
                        Button {
                            copyState = onCopyTranscript() ? .copied : .failed
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                copyState = .idle
                            }
                        } label: {
                            Label(copyButtonTitle, systemImage: copyButtonIcon)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(copyState == .failed ? AppTheme.Status.error : AppTheme.Accent.primary)
                    }

                    Text(latestTranscript)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(AppTheme.Accent.fill, in: RoundedRectangle(cornerRadius: 14))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let testError {
                Label(testError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Status.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.Status.error.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            }

            Divider()

            HStack(spacing: 18) {
                infoPill(title: "Model", value: modelName, systemImage: "cpu")
                Spacer()
                Text("Audio is processed according to the selected local or cloud model.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .background(AppCardBackground(cornerRadius: 22))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: state)
    }

    private var activeColor: Color {
        switch state {
        case .recording, .starting: return .red
        case .idle, .transcribing, .enhancing, .busy: return AppTheme.Accent.primary
        }
    }

    private var copyButtonTitle: LocalizedStringKey {
        switch copyState {
        case .idle: return "Copy to Clipboard"
        case .copied: return "Copied"
        case .failed: return "Copy failed"
        }
    }

    private var copyButtonIcon: String {
        switch copyState {
        case .idle: return "doc.on.doc"
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func flowStep(_ title: LocalizedStringKey, systemImage: String, isComplete: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(isComplete ? activeColor : .secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background((isComplete ? activeColor : Color.secondary).opacity(0.1), in: Capsule())
    }

    private func flowConnector(isActive: Bool) -> some View {
        Capsule()
            .fill((isActive ? activeColor : Color.secondary).opacity(0.28))
            .frame(maxWidth: .infinity)
            .frame(height: 2)
    }

    private func infoPill(title: LocalizedStringKey, value: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).foregroundStyle(AppTheme.Accent.primary)
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
        .font(.system(size: 12))
    }
}

private struct AccessibilityReminder: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: 34, height: 34)
                .background(AppTheme.Accent.fill, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text("Enable Accessibility Access").font(.system(size: 13, weight: .semibold))
                Text("Required for Local Voice shortcuts and app-wide controls to work properly.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings", action: onOpenSettings).controlSize(.small)
        }
        .padding(16)
        .background(AppCardBackground(cornerRadius: 16))
    }
}
