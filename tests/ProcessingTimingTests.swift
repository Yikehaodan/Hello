import Foundation
import AVFoundation

@MainActor private final class TimingLoginItems: LoginItemManaging {
    var state: LoginItemState { .notRegistered }
    func register() throws { preconditionFailure() }
    func unregister() throws { preconditionFailure() }
    func openSettings() { preconditionFailure() }
}

@MainActor private final class TimingRecorder: VoiceRecording {
    var currentTime: TimeInterval { 8 }
    var delegate: AVAudioRecorderDelegate?
    var isMeteringEnabled = false
    init(url: URL) throws { try Data("fixture recording".utf8).write(to: url) }
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { true }
    func stop() {}
    func updateMeters() {}
    func peakPower(forChannel: Int) -> Float { -10 }
    func averagePower(forChannel: Int) -> Float { -20 }
}

@main struct ProcessingTimingTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("timing-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Hello.TimingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let persisted = ["autoPolish", "autoPaste", "soundEnabled"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in persisted {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let preferences = AppPreferences(defaults: defaults, loginItems: TimingLoginItems(),
            microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .authorized) },
            openURL: { _ in false }, accessibilityProvider: { false }, screenCaptureProvider: { false })
        let library = LibraryStore(root: root.appendingPathComponent("library"))
        var now: TimeInterval = 100
        var asr: CheckedContinuation<String, Error>?
        var llm: CheckedContinuation<VoiceProcessingResult, Error>?
        let model = VoiceModel(library: library, sessionRoot: root.appendingPathComponent("recordings"),
            preferences: preferences, requestMicrophoneAccess: { true },
            transcriptionOperation: { _, _, _ in try await withCheckedThrowingContinuation { asr = $0 } },
            processingOperation: { _, _, _, _, _ in try await withCheckedThrowingContinuation { llm = $0 } },
            recordingFactory: { url, _ in try TimingRecorder(url: url) }, destinationCapture: { _ in nil },
            processingNow: { now })
        model.autoPolish = true; model.autoPaste = false; model.soundEnabled = false
        model.toggle()
        await eventually { model.phase == .recording }
        now = 200; model.stop()
        await eventually { asr != nil }
        now = 202.5; asr!.resume(returning: "测试原文"); asr = nil
        await eventually { llm != nil }
        now = 204.25; llm!.resume(returning: VoiceProcessingResult(text: "整理结果")); llm = nil
        await eventually { model.phase == .ready && library.history.count == 1 }
        let id = library.history[0].id
        check(library.history[0].timings, total: 4.25, asr: 2.5, llm: 1.75)
        precondition(library.history[0].duration == 8)
        precondition(LibraryStore(root: root.appendingPathComponent("library")).history[0].timings == library.history[0].timings)
        print("PASS: stop-to-result total excludes recording and persists separate ASR/LLM stages")

        now = 300; model.retryHistory(id: id)
        await eventually { llm != nil }
        now = 301.25; llm!.resume(throwing: VoiceError.message("fixture failure")); llm = nil
        await eventually { model.phase == .ready }
        precondition(library.history.count == 1 && !library.history[0].succeeded)
        check(library.history[0].timings, total: 1.25, asr: nil, llm: 1.25)
        print("PASS: failed text-only retry reports the latest attempt without stale ASR timing")

        now = 400; model.retryProcessing()
        await eventually { llm != nil }
        now = 403; model.cancel()
        check(library.history[0].timings, total: 3, asr: nil, llm: 3)
        now = 999; llm!.resume(returning: VoiceProcessingResult(text: "late result")); llm = nil
        try await Task.sleep(for: .milliseconds(40))
        check(library.history[0].timings, total: 3, asr: nil, llm: 3)
        print("PASS: cancellation freezes elapsed time and late responses cannot change it")

        model.autoPolish = false
        model.toggle(); await eventually { model.phase == .recording }
        now = 1100; model.stop(); await eventually { asr != nil }
        now = 1100.5; asr!.resume(returning: "无需整理"); asr = nil
        await eventually { library.history.count == 2 && model.phase == .ready }
        check(library.history[0].timings, total: 0.5, asr: 0.5, llm: nil)
        precondition(llm == nil)
        print("PASS: ASR-only dictation reports unused LLM")

        model.toggle(); await eventually { model.phase == .recording }
        now = 1200; model.stop(); await eventually { asr != nil }
        now = 1202; asr!.resume(throwing: VoiceError.message("recognition failure")); asr = nil
        await eventually { library.history.count == 3 && model.phase == .ready }
        check(library.history[0].timings, total: 2, asr: 2, llm: nil)
        let failedID = library.history[0].id
        now = 1300; model.retryHistory(id: failedID); await eventually { asr != nil }
        now = 1300.75; asr!.resume(returning: "重新识别成功"); asr = nil
        await eventually { model.phase == .ready && library.history[0].succeeded }
        check(library.history[0].timings, total: 0.75, asr: 0.75, llm: nil)
        precondition(library.history.count == 3)
        print("PASS: ASR failures and audio retries retain only the latest attempt's times")
    }

    static func check(_ value: HistoryTimings?, total: Double, asr: Double?, llm: Double?) {
        precondition(value == HistoryTimings(total: total, asr: asr, llm: llm), "Unexpected timings: \(String(describing: value))")
    }
    @MainActor static func eventually(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timing fixture did not reach expected phase")
    }
}
