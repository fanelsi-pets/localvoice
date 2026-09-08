import MeetingScribeUI
import Store
import SwiftUI
import UniformTypeIdentifiers

/// The "Meetings" section of the main window: overview and settings. The full workspace (transcript,
/// speakers, project memory) lives in its own window — see `MeetingsScene`.
struct MeetingsOverviewView: View {
    private let host = MeetingsHost.shared
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Meetings",
                infoMessage:
                    "Meetings are transcribed on this Mac: speakers, timecodes, project memory and export. The full workspace opens in its own window."
            ) {
                HStack(spacing: 10) {
                    Button("Import Recording…") { importRecording() }
                    Button("Open Meetings") { host.openWindow() }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    recentCard
                    dropZone
                    settingsCard
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .task { await host.model.bootstrap() }
    }

    // MARK: - Cards

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if host.processingSummary != nil {
                MeetingsProcessingStatus(model: host.model)
            } else if !host.model.settings.onboardingCompleted {
                Label(
                    "Models are not set up yet — open Meetings to download them and run the self-test.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                Label(
                    "Ready: models are downloaded. Processing keeps running in the background even with the window closed.",
                    systemImage: "checkmark.circle"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppCardBackground())
    }

    private var recentMeetings: [MeetingRecord] {
        Array(
            host.model.library.meetings
                .sorted { ($0.date ?? $0.createdAt) > ($1.date ?? $1.createdAt) }
                .prefix(5)
        )
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Meetings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if recentMeetings.isEmpty {
                Text("No meetings yet. Import a Zoom recording to get a transcript with speakers.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentMeetings) { record in
                    Button {
                        host.model.selectMeeting(record.id)
                        host.openWindow()
                    } label: {
                        HStack(spacing: 12) {
                            Text(record.title)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(record.date ?? record.createdAt, format: .dateTime.day().month().year())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if let duration = record.duration {
                                Text(
                                    Duration.seconds(duration),
                                    format: .time(pattern: .hourMinuteSecond)
                                )
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }
                            Text(record.status.title)
                                .font(.system(size: 11))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(AppTheme.Surface.window, in: Capsule())
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if record.id != recentMeetings.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppCardBackground())
    }

    private var dropZone: some View {
        Label("Drop a Zoom recording or its folder here", systemImage: "square.and.arrow.down")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTargeted ? AppTheme.Selection.border : AppTheme.Border.subtle,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                host.openWindow()
                return MeetingsDrop.handle(providers, model: host.model)
            }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            MeetingsSettingsView(model: host.model)
                .frame(height: 620)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppCardBackground())
    }

    // MARK: - Actions

    private func importRecording() {
        host.openWindow()
        host.model.isFileImporterPresented = true
    }
}
