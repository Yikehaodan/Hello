import AVFoundation

/// Keeps microphone capture replaceable by a paced fixture in end-to-end tests.
@MainActor
protocol VoiceRecording: AnyObject {
    var currentTime: TimeInterval { get }
    var delegate: AVAudioRecorderDelegate? { get set }
    var isMeteringEnabled: Bool { get set }
    func prepareToRecord() -> Bool
    func record() -> Bool
    func startRecording() async throws
    func stop()
    func updateMeters()
    func peakPower(forChannel channelNumber: Int) -> Float
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension VoiceRecording {
    func startRecording() async throws {
        guard prepareToRecord(), record() else {
            throw VoiceError.message("无法启动麦克风，请检查系统声音输入。")
        }
    }
}

// AVAudioRecorder is transferred exclusively to this serial queue during startup.
// The controller must await the handoff before metering, stopping or assigning it.
private final class RecorderTransfer: @unchecked Sendable {
    let recorder: AVAudioRecorder
    init(_ recorder: AVAudioRecorder) { self.recorder = recorder }
}

enum RecordingStartup {
    private static let queue = DispatchQueue(label: "Hello.microphone-startup", qos: .userInitiated)
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

extension AVAudioRecorder: VoiceRecording {
    @MainActor static func makeForRecording(url: URL, settings: [String: Any]) async throws -> AVAudioRecorder {
        // Copy the immutable settings into the queue's closure; no recorder is shared
        // with the main actor until creation completes.
        let transfer = try await RecordingStartup.run {
            RecorderTransfer(try AVAudioRecorder(url: url, settings: settings))
        }
        return transfer.recorder
    }

    func startRecording() async throws {
        let transfer = RecorderTransfer(self)
        let started = try await RecordingStartup.run {
            transfer.recorder.prepareToRecord() && transfer.recorder.record()
        }
        guard started else { throw VoiceError.message("无法启动麦克风，请检查系统声音输入。") }
    }
}
