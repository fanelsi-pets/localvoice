import Foundation

@MainActor
enum OnlineFirstModelMigration {
    private static let migrationKey = "OnlineFirstModelMigrationV2"

    static func run(using manager: TranscriptionModelManager) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        let currentIsOffline = manager.currentTranscriptionModel.map {
            $0.provider == .whisper || $0.provider == .fluidAudio
        } ?? true
        guard currentIsOffline else { return }

        guard let cloudModel = manager.allAvailableModels.first(where: {
            $0.provider == .gemini || $0.provider == .openAI
        }) else { return }

        manager.setDefaultTranscriptionModel(cloudModel)
    }
}
