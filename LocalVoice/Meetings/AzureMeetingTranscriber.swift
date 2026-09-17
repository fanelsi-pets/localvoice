import Core
import Foundation
import OSLog

/// Облачное распознавание встречи через Microsoft MAI-Transcribe-2 (Azure Speech) — режим встреч по
/// умолчанию. Ключ хранит `MeetingCloudCredentials`; если его ещё нет, ядро перед первой обработкой
/// показывает экран ввода (`setupRequest`). Ядро (`RemoteAsrEngine`) режет запись на куски и зовёт этот
/// класс на каждый файл; слова с таймкодами ложатся на локальную диаризацию. Диаризацию Azure не просим:
/// в preview она падает на записях от ~15 минут, а её метки не сшиваются между кусками.
final class AzureMeetingTranscriber: RemoteTranscribing {
    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "MeetingsCloud")

    let title = "MAI-Transcribe-2 (Azure)"
    var model: String { AzureSpeechClient.modelName }
    /// Карточка модели: до 2 часов в одном запросе; ядро всё равно режет по 15 минут.
    var maximumClipSeconds: Double { 7200 }

    func availability() async -> RemoteTranscriberAvailability {
        guard MeetingCloudCredentials.current != nil else {
            return RemoteTranscriberAvailability(
                isAvailable: false, reason: MeetingCloudCredentials.unavailableReason)
        }
        return .available
    }

    /// Экран ввода ключа перед первой облачной обработкой; ключ уже есть — спрашивать нечего.
    func setupRequest() async -> RemoteSetupRequest? {
        guard MeetingCloudCredentials.current == nil else { return nil }
        return RemoteSetupRequest(
            title: String(localized: "Azure key for meetings"),
            explanation: String(
                localized:
                    "Meetings are transcribed by Microsoft MAI-Transcribe-2 in Azure: a two-hour recording takes minutes instead of tens of minutes, and mixed Russian and Ukrainian speech comes out better. Audio is sent to Azure, which does not keep it; voices, names and project memory stay on this Mac."
            ),
            fieldTitle: String(localized: "Azure Speech key"),
            footnote: String(
                localized:
                    "Paste the key you were given. It is checked with a one-second request, stored in this Mac's Keychain and used only for transcription. You can change it later in AI Models, or process meetings on this Mac instead."
            ))
    }

    /// Проверка ключа настоящим запросом и сохранение в связку ключей: ошибку показываем рядом с полем.
    func completeSetup(value: String) async -> String? {
        await MeetingCloudCredentials.verifyAndSave(key: value, region: AzureSpeechSettings.region)
    }

    func transcribe(clip url: URL, mimeType: String, duration: Double, language: Core.Language?)
        async throws -> [RemoteWord]
    {
        guard let credential = MeetingCloudCredentials.current else {
            throw RemoteTranscriptionError(
                message: MeetingCloudCredentials.unavailableReason, isRetryable: false)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw RemoteTranscriptionError(message: error.localizedDescription, isRetryable: false)
        }
        do {
            let transcript = try await AzureSpeechClient.transcribe(
                audioData: data, fileName: url.lastPathComponent, mimeType: mimeType,
                apiKey: credential.key, region: credential.region,
                // Язык не навязываем: модель определяет его сама и держит смешанную речь.
                definition: AzureSpeechClient.definition(style: .verbatim, timestamps: .word, phrases: [], locales: []),
                timeout: 600)
            logger.info(
                "☁️ Azure MAI-Transcribe-2: \(url.lastPathComponent, privacy: .public) → \(transcript.words.count, privacy: .public) words"
            )
            return Self.remoteWords(transcript, clipDuration: duration)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Слова с таймкодами; если их не оказалось, а текст есть — раскладываем по куску равномерно:
    /// приблизительные таймкоды лучше, чем потерянный кусок записи.
    static func remoteWords(_ transcript: AzureSpeechClient.Transcript, clipDuration: Double) -> [RemoteWord] {
        if !transcript.words.isEmpty {
            return transcript.words.map { RemoteWord(text: $0.text, start: $0.start, end: $0.end) }
        }
        let parts = transcript.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty, clipDuration > 0 else { return [] }
        let step = clipDuration / Double(parts.count)
        return parts.enumerated().map { index, word in
            RemoteWord(text: word, start: Double(index) * step, end: Double(index + 1) * step)
        }
    }

    /// 408/429/5xx — временный отказ (ядро подождёт и повторит), 401/403 и прочее показываем как есть.
    static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let cloud = error as? CloudTranscriptionError else {
            return RemoteTranscriptionError(message: error.localizedDescription, isRetryable: false)
        }
        switch cloud {
        case .apiRequestFailed(let statusCode, let message):
            return RemoteTranscriptionError(
                message: "HTTP \(statusCode): \(message)",
                isRetryable: statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode))
        case .networkError(let underlying):
            return RemoteTranscriptionError(
                message: underlying.localizedDescription,
                isRetryable: (underlying as NSError).code != NSURLErrorCancelled)
        default:
            return RemoteTranscriptionError(message: cloud.localizedDescription, isRetryable: false)
        }
    }
}
