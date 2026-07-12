import Foundation

struct TranscriptionOutputFilter {
    private static let hallucinationPatterns = [
        #"\[.*?\]"#,  // []
        #"\(.*?\)"#,  // ()
        #"\{.*?\}"#,  // {}
    ]

    // Standalone hesitation sounds in Russian and Ukrainian. Single "м" and
    // single Ukrainian "е" are intentionally not removed because they can be
    // meaningful tokens; repeated or hyphenated forms are safe to classify as
    // speech disfluencies.
    private static let cyrillicHesitationPattern =
        #"(?<![\p{L}\p{N}])(?:э(?:[-‐‑‒–—\s]*э){0,3}|эм+|м(?:[-‐‑‒–—\s]*м){1,4}|е(?:[-‐‑‒–—\s]+е){1,3}|гм+)(?:\s*[,.;:!?…]+)?(?![\p{L}\p{N}])"#

    static func filter(_ text: String) -> String {
        var filteredText = text

        // Remove <TAG>...</TAG> blocks
        let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: tagBlockPattern) {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Remove bracketed hallucinations
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        if let regex = try? NSRegularExpression(
            pattern: cyrillicHesitationPattern,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(
                in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Remove configured filler words. An empty list is naturally a no-op.
        for fillerWord in FillerWordManager.shared.fillerWords {
            let escapedWord = NSRegularExpression.escapedPattern(for: fillerWord)
            let pattern = "(?<![\\p{L}\\p{N}])\(escapedWord)(?:\\s*[,.;:!?…]+)?(?![\\p{L}\\p{N}])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Clean whitespace
        filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        filteredText = filteredText.replacingOccurrences(
            of: #"\s+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        filteredText = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)

        return filteredText
    }
}
