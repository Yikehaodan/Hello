import Foundation

/// Anchors the paste using UTF-16 offsets, as used by macOS accessibility.
struct MemoryInsertionAnchor {
    let prefix: String
    let suffix: String
    let inserted: String
    var expected: String { prefix + inserted + suffix }
    init?(before: String, selection: NSRange?, inserted: String) {
        let text = before as NSString
        // Some chat editors omit the caret range while empty; the insertion point is unambiguous.
        guard let selection = selection ?? (before.isEmpty ? NSRange(location: 0, length: 0) : nil) else { return nil }
        guard before.count <= 12000, !inserted.isEmpty, inserted.count <= 12000,
              selection.location >= 0, selection.length >= 0, selection.location <= text.length,
              selection.length <= text.length - selection.location else { return nil }
        self.prefix = text.substring(to: selection.location)
        self.suffix = text.substring(from: selection.location + selection.length)
        self.inserted = inserted
    }
    func fragment(in value: String) -> String? {
        guard value.count <= 24000, value.hasPrefix(prefix), value.hasSuffix(suffix),
              value.utf16.count >= prefix.utf16.count + suffix.utf16.count else { return nil }
        return (value as NSString).substring(with: NSRange(location: prefix.utf16.count,
            length: value.utf16.count - prefix.utf16.count - suffix.utf16.count))
    }
}

enum MemoryFieldText {
    static func string(_ value: Any?, limit: Int = 24000) -> String? {
        let text = (value as? String) ?? (value as? NSAttributedString)?.string
        guard let text, text.count <= limit else { return nil }
        return text
    }
}

/// Observes only the verified paste destination for a bounded time. No keyboard logging or screenshots.
@MainActor
final class MemoryCapture {
    enum Status { case waiting, observing, captured, finished, cancelled }
    private var anchor: MemoryInsertionAnchor?
    private var read: (@MainActor () async -> String?)?
    private let complete: (String, String) -> Void
    private let status: (Status) -> Void
    private let now: () -> TimeInterval
    private var task: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var stopObservation: (() -> Void)?
    private var latest: String?
    private var lastChange: TimeInterval = 0
    private var started: TimeInterval?
    private var samples = 0
    private var sampling = false
    private var verified = false
    init(anchor: MemoryInsertionAnchor, read: @escaping @MainActor () async -> String?,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         status: @escaping (Status) -> Void = { _ in }, complete: @escaping (String, String) -> Void) {
        self.anchor = anchor; self.read = read; self.complete = complete
        self.now = now; self.status = status
    }
    func attachObservation(stop: @escaping () -> Void) {
        guard anchor != nil else { stop(); return }
        stopObservation?()
        stopObservation = stop
    }

    /// AX notifications request a coalesced read; unsupported controls still use bounded polling.
    func notifyChange() {
        guard anchor != nil, notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self else { return }
            self.notificationTask = nil
            await self.sample()
        }
    }
    func start() {
        guard task == nil, anchor != nil else { return }
        started = now(); status(.waiting)
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.anchor != nil else { return }
                await self.sample()
                guard self.anchor != nil else { return }
                do { try await Task.sleep(for: self.verified ? .milliseconds(250) : .milliseconds(50)) }
                catch { return }
            }
        }
    }

    func sample() async {
        guard !sampling, let read, let anchor else { return }
        sampling = true
        defer { sampling = false }
        if started == nil { started = now() }
        guard now() - started! < 30 else { finish(); return }
        let value = await read()
        guard self.anchor != nil else { return }
        guard let value else { finish(); return }
        if !verified {
            if value == anchor.expected {
                verified = true; latest = anchor.inserted; lastChange = now(); samples = 1
                status(.observing)
            } else if now() - started! >= 2 { cancel() }
            return
        }
        guard let fragment = anchor.fragment(in: value), !fragment.isEmpty else {
            // A cleared/sent field is a boundary, never evidence that the text was deleted.
            finish(); return
        }
        if fragment != latest { latest = fragment; lastChange = now(); samples = 1 }
        else { samples += 1 }
        // Submit a settled correction promptly instead of waiting for the entire 30-second window.
        if fragment != anchor.inserted, samples >= 2, now() - lastChange >= 1.2,
           MemoryEdit.excerpt(before: anchor.inserted, after: fragment) != nil { finish() }
    }

    func finish() {
        guard anchor != nil else { return }
        let inserted = anchor?.inserted
        // Two matching observations also preserve a quick edit followed by send/focus change.
        let settled = samples >= 2 && now() - lastChange >= 0.2
        let change = verified && settled ? latest : nil
        release()
        if let change, let inserted, change != inserted,
           MemoryEdit.excerpt(before: inserted, after: change) != nil {
            complete(inserted, change); status(.captured)
        } else { status(.finished) }
    }
    func cancel() {
        guard anchor != nil else { return }
        release(); status(.cancelled)
    }
    private func release() {
        task?.cancel(); task = nil; notificationTask?.cancel(); notificationTask = nil
        let stop = stopObservation; stopObservation = nil; stop?()
        latest = nil; verified = false; anchor = nil; read = nil
    }
    deinit { task?.cancel(); notificationTask?.cancel(); stopObservation?() }
}
