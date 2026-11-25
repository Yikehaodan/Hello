import AppKit
import Combine

@MainActor
private final class HUDTestLoginItems: LoginItemManaging {
    var state: LoginItemState { .notRegistered }
    func register() throws { preconditionFailure("HUD test cannot register login items") }
    func unregister() throws { preconditionFailure("HUD test cannot unregister login items") }
    func openSettings() { preconditionFailure("HUD test cannot open settings") }
}

@MainActor
private final class HUDScenario {
    let model: VoiceModel
    let output: URL
    let started = Date()
    var records: [[String: Any]] = []
    var firstPixels: [String: Data] = [:]

    init(model: VoiceModel, output: URL) { self.model = model; self.output = output }

    func run() async throws {
        guard let panel = NSApp.windows.first(where: { $0 is VoicePanel }) else {
            throw VoiceError.message("AppDelegate did not create a VoicePanel")
        }
        // Keep only the test-owned HUD visible; no other application is inspected or captured.
        for window in NSApp.windows where !(window is VoicePanel) { window.orderOut(nil) }
        let preparedView = panel.contentView
        var publishedUpdates = 0
        let observation = model.objectWillChange.sink { publishedUpdates += 1 }
        for index in 0..<60 { model.level = Float(index) / 60 }
        try require(publishedUpdates == 0, "60 audio level updates do not publish whole-model redraws")
        observation.cancel()

        model.level = 0.6
        model.phase = .recording
        try await pause(0.6)
        try require(panel.isVisible, "recording HUD is visible")
        try require(panel.contentView === preparedView, "first activation reuses the prebuilt recording HUD")
        let focusTarget = Process()
        focusTarget.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        focusTarget.arguments = ["--focus-target"]
        try focusTarget.run()
        defer { if focusTarget.isRunning { focusTarget.terminate() } }
        let deadline = Date().addingTimeInterval(4)
        while NSApp.isActive && Date() < deadline { try await pause(0.1) }
        try require(!NSApp.isActive, "the separate test-owned app has focus")
        try require(panel.isVisible, "recording HUD remains visible while its application is inactive")
        let recordingView = panel.contentView
        try await snapshot("recording", suffix: "1", panel: panel)

        try await pause(0.22)
        try await snapshot("recording", suffix: "2", panel: panel)
        try await pause(1.78)

        model.phase = .transcribing
        model.status = "正在本地转文字……"
        try await pause(0.35)
        try require(panel.isVisible && !NSApp.isActive, "transcribing HUD is visible while its app is inactive")
        try require(panel.contentView === recordingView, "recording-to-thinking preserves its hosting view")
        try await snapshot("transcribing", suffix: "1", panel: panel)
        try await pause(0.22)
        try await snapshot("transcribing", suffix: "2", panel: panel)
        try await pause(2.43)

        model.phase = .polishing
        model.status = "正在整理文字……"
        try await pause(0.35)
        try require(panel.isVisible && !NSApp.isActive, "polishing HUD is visible while its app is inactive")
        try require(panel.contentView === recordingView, "transcription-to-polishing keeps the same hosting view")
        try await snapshot("polishing", suffix: "1", panel: panel)
        try await pause(0.22)
        try await snapshot("polishing", suffix: "2", panel: panel)
        try await pause(2.43)

        model.mode = .ask
        for (phase, name) in [(VoiceModel.Phase.authorizing, "ask-preparing"), (.recording, "ask-recording"),
                              (.transcribing, "ask-transcribing"), (.polishing, "ask-thinking")] {
            model.phase = phase
            try await pause(0.35)
            try require(panel.isVisible && panel.contentView === recordingView,
                        "Ask mode remains visible without recreating the animated HUD")
            try await snapshot(name, suffix: "1", panel: panel)
        }
        model.mode = .dictate
        model.phase = .ready
        model.mode = .context
        for (phase, name) in [(VoiceModel.Phase.recording, "context-recording"), (.polishing, "context-thinking")] {
            model.phase = phase
            try await pause(0.35)
            try require(panel.isVisible && panel.contentView === recordingView, "Context HUD preserves animation view")
            try await snapshot(name, suffix: "1", panel: panel)
        }
        model.mode = .dictate
        model.phase = .ready
        for message in ["已输入到测试编辑器。", "已复制，可按 ⌘V 粘贴。", "处理完成，可查看或复制结果。", "已取消。"] {
            model.status = message
            try await pause(0.15)
            try require(!panel.isVisible, "completion/copy/cancellation never opens a status card: \(message)")
        }
        records.append(["phase": "ready-hidden", "elapsed": Date().timeIntervalSince(started),
                        "visible": panel.isVisible, "windowNumber": panel.windowNumber])
        model.phase = .authorizing
        try await pause(0.05)
        try require(panel.isVisible && panel.contentView === preparedView,
                    "Fn startup after hiding reuses the same HUD immediately")
        model.phase = .ready
        try await pause(0.05)
        if ProcessInfo.processInfo.environment["HUD_STARTUP_ONLY"] == "1" {
            let report: [String: Any] = ["passed": true, "scope": "startup HUD reuse and phase transitions",
                "realMicrophoneUsed": false, "hardwareFnTest": false, "records": records]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("startup-hud-validation.json"))
            print("PASS: startup HUD reuse, cancellation visibility and recording/processing transitions")
            return
        }
        FaultTransport.reset(Array(repeating: 503, count: 6))
        model.raw = "保留这段原文"; model.polish()
        let retryDeadline = Date().addingTimeInterval(35)
        while model.apiRetryAttempt == 0 && Date() < retryDeadline { try await pause(0.05) }
        try require(model.apiRetryAttempt == 1 && model.status.contains("1/5"), "connection failure publishes visible retry progress")
        try await pause(0.2)
        try await snapshot("api-retrying", suffix: "1", panel: panel)
        while model.busy && Date() < retryDeadline { try await pause(0.1) }
        try require(model.canRetryProcessing && !model.busy && FaultTransport.requests.count == 6,
                    "five failed retries expose manual retry and retain source")
        try await pause(0.2)
        try await snapshot("api-retry-exhausted", suffix: "1", panel: panel)
        try await pause(6.2)
        try require(panel.isVisible, "retry action stays visible until handled or dismissed")
        FaultTransport.reset([200])
        model.retryProcessing()
        let successDeadline = Date().addingTimeInterval(3)
        while model.busy && Date() < successDeadline { try await pause(0.05) }
        try require(!model.canRetryProcessing && !model.busy && FaultTransport.requests.count == 1,
                    "manual retry recovers without recording again")
        try await pause(0.2)
        try require(!panel.isVisible, "successful manual retry also closes the HUD without a completion card")
        // Fn+Space now hands off to Agent. Missing Agent must not revive the removed answer gateway.
        model.onAgentRequest = nil
        FaultTransport.reset([200])
        model.mode = .ask; model.raw = "为什么天空是蓝色？"; model.polish()
        let answerDeadline = Date().addingTimeInterval(3)
        while model.busy && Date() < answerDeadline { try await pause(0.05) }
        try require(!model.showAnswer && model.canRetryProcessing && FaultTransport.requests.isEmpty,
                    "Ask without Agent retains the prompt and reports unavailable without calling the removed gateway (answer=\(model.showAnswer), retry=\(model.canRetryProcessing), requests=\(FaultTransport.requests.count), status=\(model.status))")
        var handedOff = ""
        model.onAgentRequest = { text, _, _ in handedOff = text; return UUID() }
        model.polish()
        let handoffDeadline = Date().addingTimeInterval(3)
        while model.busy && Date() < handoffDeadline { try await pause(0.05) }
        try require(handedOff == model.raw && !model.showAnswer && !model.canRetryProcessing && FaultTransport.requests.isEmpty,
                    "Ask hands the prompt to Agent without opening the legacy answer panel")
        model.onAgentRequest = nil
        // The retained answer view can still be rendered independently for compatibility.
        model.result = "完成"; model.showAnswer = true
        try await pause(0.2)
        guard let answerPanel = NSApp.windows.first(where: { $0 is AnswerPanel }) else {
            throw VoiceError.message("AppDelegate did not create an AnswerPanel")
        }
        try require(answerPanel.isVisible && !panel.isVisible,
                    "Retained answer view is visible independently of the suppressed completion status card")
        try await snapshot("ask-answer", suffix: "1", panel: answerPanel)
        model.showAnswer = false
        try await pause(0.15)
        try require(!answerPanel.isVisible, "dismissing Ask closes its answer window")
        FaultTransport.reset([200])
        FaultTransport.plainTextFixture = "你觉得这个任务应该如何设计？"
        model.mode = .context; model.raw = "你觉得这个任务应该如何设计？"; model.polish()
        let dictationDeadline = Date().addingTimeInterval(4)
        while model.busy && Date() < dictationDeadline { try await pause(0.05) }
        try await pause(0.2)
        try require(!model.showAnswer && !answerPanel.isVisible && !panel.isVisible,
                    "context dictation never opens an answer or success window")
        try require(model.result == model.raw && !model.answerLookupPerformed && FaultTransport.requests.count == 1,
                    "context question is transcribed as a question through the production Gateway, with no lookup")
        let contextBody = try JSONSerialization.jsonObject(with: FaultTransport.requests[0]) as! [String: Any]
        let contextMessages = contextBody["messages"] as! [[String: Any]]
        try require((contextMessages.first?["content"] as? String ?? "").contains("本次是上下文听写") && contextBody["response_format"] == nil,
                    "controller calls the dictation prompt rather than the answer planner")
        let report: [String: Any] = [
            "passed": true, "pid": ProcessInfo.processInfo.processIdentifier,
            "levelUpdatePublications": publishedUpdates,
            "realMicrophoneUsed": false, "networkUsed": false, "globalShortcutListening": false,
            "phaseDriver": "direct model state injection; not a hardware Fn end-to-end test",
            "captureMode": "designated-window screenshots only; video mode did not honor the window filter and its output was deleted without inspection",
            "records": records
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("hud-validation.json"))
        print("PASS: production AppDelegate HUD transitions, continuous view identity, isolated level updates, silent completion and retry-only status cards")
    }

    func snapshot(_ phase: String, suffix: String, panel: NSWindow) async throws {
        let file = output.appendingPathComponent("\(phase)-\(suffix).png")
        let status = try await command(["-x", "-o", "-l", String(panel.windowNumber), file.path])
        try require(status == 0 && FileManager.default.fileExists(atPath: file.path), "\(phase) designated-window screenshot saved")
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: file)), let bitmapData = bitmap.bitmapData else {
            throw VoiceError.message("Cannot decode designated-window screenshot")
        }
        try require(bitmap.pixelsWide == Int(panel.frame.width * panel.backingScaleFactor)
                    && bitmap.pixelsHigh == Int(panel.frame.height * panel.backingScaleFactor),
                    "\(phase) screenshot dimensions match only its HUD window")
        let pixels = Data(bytes: bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        if let first = firstPixels[phase] {
            let changes = zip(first, pixels).filter { $0 != $1 }.count
            try require(changes > 0, "\(phase) rendered pixels changed between animation frames")
            records.append(["phase": phase, "changedChannelBytes": changes,
                            "inputLevel": model.level, "applicationActive": NSApp.isActive])
        } else { firstPixels[phase] = pixels }
        records.append(["phase": phase, "elapsed": Date().timeIntervalSince(started),
                        "visible": panel.isVisible, "windowNumber": panel.windowNumber,
                        "applicationActive": NSApp.isActive,
                        "width": panel.frame.width, "height": panel.frame.height,
                        "hostingView": String(describing: ObjectIdentifier(panel.contentView!)),
                        "screenshot": file.lastPathComponent])
        print("HUD_FRAME phase=\(phase) window=\(panel.windowNumber) elapsed=\(Date().timeIntervalSince(started))")
        fflush(stdout)
    }

    func command(_ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
    }

    func pause(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VoiceError.message(message) }
        print("PASS: \(message)")
    }
}

