import Foundation

/// One-time move of the Gemini enhancement model to gemini-3.5-flash-lite (4.1.3).
/// On the free tier gemini-3.5-flash kept hitting its limits ("Improve failed: … server encountered an error");
/// the AI Studio rate-limit dashboard (2026-09-15) gives 3.5 Flash-Lite 15 requests per minute, enough for
/// dictation enhancement. Unset selections, the old default and the short-lived 3.1 Flash-Lite choice move;
/// any other explicit Gemini model stays.
enum GeminiFlashLiteEnhancementMigration {
    static let flagKey = "gemini-3.5-flash-lite-enhancement-migrated"
    static let oldModels: Set<String> = ["gemini-3.5-flash", "gemini-3.1-flash-lite"]
    static let newModel = "gemini-3.5-flash-lite"

    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }

        let selected = defaults.string(forKey: "GeminiSelectedModel")
        if selected == nil || oldModels.contains(selected!) {
            defaults.set(newModel, forKey: "GeminiSelectedModel")
        }

        for modeKey in ["modeConfigurationsV2", "powerModeConfigurationsV2"] {
            guard let data = defaults.data(forKey: modeKey),
                var configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { continue }
            var changed = false
            for index in configs.indices {
                if let model = configs[index]["selectedAIModel"] as? String, oldModels.contains(model) {
                    configs[index]["selectedAIModel"] = newModel
                    changed = true
                }
            }
            if changed, let updated = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(updated, forKey: modeKey)
            }
        }

        defaults.set(true, forKey: flagKey)
    }
}
