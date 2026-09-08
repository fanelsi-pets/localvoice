import AppKit
import MeetingScribeUI
import Store
import SwiftUI
import UniformTypeIdentifiers

/// The "Meetings" section of the main window, in the dashboard's visual language: a hero card with the
/// current state (set-up, ready, processing), the import → transcribe → ready flow, recent meetings and a
/// drop zone. The full workspace lives in its own window (`MeetingsScene`); core settings open in a sheet.
struct MeetingsOverviewView: View {
    private let host = MeetingsHost.shared
    @State private var isDropTargeted = false
    @State private var showsSettings = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    MeetingsHeroCard(
                        model: host.model,
                        onOpen: { host.openWindow() },
                        onImport: importRecording,
                        onSettings: { showsSettings = true },
                        onCancel: { host.cancelProcessing($0) }
                    )

                    MeetingsRecentCard(model: host.model) { meetingID in
                        if let meetingID {
                            host.model.selectMeeting(meetingID)
                        } else {
                            host.model.select(.allMeetings)
                        }
                        host.openWindow()
                    }

                    dropZone
                }
                .frame(maxWidth: 900)
                .frame(minHeight: max(0, geometry.size.height - 56), alignment: .top)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await host.model.bootstrap() }
        .sheet(isPresented: $showsSettings) {
            MeetingsSettingsSheet(model: host.model)
        }
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: 34, height: 34)
                .background(AppTheme.Accent.fill, in: RoundedRectangle(cornerRadius: 10))
            Text("Drop a Zoom recording or its folder here")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDropTargeted ? AppTheme.Accent.fillSubtle : AppTheme.Surface.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            isDropTargeted ? AppTheme.Accent.border : AppTheme.Border.card,
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                        )
                )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            host.openWindow()
            return MeetingsDrop.handle(providers, model: host.model)
        }
    }

    private func importRecording() {
        host.openWindow()
        host.model.isFileImporterPresented = true
    }
}

// MARK: - Hero

private struct MeetingsHeroCard: View {
    let model: MeetingScribeUI.AppModel
    let onOpen: () -> Void
    let onImport: () -> Void
    let onSettings: () -> Void
    let onCancel: (UUID) -> Void
    @State private var isPulsing = false

    private enum Phase {
        case setup
        case idle
        case processing
    }

    private var progress: MeetingProgressModel? {
        guard let progress = model.toolbarProgress, !progress.isFinished else { return nil }
        return progress
    }

    private var phase: Phase {
        if progress != nil { return .processing }
        return model.settings.onboardingCompleted ? .idle : .setup
    }

    private var meetings: [MeetingRecord] { model.library.meetings }
    private var hasReadyMeeting: Bool { meetings.contains { $0.status == .ready } }
    private var activeColor: Color { AppTheme.Accent.primary }

    private var title: Text {
        switch phase {
        case .setup: return Text("Set up Meetings")
        case .idle: return Text(hasReadyMeeting ? "Meetings are ready" : "Transcribe a meeting")
        case .processing: return Text("Processing: \(model.toolbarProgressMeeting?.title ?? "")")
        }
    }

