import AppKit

@main struct AgentProgressTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-progress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let node = ProcessInfo.processInfo.environment["HELLO_TEST_NODE"] ?? "/Applications/Hello.app/Contents/Resources/AgentRuntime/node"
        try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent("node"), withDestinationURL: URL(fileURLWithPath: node))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "tests/agent-native-fixture.mjs"), to: runtime.appendingPathComponent("bridge.mjs"))
        var key = "fixture-key"
        let store = AgentConfigurationStore(root: root.appendingPathComponent("state"), readKey: { key }, writeKey: { key = $0 })
        var config = AgentConfiguration(); config.workspace = root.path
        try store.save(config, key: key)
        var lookupGate: CheckedContinuation<[AnswerSource], Never>?
        let agent = AgentSession(store: store, runtime: runtime, lookup: { _, _ in
            await withCheckedContinuation { lookupGate = $0 }
        })
        let suite = "Hello.Progress.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults, microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .authorized) },
            openURL: { _ in false }, accessibilityProvider: { true }, screenCaptureProvider: { false })
        preferences.dismissPermissionIntro()
        let model = VoiceModel(library: LibraryStore(root: root.appendingPathComponent("library")),
            sessionRoot: root.appendingPathComponent("sessions"), preferences: preferences,
            requestMicrophoneAccess: { preconditionFailure("UI regression must not record") })
        let app = NSApplication.shared
        let delegate = AppDelegate(model: model, agent: agent, listenForShortcuts: false)
        app.delegate = delegate; app.finishLaunching()
        Task { @MainActor in
            do {
                try await pause()
                let main = app.windows.first { $0.title == "Hello" && !($0 is NSPanel) }!
                let window = app.windows.first { $0.title == "Hello · 任务结果" }!
                main.orderOut(nil)
                let hud = app.windows.first { $0 is VoicePanel }!
                delegate.closeAgentWindow()
                agent.receiveVoice("整理这段资料", selection: "")
                try await wait { lookupGate != nil && hud.isVisible }
                precondition(agent.showsProgress && !window.isVisible && model.phase == .ready)
                precondition(agent.progressTitle == "正在查询天气")
                precondition(hud.contentView!.frame.size == AgentProgressHUD.size && hud.frame.height > hud.frame.width)
                let available = hud.screen!.visibleFrame
                precondition(abs(hud.frame.maxX - (available.maxX - 20)) < 1 && available.contains(hud.frame))
                precondition(!hud.isKeyWindow, "Progress must not steal keyboard focus")
                try snapshot(hud, to: output.appendingPathComponent("agent-searching.png"))
                let source = AnswerSource(title: "relative", url: "https://docs.example.org/research", content: "检索结果摘要")
                precondition(source.displayTitle == "docs.example.org")
                lookupGate!.resume(returning: [source]); lookupGate = nil
                try await wait { agent.phase == .waiting }
                try await pause()
                precondition(!window.isVisible && hud.isVisible && agent.showsProgress)
                try snapshot(hud, to: output.appendingPathComponent("agent-confirmation.png"))
                try doubleClick(hud)
                try await wait { window.isVisible && !hud.isVisible }
                precondition(agent.visible && agent.phase == .waiting, "Double click opens the live Agent chat")
                try snapshot(window, to: output.appendingPathComponent("agent-chat-expanded.png"))
                agent.reply(agent.permissions[0], allow: true)
                try await wait { agent.phase == .completed && window.isVisible && !hud.isVisible }
                try await Task.sleep(for: .milliseconds(350))
                precondition(agent.record?.messages.last?.sources == [source])
                precondition(!main.isVisible && !(window is NSPanel) && window.styleMask.contains(.resizable))
                try snapshot(window, to: output.appendingPathComponent("agent-result-window.png"))
                let restored = AgentSession(store: store, runtime: runtime)
                restored.select(agent.selectedID!)
                precondition(restored.sources == [source], "Completed sources survive history reopening")

                delegate.closeAgentWindow()
                agent.receiveVoice("第二个任务", selection: "")
                try await wait { lookupGate != nil && hud.isVisible }
                lookupGate!.resume(returning: []); lookupGate = nil
                try await wait { !agent.permissions.isEmpty }
                agent.receiveVoice("排队补充", selection: "")
                precondition(agent.queuedCount == 1 && !window.isVisible)
                agent.dismissPresentation()
                agent.reply(agent.permissions[0], allow: false)
                try await wait { lookupGate != nil && agent.queuedCount == 0 }
                precondition(!agent.visible && !agent.showsProgress && !window.isVisible,
                             "Queued continuation must respect an explicitly hidden progress window")
                lookupGate!.resume(returning: []); lookupGate = nil
                try await wait { !agent.permissions.isEmpty }
                agent.reply(agent.permissions[0], allow: true)
                try await wait { agent.phase == .completed }
                try await pause()
                precondition(!window.isVisible && !hud.isVisible, "Hidden task must not reopen at completion")
                agent.consume(["type": "delta", "text": "stale"])
                precondition(!agent.output.contains("stale"))

                key = ""
                agent.receiveVoice("缺少配置的任务", selection: "")
                try await wait { agent.pendingSubmission != nil && hud.isVisible }
                precondition(!window.isVisible && !agent.showSettings)
                agent.presentDetails(); try await pause()
                precondition(window.isVisible && agent.showSettings)
                agent.showSettings = false
                try await pause()
                print("PASS: voice handoff stays in HUD; searching and approval statuses; final-only regular result window; persisted sources; hidden queued task never reopens; configuration is opened explicitly")
                preferences.stopPermissionMonitoring(); defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
                app.terminate(nil)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(15)) }
        throw VoiceError.message("Agent presentation condition timed out")
    }
    @MainActor static func doubleClick(_ window: NSWindow) throws {
        let host = window.contentView!
        let point = host.convert(NSPoint(x: 95, y: host.isFlipped ? 82 : host.bounds.height - 82), to: nil)
        for count in 1...2 {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw VoiceError.message("Cannot create progress double click")
                }
                window.sendEvent(event)
            }
        }
    }
    static func pause() async throws { try await Task.sleep(for: .milliseconds(250)) }
    @MainActor static func snapshot(_ window: NSWindow, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
