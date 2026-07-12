import SwiftData
import SwiftUI

struct HistorySettingsPanel: View {
    @Environment(\.modelContext) private var modelContext

    let onClose: () -> Void

    @AppStorage(CleanupSettingsKeys.isTranscriptionCleanupEnabled) private var isTranscriptionCleanupEnabled = false
    @AppStorage(CleanupSettingsKeys.transcriptionRetentionMinutes) private var transcriptionRetentionMinutes = 24 * 60
    @AppStorage(CleanupSettingsKeys.isAudioCleanupEnabled) private var isAudioCleanupEnabled = false
    @AppStorage(CleanupSettingsKeys.audioRetentionPeriod) private var audioRetentionPeriod = 7

    @State private var isPerformingAudioCleanup = false
    @State private var isShowingAudioConfirmation = false
    @State private var cleanupInfo: (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) = (0, 0, [])
    @State private var showAudioCleanupResult = false
    @State private var audioCleanupResult: (deletedCount: Int, errorCount: Int) = (0, 0)
    @State private var showTranscriptCleanupResult = false

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "History Settings", onClose: onClose)

            Form {
                Section {
                    Picker("Keep Transcriptions", selection: transcriptionRetentionBinding) {
                        Text("1 day").tag(24 * 60)
                        Text("7 days").tag(7 * 24 * 60)
                        Text("30 days").tag(30 * 24 * 60)
                        Text("Always").tag(-1)
                    }

                    if isTranscriptionCleanupEnabled {
                        Button("Run Cleanup Now") {
                            Task {
                                await TranscriptionAutoCleanupService.shared.runManualCleanup(
                                    modelContext: modelContext)
                                await MainActor.run {
                                    showTranscriptCleanupResult = true
                                }
                            }
                        }
                    }
                } header: {
                    sectionHeader(
                        "Transcript History",
                        tip: "Delete transcript history and related audio files after the retention period."
                    )
                }

                Section {
                    Picker("Keep Audio Recordings", selection: audioRetentionBinding) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("Always").tag(-1)
                    }

                    if isAudioCleanupEnabled {
                        Button {
                            analyzeAudioCleanup()
                        } label: {
                            Text(isPerformingAudioCleanup ? "Analyzing..." : "Run Cleanup Now")
                        }
                        .disabled(isPerformingAudioCleanup)
                    }
                } header: {
                    sectionHeader(
                        "Audio Recordings",
                        tip: "Delete old recordings while keeping transcript history."
                    )
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Transcript Cleanup", isPresented: $showTranscriptCleanupResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cleanup complete.")
        }
        .alert("Audio Cleanup", isPresented: $isShowingAudioConfirmation) {
            Button("Cancel", role: .cancel) {}

            if cleanupInfo.fileCount > 0 {
                Button(String(localized: "Delete \(cleanupInfo.fileCount) Files"), role: .destructive) {
                    runAudioCleanup()
                }
            }
        } message: {
            if cleanupInfo.fileCount > 0 {
                Text(
                    String(
                        localized:
                            "This will delete \(cleanupInfo.fileCount) audio files (\(AudioCleanupManager.shared.formatFileSize(cleanupInfo.totalSize)))."
                    ))
            } else {
                Text(String(localized: "No audio files found older than \(audioRetentionPeriod) days."))
            }
        }
        .alert("Cleanup Complete", isPresented: $showAudioCleanupResult) {
            Button("OK", role: .cancel) {}
        } message: {
            if audioCleanupResult.errorCount > 0 {
                Text(
                    String(
                        format: String(localized: "Deleted files: %lld. Failed: %lld."),
                        Int64(audioCleanupResult.deletedCount), Int64(audioCleanupResult.errorCount)))
            } else {
                Text(String(localized: "Deleted \(audioCleanupResult.deletedCount) audio files."))
            }
        }
        .onChange(of: isTranscriptionCleanupEnabled) { _, newValue in
            if !newValue, isAudioCleanupEnabled {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            }
        }
        .onChange(of: isAudioCleanupEnabled) { _, newValue in
            if newValue {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            } else {
                AudioCleanupManager.shared.stopAutomaticCleanup()
            }
        }
    }

    private var transcriptionRetentionBinding: Binding<Int> {
        Binding(
            get: { isTranscriptionCleanupEnabled ? transcriptionRetentionMinutes : -1 },
            set: { value in
                if value < 0 {
                    isTranscriptionCleanupEnabled = false
                } else {
                    transcriptionRetentionMinutes = value
                    isTranscriptionCleanupEnabled = true
                }
            }
        )
    }

    private var audioRetentionBinding: Binding<Int> {
        Binding(
            get: { isAudioCleanupEnabled ? audioRetentionPeriod : -1 },
            set: { value in
                if value < 0 {
                    isAudioCleanupEnabled = false
                } else {
                    audioRetentionPeriod = value
                    isAudioCleanupEnabled = true
                }
            }
        )
    }

    private func sectionHeader(_ title: LocalizedStringKey, tip: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(title)

            InfoTip(message: tip, iconSize: .small, iconColor: .secondary, width: 260)
        }
    }

    private func analyzeAudioCleanup() {
        Task {
            await MainActor.run { isPerformingAudioCleanup = true }
            let info = await AudioCleanupManager.shared.getCleanupInfo(modelContext: modelContext)
            await MainActor.run {
                cleanupInfo = info
                isPerformingAudioCleanup = false
                isShowingAudioConfirmation = true
            }
        }
    }

    private func runAudioCleanup() {
        Task {
            await MainActor.run { isPerformingAudioCleanup = true }
            let result = await AudioCleanupManager.shared.runCleanupForTranscriptions(
                modelContext: modelContext,
                transcriptions: cleanupInfo.transcriptions
            )
            await MainActor.run {
                audioCleanupResult = result
                isPerformingAudioCleanup = false
                showAudioCleanupResult = true
            }
        }
    }
}
