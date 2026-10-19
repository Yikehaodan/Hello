import AppKit
import SwiftUI
import Combine

final class VoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AnswerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: VoiceModel
    let agent = AgentSession()
    let shortcut = FnShortcut()
    private let listenForShortcuts: Bool
    private var window: NSWindow!
    private var hud: NSPanel!
    private var recordingHUD: NSView!
    private var answer: NSPanel!
    private var agentPanel: NSPanel!
    private var item: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private enum HUDContent { case hidden, recording, status }
    private var hudContent = HUDContent.hidden
    private var pendingHUDStatus: String?
    private var hudRevision: UInt = 0
    private var isTerminating = false
    init(model: VoiceModel? = nil, listenForShortcuts: Bool = true) {
        self.model = model ?? VoiceModel()
        self.listenForShortcuts = listenForShortcuts
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(model.preferences.showDockIcon ? .regular : .accessory)
        model.preferences.onDockVisibilityChange = { visible in
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "打开Hello", action: #selector(show), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出Hello", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Hello"; window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1000, height: 700)
        window.contentView = NSHostingView(rootView: MainView(model: model, enableShortcut: { [weak self] in
            guard let self else { return }
            self.model.preferences.requestAccessibility()
            if self.listenForShortcuts { self.shortcut.refresh() }
        }))
        window.center(); show()
        hud = VoicePanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 70), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = true
        hud.hidesOnDeactivate = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; hud.ignoresMouseEvents = false
        recordingHUD = NSHostingView(rootView: RecordingHUD(model: model))
        hud.contentView = recordingHUD
        answer = AnswerPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 488), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        answer.title = "Hello · 回答"; answer.isReleasedWhenClosed = false
        answer.isOpaque = false; answer.backgroundColor = .clear; answer.hasShadow = false
        answer.level = .floating; answer.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        answer.contentView = NSHostingView(rootView: AnswerView(model: model))
        agentPanel = AnswerPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        agentPanel.title = "Hello Agent"; agentPanel.isReleasedWhenClosed = false
        agentPanel.isOpaque = false; agentPanel.backgroundColor = .clear; agentPanel.hasShadow = true
        agentPanel.level = .floating; agentPanel.hidesOnDeactivate = false
        agentPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        agentPanel.contentView = NSHostingView(rootView: AgentBubbleView(agent: agent))
        model.onAgentRequest = { [weak self] text, selection in self?.agent.receiveVoice(text, selection: selection) }
        agent.onVoice = { [weak self] in
            guard let self, !self.model.busy else { return }
            self.agent.visible = false; self.model.toggle(mode: .ask)
        }
        agent.$visible.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible {
                let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
                let frame = screen?.visibleFrame ?? .zero
                self.agentPanel.setFrameOrigin(NSPoint(x: frame.midX - 320, y: frame.minY + 20))
                self.agentPanel.orderFrontRegardless()
            } else { self.agentPanel.orderOut(nil) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .helloShowAgent).sink { [weak self] _ in self?.agent.visible = true }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .helloShowAgentSettings).sink { [weak self] _ in
            self?.agent.visible = true; self?.agent.showSettings = true
        }.store(in: &subscriptions)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hello")
        let menu = NSMenu()
        menu.addItem(withTitle: "打开Hello", action: #selector(show), keyEquivalent: "")
        let permissionItem = menu.addItem(withTitle: "权限设置…", action: #selector(showPermissions), keyEquivalent: "")
        model.preferences.$microphones.combineLatest(model.preferences.$accessibilityAllowed,
            model.preferences.$screenCaptureAllowed, model.preferences.$contextScreenshots)
            .sink { microphone, accessibility, screen, screenshots in
                let count = (microphone.permission == .authorized ? 0 : 1) + (accessibility ? 0 : 1)
                    + (screenshots && !screen ? 1 : 0)
                permissionItem.title = count == 0 ? "权限设置 · 已就绪" : "权限设置 · \(count) 项待设置"
            }.store(in: &subscriptions)
        menu.addItem(withTitle: "开始 / 结束录音  Fn", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "语音翻译  Fn ⇧", action: #selector(translate), keyEquivalent: "")
        menu.addItem(withTitle: "上下文听写  Fn ⌃", action: #selector(contextDictate), keyEquivalent: "")
        menu.addItem(withTitle: "语音任务  Fn Space", action: #selector(ask), keyEquivalent: "")
        menu.addItem(withTitle: "打开 Agent / 任务记录", action: #selector(showAgent), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }; item.menu = menu
        shortcut.onToggle = { [weak self] in self?.model.toggle(mode: .dictate) }
        shortcut.onMode = { [weak self] mode in
            if mode == .ask { self?.agent.visible = false }
            self?.model.toggle(mode: mode)
        }
        shortcut.isRecording = { [weak self] in self?.model.phase == .recording }
        shortcut.onCancel = { [weak self] in
            guard let self else { return false }
            if self.model.busy { self.model.cancel(); return true }
            if self.agent.visible { self.agent.visible = false; return true }
            if self.model.showAnswer { self.model.showAnswer = false; return true }
            return false
        }
        shortcut.onStatus = { [weak self] text in self?.model.shortcutStatus = text }
        shortcut.onLongPress = { [weak self] in
            guard let self, self.model.phase == .ready else { return }
            self.model.status = "轻按 Fn 即可开始，再按一次结束，不用一直按住。"
        }
        shortcut.onPasteLast = { [weak self] in self?.model.pasteLastResult() ?? false }
        if listenForShortcuts { shortcut.start() }
        model.preferences.startPermissionMonitoring()
        model.$phase.combineLatest(model.$seconds)
            .map { phase, seconds in
                phase == .recording ? String(format: " ● %d:%02d", Int(seconds) / 60, Int(seconds) % 60) : ""
            }.removeDuplicates().sink { [weak self] title in
                self?.item.button?.title = title
            }.store(in: &subscriptions)
        model.$phase.removeDuplicates().dropFirst().sink { [weak self] phase in
            guard let self, !self.isTerminating else { return }
            if phase != .ready { self.pendingHUDStatus = nil }
            if phase == .ready && [.denied, .restricted].contains(self.model.preferences.microphones.permission) {
                self.show()
            }
            self.scheduleHUDRefresh()
        }.store(in: &subscriptions)
        model.$status.dropFirst().sink { [weak self] status in
            guard let self, !self.isTerminating, self.model.phase == .ready else { return }
            self.pendingHUDStatus = status
            self.scheduleHUDRefresh()
        }.store(in: &subscriptions)
        model.$showAnswer.sink { [weak self] visible in
            guard let self else { return }
            if visible {
                let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
                let frame = screen?.visibleFrame ?? .zero
                self.answer.setFrameOrigin(NSPoint(x: frame.midX - self.answer.frame.width / 2, y: frame.minY + 20))
                self.answer.orderFrontRegardless()
            } else { self.answer.orderOut(nil) }
        }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--ui-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print(self.window.isVisible ? "PASS: window displayed" : "FAIL: no window")
                self.quit()
            }
        }
    }
    private func scheduleHUDRefresh() {
        hudRevision &+= 1
        let revision = hudRevision
        // Published values arrive before their properties change. Coalesce the phase/status pair.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminating, self.hudRevision == revision else { return }
            self.refreshHUD(revision: revision)
        }
    }
    private func refreshHUD(revision: UInt) {
        if model.busy {
            pendingHUDStatus = nil
            if hudContent != .recording {
                if hud.contentView !== recordingHUD { hud.contentView = recordingHUD }
                hudContent = .recording
                showHUD(size: NSSize(width: 220, height: 70))
            }
            return
        }
        // Completion, copy and cancellation remain visible in the main window only.
        // The floating message card is reserved for a failed request that can be retried.
        guard model.canRetryProcessing else {
            pendingHUDStatus = nil
            hud.orderOut(nil); hudContent = .hidden
            return
        }
        guard let message = pendingHUDStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return }
        pendingHUDStatus = nil
        hud.contentView = NSHostingView(rootView: StatusHUD(message: message,
            retry: { [weak self] in self?.model.retryProcessing() },
            dismiss: { [weak self] in self?.dismissHUDStatus() }))
        hudContent = .status
        showHUD(size: NSSize(width: 360, height: 120))
    }
    private func showHUD(size: NSSize) {
        let screen = (hud.isVisible ? hud.screen : nil)
            ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        hud.setContentSize(size)
        if let frame = screen?.visibleFrame {
            hud.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 8))
        }
        hud.orderFrontRegardless()
    }
    private func dismissHUDStatus() {
        guard !model.busy else { return }
        hudRevision &+= 1
        pendingHUDStatus = nil
        hud.orderOut(nil); hudContent = .hidden
    }
    private func stopHUD() {
        isTerminating = true
        hudRevision &+= 1
        pendingHUDStatus = nil
        hud?.orderOut(nil); hudContent = .hidden
    }
    @objc func show() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showPermissions() {
        show()
        NotificationCenter.default.post(name: .helloShowPermissions, object: nil)
    }
    @objc func toggle() { model.toggle(mode: .dictate) }
    @objc func translate() { model.toggle(mode: .translate) }
    @objc func contextDictate() { model.toggle(mode: .context) }
    @objc func ask() { model.toggle(mode: .ask) }
    @objc func showAgent() { agent.visible = true }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.prepareForTermination() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "录音尚未保存到历史"
        alert.informativeText = "退出后，这段录音无法从历史记录中找回。可以返回应用，处理保存错误后重试。"
        alert.addButton(withTitle: "返回应用")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.preferences.refresh() }
    func applicationWillTerminate(_ notification: Notification) {
        model.preferences.stopPermissionMonitoring()
        agent.stop(); stopHUD(); model.cancel(); shortcut.stop()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        do { try renderPreviews(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
} else if let index = CommandLine.arguments.firstIndex(of: "--gateway-test"), CommandLine.arguments.count > index + 2 {
    let mode = CommandLine.arguments[index + 1], input = CommandLine.arguments[index + 2]
    Task {
        do {
            let gateway = try Gateway()
            switch mode {
            case "translate": print("RESULT: \(try await gateway.translate(input, to: "English"))")
            case "ask":
                let selected = CommandLine.arguments.count > index + 3 ? CommandLine.arguments[index + 3] : ""
                let result = try await gateway.ask(input, selectedText: selected)
                print("REPLACES_SELECTION: \(result.replacesSelection)\nRESULT: \(result.text)")
            default: print("RESULT: \(try await gateway.polish(input))")
            }
            exit(0)
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--context-capture-test") {
    Task { @MainActor in
        guard let destination = TextDestination.capture(includeSelection: true) else { print("FAIL: no external application focused"); exit(1) }
        let context = await destination.captureContext(includeScreenshot: true)
        let report: [String: Any] = ["application": context.application, "inputText": context.inputText,
            "windowTitle": context.windowTitle, "captureStatus": context.captureStatus, "screenshot": context.imageDataURL != nil]
        do { print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)); exit(0) }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else if let index = CommandLine.arguments.firstIndex(of: "--paste-test"), CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        let text = CommandLine.arguments[index + 1]
        guard let destination = TextDestination.capture() else { print("FAIL: no external application focused"); exit(1) }
        print(destination.insert(text))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
} else if let index = CommandLine.arguments.firstIndex(of: "--transcribe-test"), CommandLine.arguments.count > index + 1 {
    let path = CommandLine.arguments[index + 1]
    Task {
        do {
            let started = Date()
            let raw = try await LocalASR().transcribe(URL(fileURLWithPath: path))
            print("RAW: \(raw)")
            print(String(format: "ASR_SECONDS: %.2f", Date().timeIntervalSince(started)))
            if CommandLine.arguments.contains("--polish"), !raw.isEmpty { print("RESULT: \(try await Gateway().polish(raw))") }
            exit(0)
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--shortcut-test") {
    var gesture = FnGesture()
    let first = gesture.consume(type: .flagsChanged, key: 63, flags: .maskSecondaryFn)
    let repeated = gesture.consume(type: .flagsChanged, key: 63, flags: .maskSecondaryFn)
    let release = gesture.consume(type: .flagsChanged, key: 63, flags: [])
    precondition(!first.trigger && !repeated.trigger && release.trigger)
    _ = gesture.consume(type: .flagsChanged, key: 63, flags: .maskSecondaryFn)
    _ = gesture.consume(type: .keyDown, key: 123, flags: .maskSecondaryFn)
    precondition(!gesture.consume(type: .flagsChanged, key: 63, flags: []).trigger)
    precondition(!gesture.consume(type: .keyDown, key: 123, flags: .maskSecondaryFn).trigger)
    print("PASS: Fn press/release, repeat suppression, modifier combination")
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.finishLaunching()
        withExtendedLifetime(delegate) { application.run() }
    }
}
