import Foundation
import Darwin

/// A held advisory lock distinguishes a live session from crash leftovers,
/// including when a separate test/preview process uses the same temporary root.
private final class LiveDirectoryLease {
    private var descriptor: Int32
    init(_ directory: URL) throws {
        descriptor = open(directory.appendingPathComponent(".lease").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw VoiceError.message("无法保护临时录音目录。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw VoiceError.message("临时录音目录正在使用。")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}

/// A copied, frame-aligned prefix of our 16 kHz mono PCM recording. The recorder
/// may not have finalized RIFF/data lengths yet, so live reads use available bytes.
struct RecordingPCM: Sendable {
    static let rate = 16_000
    let bytes: Data
    var frames: Int { bytes.count / 2 }

    init(bytes: Data) { self.bytes = Data(bytes.prefix(bytes.count - bytes.count % 2)) }

    init(wav: URL, live: Bool) throws {
        let file = try Data(contentsOf: wav)
        guard file.count >= 12, file.count <= 4_100_000,
              String(decoding: file[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: file[8..<12], as: UTF8.self) == "WAVE" else {
            throw VoiceError.message("录音格式暂不可读取。")
        }
        func u16(_ n: Int) -> Int { Int(file[n]) | Int(file[n + 1]) << 8 }
        func u32(_ n: Int) -> Int { u16(n) | u16(n + 2) << 16 }
        var offset = 12, validFormat = false
        while offset + 8 <= file.count {
            let tag = String(decoding: file[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4), start = offset + 8
            if tag == "fmt " {
                guard size >= 16, start + size <= file.count else { break }
                validFormat = u16(start) == 1 && u16(start + 2) == 1 &&
                    u32(start + 4) == Self.rate && u16(start + 12) == 2 && u16(start + 14) == 16
            }
            if tag == "data", validFormat {
                let length = live ? file.count - start : min(size, file.count - start)
                self.init(bytes: Data(file[start..<start + length])); return
            }
            guard size <= file.count - start else { break }
            offset = start + size + size % 2
        }
        throw VoiceError.message("录音头尚未就绪，将在结束后完整识别。")
    }

    func hasSignal(from start: Int, through end: Int) -> Bool {
        guard start < end else { return false }
        return bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in start..<end {
                let value = Int16(bitPattern: UInt16(p[i * 2]) | UInt16(p[i * 2 + 1]) << 8)
                if abs(Int(value)) > 3 { return true }
            }
            return false
        }
    }

    /// Pause detection only chooses a boundary. No samples (including quiet
    /// speech) are discarded; every frame is included in one contiguous chunk.
    func pauseBoundary(after start: Int) -> Int? {
        let window = 320, minimum = Self.rate * 3, quietWindows = 10
        guard frames - start >= minimum else { return nil }
        return bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var quiet = 0, candidate: Int?
            for n in stride(from: start, through: frames - window, by: window) {
                var power = 0.0
                for i in n..<n + window {
                    let value = Double(Int16(bitPattern: UInt16(p[i * 2]) | UInt16(p[i * 2 + 1]) << 8)) / 32768
                    power += value * value
                }
                quiet = power / Double(window) < 0.000016 ? quiet + 1 : 0
                if quiet >= quietWindows, n + window - start >= minimum { candidate = n + window }
            }
            return candidate
        }
    }

    func write(from start: Int, through end: Int, to url: URL) throws {
        guard 0 <= start, start <= end, end <= frames else { throw VoiceError.message("录音分段范围无效。") }
        let audio = Data(bytes[start * 2..<end * 2])
        var wav = Data()
        func tag(_ value: String) { wav.append(contentsOf: value.utf8) }
        func number(_ value: Int, _ count: Int) {
            for n in 0..<count { wav.append(UInt8((value >> (n * 8)) & 255)) }
        }
        tag("RIFF"); number(36 + audio.count, 4); tag("WAVEfmt "); number(16, 4)
        number(1, 2); number(1, 2); number(Self.rate, 4); number(Self.rate * 2, 4)
        number(2, 2); number(16, 2); tag("data"); number(audio.count, 4); wav.append(audio)
        try wav.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Speculative work stays local. Only finish() may publish the complete text;
/// translation always receives the full session, including corrections and tail.
@MainActor
final class LiveTranscription {
    typealias Operation = @Sendable (URL, String, String) async throws -> String
    private struct Job { let id: UUID; let task: Task<String, Error>; let file: URL }
    private let directory: URL
    private let language: String
    private let dictionary: String
    private let operation: Operation
    private var active: Job?
    private var latest: RecordingPCM?
    private var cursor = 0
    private var committed = Data()
    private var results: [String] = []
    private var error: Error?
    private var finishing = false
    private var cancelled = false
    private var planning = false
    private var lease: LiveDirectoryLease?
    private(set) var completedChunks = 0

    init(directory: URL, language: String, dictionary: String, operation: @escaping Operation) throws {
        self.directory = directory; self.language = language; self.dictionary = dictionary; self.operation = operation
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        lease = try LiveDirectoryLease(directory)
    }

    static func cleanupAbandoned(in root: URL, removeRecent: Bool) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? [] {
            let name = directory.lastPathComponent
            guard name.hasPrefix("live-"), UUID(uuidString: String(name.dropFirst(5))) != nil,
                  let values = try? directory.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink != true,
                  removeRecent || (values.contentModificationDate ?? .distantFuture) < Date().addingTimeInterval(-86400),
                  let lease = try? LiveDirectoryLease(directory) else { continue }
            withExtendedLifetime(lease) { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        lease = nil
    }

    func offer(_ snapshot: RecordingPCM) {
        guard !finishing, !cancelled, error == nil, snapshot.frames >= cursor else { return }
        latest = snapshot
        schedule()
    }

    private func schedule() {
        guard !finishing, !cancelled, !planning, error == nil, active == nil, let snapshot = latest else { return }
        planning = true
        let start = cursor
        Task { [weak self] in
            let boundary = await Task.detached(priority: .utility) { snapshot.pauseBoundary(after: start) }.value
            guard let self else { return }
            self.planning = false
            guard !self.finishing, !self.cancelled, self.error == nil, self.cursor == start else { return }
            do {
                if let boundary { try self.submit(snapshot, through: boundary) }
                else if let latest = self.latest, latest.frames > snapshot.frames { self.schedule() }
            } catch { self.error = error }
        }
    }

    private func submit(_ snapshot: RecordingPCM, through end: Int) throws {
        guard snapshot.bytes.prefix(cursor * 2) == committed else {
            throw VoiceError.message("录音前缀变化，将重新完整识别。")
        }
        let start = cursor
        cursor = end; committed = Data(snapshot.bytes.prefix(end * 2))
        guard snapshot.hasSignal(from: start, through: end) else { return }
        let file = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try snapshot.write(from: start, through: end, to: file)
        let operation = self.operation, language = self.language, dictionary = self.dictionary
        let task = Task { try await operation(file, language, dictionary) }
        let job = Job(id: UUID(), task: task, file: file)
        active = job
        Task { [weak self] in
            let result = await task.result
            self?.complete(job, with: result)
        }
    }

    private func complete(_ job: Job, with result: Result<String, Error>) {
        guard active?.id == job.id else { return }
        active = nil
        try? FileManager.default.removeItem(at: job.file)
        guard !cancelled else { return }
        switch result {
        case .success(let text):
            // A voiced chunk with no transcript cannot silently disappear.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error = VoiceError.message("分段没有返回文字，将完整重试识别。")
            } else { results.append(text); completedChunks += 1 }
        case .failure(let failure): error = failure
        }
        schedule()
    }

    func finish(audio: URL) async throws -> String {
        finishing = true
        defer { cleanup() }
        if let job = active { complete(job, with: await job.task.result) }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        if let error { throw error }
        let snapshot = try RecordingPCM(wav: audio, live: false)
        guard snapshot.frames >= cursor, snapshot.bytes.prefix(cursor * 2) == committed else {
            throw VoiceError.message("录音尾段无法校验，将完整重试识别。")
        }
        // A last-second correction such as “不” must not be decoded in isolation
        // with too little acoustic context. The caller still owns the full WAV.
        if cursor > 0, snapshot.frames - cursor < RecordingPCM.rate,
           snapshot.hasSignal(from: cursor, through: snapshot.frames) {
            throw VoiceError.message("录音尾段较短，将结合完整上下文识别。")
        }
        if snapshot.frames > cursor { try submit(snapshot, through: snapshot.frames) }
        if let job = active { complete(job, with: await job.task.result) }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        if let error { throw error }
        return results.joined(separator: "\n")
    }

    func cancel() {
        cancelled = true; active?.task.cancel(); latest = nil
        cleanup()
    }
}