@main
struct HUDIntegrationTests {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.contains("--focus-target") {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 280, height: 90),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "轻声输入 · HUD 测试焦点窗口"
            window.contentView = NSTextField(labelWithString: "仅用于验证悬浮窗在应用失去焦点时可见。")
            application.finishLaunching()
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            withExtendedLifetime(window) { application.run() }
            return
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("LightVoiceHUD-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let suite = "LightVoice.HUDTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults, loginItems: HUDTestLoginItems(),
            microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .notDetermined) }, openURL: { _ in false })
        let env = sandbox.appendingPathComponent("gateway.env")
        try "OPENCAS_LLM_BASE_URL=https://retry.invalid/v1\nOPENCAS_LLM_API_KEY=fixture\nKNOCK_LLM_MODEL=DeepSeek-V4.1-Flash".write(to: env, atomically: true, encoding: .utf8)
        setenv("LIGHTVOICE_ENV", env.path, 1)
        URLProtocol.registerClass(FaultTransport.self)
        let model = VoiceModel(library: LibraryStore(root: sandbox.appendingPathComponent("library")),
            sessionRoot: sandbox.appendingPathComponent("recordings"), preferences: preferences,
            requestMicrophoneAccess: { preconditionFailure("HUD test cannot request microphone access") },
            transcriptionOperation: { _, _, _ in preconditionFailure("HUD test cannot transcribe") })
        let application = NSApplication.shared
        let delegate = AppDelegate(model: model, listenForShortcuts: false)
        application.delegate = delegate
        application.finishLaunching()
        // Never hand this suite's synthetic prompts to the user's Agent runtime.
        model.onAgentRequest = nil
        Task { @MainActor in
            do {
                try await HUDScenario(model: model, output: output).run()
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: sandbox)
                application.terminate(nil)
            } catch {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: sandbox)
                print("FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        withExtendedLifetime(delegate) { application.run() }
    }
}
