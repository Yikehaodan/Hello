import AppKit
import AVFoundation

@MainActor private final class StartupLoginItems: LoginItemManaging {
    var state: LoginItemState { .notRegistered }
    func register() throws { preconditionFailure() }
    func unregister() throws { preconditionFailure() }
    func openSettings() { preconditionFailure() }
}

@MainActor private final class StartupRecorder: VoiceRecording {
    var currentTime: TimeInterval { 0 }
    var delegate: AVAudioRecorderDelegate?
    var isMeteringEnabled = false
    var stopped = false
    var starts = 0
    var pending: CheckedContinuation<Void, Error>?
    let delayed: Bool
    init(url: URL, delayed: Bool) throws {
        self.delayed = delayed
        try Data("isolated startup fixture".utf8).write(to: url)
    }
    func prepareToRecord() -> Bool { preconditionFailure("Use asynchronous startup") }
    func record() -> Bool { preconditionFailure("Use asynchronous startup") }
    func startRecording() async throws {
        starts += 1
        if delayed { try await withCheckedThrowingContinuation { pending = $0 } }
    }
    func stop() { stopped = true }
    func updateMeters() {}
    func peakPower(forChannel: Int) -> Float { -160 }
    func averagePower(forChannel: Int) -> Float { -160 }
}

@main struct StartupResponsivenessTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("startup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Hello.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var permissionReads = 0
        let preferences = AppPreferences(defaults: defaults, loginItems: StartupLoginItems(),
            microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .authorized) },
            openURL: { _ in false }, screenCaptureProvider: { permissionReads += 1; return false })
        var permissionRequests = 0
        var destinationGate: CheckedContinuation<TextDestination?, Never>?
        var factoryGate: CheckedContinuation<any VoiceRecording, Error>?
        var pendingURL: URL?
        var factoryDelayed = false, startDelayed = false, destinationDelayed = true
        var captures: [StartupRecorder] = []
        let model = VoiceModel(library: LibraryStore(root: root.appendingPathComponent("library")),
            sessionRoot: root.appendingPathComponent("sessions"), preferences: preferences,
            requestMicrophoneAccess: { permissionRequests += 1; return true },
            transcriptionOperation: { _, _, _ in "fixture" },
            processingOperation: { _, _, _, _, _ in VoiceProcessingResult(text: "fixture") },
            recordingFactory: { url, _ in
                if factoryDelayed {
                    pendingURL = url
                    return try await withCheckedThrowingContinuation { factoryGate = $0 }
                }
                let capture = try StartupRecorder(url: url, delayed: startDelayed)
                captures.append(capture)
                return capture
            }, destinationCapture: { _ in
                if destinationDelayed { return await withCheckedContinuation { destinationGate = $0 } }
                return nil
            })
        let baselineReads = permissionReads

        model.toggle()
        await eventually { destinationGate != nil }
        model.cancel()
        destinationGate!.resume(returning: nil); destinationGate = nil
        await settle()
        require(permissionRequests == 0 && captures.isEmpty && model.phase == .ready,
                "canceling slow destination capture cannot open the microphone")

        destinationDelayed = false; factoryDelayed = true
        model.toggle()
        await eventually { factoryGate != nil }
        model.cancel()
        factoryDelayed = false
        model.toggle()
        await eventually { model.phase == .recording }
        let stale = try StartupRecorder(url: pendingURL!, delayed: false)
        factoryGate!.resume(returning: stale); factoryGate = nil
        await settle()
        require(stale.stopped && stale.starts == 0 && !FileManager.default.fileExists(atPath: pendingURL!.path),
                "late factory result is stopped and removed without starting")
        require(model.phase == .recording && !captures.last!.stopped,
                "late factory result cannot replace the new session")
        model.cancel()

        startDelayed = true
        model.toggle()
        await eventually { captures.last?.pending != nil }
        let starting = captures.last!
        model.cancel()
        startDelayed = false
        model.toggle()
        await eventually { model.phase == .recording }
        starting.pending!.resume(); starting.pending = nil
        await settle()
        require(starting.stopped && model.phase == .recording && !captures.last!.stopped,
                "late microphone start is stopped without disturbing the replacement")
        model.cancel()

        startDelayed = true
        model.toggle()
        await eventually { captures.last?.pending != nil }
        let failing = captures.last!
        model.cancel()
        failing.pending!.resume(throwing: VoiceError.message("delayed device error")); failing.pending = nil
        await settle()
        require(failing.stopped && model.phase == .ready && model.status == "已取消。",
                "late device failure cannot overwrite cancellation")
        require(permissionReads == baselineReads, "successful startup does not query screenshot permissions")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path)
        require(files.isEmpty, "all canceled startup recordings are removed")

        // Block the same serial worker used by real AVAudioRecorder startup. The
        // main actor must continue processing UI/cancel work while the device waits.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = Task {
            try await RecordingStartup.run {
                precondition(!Thread.isMainThread)
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw VoiceError.message("UI blocked") }
                return true
            }
        }
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 3) == .success)
            }
        }
        require(didEnter, "microphone work enters its background queue")
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(20))
        let latency = ProcessInfo.processInfo.systemUptime - start
        release.signal()
        let finished = try await worker.value
        require(finished && latency < 0.5, "main actor remains responsive during blocked device initialization")
        print(String(format: "PASS: main-actor heartbeat during blocked microphone startup %.1f ms", latency * 1000))
    }

    @MainActor static func eventually(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timed out waiting for startup boundary")
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(50)) }
    static func require(_ value: Bool, _ message: String) {
        precondition(value, message); print("PASS: \(message)")
    }
}
