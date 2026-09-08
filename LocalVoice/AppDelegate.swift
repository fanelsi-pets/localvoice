import Cocoa
import OSLog
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "MenuBarWindowFlow")

    weak var menuBarManager: MenuBarManager?
    weak var enhancementService: AIEnhancementService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the notification observer before the status item can emit an
        // open-window request. Its retained SwiftUI action outlives the window.
        _ = MainWindowRequestCoordinator.shared
        logger.notice(
            "🧭 Application finished launching. hasMenuBarManager=\((self.menuBarManager != nil), privacy: .public); activationPolicy=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
        )
        menuBarManager?.applyActivationPolicy()
        menuBarManager?.ensureStatusItemInstalled()

        TextImprovementServiceProvider.shared.enhancementService = enhancementService
        NSApplication.shared.servicesProvider = TextImprovementServiceProvider.shared
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.notice(
            "🧭 Dock/app reopen requested. hasVisibleWindowsFlag=\(flag, privacy: .public); isMenuBarOnly=\(self.menuBarManager?.isMenuBarOnly ?? UserDefaults.standard.bool(forKey: "IsMenuBarOnly"), privacy: .public); activationPolicy=\(WindowDiagnostics.activationPolicyDescription(sender.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
        )

        if let menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.currentMainWindow() != nil {
                WindowManager.shared.showMainWindow()
                logger.notice("🧭 Dock/app reopen presented the existing main window.")
                return false
            }

            WindowManager.shared.prepareForUserRequestedMainWindow()
            let didForwardToSwiftUI = MainWindowRequestCoordinator.shared.requestMainWindow(
                queueIfUnavailable: false
            )
            logger.notice(
                "🧭 Dock/app reopen requested main window creation. retainedSwiftUIActionAvailable=\(didForwardToSwiftUI, privacy: .public)"
            )
            // If SwiftUI has not registered its action yet, let AppKit perform
            // the normal reopen. That initial scene will then register it.
            return !didForwardToSwiftUI
        }

        logger.notice("🧭 Dock/app reopen left to default handling.")
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowManager.shared.prepareForApplicationTermination()
        // Meetings: confirmation while a recording is being processed, short wait for the library to save.
        return MeetingsHost.shared.applicationShouldTerminate(sender)
    }
}
