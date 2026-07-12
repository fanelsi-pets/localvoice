import Foundation

class FillerWordManager: ObservableObject {
    static let shared = FillerWordManager()

    static let defaultFillerWords = [
        "uh", "um", "uhm", "umm", "uhh", "uhhh",
        "hmm", "hm", "mmm", "mm", "mh", "ehh",
        "э", "э-э", "ээ", "эээ", "эм", "мм", "м-м", "ммм", "е-е", "гм", "а",
    ]

    private let fillerWordsKey = "FillerWords"
    private let cyrillicDefaultsMigrationKey = "FillerWordsCyrillicDefaultsV1"

    @Published var fillerWords: [String] {
        didSet {
            UserDefaults.standard.set(fillerWords, forKey: fillerWordsKey)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: fillerWordsKey) {
            if UserDefaults.standard.bool(forKey: cyrillicDefaultsMigrationKey) {
                self.fillerWords = saved
            } else {
                self.fillerWords = Self.mergingDefaults(into: saved)
                UserDefaults.standard.set(true, forKey: cyrillicDefaultsMigrationKey)
            }
        } else {
            self.fillerWords = Self.defaultFillerWords
            UserDefaults.standard.set(true, forKey: cyrillicDefaultsMigrationKey)
        }
    }

    private static func mergingDefaults(into saved: [String]) -> [String] {
        var result = saved
        let existing = Set(saved.map { $0.lowercased() })
        result.append(contentsOf: defaultFillerWords.filter { !existing.contains($0.lowercased()) })
        return result
    }

    func addWord(_ word: String) -> Bool {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        guard !fillerWords.contains(where: { $0.lowercased() == normalized }) else { return false }
        fillerWords.append(normalized)
        return true
    }

    func removeWord(_ word: String) {
        fillerWords.removeAll { $0.lowercased() == word.lowercased() }
    }

}
