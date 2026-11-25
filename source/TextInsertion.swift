import AppKit
import ApplicationServices

// AX references are immutable handles. Capture them on a dedicated queue and
// transfer the completed snapshot to the main actor; never query both at once.
private struct DestinationSnapshot: @unchecked Sendable {
    let window: AXUIElement?
    let selectedText: String
    let selectionElement: AXUIElement?
    let selectionRange: CFRange?
}
private let destinationCaptureQueue = DispatchQueue(label: "Hello.destination-capture", qos: .userInitiated)
private let memoryCaptureQueue = DispatchQueue(label: "Hello.memory-capture", qos: .utility)
private struct MemoryInputSource: @unchecked Sendable {
    let app: AXUIElement
    let field: AXUIElement
    let pid: pid_t
}

/// Notifications are optional: unsupported controls retain the polling fallback.
private final class MemoryAXObservation: @unchecked Sendable {
    private var observer: AXObserver?
    private var changed: (@MainActor () -> Void)?
    init?(source: MemoryInputSource, changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        var observer: AXObserver?
        guard AXObserverCreate(source.pid, { _, _, _, context in
            guard let context else { return }
            let observation = Unmanaged<MemoryAXObservation>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observation.changed?() }
        }, &observer) == .success, let observer else { return nil }
        self.observer = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for (element, notification) in [(source.field, kAXValueChangedNotification),
                (source.field, kAXSelectedTextChangedNotification),
                (source.field, kAXUIElementDestroyedNotification),
                (source.app, kAXFocusedUIElementChangedNotification)] {
            if AXObserverAddNotification(observer, element, notification as CFString, context) == .success { registered = true }
        }
        guard registered else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; changed = nil
    }
    deinit { stop() }
}
private struct ContextCaptureSource: @unchecked Sendable {
    let pid: pid_t
    let name: String
    let window: AXUIElement?
}

/// Only restore a known, still-running user application when Hello owns focus.
/// No background snapshots: the restored app must actually become frontmost.
@MainActor
final class RecordingContextTarget {
    static let shared = RecordingContextTarget()
    private var lastExternal: NSRunningApplication?
    private var observer: NSObjectProtocol?
    func start() {
        guard observer == nil else { return }
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }
    private func remember(_ app: NSRunningApplication?) {
        guard let app, !Self.isHello(app.processIdentifier), app.activationPolicy == .regular, !app.isTerminated else { return }
        lastExternal = app
    }
    private static func isHello(_ pid: pid_t) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        guard let own = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == own
    }
    func prepare() async -> pid_t? {
        start()
        guard let current = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        guard Self.isHello(current) else { return current }
        let target = lastExternal
        let restored = await Self.restore(lastPID: target?.processIdentifier,
            frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            isHello: Self.isHello,
            available: { target?.isTerminated == false },
            activate: { target?.activate(options: [.activateIgnoringOtherApps]) ?? false })
        return restored ? target?.processIdentifier : nil
    }
    // Injected focus operations keep race/cancellation tests away from real applications.
    static func restore(lastPID: pid_t?, frontmost: () -> pid_t?, isHello: (pid_t) -> Bool,
                        available: () -> Bool, activate: () -> Bool,
                        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(10)) }) async -> Bool {
        guard !Task.isCancelled, let current = frontmost(), isHello(current), let lastPID,
              !isHello(lastPID), available(), activate() else { return false }
        for _ in 0..<30 {
            guard !Task.isCancelled, available(), let foreground = frontmost() else { return false }
            if foreground == lastPID { return true }
            // A third app winning focus is a user focus change, not permission to retarget.
            guard isHello(foreground) else { return false }
            do { try await pause() } catch { return false }
        }
        return false
    }
}

/// 保存触发录音的应用和窗口。输入时使用该窗口当前的光标，不激活或抢走焦点。
@MainActor
struct TextDestination {
    let pid: pid_t
    let name: String
    private let window: AXUIElement?
    let selectedText: String
    private let selectionElement: AXUIElement?
    private let selectionRange: CFRange?

