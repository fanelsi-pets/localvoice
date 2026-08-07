import Foundation

struct MeetingSpeakerAnchor: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var timestamp = ""
    var speakerName = ""
    /// The diarization cluster selected by the player, when one is known.
    ///
    /// Older saved anchors do not contain this value, so it remains optional and
    /// time-based matching continues to work as a fallback.
    var speakerID: String? = nil

    var timeInterval: TimeInterval? {
        MeetingTimecode.parse(timestamp)
    }

    /// A typed timecode is authoritative. Once the user edits it, the cluster
    /// captured at the original player position is no longer safe to reuse and
    /// must be resolved again from the new second.
    mutating func updateTimestampManually(_ value: String) {
        timestamp = value
        speakerID = nil
    }
}

struct MeetingSpeakerSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let speakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(id: UUID = UUID(), speakerID: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct MeetingTranscriptTurn: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let speakerID: String
    let speakerName: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    init(
        id: UUID = UUID(),
        speakerID: String,
        speakerName: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

struct MeetingInsights: Codable, Hashable, Sendable {
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [String] = []
    var questions: [String] = []
}

struct MeetingTranscript: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sourceFilename: String
    let createdAt: Date
    let duration: TimeInterval
    let turns: [MeetingTranscriptTurn]
    let speakerNames: [String: String]
    let insights: MeetingInsights

    init(
        id: UUID = UUID(),
        sourceFilename: String,
        createdAt: Date = Date(),
        duration: TimeInterval,
        turns: [MeetingTranscriptTurn],
        speakerNames: [String: String],
        insights: MeetingInsights
    ) {
        self.id = id
        self.sourceFilename = sourceFilename
        self.createdAt = createdAt
        self.duration = duration
        self.turns = turns
        self.speakerNames = speakerNames
        self.insights = insights
    }

    var markdown: String {
        var lines = [
            "# \(sourceFilename)",
            "",
            "Дата расшифровки: \(createdAt.formatted(date: .abbreviated, time: .shortened))",
            "Длительность: \(MeetingTimecode.format(duration))",
            "",
            "## Итоги",
            "",
        ]

        appendSection("Ключевые мысли", values: insights.keyPoints, to: &lines)
        appendSection("Решения", values: insights.decisions, to: &lines)
        appendSection("Задачи и фоллоу-ап", values: insights.actionItems, to: &lines)
        appendSection("Открытые вопросы", values: insights.questions, to: &lines)

        lines.append(contentsOf: ["## Транскрипция", ""])
        for turn in turns {
            lines.append("**[\(MeetingTimecode.format(turn.startTime))] \(turn.speakerName)**")
            lines.append("")
            lines.append(turn.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func appendSection(_ title: String, values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("### \(title)")
        lines.append("")
        lines.append(contentsOf: values.map { "- \($0)" })
        lines.append("")
    }
}

enum MeetingTimecode {
    static func parse(_ value: String) -> TimeInterval? {
        let parts = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)

        guard parts.count == 2 || parts.count == 3 else { return nil }
        var components: [Double] = []
        for part in parts {
            let normalized = part.replacingOccurrences(of: ",", with: ".")
            guard !normalized.isEmpty,
                let component = Double(normalized),
                component.isFinite,
                component >= 0
            else { return nil }
            components.append(component)
        }

        if components.count == 2 {
            guard components[1] < 60 else { return nil }
            return components[0] * 60 + components[1]
        }

        guard components[1] < 60, components[2] < 60 else { return nil }
        return components[0] * 3600 + components[1] * 60 + components[2]
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum MeetingTranscriptBuilder {
    static func build(
        sourceFilename: String,
        duration: TimeInterval,
        whisperSegments: [WhisperTimedSegment],
        speakerSegments: [MeetingSpeakerSegment],
        anchors: [MeetingSpeakerAnchor]
    ) -> MeetingTranscript {
        let clusterNames = resolveSpeakerNames(speakerSegments: speakerSegments, anchors: anchors)
        let rawTurns = whisperSegments.map { segment in
            let speakerID = bestSpeakerID(for: segment, speakerSegments: speakerSegments) ?? "S1"
            return MeetingTranscriptTurn(
                speakerID: speakerID,
                speakerName: clusterNames[speakerID] ?? defaultSpeakerName(speakerID),
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text
            )
        }
        let turns = mergeAdjacentTurns(rawTurns)
        let insights = MeetingInsightExtractor.extract(from: turns)

        return MeetingTranscript(
            sourceFilename: sourceFilename,
            duration: duration,
            turns: turns,
            speakerNames: clusterNames,
            insights: insights
        )
    }

    static func resolveSpeakerNames(
        speakerSegments: [MeetingSpeakerSegment], anchors: [MeetingSpeakerAnchor]
    ) -> [String: String] {
        let speakerIDs = Set(speakerSegments.map(\.speakerID)).sorted()
        var names = Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, defaultSpeakerName($0)) })
        var claimed = Set<String>()

        // Player-created anchors already know the exact diarization cluster. Apply
        // those first so repeated anchors for one participant can never rename a
        // different voice merely because the first cluster was already claimed.
        for anchor in anchors {
            guard let speakerID = anchor.speakerID, names[speakerID] != nil else { continue }
            let name = anchor.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            names[speakerID] = name
            claimed.insert(speakerID)
        }

        for anchor in anchors {
            if let speakerID = anchor.speakerID, names[speakerID] != nil { continue }
            guard let time = anchor.timeInterval else { continue }
            let name = anchor.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            // A manual timecode may intentionally point to a cluster that was
            // named by an earlier anchor. Prefer an exact containing segment even
            // when it is already claimed; only the nearest-time fallback excludes
            // clusters assigned to a different participant.
            let exactCandidates = speakerSegments
                .filter { time >= $0.startTime && time <= $0.endTime }
                .map { segment -> (MeetingSpeakerSegment, TimeInterval) in
                    (segment, 0)
                }

            let fallbackCandidates = speakerSegments
                .filter { !claimed.contains($0.speakerID) }
                .map { segment in
                    (segment, min(abs(time - segment.startTime), abs(time - segment.endTime)))
                }
                .sorted { lhs, rhs in lhs.1 < rhs.1 }

            if let match = (exactCandidates.first ?? fallbackCandidates.first)?.0 {
                names[match.speakerID] = name
                claimed.insert(match.speakerID)
            }
        }
        return names
    }

    static func bestSpeakerID(
        for whisperSegment: WhisperTimedSegment, speakerSegments: [MeetingSpeakerSegment]
    ) -> String? {
        guard !speakerSegments.isEmpty else { return nil }
        var overlapBySpeaker: [String: TimeInterval] = [:]

        for speaker in speakerSegments {
            let overlap = max(0, min(whisperSegment.endTime, speaker.endTime) - max(whisperSegment.startTime, speaker.startTime))
            overlapBySpeaker[speaker.speakerID, default: 0] += overlap
        }

        if let best = overlapBySpeaker.max(by: { $0.value < $1.value }), best.value > 0 {
            return best.key
        }

        let midpoint = (whisperSegment.startTime + whisperSegment.endTime) / 2
        return speakerSegments.min { lhs, rhs in
            distance(from: midpoint, to: lhs) < distance(from: midpoint, to: rhs)
        }?.speakerID
    }

    static func mergeAdjacentTurns(_ turns: [MeetingTranscriptTurn]) -> [MeetingTranscriptTurn] {
        var result: [MeetingTranscriptTurn] = []
        for turn in turns {
            guard let previous = result.last,
                previous.speakerID == turn.speakerID,
                turn.startTime - previous.endTime <= 2.0
            else {
                result.append(turn)
                continue
            }

            result[result.count - 1] = MeetingTranscriptTurn(
                id: previous.id,
                speakerID: previous.speakerID,
                speakerName: previous.speakerName,
                startTime: previous.startTime,
                endTime: max(previous.endTime, turn.endTime),
                text: [previous.text, turn.text].joined(separator: " ")
            )
        }
        return result
    }

    private static func distance(from time: TimeInterval, to segment: MeetingSpeakerSegment) -> TimeInterval {
        if time >= segment.startTime && time <= segment.endTime { return 0 }
        return min(abs(time - segment.startTime), abs(time - segment.endTime))
    }

    static func defaultSpeakerName(_ speakerID: String) -> String {
        let number = speakerID.filter(\.isNumber)
        return number.isEmpty ? "Спикер \(speakerID)" : "Спикер \(number)"
    }
}

enum MeetingInsightExtractor {
    private static let actionMarkers = [
        "нам надо разработать", "нам надо придумать", "надо подготов", "нужно подготов", "предлагаю сделать",
        "предлагаю придумать", "давайте сделаем", "давайте встретимся", "встретимся в", "созвонимся",
        "созвониться", "выписывать", "подготовить", "отправлю", "скину", "проверить", "договорились сделать",
        "follow up", "follow-up",
    ]
    private static let decisionMarkers = [
        "решили", "договорились", "фиксируем", "утвердили", "выбираем", "остановились на", "итого",
    ]
    private static let keyPointMarkers = [
        "важно", "главное", "проблема", "идея", "предлагаю", "суть", "риск", "ценность",
    ]

    static func extract(from turns: [MeetingTranscriptTurn]) -> MeetingInsights {
        let candidates = turns.flatMap { turn in
            splitIntoSentences(turn.text).map { sentence in
                (speaker: turn.speakerName, text: sentence)
            }
        }

        let actions = select(candidates, markers: actionMarkers, limit: 12)
        let decisions = select(candidates, markers: decisionMarkers, limit: 8)
        let questions = unique(
            candidates.filter { $0.text.contains("?") }.map { "\($0.speaker): \($0.text)" },
            limit: 10
        )
        var keyPoints = select(candidates, markers: keyPointMarkers, limit: 10)

        if keyPoints.isEmpty {
            keyPoints = candidates
                .filter { $0.text.count >= 70 }
                .sorted { $0.text.count > $1.text.count }
                .prefix(8)
                .map { "\($0.speaker): \($0.text)" }
        }

        return MeetingInsights(
            keyPoints: unique(keyPoints, limit: 10),
            decisions: unique(decisions, limit: 8),
            actionItems: unique(actions, limit: 12),
            questions: questions
        )
    }

    private static func select(
        _ candidates: [(speaker: String, text: String)], markers: [String], limit: Int
    ) -> [String] {
        candidates.filter { candidate in
            let lowercased = candidate.text.lowercased()
            return markers.contains { lowercased.contains($0) }
        }
        .prefix(limit)
        .map { "\($0.speaker): \($0.text)" }
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        text.split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
            .map { sentence in
                let suffix = text.contains("\(sentence)?") ? "?" : "."
                return sentence + suffix
            }
    }

    private static func unique(_ values: [String], limit: Int) -> [String] {
        var fingerprints = Set<String>()
        var result: [String] = []
        for value in values {
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
