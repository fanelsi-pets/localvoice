import AppKit
import Foundation
import Testing
@testable import LocalVoice

struct WindowLifecycleTests {
    @Test @MainActor func queuesAWindowRequestUntilSwiftUIRegistersItsOpenAction() {
        let notificationCenter = NotificationCenter()
        let coordinator = MainWindowRequestCoordinator(notificationCenter: notificationCenter)
        var openCount = 0

        #expect(!coordinator.requestMainWindow())

        coordinator.registerOpenMainWindowAction {
            openCount += 1
        }

        #expect(openCount == 1)
    }

    @Test @MainActor func retainedOpenActionReceivesRequestsAfterItsRegisteringViewDisappears() {
        let notificationCenter = NotificationCenter()
        let coordinator = MainWindowRequestCoordinator(notificationCenter: notificationCenter)
        var openCount = 0

        coordinator.registerOpenMainWindowAction {
            openCount += 1
        }
        notificationCenter.post(name: .showMainWindowRequested, object: nil)
        notificationCenter.post(name: .showMainWindowRequested, object: nil)

        #expect(openCount == 2)
    }

    @Test @MainActor func repeatedPendingRequestsAreCoalesced() {
        let coordinator = MainWindowRequestCoordinator(notificationCenter: NotificationCenter())
        var openCount = 0

        #expect(!coordinator.requestMainWindow())
        #expect(!coordinator.requestMainWindow())
        coordinator.registerOpenMainWindowAction {
            openCount += 1
        }

        #expect(openCount == 1)
    }

    @Test @MainActor func dockFallbackDoesNotQueueADuplicateRequest() {
        let coordinator = MainWindowRequestCoordinator(notificationCenter: NotificationCenter())
        var openCount = 0

        #expect(!coordinator.requestMainWindow(queueIfUnavailable: false))
        coordinator.registerOpenMainWindowAction {
            openCount += 1
        }

        #expect(openCount == 0)
    }

    @Test func normalWindowPresentationUsesTheWholeVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 38, width: 1728, height: 994)

        #expect(
            AppWindowLayout.presentationFrame(
                for: visibleFrame,
                styleMask: [.titled, .resizable]
            ) == visibleFrame
        )
    }

    @Test func nativeFullScreenIsNotResizedIntoANormalWindow() {
        let visibleFrame = NSRect(x: 0, y: 38, width: 1728, height: 994)

        #expect(
            AppWindowLayout.presentationFrame(
                for: visibleFrame,
                styleMask: [.titled, .resizable, .fullScreen]
            ) == nil
        )
    }
}