    /// AX, window capture and encoding run away from the UI actor. Pin the target
    /// and discard the snapshot if focus changes; retries reuse the saved context.
    func captureContext(includeScreenshot: Bool) async -> VoiceContext {
        let source = ContextCaptureSource(pid: pid, name: name, window: window)
        let job = Task.detached(priority: .userInitiated) {
            await Self.captureContext(source, includeScreenshot: includeScreenshot)
        }
        return await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
    }

    nonisolated private static func captureContext(_ source: ContextCaptureSource, includeScreenshot: Bool) async -> VoiceContext {
        let pid = source.pid, name = source.name, window = source.window
        var result = VoiceContext(application: name)
        guard !Task.isCancelled, await isFrontmost(pid) else { return result }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        func sameWindow() -> Bool {
            guard let window else { return true }
            guard let current = Self.axElement(app, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(window, current)
        }
        guard sameWindow() else { result.captureStatus = "已切换窗口 · 未读取上下文"; return result }
        // Chromium/Electron create their editable AX nodes lazily. Request that tree
        // before asking for focus; this changes no macOS permission or page content.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var focused = Self.focusedInput(app: app, pid: pid)
        // Browsers can publish the focused editable element shortly after their AX tree activates.
        // Retry only this application's focus; never fall back to arbitrary page text.
        if focused == nil {
            for delay in [40, 80, 120, 160, 200] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return result }
                guard !Task.isCancelled, await isFrontmost(pid), sameWindow() else {
                    result.captureStatus = "已切换应用 · 未读取原输入框或截图"
                    return result
                }
                focused = Self.focusedInput(app: app, pid: pid)
                if focused != nil { break }
            }
        }

