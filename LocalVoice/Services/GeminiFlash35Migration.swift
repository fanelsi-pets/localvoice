import Foundation

enum GeminiFlash35Migration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "gemini-3.5-flash-migrated") else { return }

        if defaults.string(forKey: "CurrentTranscriptionModel") == "gemini-2.5-flash" {
            defaults.set("gemini-3.1-flash-lite", forKey: "CurrentTranscriptionModel")
        }
        if defaults.string(forKey: "GeminiSelectedModel") == "gemini-2.5-flash" {
            defaults.set("gemini-3.5-flash", forKey: "GeminiSelectedModel")
        }

        for modeKey in ["modeConfigurationsV2", "powerModeConfigurationsV2"] {
            guard let data = defaults.data(forKey: modeKey),
                var configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { continue }

            var changed = false
            for index in configs.indices {
                if configs[index]["selectedTranscriptionModelName"] as? String == "gemini-2.5-flash" {
                    configs[index]["selectedTranscriptionModelName"] = "gemini-3.1-flash-lite"
                    changed = true
                }
                if configs[index]["selectedAIModel"] as? String == "gemini-2.5-flash" {
                    configs[index]["selectedAIModel"] = "gemini-3.5-flash"
                    changed = true
                }
            }

            if changed, let updated = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(updated, forKey: modeKey)
            }
        }

        defaults.set(true, forKey: "gemini-3.5-flash-migrated")
    }
}
