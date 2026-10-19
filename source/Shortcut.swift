import AppKit
import ApplicationServices

struct FnGesture {
    private(set) var down = false
    private var active = false
    private var armed = false
    private var pendingMode = InputMode.dictate
    private var suppressSpace = false
    private var shiftDown = false
    private var controlDown = false
    private var pressedAt: TimeInterval = 0
    private var handledOnPress = false
    private var timedOutLoneFn = false
    private(set) var triggeredMode: InputMode?
    private(set) var ignoredLongPress = false
    // Fn Space fires on Space-down; only release-triggered gestures have a deadline.
    var longPressDeadline: TimeInterval? { active && armed && pendingMode == .dictate ? pressedAt + 0.6 : nil }
    mutating func consumeLongPress(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let deadline = longPressDeadline, now >= deadline else { return false }
        timedOutLoneFn = pendingMode == .dictate
        armed = false
        ignoredLongPress = true
        return true
    }
    private mutating func finishIfReleased(now: TimeInterval) -> Bool {
        guard active, !down, !suppressSpace, !(pendingMode == .translate && shiftDown), !(pendingMode == .context && controlDown) else { return false }
        ignoredLongPress = armed && pendingMode == .dictate && now >= pressedAt + 0.6
        let trigger = armed && !ignoredLongPress
        if trigger { triggeredMode = pendingMode }
        active = false; armed = false; handledOnPress = false; timedOutLoneFn = false
        return trigger
    }
    mutating func consume(type: CGEventType, key: Int64, flags: CGEventFlags, now: TimeInterval = ProcessInfo.processInfo.systemUptime, isRecording: Bool = false) -> (trigger: Bool, suppress: Bool) {
        triggeredMode = nil
        ignoredLongPress = false
        let function = flags.contains(.maskSecondaryFn)
        let others = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if type == .flagsChanged && (key == 56 || key == 60) {
            shiftDown = flags.contains(.maskShift)
        }
        if type == .flagsChanged && (key == 59 || key == 62) {
            controlDown = flags.contains(.maskControl)
        }
        if type == .keyDown || type == .keyUp {
            if key == 49 && suppressSpace {
                if type == .keyUp {
                    suppressSpace = false
                    return (finishIfReleased(now: now), true)
                }
                return (false, true)
            }
            if type == .keyDown, key == 49, down, others.isEmpty,
               handledOnPress || ((armed || timedOutLoneFn) && pendingMode == .dictate) {
                suppressSpace = true
                guard !handledOnPress else { return (false, true) }
                // An explicit chord remains usable after holding Fn alone. Start immediately,
                // and consume its releases/repeats without toggling the new recording again.
                pendingMode = .ask; triggeredMode = .ask
                armed = false; timedOutLoneFn = false; handledOnPress = true
                return (true, true)
            }
            if active { armed = false; timedOutLoneFn = false }
            return (false, false)
        }
        guard type == .flagsChanged else { return (false, false) }
        // Direction keys may carry the Fn flag; only an actual Fn transition starts a session.
        guard key == 63 || active else { return (false, false) }
        if key == 63 && function && !down {
            down = true
            // Repressing Fn while another chord key remains held is not a new gesture.
            guard !active else { armed = false; timedOutLoneFn = false; return (false, true) }
            active = true; pressedAt = now; handledOnPress = false; timedOutLoneFn = false
            armed = others.isEmpty || (others == .maskShift && shiftDown) || (others == .maskControl && controlDown)
            pendingMode = others == .maskShift ? .translate : others == .maskControl ? .context : .dictate
            if isRecording && armed {
                handledOnPress = true; armed = false; triggeredMode = pendingMode
                return (true, true)
            }
            return (false, armed)
        }
        guard active else { return (false, false) }
        let shiftChord = others == .maskShift && (key == 56 || key == 60) && shiftDown
        let controlChord = others == .maskControl && (key == 59 || key == 62) && controlDown
        if down && (shiftChord || controlChord) && pendingMode != .ask {
            let chordMode: InputMode = shiftChord ? .translate : .context
            if pendingMode != .dictate && pendingMode != chordMode { armed = false }
            else if timedOutLoneFn && !handledOnPress { armed = true }
            pendingMode = chordMode
            timedOutLoneFn = false
        } else if !others.isEmpty && !(others == .maskShift && pendingMode == .translate) &&
                    !(others == .maskControl && pendingMode == .context) {
            armed = false; timedOutLoneFn = false
        }
        if key == 63 && !function { down = false }
        return (finishIfReleased(now: now), key == 63)
    }
}

