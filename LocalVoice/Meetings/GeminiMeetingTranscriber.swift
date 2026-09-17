import Core
import Foundation
import OSLog

/// Облачное распознавание встречи через Gemini 3.5 Transcribe по ключу пользователя — тот же ключ, что
/// у follow-up и диктовки. Ядро (`RemoteAsrEngine`) режет запись на куски по 15 минут и зовёт этот класс
/// на каждый файл; спикеров по-прежнему размечает локальный диаризатор, поэтому диаризацию Gemini
/// не просим (её метки живут внутри одного запроса и между кусками не сшиваются).
final class GeminiMeetingTranscriber: RemoteTranscribing {
    static let modelName = "gemini-3.5-transcribe"

    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "MeetingsCloud")

    let title = "Gemini 3.5 Transcribe"
    var model: String { Self.modelName }
    var maximumClipSeconds: Double { GeminiTranscribeClient.maximumTimedClipSeconds }

    func availability() async -> RemoteTranscriberAvailability {
        guard let key = apiKey, !key.isEmpty else {
            return RemoteTranscriberAvailability(
                isAvailable: false,
                reason: String(
                    localized: "Add a Gemini API key in AI Models to transcribe meetings in the cloud."))
        }
        return .available
    }

    func transcribe(clip url: URL, mimeType: String, duration: Double, language: Core.Language?)
        async throws -> [RemoteWord]
    {
        guard let key = apiKey, !key.isEmpty else {
            throw RemoteTranscriptionError(
                message: String(localized: "Add a Gemini API key in AI Models to transcribe meetings in the cloud."),
                isRetryable: false)
        }
        do {
            let words = try await GeminiTranscribeClient.transcribeWords(
                fileURL: url,
                mimeType: mimeType,
                apiKey: key,
                model: Self.modelName,
                // Язык не навязываем: модель определяет его по каждой реплике и держит смешанную речь.
                language: nil,
                clipDuration: duration)
            logger.info(
                "☁️ Gemini transcribe: \(url.lastPathComponent, privacy: .public) → \(words.count, privacy: .public) words"
            )
            return words.map {
                RemoteWord(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    private var apiKey: String? {
        APIKeyManager.shared.getAPIKey(forProvider: AIProvider.gemini.rawValue)
    }

    /// 429 и 5xx — временный отказ (ядро подождёт и повторит), остальное показываем пользователю как есть.
    static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let cloud = error as? CloudTranscriptionError else {
            return RemoteTranscriptionError(message: error.localizedDescription, isRetryable: false)
        }
        switch cloud {
        case .apiRequestFailed(let statusCode, let message):
            return RemoteTranscriptionError(
                message: "HTTP \(statusCode): \(message)",
                isRetryable: statusCode == 429 || (500..<600).contains(statusCode))
        case .networkError(let underlying):
            return RemoteTranscriptionError(
                message: underlying.localizedDescription,
                isRetryable: (underlying as NSError).code != NSURLErrorCancelled)
        default:
            return RemoteTranscriptionError(
                message: cloud.localizedDescription, isRetryable: false)
        }
    }
}
