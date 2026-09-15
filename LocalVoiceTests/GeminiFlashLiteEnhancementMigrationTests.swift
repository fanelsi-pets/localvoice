import Foundation
import Testing

@testable import LocalVoice

@Suite("Gemini Flash-Lite enhancement migration")
struct GeminiFlashLiteEnhancementMigrationTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Unset, gemini-3.5-flash and gemini-3.1-flash-lite move to gemini-3.5-flash-lite, another explicit model stays")
    func movesDefaultAndOldModel() {
        let unset = makeDefaults()
        GeminiFlashLiteEnhancementMigration.run(defaults: unset)
        #expect(unset.string(forKey: "GeminiSelectedModel") == "gemini-3.5-flash-lite")
        #expect(unset.bool(forKey: GeminiFlashLiteEnhancementMigration.flagKey))

        let old = makeDefaults()
        old.set("gemini-3.5-flash", forKey: "GeminiSelectedModel")
        GeminiFlashLiteEnhancementMigration.run(defaults: old)
        #expect(old.string(forKey: "GeminiSelectedModel") == "gemini-3.5-flash-lite")

        let lite = makeDefaults()
        lite.set("gemini-3.1-flash-lite", forKey: "GeminiSelectedModel")
        GeminiFlashLiteEnhancementMigration.run(defaults: lite)
        #expect(lite.string(forKey: "GeminiSelectedModel") == "gemini-3.5-flash-lite")

        let explicit = makeDefaults()
        explicit.set("gemini-3.1-pro-preview", forKey: "GeminiSelectedModel")
        GeminiFlashLiteEnhancementMigration.run(defaults: explicit)
        #expect(explicit.string(forKey: "GeminiSelectedModel") == "gemini-3.1-pro-preview")
    }

    @Test("Mode configurations with the old model are rewritten, the migration runs once")
    func rewritesModesOnce() throws {
        let defaults = makeDefaults()
        let configs: [[String: Any]] = [["name": "Work", "selectedAIModel": "gemini-3.5-flash"], ["name": "Other", "selectedAIModel": "gpt-4o-mini"]]
        defaults.set(try JSONSerialization.data(withJSONObject: configs), forKey: "modeConfigurationsV2")
        GeminiFlashLiteEnhancementMigration.run(defaults: defaults)
        let data = try #require(defaults.data(forKey: "modeConfigurationsV2"))
        let updated = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(updated[0]["selectedAIModel"] as? String == "gemini-3.5-flash-lite")
        #expect(updated[1]["selectedAIModel"] as? String == "gpt-4o-mini")

        defaults.set("gemini-3.5-flash", forKey: "GeminiSelectedModel")
        GeminiFlashLiteEnhancementMigration.run(defaults: defaults)
        #expect(defaults.string(forKey: "GeminiSelectedModel") == "gemini-3.5-flash")
    }
}
