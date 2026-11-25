import AppKit

// Synthetic data only: exercise same-day history, long text and a full dictionary.
@main struct NavigationPerformanceTests {
    struct Fixture: Encodable {
        var version = 1
        var retention = HistoryRetention.forever
        var history: [HistoryEntry]
        var words: [DictionaryWord]
    }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-navigation-performance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let count = Int(ProcessInfo.processInfo.environment["NAV_HISTORY_COUNT"] ?? "300")!
        let entries = (0..<count).map { i in
            HistoryEntry(date: Date().addingTimeInterval(Double(-i)), raw: String(repeating: "这是用于验证切换速度的测试文字。", count: 20), text: "记录 \(i)：" + String(repeating: "测试文字。", count: 60), duration: 12, application: "Fixture")
        }
        let words = (0..<2000).map { DictionaryWord(text: "测试词语\($0)") }
        try JSONEncoder().encode(Fixture(history: entries, words: words)).write(to: root.appendingPathComponent("library.json"))
        let suite = "Hello.NavigationPerformance.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults, microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .authorized) }, openURL: { _ in false }, accessibilityProvider: { true }, screenCaptureProvider: { false })
        preferences.dismissPermissionIntro()
        let model = VoiceModel(library: LibraryStore(root: root), sessionRoot: root.appendingPathComponent("sessions"), preferences: preferences,
            requestMicrophoneAccess: { preconditionFailure("Navigation must not record") })
        let store = AgentConfigurationStore(root: root.appendingPathComponent("agent"), readKey: { "" }, writeKey: { _ in })
        let agent = AgentSession(store: store)
        let app = NSApplication.shared
        let delegate = AppDelegate(model: model, agent: agent, listenForShortcuts: false)
        app.delegate = delegate; app.finishLaunching()
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                let window = app.windows.first { $0.title == "Hello" && !($0 is NSPanel) }!
                for (label, index) in [("history-first", 1), ("dictionary-first", 2), ("home", 0), ("history-repeat", 1), ("dictionary-repeat", 2)] {
                    let started = ProcessInfo.processInfo.systemUptime
                    try clickSidebar(index, in: window)
                    window.contentView!.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    // Wait one main-queue turn so SwiftUI commits pending layout.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    window.contentView!.layoutSubtreeIfNeeded()
                    let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    print(String(format: "NAV %@ %.1f ms (%d history / 2000 words)", label, milliseconds, count))
                    fflush(stdout)
                    if ProcessInfo.processInfo.environment["NAV_ASSERT_FAST"] == "1" {
                        precondition(milliseconds < 500, "Navigation should not block for half a second")
                    }
                    if let output = ProcessInfo.processInfo.environment["NAV_OUTPUT_DIR"], label == "history-first" || label == "dictionary-first" {
                        let directory = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let host = window.contentView!
                        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(label + ".png"))
                        }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                preferences.stopPermissionMonitoring(); defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
                print("PASS: navigation benchmark completed without recording")
                app.terminate(nil)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
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
}