struct PasteLastGesture {
    private var keyIsDown = false
    private var suppressUntilRelease = false

    mutating func consume(type: CGEventType, key: Int64, flags: CGEventFlags, isRepeat: Bool,
                          isOwnEvent: Bool = false, perform: () -> Bool) -> Bool {
        // insert() posts Cmd+V from this process. Those events must reach the destination and
        // must not release the latch belonging to the user's physical Ctrl+Cmd+V chord.
        guard !isOwnEvent, key == 9 else { return false }
        if type == .keyUp {
            let suppressed = suppressUntilRelease
            keyIsDown = false; suppressUntilRelease = false
            return suppressed
        }
        guard type == .keyDown else { return false }
        if keyIsDown { return suppressUntilRelease }
        keyIsDown = true
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
        guard modifiers == [.maskCommand, .maskControl] else { return false }
        if isRepeat { suppressUntilRelease = true; return true }
        suppressUntilRelease = perform()
        return suppressUntilRelease
    }
}

@MainActor
final class FnShortcut {
    var onToggle: (() -> Void)?
    var onMode: ((InputMode) -> Void)?
    var onCancel: (() -> Bool)?
    var onLongPress: (() -> Void)?
    var onPasteLast: (() -> Bool)?
    var onStatus: ((String) -> Void)?
    var isRecording: (() -> Bool)?
    private var gesture = FnGesture()
    private var pasteGesture = PasteLastGesture()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var local: Any?
    private var timer: Timer?
    private var longPressTimer: Timer?
    private var trusted = false

    func start() {
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            guard let self, self.tap == nil, let cg = event.cgEvent else { return event }
            return self.handle(cg.type, cg) ? nil : event
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        let allowed = AXIsProcessTrusted()
        if allowed == trusted, tap != nil { return }
        if trusted != allowed { resetGestures() }
        trusted = allowed
        guard allowed else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap); self.tap = nil }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); self.source = nil }
            onStatus?("跨应用使用 Fn 需要辅助功能权限。窗口按钮可直接录音。")
            return
        }
        guard tap == nil else { return }
        resetGestures()
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let shortcut = Unmanaged<FnShortcut>.fromOpaque(info).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        shortcut.resetGestures()
                        if let tap = shortcut.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    return shortcut.handle(type, event) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            onStatus?("Fn 已就绪 · 轻按开始，再按结束")
        } else { onStatus?("Fn 监听尚未启动，请检查辅助功能权限后重新打开应用。") }
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let ownEvent = event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier)
        if pasteGesture.consume(type: type, key: key, flags: event.flags,
                                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                isOwnEvent: ownEvent, perform: { onPasteLast?() == true }) { return true }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53,
           event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
           onCancel?() == true { resetGestures(); return true }
        let action = gesture.consume(type: type, key: key, flags: event.flags, isRecording: isRecording?() == true)
        scheduleLongPressHint()
        if gesture.ignoredLongPress { onLongPress?() }
        if action.trigger {
            if let mode = gesture.triggeredMode, let onMode { onMode(mode) }
            else { onToggle?() }
        }
        return action.suppress
    }
    private func scheduleLongPressHint() {
        longPressTimer?.invalidate(); longPressTimer = nil
        guard let deadline = gesture.longPressDeadline else { return }
        let scheduled = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.gesture.longPressDeadline == deadline else { return }
                self.longPressTimer = nil
                if self.gesture.consumeLongPress() { self.onLongPress?() }
                else { self.scheduleLongPressHint() }
            }
        }
        longPressTimer = scheduled
        RunLoop.main.add(scheduled, forMode: .common)
    }
    private func resetGestures() {
        longPressTimer?.invalidate(); longPressTimer = nil
        gesture = FnGesture(); pasteGesture = PasteLastGesture()
    }
    func stop() {
        timer?.invalidate()
        resetGestures()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let local { NSEvent.removeMonitor(local) }
        tap = nil; source = nil; local = nil
    }
}
