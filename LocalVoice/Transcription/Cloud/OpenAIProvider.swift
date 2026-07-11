import Foundation
import SwiftData

struct OpenAIProvider: CloudProvider {
    let modelProvider: ModelProvider = .openAI
    let providerKey = "OpenAI"
    let languageCodes: [String]? = ["en", "ru", "uk"]
    let includesAutoDetect = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: "gpt-4o-mini-transcribe",
                displayName: "GPT-4o Mini Transcribe",
                description: String(localized: "OpenAI's lowest-cost GPT speech-to-text model"),
                provider: .openAI,
                speed: 0.96,
                accuracy: 0.95,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .openAI)
            ),
            CloudModel(
                name: "gpt-4o-transcribe",
                displayName: "GPT-4o Transcribe",
                description: String(localized: "Higher-accuracy OpenAI transcription at a higher API cost"),
                provider: .openAI,
                speed: 0.91,
                accuracy: 0.98,
                isMultilingual: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .openAI)
            ),
        ]
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String]
    ) async throws -> String {
        try await OpenAITranscriptionClient.transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model,
            language: language,
            customVocabulary: customVocabulary
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await OpenAITranscriptionClient.verifyAPIKey(key)
    }
}

private enum OpenAITranscriptionClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    static func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String]
    ) async throws -> String {
        let boundary = "LocalVoice-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendFormField(name: "model", value: model, boundary: boundary)
        body.appendFormField(name: "response_format", value: "json", boundary: boundary)

        if let language, !language.isEmpty, language.lowercased() != "auto" {
            body.appendFormField(name: "language", value: language, boundary: boundary)
        }
        if !customVocabulary.isEmpty {
            body.appendFormField(
                name: "prompt",
                value: customVocabulary.prefix(100).joined(separator: ", "),
                boundary: boundary
            )
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType(for: fileName))\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAITranscriptionError.apiError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAITranscriptionError.emptyTranscript }
        return text
    }

    static func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "OpenAI returned an invalid response.")
            }
            if (200...299).contains(httpResponse.statusCode) { return (true, nil) }
            return (false, errorMessage(from: data, statusCode: httpResponse.statusCode))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let payload = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return payload.error.message
        }
        return "OpenAI request failed (HTTP \(statusCode))."
    }

    private static func mimeType(for fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "webm": return "audio/webm"
        case "ogg": return "audio/ogg"
        default: return "audio/wav"
        }
    }

    private struct TranscriptionResponse: Decodable { let text: String }
    private struct ErrorEnvelope: Decodable { let error: APIError }
    private struct APIError: Decodable { let message: String }
}

private enum OpenAITranscriptionError: LocalizedError {
    case invalidResponse
    case emptyTranscript
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "OpenAI returned an invalid response."
        case .emptyTranscript: return "OpenAI returned an empty transcript."
        case .apiError(let message): return message
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }
}
