import Foundation

@MainActor
final class AgentProcess {
    private let process = Process()
    private let input = Pipe()
    private var stopped = false
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    nonisolated static var runtime: URL { Bundle.main.resourceURL!.appendingPathComponent("AgentRuntime") }
    nonisolated static var ready: Bool {
        FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("node").path)
        && FileManager.default.fileExists(atPath: runtime.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json").path)
    }
    func start(_ payload: [String: Any], runtime: URL = AgentProcess.runtime) throws {
        let executable = runtime.appendingPathComponent("node")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentError.message("此版本缺少 Agent 运行组件，请使用完整构建版本；开发时先运行 source/build-agent.sh。")
        }
        let output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = [runtime.appendingPathComponent("bridge.mjs").path]
        // The runtime needs no shell, desktop app, or developer-specific installation path.
        process.currentDirectoryURL = runtime
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                if buffer.count > 8_000_000 { break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        Task { @MainActor [weak self] in self?.onEvent?(event) }
                    }
                }
            }
            Task { @MainActor [weak self] in self?.onExit?() }
        }
        DispatchQueue.global(qos: .utility).async {
            while !errors.fileHandleForReading.availableData.isEmpty {} // Drain without retaining secrets.
        }
        send(payload)
    }
    func send(_ payload: [String: Any]) {
        guard process.isRunning, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
        catch { onEvent?(["type": "error", "text": "Agent 通信已断开，任务未完成。"] ) }
    }
    func cancel() {
        guard !stopped else { return }; stopped = true
        send(["type": "cancel"])
        Task { [self] in
            try? await Task.sleep(for: .seconds(4))
            if process.isRunning { process.terminate() }
        }
    }
}
