import AppKit
import SwiftUI

/// Renders our own views into files without capturing or controlling the desktop.
@MainActor
func renderPreviews(to directory: URL) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.appearance = NSAppearance(named: .aqua)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LightVoicePreview-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let library = LibraryStore(root: temporary)
    let shellAgent = AgentSession(store: AgentConfigurationStore(root: temporary.appendingPathComponent("shell-agent"), readKey: { "" }, writeKey: { _ in }))
    library.addHistory(raw: "我们周三开会，不对，改成周四下午三点。记得带预算表，不要带旧版。", text: "我们周四下午三点开会，记得带预算表，不要带旧版。", duration: 12.4, application: "示例编辑器")
    library.addHistory(raw: "请把会议时间改为周四下午三点。", text: "Please reschedule the meeting to Thursday at 3 PM.", duration: 8.2, application: "示例编辑器", mode: "translate")
    let fixture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 600, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: fixture)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 600).fill()
    for (index, line) in ["当时的页面截图", "测试编辑器", "输入框：正在整理预算", "金额 3200 元", "口述：金额改为 4500 元"].enumerated() {
        (line as NSString).draw(at: NSPoint(x: 45, y: 500 - index * 85), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    let fixtureData = fixture.representation(using: .jpeg, properties: [.compressionFactor: 0.75])!
    let contextID = library.addHistory(raw: "金额改为四千五百元。", text: "金额改为 4500 元。", duration: 3,
        application: "示例编辑器", mode: "context", contextCaptureStatus: "已读取输入框（7 字） · 已获取窗口截图",
        contextInputText: "正在整理预算", contextWindowTitle: "预算草稿",
        contextScreenshotDataURL: "data:image/jpeg;base64," + fixtureData.base64EncodedString())!
    library.addWord("Agent"); library.addWord("Hello"); library.addWord("API")
    let previewDefaults = UserDefaults(suiteName: "Hello.Preview." + UUID().uuidString)!
    previewDefaults.set("light", forKey: "appearance")
    var previewMicrophone = MicrophonePermission.notDetermined
    var previewAccessibility = false, previewScreen = false
    let previewPreferences = AppPreferences(defaults: previewDefaults,
        microphoneProvider: { MicrophoneSnapshot(devices: [], permission: previewMicrophone) },
        openURL: { _ in false }, accessibilityProvider: { previewAccessibility }, screenCaptureProvider: { previewScreen })
    let model = VoiceModel(library: library, sessionRoot: temporary.appendingPathComponent("sessions"), preferences: previewPreferences)
    try renderView(PermissionWelcome(preferences: previewPreferences, enableShortcut: {}, close: {}),
                   size: NSSize(width: 600, height: 690), to: directory.appendingPathComponent("permissions.png"))
    previewMicrophone = .denied
    previewPreferences.contextScreenshots = true
    previewPreferences.refresh()
    try renderView(PermissionWelcome(preferences: previewPreferences, enableShortcut: {}, close: {}),
                   size: NSSize(width: 600, height: 690), to: directory.appendingPathComponent("permissions-denied.png"))
    try renderView(MainView(model: model, agent: shellAgent, enableShortcut: {}, previewPage: "home"),
                   size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent("permissions-banner.png"))
    previewMicrophone = .restricted
    previewPreferences.refresh()
    try renderView(PermissionWelcome(preferences: previewPreferences, enableShortcut: {}, close: {}),
                   size: NSSize(width: 600, height: 690), to: directory.appendingPathComponent("permissions-restricted.png"))
    previewMicrophone = .authorized; previewAccessibility = true; previewScreen = true
    previewPreferences.refresh()
    try renderView(PermissionWelcome(preferences: previewPreferences, enableShortcut: {}, close: {}),
                   size: NSSize(width: 600, height: 690), to: directory.appendingPathComponent("permissions-ready.png"))
    previewMicrophone = .notDetermined; previewAccessibility = false; previewScreen = false
    previewPreferences.contextScreenshots = false
    previewPreferences.refresh()
    model.shortcutStatus = "预览模式 · 不会启用麦克风或监听快捷键"
    model.raw = library.history.last?.raw ?? ""
    model.result = library.history.last?.text ?? ""
    let identical = HistoryEntry(raw: "请明天下午提醒我开会。", text: "请明天下午提醒我开会。", duration: 3, application: "示例编辑器")
    let missing = HistoryEntry(raw: "", text: "", duration: 0.5, application: "示例编辑器", succeeded: false)
    let timed = HistoryEntry(raw: "请把会议改到周四。", text: "请把会议改到周四。", duration: 8, application: "示例编辑器",
                             timings: HistoryTimings(total: 2.63, asr: 0.52, llm: 2.03))
    let asrOnly = HistoryEntry(raw: "今天下午三点开会。", text: "今天下午三点开会。", duration: 5, application: "示例编辑器",
                               timings: HistoryTimings(total: 0.48, asr: 0.46))
    try renderView(VStack(spacing: 12) {
        HistoryRow(model: model, entry: timed, hasAudio: true, canRetry: true, delete: {})
        HistoryRow(model: model, entry: asrOnly, hasAudio: true, canRetry: true, delete: {})
        HistoryRow(model: model, entry: identical, hasAudio: false, canRetry: true, delete: {})
    }.padding(20).frame(width: 850).background(Color.white), size: NSSize(width: 850, height: 530),
                   to: directory.appendingPathComponent("history-timings.png"))
    try renderView(VStack(spacing: 20) {
        HistoryRow(model: model, entry: identical, hasAudio: true, canRetry: true, delete: {}, expanded: true)
        HistoryRow(model: model, entry: missing, hasAudio: true, canRetry: true, delete: {}, expanded: true)
    }.padding(20).frame(width: 850).background(Color.white), size: NSSize(width: 850, height: 530), to: directory.appendingPathComponent("history-original-details.png"))
    let screenshotURL = library.screenshotURL(for: contextID)!
    try renderView(HistoryRow(model: model, entry: library.history.first(where: { $0.id == contextID })!, hasAudio: false,
        canRetry: true, delete: {}, expanded: true).padding(20).frame(width: 850).background(Color.white),
        size: NSSize(width: 850, height: 380), to: directory.appendingPathComponent("history-context-thumbnail.png"))
    try renderView(HistoryScreenshotPreview(url: screenshotURL, title: "预算草稿", close: {}), size: NSSize(width: 960, height: 660),
                   to: directory.appendingPathComponent("history-context-enlarged.png"))
    previewMicrophone = .authorized; previewAccessibility = true; previewPreferences.refresh()
    var tokenFixture = TokenUsageSnapshot(today: TokenCount(input: 12480, output: 3200),
        month: TokenCount(input: 148200, output: 42160), all: TokenCount(input: 1200000, output: 340000))
    tokenFixture.breakdowns = [TokenBreakdown(dictation: 10200, agent: 5480, points: (0..<12).map {
        TokenTrendPoint(date: Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double($0) * 3600),
            dictation: [0,0,200,400,200,1200,1800,900,2300,700,1600,900][$0], agent: [0,0,0,100,300,400,1100,800,600,1200,500,480][$0])
    })]
    try renderView(TokenUsageCard(snapshot: tokenFixture).padding(20).frame(width: 500, height: 370).background(LVTheme.background),
        size: NSSize(width: 500, height: 370), to: directory.appendingPathComponent("token-usage.png"))
    try renderView(TokenUsageCard(snapshot: nil, error: "fixture").padding(20).frame(width: 500, height: 370).background(LVTheme.background),
        size: NSSize(width: 500, height: 370), to: directory.appendingPathComponent("token-unavailable.png"))
    for page in ["home", "history", "dictionary", "memory", "settings", "studio"] {
        try renderView(MainView(model: model, agent: shellAgent, enableShortcut: {}, previewPage: page), size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent(page + ".png"))
    }
    try renderView(MainView(model: model, agent: shellAgent, enableShortcut: {}, previewPage: "home"),
        size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent("home-scrolled.png"), scrollY: 350)
    for category in ["权限", "服务配置", "本机数据", "设置", "语音模型", "个性化", "关于", "帮助"] {
        try renderView(SettingsPage(model: model, library: library, enableShortcut: {}, close: {}, previewCategory: category),
            size: NSSize(width: 920, height: 620), to: directory.appendingPathComponent("settings-" + category + ".png"))
    }
    try renderView(DictionaryPage(library: library, memory: model.memory).wordEditor,
        size: NSSize(width: 430, height: 280), to: directory.appendingPathComponent("dictionary-editor.png"))
    let previewMemory = MemoryStore(root: temporary.appendingPathComponent("memory-preview"))
    previewMemory.setEnabled(true)
    previewMemory.save(original: "小雪", preferred: "晓雪", kind: .correction, scope: .person)
    previewMemory.save(original: "好的", preferred: "OK", kind: .expression, scope: .dictation)
    previewMemory.record(before: "我们在飞数上沟通。", after: "我们在飞书上沟通。", session: UUID())
    try renderView(MemoryPage(store: previewMemory).padding(24).frame(width: 850, height: 650).background(Color.white),
        size: NSSize(width: 850, height: 650), to: directory.appendingPathComponent("memory-populated.png"))
    try renderView(MemoryPage(store: previewMemory, previewCandidates: true).padding(24).background(LVTheme.background),
        size: NSSize(width: 850, height: 780), to: directory.appendingPathComponent("memory-candidates.png"))
    try renderView(MemoryPage(store: previewMemory).editor, size: NSSize(width: 470, height: 390),
        to: directory.appendingPathComponent("memory-editor.png"))
    for page in ["home", "history", "dictionary", "memory", "studio"] {
        try renderView(MainView(model: model, agent: shellAgent, enableShortcut: {}, previewPage: page),
            size: NSSize(width: 1000, height: 700), to: directory.appendingPathComponent(page + "-compact.png"))
    }
    try renderView(MainView(model: model, agent: shellAgent, enableShortcut: {}, previewPage: "history"),
        size: NSSize(width: 1440, height: 900), to: directory.appendingPathComponent("history-wide.png"))
    app.appearance = NSAppearance(named: .darkAqua)
    for page in ["home", "history", "dictionary", "memory", "settings"] {
        try renderView(MainView(model: model, agent: shellAgent, enableShortcut: {}, previewPage: page, previewScheme: .dark),
            size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent(page + "-dark.png"))
    }
    try renderView(MainView(model: model, agent: shellAgent, enableShortcut: {}, previewPage: "home", previewScheme: .dark),
        size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent("home-scrolled-dark.png"), scrollY: 350)
    app.appearance = NSAppearance(named: .aqua)
    let emptyModel = VoiceModel(library: LibraryStore(root: temporary.appendingPathComponent("empty")), sessionRoot: temporary.appendingPathComponent("empty-sessions"))
    try renderView(MainView(model: emptyModel, agent: shellAgent, enableShortcut: {}, previewPage: "home"), size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent("home-new.png"))
    for page in ["history", "dictionary", "memory"] {
        try renderView(MainView(model: emptyModel, agent: shellAgent, enableShortcut: {}, previewPage: page),
            size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent(page + "-empty.png"))
    }
    try renderView(StatusHUD(message: "连接暂时中断，可以重试刚才的文字处理。", retry: {}, dismiss: {}),
        size: NSSize(width: 380, height: 94), to: directory.appendingPathComponent("status-retry.png"))
    try renderView(AgentResultView(agent: shellAgent), size: AgentResultView.defaultSize,
        to: directory.appendingPathComponent("agent-empty.png"))
    model.phase = .recording; model.level = 0.55; model.seconds = 14
    try renderView(RecordingHUD(model: model), size: NSSize(width: 220, height: 70), to: directory.appendingPathComponent("voice-bar.png"))
    model.mode = .translate
    try renderView(RecordingHUD(model: model), size: NSSize(width: 220, height: 70), to: directory.appendingPathComponent("voice-bar-translate.png"))
    model.mode = .context
    try renderView(RecordingHUD(model: model), size: NSSize(width: 220, height: 70), to: directory.appendingPathComponent("voice-bar-context.png"))
    model.mode = .ask
    try renderView(RecordingHUD(model: model), size: NSSize(width: 220, height: 70), to: directory.appendingPathComponent("voice-bar-ask.png"))
    model.phase = .transcribing
    try renderView(RecordingHUD(model: model), size: NSSize(width: 220, height: 70), to: directory.appendingPathComponent("voice-bar-thinking-transcribe.png"))
    model.phase = .polishing
    try renderView(RecordingHUD(model: model), size: NSSize(width: 220, height: 70), to: directory.appendingPathComponent("voice-bar-thinking-polish.png"))
    model.phase = .ready
    model.raw = "1 加 1 等于几？"
    model.result = "1 加 1 等于 2。"
    try renderView(AnswerView(model: model), size: NSSize(width: 800, height: 488), to: directory.appendingPathComponent("answer.png"))
    let agentStore = AgentConfigurationStore(root: temporary.appendingPathComponent("agent"), readKey: { "" }, writeKey: { _ in })
    let task = AgentTaskRecord(title: "查找语音模型资料并整理说明", fingerprint: "preview", messages: [
        AgentMessage(role: "user", text: "帮我查找语音识别模型的资料，整理一份说明。"),
        AgentMessage(role: "assistant", text: "## 语音模型选择\n优先根据**识别质量**和等待时间选择，再比较资源占用。\n\n- 日常听写：关注短句响应和专名识别。\n- 长段录音：关注上下文连贯和中英混合。\n\n### 快速比较\n| 场景 | 重点 |\n| --- | --- |\n| 日常听写 | 响应速度 |\n| 会议整理 | 长句准确度 |\n\n> 建议使用同一段录音对比，避免仅凭一次结果判断。", sources: [
            AnswerSource(title: "语音识别研究与模型说明", url: "https://example.com/research/speech", content: "模型能力、数据和评估方法。"),
            AnswerSource(title: "relative", url: "https://docs.example.org/speech", content: "使用与配置说明。")])
    ], state: "任务完成")
    try AgentConfigurationStore.writePrivate(JSONEncoder().encode([task]), to: agentStore.root.appendingPathComponent("tasks.json"))
    previewMicrophone = .authorized; previewAccessibility = true; previewPreferences.refresh()
    let agent = AgentSession(store: agentStore); agent.select(task.id)
    try renderView(MainView(model: model, agent: agent, enableShortcut: {}, previewPage: "history"),
                   size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent("agent-page.png"))
    try renderView(AgentResultView(agent: agent), size: AgentResultView.defaultSize, to: directory.appendingPathComponent("agent-result.png"))
    try renderView(AgentResultView(agent: agent), size: AgentResultView.minimumSize,
        to: directory.appendingPathComponent("agent-result-compact.png"))
    app.appearance = NSAppearance(named: .darkAqua)
    try renderView(AgentResultView(agent: agent).environment(\.colorScheme, .dark), size: AgentResultView.defaultSize,
        to: directory.appendingPathComponent("agent-result-dark.png"))
    app.appearance = NSAppearance(named: .aqua)
    try renderView(AgentPermissionView(permission: AgentPermission(id: "preview", tool: "Write", input: ["file_path": "/示例目录/模型说明.md", "content": "语音模型选择说明……"])) { _, _ in },
                   size: NSSize(width: 640, height: 360), to: directory.appendingPathComponent("agent-permission.png"))
    try renderView(MarkdownView(text: task.messages[1].text).padding(24).background(LVTheme.background), size: NSSize(width: 800, height: 760), to: directory.appendingPathComponent("agent-markdown.png"))
    try renderView(AgentSourceCards(sources: agent.sources).padding(24).background(LVTheme.background), size: NSSize(width: 800, height: 260), to: directory.appendingPathComponent("agent-sources.png"))
    try renderView(AgentProgressHUD(agent: agent), size: AgentProgressHUD.size, to: directory.appendingPathComponent("agent-progress.png"))
    agent.stop()
    try renderView(AgentSettingsView(agent: agent), size: NSSize(width: 550, height: 620), to: directory.appendingPathComponent("agent-settings.png"))
    print("PASS: view previews rendered to \(directory.path)")
}

@MainActor
private func renderView<V: View>(_ view: V, size: NSSize, to url: URL, scrollY: CGFloat? = nil) throws {
    let host = NSHostingView(rootView: view)
    host.appearance = NSApp.appearance
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    host.layoutSubtreeIfNeeded()
    if let scrollY {
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        guard let scroll = findScrollView(in: host), let document = scroll.documentView else {
            throw VoiceError.message("预览滚动容器未找到。")
        }
        let offset = min(scrollY, max(0, document.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : document.bounds.height - scroll.contentView.bounds.height - offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw VoiceError.message("预览图像初始化失败。")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw VoiceError.message("预览图像编码失败。")
    }
    try data.write(to: url)
    window.close()
}
