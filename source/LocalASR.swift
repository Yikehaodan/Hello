import Foundation
import AVFoundation

final class ASRJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    func start(_ child: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        process = child
        try child.run()
    }
    func cancel(timeout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; timedOut = timeout
        if let process, process.isRunning { process.terminate() }
    }
    func error() -> Error? {
        lock.lock(); defer { lock.unlock() }
        if timedOut { return VoiceError.message("识别用时过长，录音仍可重试。") }
        return cancelled ? CancellationError() : nil
    }
}

struct LocalASR {
    let resources: URL
    private let suppliedModelURL: URL?
    init(resources: URL = Bundle.main.resourceURL!, modelURL: URL? = nil) { self.resources = resources; self.suppliedModelURL = modelURL }
    var modelFile: String {
        FileManager.default.fileExists(atPath: resources.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path)
            ? "ggml-large-v3-turbo-q5_0.bin" : "ggml-small-q5_1.bin"
    }
    private var modelURL: URL { suppliedModelURL ?? resources.appendingPathComponent(modelFile) }
    var ready: Bool {
        FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("whisper-cli").path)
            && FileManager.default.fileExists(atPath: modelURL.path)
    }
    func transcribe(_ audio: URL, language: String = "auto", dictionary: String = "") async throws -> String {
        guard ready else { throw VoiceError.message("本地语音模型不完整，请重新打开完整的Knock应用包。") }
        // 只过滤近乎无声的文件；有声音时仍把完整录音交给 Whisper，不切段。
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw VoiceError.message("无法读取录音，请重新录制。")
        }
        var hasSignal = false
        while file.framePosition < file.length && !hasSignal {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
                if samples.contains(where: { abs($0) > 0.0001 }) { hasSignal = true; break }
            }
        }
        guard hasSignal else { return "" }
        let output = audio.deletingPathExtension().appendingPathExtension(UUID().uuidString)
        let log = output.appendingPathExtension("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: output.appendingPathExtension("txt"))
        }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("whisper-cli")
        process.arguments = ["-m", modelURL.path,
                             "-f", audio.path, "-l", language, "-t", "4", "-nt", "-np",
                             "-otxt", "-of", output.path]
        if !dictionary.isEmpty { process.arguments?.append(contentsOf: ["--prompt", String(dictionary.prefix(2000))]) }
        process.standardOutput = handle; process.standardError = handle
        let job = ASRJob()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(180)); job.cancel(timeout: true) }
            catch { }
        }
        defer { timeout.cancel() }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
                do { try job.start(process) }
                catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        } onCancel: { job.cancel() }
        if let error = job.error() { throw error }
        try Task.checkCancellation()
        guard status == 0 else { throw VoiceError.message("本地语音识别失败（\(status)），可以点击重新识别。") }
        let raw = (try? String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == "zh" || language == "auto" {
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        }
        return text
    }
}
