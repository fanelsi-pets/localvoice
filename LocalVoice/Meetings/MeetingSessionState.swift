import SwiftUI

/// Window-owned inputs for the current meeting.
///
/// `MeetingTranscribeView` is recreated when the user changes sidebar sections,
/// so keeping these values in the destination view would discard an imported
/// recording and its speaker labels. `ContentView` owns one session for the
/// lifetime of the main window and injects it back into the Meetings screen.
@MainActor
final class MeetingSessionState: ObservableObject {
    @Published var sourceURL: URL?
    @Published var selectedModelName = ""
    @Published var language = "auto"
    @Published var expectedSpeakerCount = 0
    @Published var anchors: [MeetingSpeakerAnchor] = []
    @Published var detectedSpeakerNames: [String: String] = [:]
    @Published var useAIInsights = false

    func clearRecordingInputs() {
        sourceURL = nil
        anchors = []
        detectedSpeakerNames = [:]
        useAIInsights = false
    }
}
