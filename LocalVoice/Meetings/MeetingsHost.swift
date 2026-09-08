import AppKit
import Foundation
import MeetingScribeUI
import OSLog

/// Meetings (the MeetingScribe core) as a LocalVoice feature: one core model per app, data inside the app
/// container (`Application Support/app.localvoice.LocalVoice/Meetings`), the core's own updater disabled
/// (`GitHubUpdateService` delivers updates), and the meetings window as a separate SwiftUI scene that
/// AppKit code (status-bar menu) opens through a registered `openWindow` action — like the main window.
@MainActor
final class MeetingsHost {
    static let shared = MeetingsHost()
    static let windowID = "meetings"

    let model: MeetingScribeUI.AppModel
    let dataDirectory: URL

    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "Meetings")
    private var openWindowAction: (() -> Void)?
    private var hasPendingOpenRequest = false
    private var windowCloseObserver: NSObjectProtocol?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.localvoice.LocalVoice", isDirectory: true)
        dataDirectory = appSupport.appendingPathComponent("Meetings", isDirectory: true)
        model = MeetingScribeUI.AppModel.live(
            libraryDirectory: dataDirectory,
            modelsRoot: dataDirectory.appendingPathComponent("Models", isDirectory: true)
        )
        model.windowTitle = String(localized: "Meetings")
    }

    /// Called by `MeetingsWindowRequestBridge` once SwiftUI can open windows.
    func registerOpenWindowAction(_ action: @escaping () -> Void) {
        openWindowAction = action
        guard hasPendingOpenRequest else { return }
        hasPendingOpenRequest = false
        action()
    }

    /// Opens (or brings forward) the meetings window; in menu-bar-only mode activates the app first.
    func openWindow() {
        AppPresentationPolicy.activateForUserFacingWindow(reason: "MeetingsWindow")
        guard let openWindowAction else {
            hasPendingOpenRequest = true
            logger.notice("🧭 Meetings window requested before SwiftUI registered its action; queued.")
            return
        }
        openWindowAction()
    }

    /// The meetings window was created by SwiftUI: frame autosave and accessory policy after closing.
    func attach(window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("app.localvoice.LocalVoice.meetingsWindow")
        window.setFrameAutosaveName("LocalVoiceMeetingsWindowFrame")
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed(
                    reason: "MeetingsWindowClosed")
            }
        }
    }

    // MARK: - Facade for AppKit code that does not import the core

    /// Current processing, if any: meeting id, headline ("stage · percent · estimate") and pulse line.
    var processingSummary: (meetingID: UUID, headline: String, pulse: String)? {
        guard let progress = model.toolbarProgress, !progress.isFinished else { return nil }
        return (progress.meetingID, progress.line1, progress.line2)
    }

    func cancelProcessing(_ meetingID: UUID) {
        model.cancel(meetingID)
    }

    /// Confirmation while a recording is being processed and a short wait for the library to save.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.applicationShouldTerminate(sender)
    }
}
