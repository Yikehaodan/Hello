import Foundation
import Darwin

// Cancellation owns one request, never a subsequently reused worker process.
private final class ManagedASRRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var finished = false

    func bind(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw errorLocked()! }
        self.process = process
    }
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw errorLocked()! }
        self.process = process
        try process.run()
    }
    func cancel(timeout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        cancelled = true
        timedOut = timedOut || timeout
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func finish() { lock.lock(); finished = true; process = nil; lock.unlock() }
    func error() -> Error? { lock.lock(); defer { lock.unlock() }; return errorLocked() }
    private func errorLocked() -> Error? {
        if timedOut { return VoiceError.message("识别用时过长，录音仍可重试。") }
        return cancelled ? CancellationError() : nil
    }
}

/// A private pipe transport and serial queue keep microphone/UI work off the inference thread.
/// The worker retains its model and Metal context, but resets decoding context per request.
final class ManagedSpeechASR: @unchecked Sendable {
    let resources: URL
    let root: URL
    let model: SpeechModelID
    private let queue = DispatchQueue(label: "local.lightvoice.resident-asr", qos: .userInitiated)
    private let activeLock = NSLock()
    private var active: ManagedASRRequest?
    private var worker: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var idle: DispatchWorkItem?
    private let idleSeconds: Double
    private let timeoutSeconds: Double

    init(resources: URL, root: URL, model: SpeechModelID, idleSeconds: Double = 120, timeoutSeconds: Double = 180) {
        self.resources = resources; self.root = root; self.model = model
        self.idleSeconds = idleSeconds
        self.timeoutSeconds = timeoutSeconds
    }
    var ready: Bool {
        FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("SpeechRuntime/python/bin/python3").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/" + model.rawValue + "/installed.json").path)
    }
    func warmup(language: String = "auto") async throws { _ = try await perform(fields: ["command": "prepare", "language": language]) }
    func transcribe(_ audio: URL, language: String = "auto", dictionary: String = "") async throws -> String {
        let text = try await perform(fields: ["audio": audio.path, "language": language,
                                             "dictionary": String(dictionary.prefix(2000))]).trimmingCharacters(in: .whitespacesAndNewlines)
        if language == "zh" || model == .zipformer {
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        }
        return text
    }
    func startStream(_ id: UUID, language: String) async throws {
        _ = try await perform(fields: ["command": "start", "stream": id.uuidString, "language": language])
    }
    func feedStream(_ id: UUID, bytes: Data) async throws {
        _ = try await perform(fields: ["command": "feed", "stream": id.uuidString, "pcm": bytes])
    }
    func finishStream(_ id: UUID, frames: Int) async throws -> String {
        let text = try await perform(fields: ["command": "finish", "stream": id.uuidString, "frames": frames])
        return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }
    func shutdown() async {
        cancelActive()
        await withCheckedContinuation { continuation in
            queue.async { self.discardWorker(); continuation.resume() }
        }
    }
    private func cancelActive() {
        activeLock.lock(); let request = active; activeLock.unlock()
        request?.cancel()
    }
    private func setActive(_ request: ManagedASRRequest?) {
        activeLock.lock(); active = request; activeLock.unlock()
    }
    private func perform(fields: [String: Any]?) async throws -> String {
        let request = ManagedASRRequest()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async {
                    self.idle?.cancel(); self.idle = nil
                    self.setActive(request)
                    let timeout = DispatchWorkItem { request.cancel(timeout: true) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + self.timeoutSeconds, execute: timeout)
                    defer {
                        timeout.cancel(); request.finish(); self.setActive(nil)
                        self.scheduleIdleRelease()
                    }
                    var touchedWorker = false
                    do {
                        if let error = request.error() { throw error }
                        touchedWorker = true
                        try self.ensureWorker(request)
                        var result = ""
                        if let fields {
                            let id = UUID().uuidString
                            var payload = fields.mapValues { value -> Any in
                                if let bytes = value as? Data { return bytes.base64EncodedString() }
                                return value
                            }
                            payload["id"] = id
                            var data = try JSONSerialization.data(withJSONObject: payload)
                            data.append(0x0a)
                            guard let input = self.input else { throw self.transportError() }
                            try input.write(contentsOf: data)
                            let response = try self.readResponse()
                            guard response["id"] as? String == id else { throw self.transportError() }
                            if let text = response["text"] as? String { result = text }
                            else { throw VoiceError.message(response["error"] as? String ?? "所选模型识别失败，录音仍可重试。") }
                        }
                        if let error = request.error() { throw error }
                        request.finish()
                        continuation.resume(returning: result)
                    } catch {
                        if touchedWorker { self.discardWorker() }
                        continuation.resume(throwing: request.error() ?? error)
                    }
                }
            }
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        return result
    }
    private func ensureWorker(_ request: ManagedASRRequest) throws {
        if let worker, worker.isRunning { try request.bind(worker); return }
        discardWorker()
        guard ready else { throw VoiceError.message("本地常驻识别引擎不完整，请重新打开完整应用包。") }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = resources.appendingPathComponent("SpeechRuntime/python/bin/python3")
        child.arguments = ["-I", "-B", resources.appendingPathComponent("SpeechModels/speech_worker.py").path, "--model", model.rawValue, "--root", root.path]
        child.standardInput = stdin; child.standardOutput = stdout
        // Do not persist model diagnostics, paths, or transcription content.
        child.standardError = FileHandle.nullDevice
        worker = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        try request.launch(child)
        try stdin.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        let response = try readResponse()
        guard response["ready"] as? Bool == true, response["protocol"] as? Int == 1 else {
            throw VoiceError.message(response["error"] as? String ?? "语音模型载入失败，录音仍可重试。")
        }
    }
    private func readResponse() throws -> [String: Any] {
        guard let output else { throw transportError() }
        var line = Data()
        while line.count < 1_048_576 {
            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else { throw transportError() }
            if byte.first == 0x0a {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw transportError()
                }
                return object
            }
            line.append(byte)
        }
        throw transportError()
    }
    private func transportError() -> Error { VoiceError.message("本地识别引擎连接中断，录音仍可重试。") }
    private func scheduleIdleRelease() {
        guard worker != nil else { return }
        let task = DispatchWorkItem { [weak self] in self?.discardWorker() }
        idle = task
        queue.asyncAfter(deadline: .now() + idleSeconds, execute: task)
    }
    private func discardWorker() {
        idle?.cancel(); idle = nil
        if let worker, worker.isRunning {
            worker.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
            }
        }
        try? input?.close(); try? output?.close()
        input = nil; output = nil; worker = nil
    }
    deinit {
        // An outstanding request retains self, so deinit cannot race active pipe reads.
        if let worker, worker.isRunning { worker.terminate() }
        try? input?.close(); try? output?.close()
    }
}
