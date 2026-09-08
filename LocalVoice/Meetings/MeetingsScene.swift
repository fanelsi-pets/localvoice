import MeetingScribeUI
import SwiftUI

/// The separate "Meetings" window: the MeetingScribe core as is (three columns, toolbar, inspector,
/// sheets) plus its menu commands. Opened from the sidebar section, the status-bar menu and drops.
struct MeetingsScene: Scene {
    var body: some Scene {
        Window(Text("Meetings"), id: MeetingsHost.windowID) {
            MeetingsRootView(model: MeetingsHost.shared.model)
                .background(
                    WindowAccessor { window in
                        MeetingsHost.shared.attach(window: window)
                    }
                )
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            MeetingsCommands(model: MeetingsHost.shared.model)
        }
    }
}

/// Registers the `openWindow` action for the meetings window. Lives inside the main window content, like
/// `MainWindowRequestBridge`: the retained SwiftUI action outlives the window.
struct MeetingsWindowRequestBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let openWindow = openWindow
                MeetingsHost.shared.registerOpenWindowAction {
                    openWindow(id: MeetingsHost.windowID)
                }
            }
    }
}