    private var subtitle: Text {
        switch phase {
        case .setup:
            return Text("Download the models once and run the self-test. Everything stays on this Mac.")
        case .idle:
            return Text("Import a Zoom recording to get speakers, timecodes, names and project memory.")
        case .processing:
            return Text(progress?.line1 ?? "")
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch phase {
        case .setup, .processing: return "Open Meetings"
        case .idle: return "Import Recording…"
        }
    }

    private var primaryIcon: String {
        switch phase {
        case .setup: return "arrow.down.circle"
        case .idle: return "square.and.arrow.down"
        case .processing: return "person.2.wave.2"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(activeColor.opacity(0.14))
                        .frame(width: 82, height: 82)
                        .scaleEffect(isPulsing && phase == .processing ? 1.16 : 1)
                        .opacity(isPulsing && phase == .processing ? 0.2 : 1)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [activeColor, activeColor.opacity(0.68)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)
                        .shadow(color: activeColor.opacity(0.28), radius: 16, y: 7)

                    Image(systemName: phase == .processing ? "waveform" : "person.2.wave.2.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: phase == .processing)
                }

                VStack(alignment: .leading, spacing: 6) {
                    title
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    subtitle
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Button(action: phase == .idle ? onImport : onOpen) {
                    Label(primaryTitle, systemImage: primaryIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(activeColor)
            }

            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: min(max(progress.barValue, 0), 1))
                        .tint(activeColor)
                    HStack(spacing: 12) {
                        Text(progress.line2)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Cancel") { onCancel(progress.meetingID) }
                            .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 10) {
                flowStep("Import", systemImage: "square.and.arrow.down", isComplete: phase == .processing || !meetings.isEmpty)
                flowConnector(isActive: phase == .processing || hasReadyMeeting)
                flowStep("Transcribe", systemImage: "text.bubble", isComplete: phase == .processing || hasReadyMeeting)
                flowConnector(isActive: hasReadyMeeting)
                flowStep("Ready", systemImage: "checkmark", isComplete: hasReadyMeeting)
            }

            Divider()

            HStack(spacing: 18) {
                infoPill(title: "Model", value: model.settings.engines.title, systemImage: "cpu")
                infoPill(title: "Meetings", value: "\(meetings.count)", systemImage: "person.2.wave.2")
                infoPill(title: "People", value: "\(model.library.people.count)", systemImage: "person.crop.circle")
                Spacer()
                if phase == .idle {
                    Button("Open Meetings", action: onOpen)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button(action: onSettings) {
                    Label("Meeting Settings…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(24)
        .background(AppCardBackground(cornerRadius: 22))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: phase)
    }

    private func flowStep(_ title: LocalizedStringKey, systemImage: String, isComplete: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(isComplete ? activeColor : .secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background((isComplete ? activeColor : Color.secondary).opacity(0.1), in: Capsule())
    }

    private func flowConnector(isActive: Bool) -> some View {
        Capsule()
            .fill((isActive ? activeColor : Color.secondary).opacity(0.28))
            .frame(maxWidth: .infinity)
            .frame(height: 2)
    }

    private func infoPill(title: LocalizedStringKey, value: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).foregroundStyle(AppTheme.Accent.primary)
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

// MARK: - Recent meetings

private struct MeetingsRecentCard: View {
    let model: MeetingScribeUI.AppModel
    let onOpen: (UUID?) -> Void

    private var recent: [MeetingRecord] {
        Array(
            model.library.meetings
                .sorted { ($0.date ?? $0.createdAt) > ($1.date ?? $1.createdAt) }
                .prefix(5)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Meetings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !recent.isEmpty {
                    Button("Show all") { onOpen(nil) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if recent.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.Accent.fill, in: RoundedRectangle(cornerRadius: 10))
                    Text("No meetings yet. Import a Zoom recording to get a transcript with speakers.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(recent) { record in
                        MeetingRow(record: record, projectName: projectName(for: record)) {
                            onOpen(record.id)
                        }
                        if record.id != recent.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(AppCardBackground(cornerRadius: 16))
    }

    private func projectName(for record: MeetingRecord) -> String? {
        guard let projectID = record.projectID else { return nil }
        return model.library.projects.first { $0.id == projectID }?.name
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord
    let projectName: String?
    let action: () -> Void
    @State private var isHovered = false

    private var statusColor: Color {
        switch record.status {
        case .ready: return AppTheme.Status.positive
        case .queued, .processing: return AppTheme.Accent.primary
        case .failed: return AppTheme.Status.error
        case .imported, .cancelled, .interrupted: return .secondary
        }
    }

    private var statusIcon: String {
        switch record.status {
        case .ready: return "checkmark"
        case .processing: return "waveform"
        case .queued: return "clock"
        case .failed: return "exclamationmark.triangle"
        case .imported, .cancelled, .interrupted: return "doc"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append((record.date ?? record.createdAt).formatted(date: .abbreviated, time: .omitted))
        if let duration = record.duration {
            parts.append(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)))
        }
        if let projectName { parts.append(projectName) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 34, height: 34)
                    .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 12)

                Text(record.status.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.1), in: Capsule())
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? AppTheme.Surface.subtle : AppTheme.Surface.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Settings sheet

private struct MeetingsSettingsSheet: View {
    let model: MeetingScribeUI.AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // A sheet has no title bar, so the tab bar would sit flush against the top edge
            // and get clipped by the sheet's rounded corners; give it the inset a window provides.
            MeetingsSettingsView(model: model)
                .padding(.top, 14)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 600)
    }
}
