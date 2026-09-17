import Foundation
import SwiftData

/// Microsoft MAI-Transcribe-2 через Azure Speech для диктовки: ключ ресурса Speech из Keychain, регион —
/// `AzureSpeechSettings`. Тот же ключ использует облачный движок встреч (`AzureMeetingTranscriber`).
struct AzureSpeechProvider: CloudProvider {
    static let keyName = "Azure Speech"

    let modelProvider: ModelProvider = .azureSpeech
    let providerKey: String = AzureSpeechProvider.keyName
    /// 60 языков с автоопределением — список приложения целиком.
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: AzureSpeechClient.dictationModelID,
                displayName: "MAI-Transcribe-2",
                description: String(
                    localized:
                        "Microsoft's speech-to-text model (public preview): 60 languages with automatic detection, mixed speech, uses your dictionary; $0.10 per hour of audio through 2026"
                ),
                provider: .azureSpeech,
                speed: 0.97,
                accuracy: 0.96,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .azureSpeech)
            )
        ]
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?, customVocabulary: [String]
    ) async throws -> String {
        let definition = AzureSpeechClient.definition(
            style: .clean, timestamps: .none, phrases: customVocabulary,
            locales: AzureSpeechClient.locales(for: language))
        let transcript = try await AzureSpeechClient.transcribe(
            audioData: audioData, fileName: fileName, mimeType: AzureSpeechClient.mimeType(for: fileName),
            apiKey: apiKey, region: AzureSpeechSettings.region, definition: definition, timeout: 120)
        let text = AzureSpeechClient.singleLine(transcript.text)
        guard !text.isEmpty else { throw CloudTranscriptionError.noTranscriptionReturned }
        return text
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await AzureSpeechClient.verifyAPIKey(key, region: AzureSpeechSettings.region)
    }
}
