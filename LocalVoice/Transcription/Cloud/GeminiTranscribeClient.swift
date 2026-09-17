import Foundation

/// Gemini 3.5 Transcribe (`gemini-3.5-transcribe`) is served by the Interactions API, not by the
/// `models/…:generateContent` call the other Gemini models use: the audio is uploaded through the Files API,
/// the interaction references the file URI, and the transcript comes back in `output_text`
/// (https://ai.google.dev/gemini-api/docs/transcribe, read 2026-09-16). Sent through the generateContent client
/// the model returned nothing to paste. Language codes are left empty unless the user forced a language: the
/// model then detects the language per utterance and handles code-switching (Russian/Ukrainian mixes).
enum GeminiTranscribeClient {
    static let modelPrefix = "gemini-3.5-transcribe"
    static let base = URL(string: "https://generativelanguage.googleapis.com")!
    /// How long to wait for an uploaded file to become ACTIVE (audio usually is immediately).
    static let activationTimeout: TimeInterval = 15

    struct UploadedFile: Equatable, Sendable {
        var name: String
        var uri: String
        var state: String
    }

    static func isTranscribeModel(_ model: String) -> Bool {
        model.hasPrefix(modelPrefix) && !model.hasSuffix("-live")
    }

    static func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval = 60
    ) async throws -> String {
        let mimeType = mimeType(for: fileName)
        let uploaded = try await upload(audioData, mimeType: mimeType, displayName: fileName, apiKey: apiKey, timeout: timeout)
        defer {
            let name = uploaded.name
            Task.detached { await delete(fileName: name, apiKey: apiKey) }
        }
        let active = try await waitUntilActive(uploaded, apiKey: apiKey, timeout: timeout)
        let body = interactionBody(
            model: model, uri: active.uri, mimeType: mimeType, language: language, vocabulary: customVocabulary)
        let data = try await postJSON(url: base.appending(path: "v1beta/interactions"), body: body, apiKey: apiKey, timeout: timeout)
        let text = try transcript(from: data)
        guard !text.isEmpty else { throw CloudTranscriptionError.noTranscriptionReturned }
        return text
    }

    // MARK: - Pure helpers (unit-tested)

    static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mp3"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "aac": return "audio/aac"
        case "webm": return "audio/webm"
        case "aiff", "aif": return "audio/aiff"
        default: return "audio/wav"
        }
    }

    /// BCP-47 for the few language codes the app uses; anything else is passed as given.
    static func languageCode(_ code: String) -> String {
        let regions = [
            "ru": "ru-RU", "uk": "uk-UA", "en": "en-US", "de": "de-DE", "fr": "fr-FR", "es": "es-ES",
            "it": "it-IT", "pl": "pl-PL", "pt": "pt-BR", "tr": "tr-TR", "ja": "ja-JP", "zh": "zh-CN",
        ]
        return regions[code.lowercased()] ?? code
    }

    /// `wordTimestamps` — режим встреч: `mode` становится объектом verbatim со словными таймкодами.
    /// Словарь с ними несовместим («the API rejects requests that specify custom_vocabulary alongside
    /// either feature»), поэтому в этом режиме он не отправляется.
    static func interactionBody(
        model: String, uri: String, mimeType: String, language: String?, vocabulary: [String],
        wordTimestamps: Bool = false
    ) -> [String: Any] {
        var config: [String: Any] = [
            "language_codes": language.map { [languageCode($0)] } ?? []
        ]
        if wordTimestamps {
            config["mode"] = ["type": "verbatim", "timestamp_granularities": ["word"]]
        } else {
            config["mode"] = "smart"
            let terms = vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !terms.isEmpty { config["custom_vocabulary"] = Array(terms.prefix(1000)) }
        }
        return [
            "model": model,
            "input": [["type": "audio", "uri": uri, "mime_type": mimeType]],
            "generation_config": ["transcription_config": config],
        ]
    }

    /// `output_text`, otherwise the text parts of the model output steps; an `error` object becomes a failure.
    static func transcript(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 200, message: String(data: data.prefix(300), encoding: .utf8) ?? "unreadable response")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            let code = error["code"] as? Int ?? 200
            throw CloudTranscriptionError.apiRequestFailed(statusCode: code, message: message)
        }
        if let text = object["output_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var pieces: [String] = []
        for step in object["steps"] as? [[String: Any]] ?? [] {
            guard (step["type"] as? String ?? "model_output") == "model_output" else { continue }
            for part in step["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "text", let text = part["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { pieces.append(trimmed) }
                }
            }
        }
        return pieces.joined(separator: " ")
    }

    /// Upload responses wrap the resource in `file`; `GET /v1beta/files/{name}` returns the resource itself.
    static func uploadedFile(from data: Data) throws -> UploadedFile {
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let file = (object["file"] as? [String: Any]) ?? object
        guard let name = file["name"] as? String, let uri = file["uri"] as? String else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 200, message: "Files API: unexpected upload response")
        }
        return UploadedFile(name: name, uri: uri, state: file["state"] as? String ?? "ACTIVE")
    }

    // MARK: - Network

    private static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 120)
        return URLSession(configuration: configuration)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: http.statusCode,
                message: String(data: data.prefix(500), encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }
        return http
    }

    static func upload(
        _ data: Data, mimeType: String, displayName: String, apiKey: String, timeout: TimeInterval
    ) async throws -> UploadedFile {
        let session = session(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }

        var start = URLRequest(url: base.appending(path: "upload/v1beta/files"))
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": displayName]])
        let (startData, startResponse): (Data, URLResponse)
        do { (startData, startResponse) = try await session.data(for: start) } catch { throw CloudTranscriptionError.networkError(error) }
        let http = try check(startResponse, startData)
        guard let location = http.value(forHTTPHeaderField: "x-goog-upload-url"), let uploadURL = URL(string: location) else {
            throw CloudTranscriptionError.apiRequestFailed(statusCode: http.statusCode, message: "Files API: no upload URL")
        }

        var put = URLRequest(url: uploadURL)
        put.httpMethod = "POST"
        put.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (fileData, fileResponse): (Data, URLResponse)
        do { (fileData, fileResponse) = try await session.upload(for: put, from: data) } catch { throw CloudTranscriptionError.networkError(error) }
        _ = try check(fileResponse, fileData)
        return try uploadedFile(from: fileData)
    }

    /// `activation` — сколько ждать состояния ACTIVE: короткой диктовке хватает 15 с, кусок встречи на
    /// 15 минут Files API может готовить дольше.
    static func waitUntilActive(
        _ file: UploadedFile, apiKey: String, timeout: TimeInterval,
        activation: TimeInterval = activationTimeout
    ) async throws -> UploadedFile {
        var current = file
        let deadline = Date().addingTimeInterval(activation)
        while current.state.uppercased() == "PROCESSING", Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            var request = URLRequest(url: base.appending(path: "v1beta/\(current.name)"))
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let session = session(timeout: timeout)
            defer { session.finishTasksAndInvalidate() }
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) } catch { throw CloudTranscriptionError.networkError(error) }
            _ = try check(response, data)
            current = try uploadedFile(from: data)
        }
        guard current.state.uppercased() != "FAILED" else {
            throw CloudTranscriptionError.apiRequestFailed(statusCode: 200, message: "Files API: processing failed")
        }
        return current
    }

    private static func postJSON(url: URL, body: [String: Any], apiKey: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = session(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw CloudTranscriptionError.networkError(error) }
        _ = try check(response, data)
        return data
    }

    /// Best effort: Google removes files after 48 hours anyway.
    static func delete(fileName: String, apiKey: String) async {
        var request = URLRequest(url: base.appending(path: "v1beta/\(fileName)"))
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let session = session(timeout: 15)
        defer { session.finishTasksAndInvalidate() }
        _ = try? await session.data(for: request)
    }
}

