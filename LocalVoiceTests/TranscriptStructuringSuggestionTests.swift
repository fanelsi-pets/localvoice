import Foundation
import Testing

@testable import LocalVoice

struct TranscriptStructuringSuggestionTests {
    @Test func requiresBothLongDictationAndLongText() {
        let longText = String(repeating: "a", count: 500)
        let shortText = String(repeating: "a", count: 50)

        #expect(TranscriptStructuringSuggestion.isEligible(text: longText, dictationDuration: 25))
        #expect(!TranscriptStructuringSuggestion.isEligible(text: shortText, dictationDuration: 25))
        #expect(!TranscriptStructuringSuggestion.isEligible(text: longText, dictationDuration: 10))
        #expect(!TranscriptStructuringSuggestion.isEligible(text: shortText, dictationDuration: 10))
    }

    @Test func isEligibleAtExactThresholds() {
        let thresholdText = String(repeating: "a", count: TranscriptStructuringSuggestion.minimumCharacterCount)

        #expect(
            TranscriptStructuringSuggestion.isEligible(
                text: thresholdText,
                dictationDuration: TranscriptStructuringSuggestion.minimumDictationDuration
            ))
    }
}
