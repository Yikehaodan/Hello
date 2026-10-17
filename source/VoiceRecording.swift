import AVFoundation

/// Keeps microphone capture replaceable by a paced fixture in end-to-end tests.
@MainActor
protocol VoiceRecording: AnyObject {
    var currentTime: TimeInterval { get }
    var delegate: AVAudioRecorderDelegate? { get set }
    var isMeteringEnabled: Bool { get set }
    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
    func updateMeters()
    func peakPower(forChannel channelNumber: Int) -> Float
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: VoiceRecording {}
