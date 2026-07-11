import Foundation

@MainActor
enum OnlineFirstModelMigration {
    private static let migrationKey = "OnlineFirstModelMigrationV1"

    static func run(using manager: TranscriptionModelManager) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let current = manager.currentTranscriptionModel,
            current.provider == .whisper || current.provider == .fluidAudio
        else { return }

        guard let cloudModel = manager.usableModels.first(where: {
            $0.provider == .gemini || $0.provider == .openAI
        }) else { return }

        manager.setDefaultTranscriptionModel(cloudModel)
    }
}
