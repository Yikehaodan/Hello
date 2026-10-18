import Foundation

/// Anchors the paste using UTF-16 offsets, as used by macOS accessibility.
struct MemoryInsertionAnchor {
    let prefix: String
    let suffix: String
    let inserted: String
    var expected: String { prefix + inserted + suffix }
    init?(before: String, selection: NSRange, inserted: String) {
        let text = before as NSString
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

/// Observes only the verified paste destination for a bounded time. No keyboard logging or screenshots.
@MainActor
final class MemoryCapture {
    private var anchor: MemoryInsertionAnchor?
    private var read: (() -> String?)?
    private let complete: (String, String) -> Void
    private var task: Task<Void, Never>?
    private var latest: String?
    private var lastChange = Date()
    private var verified = false
    init(anchor: MemoryInsertionAnchor, read: @escaping () -> String?, complete: @escaping (String, String) -> Void) {
        self.anchor = anchor; self.read = read; self.complete = complete
    }
    func start() {
        task = Task { [weak self] in
            let started = Date(), deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, let anchor, let read else { return }
                guard Date() < deadline else { break }
                guard let value = read() else { finish(); return }
                if !verified {
                    if value == anchor.expected { verified = true; latest = anchor.inserted; lastChange = Date() }
                    else if Date().timeIntervalSince(started) >= 2 { cancel(); return }
                    continue
                }
                guard let fragment = anchor.fragment(in: value), !fragment.isEmpty else {
                    // Clearing after send is not a correction. Keep only the last stable edit.
                    finish(); return
                }
                if fragment != latest { latest = fragment; lastChange = Date() }
            }
            self?.finish()
        }
    }
    func finish() {
        task?.cancel(); task = nil
        let inserted = anchor?.inserted
        let change = verified && Date().timeIntervalSince(lastChange) >= 1.2 ? latest : nil
        latest = nil; verified = false; anchor = nil; read = nil
        if let change, let inserted, change != inserted { complete(inserted, change) }
    }
    func cancel() { task?.cancel(); task = nil; latest = nil; verified = false; anchor = nil; read = nil }
    deinit { task?.cancel() }
}
