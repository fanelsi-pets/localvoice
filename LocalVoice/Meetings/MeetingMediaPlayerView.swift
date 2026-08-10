import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MeetingMediaPlayerController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var isVideo = false
    @Published var playbackRate: Float = 1

    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var securityScopedURL: URL?
    private var playbackEndTime: TimeInterval?

    func load(_ url: URL) {
        cleanup()
        isLoading = true
        isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedDuration = try await asset.load(.duration)
                guard !Task.isCancelled else { return }
                let seconds = loadedDuration.seconds
                duration = seconds.isFinite ? max(0, seconds) : 0
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                duration = 0
                isLoading = false
            }
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play(until endTime: TimeInterval? = nil) {
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        playbackEndTime = endTime
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
        startTimer()
    }

    func pause() {
        player.pause()
        stopTimer()
        syncCurrentTime()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(duration, 0))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
    }

    func skip(by interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    func cyclePlaybackRate() {
        switch playbackRate {
        case 1: playbackRate = 1.5
        case 1.5: playbackRate = 2
        default: playbackRate = 1
        }
        if isPlaying {
            player.rate = playbackRate
        }
    }

    func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        stopTimer()
        player.pause()
        player.replaceCurrentItem(with: nil)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isLoading = false
        isVideo = false
        playbackEndTime = nil
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.syncCurrentTime()
                let reachedSampleEnd = self.playbackEndTime.map { self.currentTime >= $0 } ?? false
                let reachedFileEnd = self.duration > 0 && self.currentTime >= self.duration - 0.05
                if self.isPlaying, reachedSampleEnd || reachedFileEnd {
                    self.pause()
                    self.playbackEndTime = nil
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func syncCurrentTime() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            let newTime = max(0, seconds)
            if abs(currentTime - newTime) >= 0.01 {
                currentTime = newTime
            }
        }
        let newIsPlaying = player.rate != 0 || player.timeControlStatus == .playing
        if isPlaying != newIsPlaying {
            isPlaying = newIsPlaying
        }
    }
}

/// SwiftUI's `VideoPlayer` is implemented by the private `_AVKit_SwiftUI`
/// framework. On some macOS installations that view aborts while resolving its
/// `AVPlayerView` superclass (before the first video frame is shown). Referencing
/// `AVPlayerView` directly both avoids that runtime path and makes AVKit an
/// explicit binary dependency instead of relying on the private bridge.
private struct MeetingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator _: Void) {
        view.player = nil
    }
}

struct MeetingMediaPlayerView: View {
    @ObservedObject var controller: MeetingMediaPlayerController
    let speakerSegments: [MeetingSpeakerSegment]
    let speakerNames: [String: String]
    let onAddAnchor: (TimeInterval, String?) -> Void

    private var currentSpeakerID: String? {
        speakerSegments.first {
            controller.currentTime >= $0.startTime && controller.currentTime <= $0.endTime
        }?.speakerID
    }

    private var currentSpeakerName: String? {
        guard let currentSpeakerID else { return nil }
        let name = speakerNames[currentSpeakerID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? MeetingTranscriptBuilder.defaultSpeakerName(currentSpeakerID) : name
    }

    var body: some View {
        VStack(spacing: 12) {
            if controller.isVideo {
                MeetingVideoPlayerView(player: controller.player)
                    .frame(minHeight: 220, idealHeight: 280, maxHeight: 340)
                    .background(.black, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Прослушивание встречи")
                            .font(.headline)
                        Text("Перематывайте запись и фиксируйте секунду, когда говорит нужный человек.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            if !speakerSegments.isEmpty, controller.duration > 0 {
                MeetingSpeakerTimelineView(
                    segments: speakerSegments,
                    currentTime: controller.currentTime,
                    duration: controller.duration,
                    onSeek: controller.seek
                )
            }

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 0.01)
            )
            .disabled(controller.duration <= 0)

            HStack(spacing: 12) {
                Text(MeetingTimecode.format(controller.currentTime))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .frame(width: 58, alignment: .leading)

                if let currentSpeakerName {
                    Label(currentSpeakerName, systemImage: "person.wave.2.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                        .lineLimit(1)
                }

                Spacer()

                Button { controller.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .help("Назад на 10 секунд")

                Button { controller.togglePlayback() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(controller.isPlaying ? "Пауза" : "Воспроизвести")

                Button { controller.skip(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .help("Вперёд на 10 секунд")

                Button { controller.cyclePlaybackRate() } label: {
                    Text(speedLabel)
                        .font(.caption.weight(.semibold))
                        .frame(width: 28)
                }
                .help("Скорость воспроизведения")

                Button {
                    onAddAnchor(controller.currentTime, currentSpeakerID)
                } label: {
                    Label(
                        "Якорь на \(MeetingTimecode.format(controller.currentTime))",
                        systemImage: "mappin.and.ellipse"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isLoading || controller.duration <= 0)
                .help("Связать голос в этой секунде с именем участника")
            }

            HStack {
                Text("Длительность: \(MeetingTimecode.format(controller.duration))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if controller.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(18)
        .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private var speedLabel: String {
        controller.playbackRate == 1 ? "1×" : controller.playbackRate == 1.5 ? "1.5×" : "2×"
    }
}

private struct MeetingSpeakerTimelineView: View {
    let segments: [MeetingSpeakerSegment]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Surface.control)

                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: segment.speakerID).opacity(0.82))
                        .frame(
                            width: max(2, geometry.size.width * CGFloat((segment.endTime - segment.startTime) / duration)),
                            height: 16
                        )
                        .offset(x: geometry.size.width * CGFloat(segment.startTime / duration))
                }

                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: 22)
                    .offset(x: geometry.size.width * CGFloat(min(max(0, currentTime / duration), 1)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(0, value.location.x / max(geometry.size.width, 1)), 1)
                        onSeek(duration * ratio)
                    }
            )
        }
        .frame(height: 22)
        .help("Цвета показывают участки разных голосов. Нажмите, чтобы перейти к моменту.")
    }

    private func color(for speakerID: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .yellow]
        let index = Int(speakerID.hashValue.magnitude % UInt(palette.count))
        return palette[index]
    }
}
