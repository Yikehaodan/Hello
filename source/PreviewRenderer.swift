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
    library.addWord("Agent"); library.addWord("Knock"); library.addWord("API")
    let previewDefaults = UserDefaults(suiteName: "Knock.Preview." + UUID().uuidString)!
    previewDefaults.set("light", forKey: "appearance")
    let previewPreferences = AppPreferences(defaults: previewDefaults,
        microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .notDetermined) },
        openURL: { _ in false }, accessibilityProvider: { false }, screenCaptureProvider: { false })
    let model = VoiceModel(library: library, sessionRoot: temporary.appendingPathComponent("sessions"), preferences: previewPreferences)
    try renderView(PermissionWelcome(preferences: previewPreferences, enableShortcut: {}, close: {}),
                   size: NSSize(width: 600, height: 690), to: directory.appendingPathComponent("permissions.png"))
    model.shortcutStatus = "预览模式 · 不会启用麦克风或监听快捷键"
    model.raw = library.history.last?.raw ?? ""
    model.result = library.history.last?.text ?? ""
    let identical = HistoryEntry(raw: "请明天下午提醒我开会。", text: "请明天下午提醒我开会。", duration: 3, application: "示例编辑器")
    let missing = HistoryEntry(raw: "", text: "", duration: 0.5, application: "示例编辑器", succeeded: false)
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
    for page in ["home", "history", "dictionary", "settings", "studio"] {
        try renderView(MainView(model: model, enableShortcut: {}, previewPage: page), size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent(page + ".png"))
    }
    app.appearance = NSAppearance(named: .darkAqua)
    try renderView(MainView(model: model, enableShortcut: {}, previewPage: "home").environment(\.colorScheme, .dark), size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent("home-dark.png"))
    app.appearance = NSAppearance(named: .aqua)
    let emptyModel = VoiceModel(library: LibraryStore(root: temporary.appendingPathComponent("empty")), sessionRoot: temporary.appendingPathComponent("empty-sessions"))
    try renderView(MainView(model: emptyModel, enableShortcut: {}, previewPage: "home"), size: NSSize(width: 1080, height: 750), to: directory.appendingPathComponent("home-new.png"))
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
    print("PASS: 15 view previews rendered to \(directory.path)")
}

@MainActor
private func renderView<V: View>(_ view: V, size: NSSize, to url: URL) throws {
    let host = NSHostingView(rootView: view)
    host.appearance = NSApp.appearance
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
