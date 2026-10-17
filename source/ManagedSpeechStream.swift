import Foundation

/// Serial, coalesced PCM delivery keeps inference and pipe I/O away from the UI.
@MainActor
final class ManagedSpeechStream {
    private let backend: ManagedSpeechASR
    private let id = UUID()
    private let language: String
    private var latest: RecordingPCM?
    private var sent = Data()
    private var started = false
    private var error: Error?
    private var cancelled = false
    private var finishing = false
    private var pump: Task<Void, Never>?

    init(backend: ManagedSpeechASR, language: String) {
        self.backend = backend; self.language = language
    }
    func offer(_ snapshot: RecordingPCM) {
        guard !cancelled, !finishing, error == nil else { return }
        latest = snapshot
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startIfNeeded()
                while let snapshot = self.latest, !self.cancelled, !Task.isCancelled {
                    self.latest = nil
                    try await self.send(snapshot)
                }
            } catch { self.error = error }
            self.pump = nil
        }
    }
    private func startIfNeeded() async throws {
        guard !started else { return }
        try Task.checkCancellation()
        try await backend.startStream(id, language: language)
        started = true
    }
    private func send(_ snapshot: RecordingPCM) async throws {
        guard snapshot.bytes.count >= sent.count, snapshot.bytes.prefix(sent.count) == sent else {
            throw VoiceError.message("录音前缀变化，将重新完整识别。")
        }
        while sent.count < snapshot.bytes.count {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let end = min(sent.count + 64_000, snapshot.bytes.count)
            let delta = Data(snapshot.bytes[sent.count..<end])
            try await backend.feedStream(id, bytes: delta)
            sent.append(delta)
        }
    }
    func finish(audio: URL) async throws -> String {
        guard !cancelled, !finishing else { throw CancellationError() }
        finishing = true
        if let pump { await pump.value }
        try Task.checkCancellation()
        if let error { throw error }
        let final = try await Task.detached(priority: .userInitiated) { try RecordingPCM(wav: audio, live: false) }.value
        try await startIfNeeded()
        try await send(final)
        return try await backend.finishStream(id, frames: final.frames)
    }
    func cancel() {
        cancelled = true; latest = nil; pump?.cancel(); pump = nil
    }
}
