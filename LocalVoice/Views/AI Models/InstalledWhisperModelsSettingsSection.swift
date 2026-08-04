import SwiftUI

struct InstalledWhisperModelsSettingsSection: View {
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @State private var deletionTarget: DeletionTarget?

    private enum DeletionTarget: Identifiable {
        case model(WhisperModelFile)
        case all

        var id: String {
            switch self {
            case .model(let model): return model.id.uuidString
            case .all: return "all"
            }
        }
    }

    var body: some View {
        Section {
            if whisperModelManager.availableModels.isEmpty {
                Text("No models")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(whisperModelManager.availableModels) { model in
                    modelRow(model)
                }

                Button("Delete All", role: .destructive) {
                    deletionTarget = .all
                }
            }
        } header: {
            Text("Local Models")
        } footer: {
            Text("Downloaded Whisper models are stored only on this Mac. Removing a model frees its model and Core ML files.")
        }
        .alert(item: $deletionTarget) { target in
            switch target {
            case .model(let model):
                return Alert(
                    title: Text("Delete Model"),
                    message: Text(
                        String(
                            format: String(localized: "Are you sure you want to delete the model '%@'?"),
                            model.name
                        )
                    ),
                    primaryButton: .destructive(Text("Delete")) {
                        Task { await whisperModelManager.deleteModel(model) }
                    },
                    secondaryButton: .cancel()
                )
            case .all:
                return Alert(
                    title: Text("Delete All Models"),
                    message: Text("All downloaded Whisper models will be removed from this Mac."),
                    primaryButton: .destructive(Text("Delete")) {
                        let models = whisperModelManager.availableModels
                        Task {
                            for model in models {
                                await whisperModelManager.deleteModel(model)
                            }
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private func modelRow(_ model: WhisperModelFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(fileSize(model.url))
                    if transcriptionModelManager.currentTranscriptionModel?.name == model.name {
                        Text("Selected")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                deletionTarget = .model(model)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete Model")
        }
    }

    private func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
