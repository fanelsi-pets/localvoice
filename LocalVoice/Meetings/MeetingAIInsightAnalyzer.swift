import Foundation
import LLMkit

struct MeetingInsightAnalysisConfiguration {
    let provider: AIProvider
    let modelName: String
}

enum MeetingAIInsightAnalyzer {
    private struct EvidenceItem: Decodable {
        let text: String
        let timecode: String?
    }

    private struct ActionItem: Decodable {
        let owner: String
        let task: String
        let deadline: String?
        let timecode: String?
    }

    private struct Payload: Decodable {
        let keyPoints: [EvidenceItem]
        let decisions: [EvidenceItem]
        let actionItems: [ActionItem]
        let openQuestions: [EvidenceItem]
    }

    static func analyze(
        turns: [MeetingTranscriptTurn],
        configuration: MeetingInsightAnalysisConfiguration,
        aiService: AIService
    ) async throws -> MeetingInsights {
        let transcript = turns.map { turn in
            "[\(MeetingTimecode.format(turn.startTime))] \(turn.speakerName): \(turn.text)"
        }
        .joined(separator: "\n\n")

        let systemPrompt = """
            Ты — аналитик рабочих встреч. Извлекай только информацию, подтверждённую транскрипцией.

            Верни строго один JSON-объект без Markdown и пояснений:
            {
              "keyPoints": [{"text": "...", "timecode": "MM:SS"}],
              "decisions": [{"text": "...", "timecode": "MM:SS"}],
              "actionItems": [{"owner": "Имя или Команда", "task": "конкретное действие", "deadline": "срок или null", "timecode": "MM:SS"}],
              "openQuestions": [{"text": "...", "timecode": "MM:SS"}]
            }

            Правила:
            - Отличай обсуждение идеи от принятого решения.
            - В actionItems включай только явное поручение, обещание или согласованный следующий шаг.
            - Объединяй повторы в одну задачу.
            - Сохраняй ответственного и срок, если они названы. Не выдумывай их.
            - Формулируй задачи глаголом: «Подготовить», «Проверить», «Созвониться».
            - Не превращай общие рассуждения со словами «надо» или «можно» в задачи.
            - Особое внимание удели последним 20% встречи: там часто фиксируют follow-up.
            - Не больше 10 ключевых мыслей, 8 решений, 12 задач и 10 открытых вопросов.
            - Пиши на русском языке.
            """

        let response = try await aiService.completeChat(
            provider: configuration.provider,
            modelName: configuration.modelName,
            messages: [.user(transcript)],
            systemPrompt: systemPrompt,
            timeout: 120
        )
        let payload = try decodePayload(from: response)

        return MeetingInsights(
            keyPoints: formattedEvidence(payload.keyPoints, limit: 10),
            decisions: formattedEvidence(payload.decisions, limit: 8),
            actionItems: formattedActions(payload.actionItems, limit: 12),
            questions: formattedEvidence(payload.openQuestions, limit: 10)
        )
    }

    private static func decodePayload(from response: String) throws -> Payload {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let openingBrace = cleaned.firstIndex(of: "{"),
            let closingBrace = cleaned.lastIndex(of: "}"),
            openingBrace <= closingBrace
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "AI response does not contain a JSON object")
            )
        }

        let json = String(cleaned[openingBrace...closingBrace])
        return try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
    }

    private static func formattedEvidence(_ items: [EvidenceItem], limit: Int) -> [String] {
        unique(
            items.map { item in
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return "" }
                return appendTimecode(item.timecode, to: text)
            },
            limit: limit
        )
    }

    private static func formattedActions(_ items: [ActionItem], limit: Int) -> [String] {
        unique(
            items.map { item in
                let owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
                let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { return "" }

                var value = owner.isEmpty ? task : "\(owner) — \(task)"
                if let deadline = item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !deadline.isEmpty,
                    deadline.lowercased() != "null"
                {
                    value += " · срок: \(deadline)"
                }
                return appendTimecode(item.timecode, to: value)
            },
            limit: limit
        )
    }

    private static func appendTimecode(_ rawTimecode: String?, to value: String) -> String {
        guard let timecode = rawTimecode?.trimmingCharacters(in: .whitespacesAndNewlines),
            MeetingTimecode.parse(timecode) != nil
        else { return value }
        return "\(value) [\(timecode)]"
    }

    private static func unique(_ values: [String], limit: Int) -> [String] {
        var fingerprints = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            let fingerprint = value.lowercased()
                .components(separatedBy: .punctuationCharacters)
                .joined()
            guard fingerprints.insert(fingerprint).inserted else { continue }
            result.append(value)
            if result.count == limit { break }
        }
        return result
    }
}
