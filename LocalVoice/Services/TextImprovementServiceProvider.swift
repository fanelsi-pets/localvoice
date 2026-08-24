import AppKit
import os

/// Backs the "✨ Improve with LocalVoice" entry in the macOS Services menu
/// (Application menu ▸ Services, and the right-click menu on selected text in
/// any app). Reuses the same structuring prompt as the post-dictation "Improve"
/// suggestion, but the Services contract is synchronous, so the async AI call is
/// blocked on with a semaphore on this (non-main) Services thread. macOS replaces
/// the original selection with whatever is written back to the pasteboard.
final class TextImprovementServiceProvider: NSObject {
    static let shared = TextImprovementServiceProvider()

    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "TextImprovementService")
    weak var enhancementService: AIEnhancementService?

    override private init() {}

    @objc(improveSelectedText:userData:error:)
    func improveSelectedText(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            error.pointee = String(localized: "LocalVoice didn't receive any selected text.") as NSString
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultText: String?
        var resultErrorMessage: String?

        Task { @MainActor [weak self] in
            defer { semaphore.signal() }
            guard let enhancementService = self?.enhancementService else {
                resultErrorMessage = String(localized: "LocalVoice isn't ready yet.")
                return
            }
            do {
                resultText = try await enhancementService.structureText(text)
            } catch {
                resultErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        semaphore.wait()

        if let resultText {
            pasteboard.clearContents()
            pasteboard.setString(resultText, forType: .string)
        } else {
            let message = resultErrorMessage ?? String(localized: "LocalVoice couldn't improve this text.")
            logger.error("Improve service failed: \(message, privacy: .public)")
            error.pointee = message as NSString
        }
    }
}
