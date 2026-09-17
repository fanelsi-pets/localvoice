import Foundation
import OSLog

/// Ключ Azure Speech, на котором работают встречи.
///
/// Ключ вводит сам пользователь: при первой облачной обработке приложение показывает экран ввода
/// (`RemoteSetupRequest` ядра → `CloudSetupSheet`). Хранится он там же, где ключ Azure для диктовки —
/// в связке ключей через `APIKeyManager`, поэтому вводить его второй раз не нужно, а в «AI Models» он
/// виден и правится как обычно. В репозитории и в сборке ключа нет.
enum MeetingCloudCredentials {
    struct Credential: Equatable {
        var key: String
        var region: String
    }

    private static let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "MeetingsCloud")

    /// Ключ и регион для распознавания встречи; `nil` — ключ ещё не вводили.
    static var current: Credential? {
        #if DEBUG
            // Проверка экрана ввода ключа на машине, где ключ уже есть: `-MSForceCloudSetup YES`.
            if UserDefaults.standard.bool(forKey: "MSForceCloudSetup") { return nil }
        #endif
        guard let key = trimmed(APIKeyManager.shared.getAPIKey(forProvider: AzureSpeechProvider.keyName)) else {
            return nil
        }
        return Credential(key: key, region: AzureSpeechSettings.region)
    }

    /// Проверяет ключ настоящим запросом (секунда тишины) и сохраняет его в связку ключей.
    /// Возвращает текст ошибки провайдера или `nil`, если ключ принят.
    static func verifyAndSave(key: String, region: String?) async -> String? {
        let key = trimmed(key) ?? ""
        guard !key.isEmpty else {
            return String(localized: "Enter the Azure Speech key.")
        }
        let region = AzureSpeechSettings.normalized(region) ?? AzureSpeechSettings.defaultRegion
        let result = await AzureSpeechClient.verifyAPIKey(key, region: region)
        guard result.isValid else {
            logger.error("🔑 Azure отклонил ключ для встреч: \(result.errorMessage ?? "—", privacy: .public)")
            return result.errorMessage ?? String(localized: "Azure rejected the key.")
        }
        AzureSpeechSettings.region = region
        guard APIKeyManager.shared.saveAPIKey(key, forProvider: AzureSpeechProvider.keyName) else {
            return String(localized: "The key could not be saved to the Keychain.")
        }
        logger.info("🔑 Ключ Azure для встреч сохранён, регион \(region, privacy: .public)")
        return nil
    }

    /// Почему облачный режим не поедет — текст в ошибке обработки.
    static var unavailableReason: String {
        String(
            localized:
                "Meetings are transcribed by Microsoft Azure. Add the Azure Speech key you were given, or process the meeting on this Mac."
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
