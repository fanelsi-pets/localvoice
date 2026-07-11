import Foundation

/// Replaces the Gemini model that returns 404 for newly provisioned API users.
enum GeminiModelMigration {
    private static let oldModel = "gemini-2.5-flash-lite"
    private static let newModel = "gemini-3.1-flash-lite"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "gemini-3.1-flash-lite-migrated") else { return }

        if defaults.string(forKey: "CurrentTranscriptionModel") == oldModel {
            defaults.set(newModel, forKey: "CurrentTranscriptionModel")
        }

        if defaults.string(forKey: "GeminiSelectedModel") == oldModel {
            defaults.set(newModel, forKey: "GeminiSelectedModel")
        }

        for modeKey in ["modeConfigurationsV2", "powerModeConfigurationsV2"] {
            guard let data = defaults.data(forKey: modeKey),
                var configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { continue }

            var changed = false
            for index in configs.indices {
                if configs[index]["selectedTranscriptionModelName"] as? String == oldModel {
                    configs[index]["selectedTranscriptionModelName"] = newModel
                    changed = true
                }
                if configs[index]["selectedAIModel"] as? String == oldModel {
                    configs[index]["selectedAIModel"] = newModel
                    changed = true
                }
            }

            if changed, let updatedData = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(updatedData, forKey: modeKey)
            }
        }

        defaults.set(true, forKey: "gemini-3.1-flash-lite-migrated")
    }
}
