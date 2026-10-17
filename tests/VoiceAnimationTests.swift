import Foundation

@main
struct VoiceAnimationTests {
    static func main() {
        var envelope = VoiceWaveformEnvelope()
        for frame in 0...120 {
            let time = Double(frame) / 60
            let value = envelope.sample(level: 0, at: time)
            check(value == 0, "silent input has no invented activity")
            check(VoiceWaveformEnvelope.heights(amplitude: value, time: time, reduceMotion: false).allSatisfy { $0 == 2 }, "silence remains flat on every frame")
        }

        var voice = VoiceWaveformEnvelope()
        _ = voice.sample(level: 0, at: 0)
        var last = 0.0
        var largestStep = 0.0
        for frame in 1...60 {
            let value = voice.sample(level: 0.8, at: Double(frame) / 60)
            largestStep = max(largestStep, value - last)
            check(value >= last, "attack envelope approaches the input without oscillation")
            last = value
        }
        check(last > 0.79 && last < 0.8, "voice amplitude settles to the measured level")
        check(largestStep < 0.22, "a sudden level change is smoothed over several display frames")
        let first = VoiceWaveformEnvelope.heights(amplitude: last, time: 1, reduceMotion: false)
        let later = VoiceWaveformEnvelope.heights(amplitude: last, time: 1.2, reduceMotion: false)
        check(zip(first, later).contains { abs($0 - $1) > 0.5 }, "a sustained voice still has continuous wave motion")
        check(first.allSatisfy { $0 >= 2 && $0 <= 21 }, "bars stay inside the HUD")
        check(VoiceWaveformEnvelope.heights(amplitude: last, time: 1, reduceMotion: true) == VoiceWaveformEnvelope.heights(amplitude: last, time: 2, reduceMotion: true), "Reduce Motion removes decorative oscillation")
        for frame in 61...180 { _ = voice.sample(level: 0, at: Double(frame) / 60) }
        check(voice.amplitude == 0, "the release tail fully settles to silence")
        check(voice.sample(level: .nan, at: 3.1).isFinite, "invalid input cannot corrupt drawing geometry")

        var lastFill = 0.0
        for frame in 0...1800 {
            let fill = ThinkingAnimationFrame.fill(at: Double(frame) / 60)
            check(fill >= lastFill && fill < 1, "thinking fill remains monotonic and indeterminate")
            lastFill = fill
        }
        check(ThinkingAnimationFrame.shimmer(at: 0.25) != ThinkingAnimationFrame.shimmer(at: 0.75), "Thinking highlight moves while processing")
        check(abs(ThinkingAnimationFrame.shimmer(at: 0.25) - ThinkingAnimationFrame.shimmer(at: 1.9)) < 0.0001, "Thinking shimmer repeats after sweep and pause")
        print("PASS: 60 Hz waveform smoothing, silence, sustained voice, Reduce Motion, and Thinking animation")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
    }
}
