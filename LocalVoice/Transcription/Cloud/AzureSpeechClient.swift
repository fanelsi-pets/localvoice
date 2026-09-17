import Foundation

/// Регион ресурса Azure Speech. MAI-Transcribe-2 отдаётся из шести регионов (карточка модели 2026-09);
/// для Европы — `northeurope`. Хранится в UserDefaults, правится в панели ключа провайдера.
enum AzureSpeechSettings {
    static let regionDefaultsKey = "AzureSpeechRegion"
    static let defaultRegion = "northeurope"
    static let knownRegions = ["northeurope", "eastus", "westus", "westus2", "centralindia", "southeastasia"]

    static var region: String {
        get { normalized(UserDefaults.standard.string(forKey: regionDefaultsKey)) ?? defaultRegion }
        set { UserDefaults.standard.set(normalized(newValue) ?? defaultRegion, forKey: regionDefaultsKey) }
    }

    /// «North Europe» → «northeurope»: портал показывает регион с пробелами и заглавными буквами.
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return value.isEmpty ? nil : value
    }
}

/// Azure Speech «Fast Transcription» с моделью Microsoft MAI-Transcribe-2 (public preview с 2026-09-03):
/// один multipart-запрос «файл целиком → JSON», без стриминга
/// (learn.microsoft.com/azure/ai-services/speech-service/mai-transcribe). Ответ — `phrases[]` с
/// `offsetMilliseconds`/`durationMilliseconds`, при `timestamps: "word"` внутри фразы лежат `words[]`,
/// `combinedPhrases[]` — текст целиком. Входные форматы: WAV, MP3, FLAC; до 2 часов в запросе.
enum AzureSpeechClient {
    static let apiVersion = "2025-10-15"
    static let modelName = "MAI-Transcribe-2"
    /// Идентификатор модели в списке моделей диктовки.
    static let dictationModelID = "mai-transcribe-2"

    struct Word: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Transcript: Equatable, Sendable {
        var text: String
        var words: [Word]
        var duration: Double
    }

    /// `verbatim` — дословно (для встреч), `clean` — без слов-паразитов (для диктовки).
    enum Style: String { case verbatim, clean }
    enum Timestamps: String { case none, word, segment }

    static func endpoint(region: String) -> URL {
        URL(
            string:
                "https://\(region).api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=\(apiVersion)"
        )!
    }

    /// Поле `definition` запроса. Диаризацию не просим: в preview она падает на записях от ~15 минут,
    /// а спикеров у встреч даёт локальный диаризатор. Словарь — до 1000 фраз (лимит API).
    static func definition(
        style: Style, timestamps: Timestamps, phrases: [String], locales: [String], diarization: Bool = false
    ) -> [String: Any] {
        var definition: [String: Any] = [
            "enhancedMode": ["enabled": true, "model": modelName],
            "diarization": ["enabled": diarization],
            "modelOptions": ["transcribeStyle": style.rawValue, "timestamps": timestamps.rawValue],
            "locales": locales,
        ]
        let terms = phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !terms.isEmpty {
            definition["phraseList"] = ["phrases": Array(terms.prefix(1000))]
        }
        return definition
    }

    /// Код языка приложения → `locales` Azure: «auto» и пусто — автоопределение (режим по умолчанию у модели).
    static func locales(for language: String?) -> [String] {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !language.isEmpty, language != "auto"
        else { return [] }
        return [language]
    }

    static func multipartBody(definition: Data, audio: Data, fileName: String, mimeType: String, boundary: String)
        -> Data
    {
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"definition\"\r\n")
        body.appendUTF8("Content-Type: application/json\r\n\r\n")
        body.append(definition)
        body.appendUTF8("\r\n--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n")
        body.appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audio)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }

    static func transcribe(
        audioData: Data, fileName: String, mimeType: String, apiKey: String, region: String,
        definition: [String: Any], timeout: TimeInterval = 600
    ) async throws -> Transcript {
        let boundary = "LocalVoice-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint(region: region))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let definitionData = try JSONSerialization.data(withJSONObject: definition)
        request.httpBody = multipartBody(
            definition: definitionData, audio: audioData, fileName: fileName, mimeType: mimeType, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudTranscriptionError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.apiRequestFailed(statusCode: 0, message: "invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CloudTranscriptionError.invalidAPIKey
            }
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: http.statusCode, message: errorMessage(from: data, statusCode: http.statusCode))
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Transcript {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 200, message: String(data: data.prefix(300), encoding: .utf8) ?? "unreadable response")
        }
        var words: [Word] = []
        var phraseTexts: [String] = []
        for phrase in object["phrases"] as? [[String: Any]] ?? [] {
            if let text = phrase["text"] as? String, !text.isEmpty { phraseTexts.append(text) }
            for word in phrase["words"] as? [[String: Any]] ?? [] {
                guard let raw = word["text"] as? String else { continue }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = seconds(word["offsetMilliseconds"])
                let end = start + seconds(word["durationMilliseconds"])
                words.append(Word(text: text, start: start, end: end))
            }
        }
        let combined = (object["combinedPhrases"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let text = (combined.isEmpty ? phraseTexts : combined)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(
            text: text,
            words: words.sorted { ($0.start, $0.end) < ($1.start, $1.end) },
            duration: seconds(object["durationMilliseconds"]))
    }

    /// Проверка ключа: настоящий запрос с секундой тишины — заодно проверяет регион и доступ к модели
    /// (плата за секунду звука). 401/403 — ключ или регион не те.
    static func verifyAPIKey(_ key: String, region: String) async -> (isValid: Bool, errorMessage: String?) {
        do {
            _ = try await transcribe(
                audioData: silentWAV(seconds: 1), fileName: "check.wav", mimeType: "audio/wav",
                apiKey: key, region: region,
                definition: definition(style: .clean, timestamps: .none, phrases: [], locales: []),
                timeout: 60)
            return (true, nil)
        } catch CloudTranscriptionError.invalidAPIKey {
            return (
                false,
                String(localized: "Azure rejected the key. Check the key and the region of your Speech resource.")
            )
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Переносы строк между фразами в `combinedPhrases` → одна строка для вставки диктовки.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == " " }).joined(separator: " ")
    }

    static func mimeType(for fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        default: "audio/wav"
        }
    }

    static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
        }
        return "Azure Speech request failed (HTTP \(statusCode))."
    }

    /// PCM 16 kHz 16-бит моно, одни нули — для проверки ключа.
    static func silentWAV(seconds: Double, sampleRate: Int = 16_000) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let dataSize = frames * 2
        var wav = Data()
        wav.appendUTF8("RIFF")
        wav.appendLittleEndian(UInt32(36 + dataSize))
        wav.appendUTF8("WAVE")
        wav.appendUTF8("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(UInt32(sampleRate * 2))
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.appendUTF8("data")
        wav.appendLittleEndian(UInt32(dataSize))
        wav.append(Data(count: dataSize))
        return wav
    }

    private static func seconds(_ milliseconds: Any?) -> Double {
        if let value = milliseconds as? Double { return value / 1000 }
        if let value = milliseconds as? Int { return Double(value) / 1000 }
        return 0
    }
}

extension Data {
    fileprivate mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }

    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<T>.size))
    }
}
