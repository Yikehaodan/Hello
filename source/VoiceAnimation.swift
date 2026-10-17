import Foundation
import SwiftUI

/// The animation owns its envelope; audio samples never publish a redraw of the app.
struct VoiceWaveformEnvelope {
    private(set) var amplitude: Double = 0
    private var lastTime: TimeInterval?

    mutating func sample(level: Float, at time: TimeInterval) -> Double {
        let finiteLevel = level.isFinite ? Double(level) : 0
        let target = min(1, max(0, (finiteLevel - 0.025) / 0.975))
        guard let previousTime = lastTime else {
            lastTime = time
            amplitude = target
            return amplitude
        }
        let elapsed = min(0.25, max(0, time - previousTime))
        lastTime = time
        let response = target > amplitude ? 0.055 : 0.14
        amplitude += (target - amplitude) * (1 - exp(-elapsed / response))
        if target == 0 && amplitude < 0.001 { amplitude = 0 }
        return amplitude
    }

    static func heights(amplitude: Double, time: TimeInterval, reduceMotion: Bool) -> [Double] {
        let amplitude = min(1, max(0, amplitude.isFinite ? amplitude : 0))
        return (0..<10).map { index in
            let distance = abs(Double(index) - 4.5) / 4.5
            let envelope = 1 - 0.62 * pow(distance, 1.25)
            let motion = reduceMotion ? 0.88 : 0.79 + 0.21 * sin(time * 8 - distance * 2.6 + Double(index) * 0.37)
            return 2 + 19 * amplitude * envelope * motion
        }
    }
}

enum ThinkingAnimationFrame {
    /// An indeterminate fill approaches the edge without claiming completion.
    static func fill(at elapsed: TimeInterval) -> Double {
        let stops: [(Double, Double)] = [(0, 0), (1, 0.80), (2, 0.90), (3, 0.95), (4, 0.97), (5, 0.98), (10, 0.99)]
        let elapsed = max(0, elapsed)
        for index in 1..<stops.count where elapsed < stops[index].0 {
            let before = stops[index - 1], after = stops[index]
            let fraction = (elapsed - before.0) / (after.0 - before.0)
            return before.1 + fraction * (after.1 - before.1)
        }
        return 0.99
    }

    static func shimmer(at elapsed: TimeInterval) -> Double {
        // A 56 pt/s sweep over the seven-letter label, followed by a 300 ms pause.
        let sweep = 1.35
        let cycle = max(0, elapsed).truncatingRemainder(dividingBy: sweep + 0.3)
        return min(1, cycle / sweep)
    }
}

@MainActor
private final class AudioWaveformAnimator {
    var envelope = VoiceWaveformEnvelope()
    func heights(level: Float, at time: TimeInterval, reduceMotion: Bool) -> [Double] {
        let amplitude = envelope.sample(level: level, at: time)
        return VoiceWaveformEnvelope.heights(amplitude: amplitude, time: time, reduceMotion: reduceMotion)
    }
}

@MainActor
struct AudioBars: View {
    let level: @MainActor () -> Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animator = AudioWaveformAnimator()

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 15 : 1.0 / 60)) { timeline in
            // Read the main-actor audio sample here. Canvas receives only immutable geometry.
            let heights = animator.heights(level: level(), at: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
            WaveformDrawing(heights: heights)
        }
        .accessibilityLabel("录音音量")
        .allowsHitTesting(false)
    }
}

private struct WaveformDrawing: View {
    let heights: [Double]
    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = min(2, size.width / 19)
            let totalWidth: CGFloat = CGFloat(heights.count * 2 - 1) * barWidth
            for (index, value) in heights.enumerated() {
                let height = min(size.height, CGFloat(value))
                let x = (size.width - totalWidth) / 2 + CGFloat(index) * barWidth * 2
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white))
            }
        }
    }
}

struct ThinkingIndicator: View {
    var leadingInset: CGFloat = 0
    var showsProgress = false
    var label = "Thinking"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            Canvas { context, size in
                if showsProgress {
                    let fill = reduceMotion ? 0.25 : ThinkingAnimationFrame.fill(at: elapsed)
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width * fill, height: size.height)), with: .color(.white.opacity(0.20)))
                }
                let point = CGPoint(x: leadingInset + (size.width - leadingInset) / 2, y: size.height / 2)
                let text = Text(label).font(.system(size: 14, weight: .medium))
                context.draw(context.resolve(text.foregroundStyle(.white.opacity(0.62))), at: point)
                if !reduceMotion {
                    let sweep = ThinkingAnimationFrame.shimmer(at: elapsed)
                    let center = point.x - 45 + sweep * 90
                    var highlight = context.resolve(text)
                    highlight.shading = .linearGradient(
                        Gradient(colors: [.clear, .white.opacity(0.95), .clear]),
                        startPoint: CGPoint(x: center - 12, y: 0),
                        endPoint: CGPoint(x: center + 12, y: 0))
                    context.draw(highlight, at: point)
                }
            }
        }
        .clipShape(Capsule())
        .accessibilityLabel("\(label)，正在处理语音")
        .allowsHitTesting(false)
    }
}
