import Foundation

/// Compatibility shim for settings backups created before the private
/// MediaRemote dependency was removed. Local Voice no longer observes or
/// controls playback in other applications.
@MainActor
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    @Published var isPauseMediaEnabled = false

    private init() {
        UserDefaults.standard.removeObject(forKey: "isPauseMediaEnabled")
    }

    func pauseMedia() async {}
    func resumeMedia() async {}
}
