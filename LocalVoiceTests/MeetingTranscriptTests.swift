import Foundation
import Testing
@testable import LocalVoice

struct MeetingTranscriptTests {
    @Test func sidebarExposesMeetingsWithoutLegacyFileTranscription() {
        let destinations = ViewType.allCases.map(\.rawValue)
        #expect(destinations.contains("Meetings"))
        #expect(!destinations.contains("Transcribe Audio"))
    }

    @Test func parsesMeetingTimecodes() {
        #expect(MeetingTimecode.parse("7:55") == 475)
        #expect(MeetingTimecode.parse("1:02:03") == 3723)
        #expect(MeetingTimecode.parse("2:75") == nil)
    }

    @Test func mapsAnchorNamesToVoiceClusters() {
        let speakers = [
            MeetingSpeakerSegment(speakerID: "S1", startTime: 0, endTime: 30),
            MeetingSpeakerSegment(speakerID: "S2", startTime: 30, endTime: 60),
        ]
        let anchors = [
            MeetingSpeakerAnchor(timestamp: "0:05", speakerName: "Анатолий"),
            MeetingSpeakerAnchor(timestamp: "0:40", speakerName: "Анна"),
        ]

        let names = MeetingTranscriptBuilder.resolveSpeakerNames(
            speakerSegments: speakers,
            anchors: anchors
        )

        #expect(names["S1"] == "Анатолий")
        #expect(names["S2"] == "Анна")
    }

    @Test func keepsFiveDistinctAnchorNamesWhenFiveVoiceClustersExist() {
        let speakers = (1...5).map { index in
            MeetingSpeakerSegment(
                speakerID: "S\(index)",
                startTime: Double(index - 1) * 600,
                endTime: Double(index) * 600 - 1
            )
        }
        let expectedNames = ["Анатолий", "Анна", "Антон", "Андрей", "Иван"]
        let anchors = expectedNames.enumerated().map { index, name in
            MeetingSpeakerAnchor(timestamp: "\(index * 10):05", speakerName: name)
        }

        let names = MeetingTranscriptBuilder.resolveSpeakerNames(
            speakerSegments: speakers,
            anchors: anchors
        )

        #expect(Set(names.values) == Set(expectedNames))
    }

    @Test func alignsWhisperTextByMaximumOverlap() {
        let whisper = WhisperTimedSegment(startTime: 28, endTime: 35, text: "Передача слова")
        let speakers = [
            MeetingSpeakerSegment(speakerID: "S1", startTime: 0, endTime: 30),
            MeetingSpeakerSegment(speakerID: "S2", startTime: 30, endTime: 60),
        ]

        #expect(MeetingTranscriptBuilder.bestSpeakerID(for: whisper, speakerSegments: speakers) == "S2")
    }

    @Test func mergesAdjacentSegmentsFromSameSpeaker() {
        let turns = [
            MeetingTranscriptTurn(
                speakerID: "S1", speakerName: "Анна", startTime: 0, endTime: 2, text: "Первая мысль."
            ),
            MeetingTranscriptTurn(
                speakerID: "S1", speakerName: "Анна", startTime: 2.4, endTime: 4, text: "Вторая мысль."
            ),
            MeetingTranscriptTurn(
                speakerID: "S2", speakerName: "Антон", startTime: 4, endTime: 6, text: "Ответ."
            ),
        ]

        let merged = MeetingTranscriptBuilder.mergeAdjacentTurns(turns)

        #expect(merged.count == 2)
        #expect(merged[0].text == "Первая мысль. Вторая мысль.")
        #expect(merged[1].speakerName == "Антон")
    }

    @Test func offlineFollowUpIgnoresGenericNeedButKeepsExplicitCommitment() {
        let turns = [
            MeetingTranscriptTurn(
                speakerID: "S1", speakerName: "Анна", startTime: 0, endTime: 5,
                text: "Нужно учитывать это условие в наших рассуждениях."
            ),
            MeetingTranscriptTurn(
                speakerID: "S2", speakerName: "Антон", startTime: 5, endTime: 10,
                text: "Я отправлю команде два варианта до среды."
            ),
        ]

        let insights = MeetingInsightExtractor.extract(from: turns)

        #expect(insights.actionItems.count == 1)
        #expect(insights.actionItems[0].contains("отправлю"))
        #expect(!insights.actionItems[0].contains("учитывать"))
    }
}
