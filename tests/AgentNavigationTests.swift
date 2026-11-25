import AppKit

@main struct AgentNavigationTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-agent-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Hello.AgentNavigation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults,
            microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .authorized) },
            openURL: { _ in false }, accessibilityProvider: { true }, screenCaptureProvider: { false })
        preferences.dismissPermissionIntro()
        let model = VoiceModel(library: LibraryStore(root: root.appendingPathComponent("library")),
            sessionRoot: root.appendingPathComponent("sessions"), preferences: preferences,
            requestMicrophoneAccess: { preconditionFailure("Closing/navigation must never start recording") })
        let store = AgentConfigurationStore(root: root.appendingPathComponent("agent"), readKey: { "" }, writeKey: { _ in })
        let task = AgentTaskRecord(title: "历史任务", fingerprint: "fixture", messages: [AgentMessage(role: "user", text: "历史任务"), AgentMessage(role: "assistant", text: "## 已完成\n这是历史任务结果。")], state: "任务完成")
        try AgentConfigurationStore.writePrivate(JSONEncoder().encode([task]), to: store.root.appendingPathComponent("tasks.json"))
        let agent = AgentSession(store: store)
        let app = NSApplication.shared
        let delegate = AppDelegate(model: model, agent: agent, listenForShortcuts: false)
        app.delegate = delegate
        app.finishLaunching()
        Task { @MainActor in
            do {
                try await pause()
                let main = try requireWindow()
                let host = main.contentView!
                try clickSidebar(1, in: main); try await pause()
                main.contentView!.layoutSubtreeIfNeeded(); main.displayIfNeeded()
                try click(NSPoint(x: 450, y: 294), in: main); try await pause()
                precondition(agent.visible && agent.selectedID == task.id, "Clicking unified history opens its result")
                delegate.closeAgentWindow(); try await pause()
                try clickSidebar(2, in: main); try await pause()
                precondition(main.isVisible && main.contentView === host && !agent.visible)
                delegate.showAgent(); try await pause()
                let result = app.windows.first { $0.title == "Hello · 任务结果" }!
                precondition(result.isVisible && !(result is NSPanel) && result.styleMask.contains(.resizable))
                checkCompactPlacement(result)
                precondition(main.isVisible && main.contentView === host)
                result.setContentSize(NSSize(width: 900, height: 720)); try await pause()
                precondition(result.contentView!.frame.width == 900)
                result.performClose(nil); try await pause()
                precondition(!result.isVisible && main.isVisible && !agent.visible && model.phase == .ready)
                main.orderOut(nil)
                agent.consume(["type": "status", "text": "后台进度更新"])
                try await pause()
                precondition(!main.isVisible && !result.isVisible)
                delegate.showAgent()
                delegate.closeAgentWindow()
                try await pause()
                precondition(!result.isVisible && !agent.visible, "Closing during animation must stay closed")
                delegate.showAgent()
                delegate.closeAgentWindow()
                delegate.showAgent(); try await pause()
                checkCompactPlacement(result)
                delegate.closeAgentWindow(); try await pause()
                delegate.showAgent(); try await pause()
                agent.showSettings = true; try await pause()
                precondition(result.attachedSheet != nil && main.attachedSheet == nil)
                agent.showSettings = false; try await pause()
                delegate.closeAgentWindow(); try await pause()
                precondition(!result.isVisible && !main.isVisible && model.phase == .ready)
                delegate.showHistory(); try await pause()
                precondition(main.isVisible && !result.isVisible)
                print("PASS: compact right-aligned animated result window; rapid close/reopen stays correct; resize, settings, independent history and close behavior")
                preferences.stopPermissionMonitoring()
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
                app.terminate(nil)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func requireWindow() throws -> NSWindow {
        guard let window = NSApp.windows.first(where: { $0.title == "Hello" && !($0 is NSPanel) }) else {
            throw VoiceError.message("Main window missing")
        }
        return window
    }
    @MainActor static func checkCompactPlacement(_ window: NSWindow) {
        let available = window.screen!.visibleFrame
        precondition(abs(window.contentView!.frame.width - AgentResultView.defaultSize.width) < 1)
        precondition(abs(window.contentView!.frame.height - AgentResultView.defaultSize.height) < 1)
        precondition(abs(window.frame.maxX - (available.maxX - 24)) < 1, "Result must appear on the right")
        precondition(available.contains(window.frame), "Result must remain inside the usable screen")
        precondition(window.alphaValue > 0.99, "Entrance must finish fully visible")
    }
    // Send events only to this test-owned window. Positions follow the shared
    // sidebar's 36-point rows / 2-point gaps and PageHeading's 32-point controls.
    @MainActor static func clickSidebar(_ index: Int, in window: NSWindow) throws {
        try click(NSPoint(x: 100, y: 117 + CGFloat(index) * 38), in: window)
    }
    @MainActor static func clickHeader(_ index: Int, in window: NSWindow) throws {
        let bounds = window.contentView!.bounds
        try click(NSPoint(x: bounds.width - 40 - CGFloat(index) * 40, y: 80), in: window)
    }
    @MainActor static func click(_ point: NSPoint, in window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        let host = window.contentView!
        let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        let location = host.convert(local, to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw VoiceError.message("Cannot create test-owned click")
            }
            window.sendEvent(event)
        }
    }
    static func pause() async throws { try await Task.sleep(for: .milliseconds(350)) }
}
