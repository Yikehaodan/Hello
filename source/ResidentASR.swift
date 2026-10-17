import Foundation
import Darwin

// Cancellation owns one request, never a subsequently reused worker process.
private final class ResidentASRRequest: @unchecked Sendable {
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
final class ResidentASR: @unchecked Sendable {
    let resources: URL
    private let suppliedModelURL: URL?
    private let queue = DispatchQueue(label: "local.lightvoice.resident-asr", qos: .userInitiated)
    private let activeLock = NSLock()
    private var active: ResidentASRRequest?
    private var worker: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var idle: DispatchWorkItem?
    private let idleSeconds: Double
    private let timeoutSeconds: Double

    init(resources: URL = Bundle.main.resourceURL!, idleSeconds: Double = 120, timeoutSeconds: Double = 180, modelURL: URL? = nil) {
        self.resources = resources; self.suppliedModelURL = modelURL
        self.idleSeconds = idleSeconds
        self.timeoutSeconds = timeoutSeconds
    }
    var ready: Bool {
        FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("lightvoice-asr-worker").path)
            && FileManager.default.fileExists(atPath: modelURL.path)
    }
    private var modelURL: URL { suppliedModelURL ?? resources.appendingPathComponent(modelFile) }
    private var modelFile: String {
        FileManager.default.fileExists(atPath: resources.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path)
            ? "ggml-large-v3-turbo-q5_0.bin" : "ggml-small-q5_1.bin"
    }
    func warmup() async throws { _ = try await perform(audio: nil, language: "auto", dictionary: "") }
    func transcribe(_ audio: URL, language: String = "auto", dictionary: String = "") async throws -> String {
        let raw = try await perform(audio: audio, language: language, dictionary: dictionary)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == "zh" || language == "auto" {
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        }
        return text
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
    private func setActive(_ request: ResidentASRRequest?) {
        activeLock.lock(); active = request; activeLock.unlock()
    }
    private func perform(audio: URL?, language: String, dictionary: String) async throws -> String {
        let request = ResidentASRRequest()
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
                        if let audio {
                            let id = UUID().uuidString
                            var data = try JSONSerialization.data(withJSONObject: ["id": id, "audio": audio.path,
                                "language": language, "dictionary": String(dictionary.prefix(2000))])
                            data.append(0x0a)
                            guard let input = self.input else { throw self.transportError() }
                            try input.write(contentsOf: data)
                            let response = try self.readResponse()
                            guard response["id"] as? String == id else { throw self.transportError() }
                            if let text = response["text"] as? String { result = text }
                            else { throw VoiceError.message("本地语音识别失败，录音仍可重试。") }
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
    private func ensureWorker(_ request: ResidentASRRequest) throws {
        if let worker, worker.isRunning { try request.bind(worker); return }
        discardWorker()
        guard ready else { throw VoiceError.message("本地常驻识别引擎不完整，请重新打开完整应用包。") }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = resources.appendingPathComponent("lightvoice-asr-worker")
        child.arguments = [modelURL.path]
        child.standardInput = stdin; child.standardOutput = stdout
        // Do not persist model diagnostics, paths, or transcription content.
        child.standardError = FileHandle.nullDevice
        worker = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        try request.launch(child)
        try stdin.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        let response = try readResponse()
        guard response["ready"] as? Bool == true, response["protocol"] as? Int == 1 else {
            throw VoiceError.message("本地语音模型载入失败，录音仍可重试。")
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