// MARK: - Слова с таймкодами (встречи)

/// Режим встреч (MeetingScribeKit): нужен не готовый текст, а слова с таймкодами — по ним реплики
/// сшиваются с локальной диаризацией. Включается `mode: {"type": "verbatim",
/// "timestamp_granularities": ["word"]}`, ответ приходит аннотациями `word_info`
/// (https://ai.google.dev/gemini-api/docs/transcribe, прочитано 16.09.2026).
extension GeminiTranscribeClient {
    struct TimedWord: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
        var speaker: String?
    }

    /// Предел одного запроса со словными таймкодами: «Audio processing is limited to 30 minutes when
    /// features like speaker diarization or word-level timestamps are enabled».
    static var maximumTimedClipSeconds: Double { 1800 }

    /// Распознаёт готовый файл с диска: куски режет вызывающий (ядро), здесь только выгрузка и запрос.
    static func transcribeWords(
        fileURL: URL, mimeType: String, apiKey: String, model: String, language: String?,
        clipDuration: Double, timeout: TimeInterval = 600
    ) async throws -> [TimedWord] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw CloudTranscriptionError.audioFileNotFound
        }
        let name = fileURL.lastPathComponent
        let uploaded = try await upload(data, mimeType: mimeType, displayName: name, apiKey: apiKey, timeout: timeout)
        defer {
            let uploadedName = uploaded.name
            Task.detached { await delete(fileName: uploadedName, apiKey: apiKey) }
        }
        let active = try await waitUntilActive(
            uploaded, apiKey: apiKey, timeout: timeout, activation: 120)
        let body = interactionBody(
            model: model, uri: active.uri, mimeType: mimeType, language: language, vocabulary: [],
            wordTimestamps: true)
        let response = try await postJSON(
            url: base.appending(path: "v1beta/interactions"), body: body, apiKey: apiKey, timeout: timeout)
        return try words(from: response, clipDuration: clipDuration)
    }

    /// Аннотации `word_info` из `steps[].content[].annotations[]`. Если их нет, а текст есть — раскладываем
    /// слова по куску равномерно: приблизительные таймкоды лучше, чем потерянный кусок записи.
    static func words(from data: Data, clipDuration: Double) throws -> [TimedWord] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: 200, message: String(data: data.prefix(300), encoding: .utf8) ?? "unreadable response")
        }
        if let error = object["error"] as? [String: Any] {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: error["code"] as? Int ?? 200,
                message: error["message"] as? String ?? "unknown error")
        }

        var words: [TimedWord] = []
        for step in object["steps"] as? [[String: Any]] ?? [] {
            for content in step["content"] as? [[String: Any]] ?? [] {
                for annotation in content["annotations"] as? [[String: Any]] ?? [] {
                    guard annotation["type"] as? String == "word_info",
                        let text = annotation["text"] as? String,
                        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    let start = offsetSeconds(annotation["start_offset"]) ?? 0
                    let end = offsetSeconds(annotation["end_offset"]) ?? start
                    words.append(
                        TimedWord(
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                            start: start, end: max(start, end),
                            speaker: annotation["speaker"] as? String))
                }
            }
        }
        if !words.isEmpty { return words.sorted { ($0.start, $0.end) < ($1.start, $1.end) } }

        let text = (try? transcript(from: data)) ?? ""
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty, clipDuration > 0 else { return [] }
        let step = clipDuration / Double(parts.count)
        return parts.enumerated().map { index, word in
            TimedWord(text: word, start: Double(index) * step, end: Double(index + 1) * step, speaker: nil)
        }
    }

    /// `"0.450s"` → 0.45; число приходит как есть.
    static func offsetSeconds(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        guard let raw = value as? String else { return nil }
        let trimmed = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        return Double(trimmed)
    }
}
