import AppKit
import AVFoundation

@MainActor private final class ContextStartupLoginItems: LoginItemManaging {
    var state: LoginItemState { .notRegistered }
    func register() throws { preconditionFailure() }
    func unregister() throws { preconditionFailure() }
    func openSettings() { preconditionFailure() }
}

@MainActor private final class ContextStartupRecorder: VoiceRecording {
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

@main struct ContextStartupTests {
    @MainActor static func main() async throws {
        var front: pid_t? = 1, activations = 0, waits = 0
        let restored = await RecordingContextTarget.restore(lastPID: 2, frontmost: { front }, isHello: { $0 == 1 },
            available: { true }, activate: { activations += 1; return true }, pause: { waits += 1; front = 2 })
        precondition(restored && front == 2 && activations == 1 && waits == 1)
        let external = await RecordingContextTarget.restore(lastPID: 3, frontmost: { front }, isHello: { $0 == 1 },
            available: { true }, activate: { activations += 1; return true })
        precondition(!external && activations == 1, "already-focused external apps must not be changed")
        front = 1
        let terminated = await RecordingContextTarget.restore(lastPID: 2, frontmost: { front }, isHello: { $0 == 1 },
            available: { false }, activate: { activations += 1; return true })
        precondition(!terminated && activations == 1)
        let race = await RecordingContextTarget.restore(lastPID: 2, frontmost: { front }, isHello: { $0 == 1 },
            available: { true }, activate: { true }, pause: { front = 3 })
        precondition(!race && front == 3, "never retarget to another app during a focus race")
        front = 1; waits = 0
        let timeout = await RecordingContextTarget.restore(lastPID: 2, frontmost: { front }, isHello: { $0 == 1 },
            available: { true }, activate: { true }, pause: { waits += 1 })
        precondition(!timeout && waits == 30)
        let cancelled = await RecordingContextTarget.restore(lastPID: 2, frontmost: { front }, isHello: { $0 == 1 },
            available: { true }, activate: { true }, pause: { throw CancellationError() })
        precondition(!cancelled)
        print("PASS: Hello restores the previous app; external focus, termination, focus races, timeout and cancellation are respected")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-startup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Hello.ContextStartup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let saved = ["autoPolish", "autoPaste", "soundEnabled"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let preferences = AppPreferences(defaults: defaults, loginItems: ContextStartupLoginItems(),
            microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .authorized) },
            openURL: { _ in false }, accessibilityProvider: { false }, screenCaptureProvider: { false })
        let library = LibraryStore(root: root.appendingPathComponent("library"))
        var captureFlags: [Bool] = [], selectionFlags: [Bool] = []
        var gates: [CheckedContinuation<VoiceContext, Never>] = []
        var handoffs: [VoiceContext?] = []
        var processCalls = 0
        let model = VoiceModel(library: library, sessionRoot: root.appendingPathComponent("sessions"),
            preferences: preferences, requestMicrophoneAccess: { true },
            transcriptionOperation: { _, _, _ in "处理这个输入框" },
            processingOperation: { text, _, _, _, _ in processCalls += 1; return VoiceProcessingResult(text: text) },
            recordingFactory: { url, _ in try ContextStartupRecorder(url: url) },
            destinationCapture: { selected in selectionFlags.append(selected); return nil },
            contextCapture: { _, screenshots in
                captureFlags.append(screenshots)
                return await withCheckedContinuation { gates.append($0) }
            })
        model.autoPolish = true; model.autoPaste = false; model.soundEnabled = false
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 3, bitsPerPixel: 24)!
        bitmap.setColor(.white, atX: 0, y: 0)
        let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
        let image = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        model.onAgentRequest = { _, _, context in handoffs.append(context); return nil }
        for mode: InputMode in [.context, .ask] {
            preferences.contextScreenshots = mode == .ask
            let previousCount = library.history.count, previousProcessing = processCalls
            model.toggle(mode: mode)
            await wait { model.phase == .recording && gates.count == 1 }
            precondition(selectionFlags.last == true && captureFlags.last == (mode == .ask))
            precondition(model.contextStatus == "正在读取输入框与页面……")
            model.toggle(mode: InputMode.primaryShortcutMode)
            precondition(model.mode == mode, "Second Fn stops the current mode without switching it")
            await wait { !model.raw.isEmpty }
            precondition(model.busy && processCalls == previousProcessing && handoffs.isEmpty,
                         "context capture must not delay microphone/ASR, but model request must wait for it")
            let snapshot = VoiceContext(application: "Fixture", windowTitle: "Pinned window", inputText: "原输入框内容", imageDataURL: mode == .ask ? image : nil, captureStatus: "已读取测试输入框")
            gates.removeFirst().resume(returning: snapshot)
            await wait { model.phase == .ready && library.history.count == previousCount + 1 }
            let entry = library.history[0]
            precondition(entry.contextInputText == snapshot.inputText && entry.contextWindowTitle == snapshot.windowTitle)
            precondition(entry.contextCaptureStatus == snapshot.captureStatus)
            if mode == .ask {
                let savedImage = try Data(contentsOf: library.screenshotURL(for: entry.id)!)
                precondition(savedImage == jpeg)
                precondition(handoffs.count == 1 && handoffs[0] == snapshot)
                let count = captureFlags.count
                model.retryHistory(id: entry.id)
                await wait { model.phase == .ready && handoffs.count == 2 }
                precondition(captureFlags.count == count && handoffs.last!?.inputText == snapshot.inputText && handoffs.last!?.imageDataURL == image,
                             "history retries must reuse the saved context without capturing a different page")
            }
        }
        handoffs.removeAll()
        model.toggle(mode: .ask)
        await wait { model.phase == .recording && gates.count == 1 }
        model.cancel()
        let captureCount = captureFlags.count
        model.toggle(mode: .translate)
        await wait { model.phase == .recording }
        gates.removeFirst().resume(returning: VoiceContext(application: "Stale", inputText: "must be discarded", captureStatus: "stale"))
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.contextStatus.isEmpty && model.phase == .recording && handoffs.isEmpty)
        precondition(captureFlags.count == captureCount && selectionFlags.last == false)
        model.stop(); await wait { model.phase == .ready }
        precondition(library.history[0].contextInputText == nil)
        model.toggle(mode: .dictate); await wait { model.phase == .recording }
        precondition(captureFlags.count == captureCount && selectionFlags.last == false)
        model.cancel()
        print("PASS: Control/Space recording and ASR run during slow context capture; handoff, history retry, screenshot switch and stale cancellation are isolated")
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("context startup condition timed out")
    }
}