        guard !Task.isCancelled, await isFrontmost(pid), sameWindow() else {
            return VoiceContext(application: name, captureStatus: "已切换窗口或取消 · 未读取上下文")
        }
        if let focused, Self.isSecure(focused) {
            result.captureStatus = "密码输入框 · 未读取文字或截图"
            return result
        }
        let input = focused.flatMap { Self.inputValue($0) }
        result.inputText = input ?? ""
        result.windowTitle = window.map { String(Self.string($0, kAXTitleAttribute).prefix(300)) } ?? ""
        guard !Task.isCancelled, await isFrontmost(pid), sameWindow() else {
            return VoiceContext(application: name, captureStatus: "已切换窗口或取消 · 未保留上下文")
        }
        let textStatus = input.map { $0.isEmpty ? "已读取输入框 · 内容为空" : "已读取输入框（\($0.count) 字）" }
            ?? (focused == nil ? "未获取到聚焦输入框" : "当前控件未提供可读取的输入文字")
        guard includeScreenshot else { result.captureStatus = textStatus + " · 截图已关闭"; return result }
        guard CGPreflightScreenCaptureAccess() else {
            result.captureStatus = textStatus + " · 请在设置中允许页面截图"
            return result
        }
        let candidates = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        // If AX knows the focused window, require its bounds to match; never silently choose another window.
        let bounds = window.flatMap { Self.bounds($0) }
        let candidate = candidates.first { item in
            guard let bounds else { return true }
            guard let dictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return abs(rect.minX - bounds.minX) < 3 && abs(rect.minY - bounds.minY) < 3 &&
                   abs(rect.width - bounds.width) < 3 && abs(rect.height - bounds.height) < 3
        }
        guard let candidate, let number = candidate[kCGWindowNumber as String] as? UInt32,
              !Task.isCancelled, await isFrontmost(pid), sameWindow(),
              let snapshot = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]) else {
            result.captureStatus = textStatus + " · 未获得当前窗口截图"
            return result
        }
        result.imageDataURL = {
            let scale = min(1.0, 1600.0 / Double(max(snapshot.width, snapshot.height)))
            let width = max(1, Int(Double(snapshot.width) * scale)), height = max(1, Int(Double(snapshot.height) * scale))
            guard let buffer = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil as String? }
            buffer.interpolationQuality = .high
            buffer.draw(snapshot, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = buffer.makeImage(), let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return nil }
            return "data:image/jpeg;base64," + data.base64EncodedString()
        }()
        guard !Task.isCancelled, await isFrontmost(pid), sameWindow() else {
            return VoiceContext(application: name, captureStatus: "已切换窗口或取消 · 未保留上下文")
        }
        result.captureStatus = textStatus + (result.imageDataURL == nil ? " · 截图编码失败" : " · 已获取窗口截图")
        return result
    }

    nonisolated private static func isFrontmost(_ pid: pid_t) async -> Bool {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    nonisolated private static func focusedInput(app: AXUIElement, pid: pid_t) -> AXUIElement? {
        var focused = axElement(app, kAXFocusedUIElementAttribute)
        if focused == nil, let window = axElement(app, kAXFocusedWindowAttribute) {
            focused = axElement(window, kAXFocusedUIElementAttribute)
        }
        if focused == nil,
           let systemFocus = axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
            var owner: pid_t = 0
            if AXUIElementGetPid(systemFocus, &owner) == .success, owner == pid { focused = systemFocus }
        }
        guard let focused else { return nil }
        // Resolve an editor's focused child to its own editable ancestor, never to
        // an unrelated text field or the surrounding page/document.
        if isSecure(focused) || isEditable(focused) { return focused }
        for attribute in ["AXHighestEditableAncestor", "AXEditableAncestor"] {
            if let editor = axElement(focused, attribute), isEditable(editor) { return editor }
        }
        return focused
    }

    nonisolated private static func isEditable(_ element: AXUIElement) -> Bool {
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(string(element, kAXRoleAttribute)) { return true }
        var editable: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success && editable as? Bool == true
    }

    nonisolated private static func inputValue(_ element: AXUIElement) -> String? {
        guard isEditable(element), !isSecure(element) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
            if let text = value as? String { return String(text.prefix(12000)) }
            if let text = value as? NSAttributedString { return String(text.string.prefix(12000)) }
        }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let number = count as? NSNumber {
            if number.intValue == 0 { return "" }
            var range = CFRange(location: 0, length: min(12000, max(0, number.intValue)))
            if let parameter = AXValueCreate(.cfRange, &range),
               AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          parameter, &value) == .success,
               let text = value as? String { return String(text.prefix(12000)) }
        }
        return nil
    }

    nonisolated private static func isSecure(_ element: AXUIElement) -> Bool {
        var node: AXUIElement? = element
        for _ in 0..<4 {
            guard let current = node else { break }
            if string(current, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return true }
            var protected: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, "AXProtectedContent" as CFString, &protected) == .success,
               protected as? Bool == true { return true }
            node = axElement(current, kAXParentAttribute)
        }
        return false
    }

    nonisolated private static func bounds(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func capture(includeSelection: Bool = false) -> TextDestination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier == nil || Bundle.main.bundleIdentifier == nil ||
                app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let snapshot = captureSnapshot(pid: app.processIdentifier, includeSelection: includeSelection)
        return TextDestination(pid: app.processIdentifier, name: app.localizedName ?? "原来的应用",
                               window: snapshot.window, selectedText: snapshot.selectedText,
                               selectionElement: snapshot.selectionElement, selectionRange: snapshot.selectionRange)
    }

    static func captureForRecording(includeSelection: Bool = false) async -> TextDestination? {
        let preparedPID = includeSelection ? await RecordingContextTarget.shared.prepare() : NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard !Task.isCancelled, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == preparedPID,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier == nil || Bundle.main.bundleIdentifier == nil ||
                app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        // Pin the destination before suspension so changing focus never retargets a paste.
        let pid = app.processIdentifier, name = app.localizedName ?? "原来的应用"
        let snapshot = await withCheckedContinuation { continuation in
            destinationCaptureQueue.async {
                continuation.resume(returning: captureSnapshot(pid: pid, includeSelection: includeSelection))
            }
        }
        guard !Task.isCancelled else { return nil }
        return TextDestination(pid: pid, name: name, window: snapshot.window,
                               selectedText: snapshot.selectedText, selectionElement: snapshot.selectionElement,
                               selectionRange: snapshot.selectionRange)
    }

    nonisolated private static func captureSnapshot(pid: pid_t, includeSelection: Bool) -> DestinationSnapshot {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let focused = includeSelection ? axElement(element, kAXFocusedUIElementAttribute) : nil
        var selection = ""
        if let focused {
            if !isSecure(focused) {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success {
                    selection = String((value as? String ?? "").prefix(12000))
                }
            }
        }
        return DestinationSnapshot(window: axElement(element, kAXFocusedWindowAttribute),
                                   selectedText: selection, selectionElement: focused,
                                   selectionRange: focused.flatMap { selectedRange($0) })
    }

    func insert(_ text: String, requireOriginalSelection: Bool = false) -> String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return "文字已复制；允许辅助功能后就能自动输入。" }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return "已切换应用，文字已复制，按 ⌘V 即可输入。"
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        if let window, let current = Self.axElement(application, kAXFocusedWindowAttribute),
           !CFEqual(window, current) {
            return "已切换窗口，文字已复制，按 ⌘V 即可输入。"
        }
        if let focused = Self.axElement(application, kAXFocusedUIElementAttribute) {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == kAXSecureTextFieldSubrole {
                return "当前是密码框，文字已复制，未自动输入。"
            }
        }
        if requireOriginalSelection {
            guard let focused = Self.axElement(application, kAXFocusedUIElementAttribute),
                  let selectionElement, CFEqual(selectionElement, focused),
                  let original = selectionRange, let current = Self.selectedRange(focused),
                  original.location == current.location, original.length == current.length else {
                return "选区已变化，改写结果已复制，请手动粘贴。"
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success,
                  value as? String == selectedText, !selectedText.isEmpty else {
                return "选中文字已变化，改写结果已复制，请手动粘贴。"
            }
        }
        // 部分网页控件对 AXSelectedText 写入返回成功却不修改内容；统一使用标准粘贴。
        // 网页、Electron 和自绘编辑器不一定公开可编辑角色。
        // 只要求原应用仍在前台，不再因缺少 AXTextArea 或输入控件对象变化而丢弃结果。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return "已切换应用，文字已复制，按 ⌘V 即可输入。"
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return "文字已复制，按 ⌘V 即可输入。"
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return "已向\(name)输入文字，结果也已复制。"
    }

    /// Called immediately before paste; inability to identify the exact field disables learning.
    func memoryCapture(for inserted: String, status: @escaping (MemoryCapture.Status) -> Void = { _ in },
                       complete: @escaping (String, String) -> Void) -> MemoryCapture? {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let field = Self.focusedInput(app: app, pid: pid), Self.isEditable(field), !Self.isSecure(field) else { return nil }
        AXUIElementSetMessagingTimeout(field, 0.15)
        guard let before = Self.memoryValue(field),
              let anchor = MemoryInsertionAnchor(before: before,
                selection: Self.selectedRange(field).map { NSRange(location: $0.location, length: $0.length) },
                inserted: inserted) else { return nil }
        let source = MemoryInputSource(app: app, field: field, pid: pid)
        let capture = MemoryCapture(anchor: anchor, read: {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return nil }
            let value: String? = await withCheckedContinuation { continuation in
                memoryCaptureQueue.async {
                    guard let current = Self.focusedInput(app: source.app, pid: source.pid),
                          CFEqual(current, source.field), !Self.isSecure(current) else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: Self.memoryValue(current))
                }
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return nil }
            return value
        }, status: status, complete: complete)
        // Observer registration can time out in unsupported editors; never hold up the paste or UI.
        Task { [weak capture] in
            let observation: MemoryAXObservation? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: MemoryAXObservation(source: source,
                        changed: { [weak capture] in capture?.notifyChange() }))
                }
            }
            guard let observation else { return }
            guard let capture else { observation.stop(); return }
            capture.attachObservation { observation.stop() }
        }
        return capture
    }

    nonisolated private static func memoryValue(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
           let text = MemoryFieldText.string(value) { return text }
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let count = count as? NSNumber, count.intValue >= 0, count.intValue <= 24000 else { return nil }
        if count.intValue == 0 { return "" }
        var range = CFRange(location: 0, length: count.intValue)
        guard let parameter = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                parameter, &value) == .success else { return nil }
        return MemoryFieldText.string(value)
    }

    nonisolated private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) ? range : nil
    }

    nonisolated private static func axElement(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
