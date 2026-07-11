import Foundation
import LLMkit
import SwiftData

struct GeminiProvider: CloudProvider {
    let modelProvider: ModelProvider = .gemini
    let providerKey: String = "Gemini"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false

    var models: [CloudModel] {
        [
            CloudModel(
                name: "gemini-2.5-flash-lite",
                displayName: "Gemini 2.5 Flash-Lite",
                description: String(localized: "Google's smallest stable and most cost-efficient multimodal model"),
                provider: .gemini,
                speed: 0.95,
                accuracy: 0.94,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .gemini)
            ),
            CloudModel(
                name: "gemini-2.5-flash",
                displayName: "Gemini 2.5 Flash",
                description: String(localized: "Higher-quality Gemini transcription with a higher API cost"),
                provider: .gemini,
                speed: 0.92,
                accuracy: 0.96,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .gemini)
            ),
        ]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?, customVocabulary: [String]
    ) async throws -> String {
        return try await GeminiTranscriptionClient.transcribe(
            audioData: audioData,
            apiKey: apiKey,
            model: model
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        return await GeminiTranscriptionClient.verifyAPIKey(key)
    }
}
