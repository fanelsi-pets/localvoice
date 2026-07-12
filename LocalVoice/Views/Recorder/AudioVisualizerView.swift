import SwiftUI

/// A compact oscilloscope-style waveform inspired by a continuous audio trace.
/// The line reacts to the live microphone level while its edges taper smoothly
/// into the recorder surface.
struct AudioVisualizer: View {
    let audioMeter: AudioMeter
    let color: Color
    let isActive: Bool

    private let sampleCount = 96
    @State private var samples = Array(repeating: CGFloat.zero, count: 96)
    @State private var sampleIndex = 0

    var body: some View {
        Canvas { context, size in
            drawWaveform(in: context, size: size)
        }
        .frame(width: 96, height: 28)
        .accessibilityHidden(true)
        .onChange(of: audioMeter.averagePower, initial: true) { _, newLevel in
            appendSample(from: newLevel)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                samples = Array(repeating: 0, count: sampleCount)
                sampleIndex = 0
            }
        }
    }

    private func appendSample(from rawLevel: Double) {
        guard isActive else { return }
        let level = CGFloat(max(0.025, pow(max(0, min(1, rawLevel)), 0.62)))
        let phase = Double(sampleIndex)
        let carrier = sin(phase * 2.17) + 0.42 * sin(phase * 4.73) + 0.18 * sin(phase * 7.31)
        samples.removeFirst()
        samples.append(CGFloat(carrier) * level)
        sampleIndex += 1
    }

    private func drawWaveform(in context: GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        var path = Path()

        for index in samples.indices {
            let progress = CGFloat(index) / CGFloat(sampleCount - 1)
            let x = progress * size.width
            let leftFade = min(1, progress / 0.14)
            let y = midY + samples[index] * leftFade * size.height * 0.38

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        context.stroke(path, with: .color(color.opacity(0.18)), lineWidth: 3.0)
        context.stroke(path, with: .color(color.opacity(0.92)), lineWidth: 0.85)

        guard isActive else { return }
        for index in samples.indices where abs(samples[index]) > 0.22 && index.isMultiple(of: 3) {
            let progress = CGFloat(index) / CGFloat(sampleCount - 1)
            let leftFade = min(1, progress / 0.14)
            let x = progress * size.width
            let waveY = midY + samples[index] * leftFade * size.height * 0.38
            let direction: CGFloat = samples[index] > 0 ? 1 : -1
            let y = waveY + direction * 2.5
            let diameter = min(1.5, 0.7 + abs(samples[index]))
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                with: .color(color.opacity(0.32))
            )
        }
    }
}

struct StaticVisualizer: View {
    let color: Color

    var body: some View {
        Capsule()
            .fill(color.opacity(0.34))
            .frame(width: 96, height: 1)
            .accessibilityHidden(true)
    }
}

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing: return 0.22
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28)
    }
}
