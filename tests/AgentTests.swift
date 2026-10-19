import Foundation

@main
struct AgentTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-agent-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent("node"), withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "tests/agent-native-fixture.mjs"), to: runtime.appendingPathComponent("bridge.mjs"))
        var key = ""
        let store = AgentConfigurationStore(root: root.appendingPathComponent("state"), readKey: { key }, writeKey: { key = $0 })
        var config = AgentConfiguration(); config.workspace = root.path
        do { _ = try config.validated(key: ""); fatalError("empty key accepted") } catch {}
        var invalid = config; invalid.baseURL = "https://example.com/chat/completions"
        do { _ = try invalid.validated(key: "x"); fatalError("chat endpoint accepted") } catch {}
        try store.save(config, key: "fixture-key")
        let disk = try String(contentsOf: store.root.appendingPathComponent("settings.json"))
        precondition(!disk.contains("fixture-key"), "API key must not be in JSON")
        key = "wrong-key"
        do { _ = try store.credentials(); fatalError("mismatched key accepted") } catch {}
        key = "fixture-key"
        let agent = AgentSession(store: store, runtime: runtime, lookup: { kind, query in
            precondition(kind == "search" && query == "fixture")
            return [AnswerSource(title: "Fixture", url: "https://example.com", content: "fixture")]
        })
        agent.receiveVoice("测试任务", selection: "参考")
        try await wait { !agent.permissions.isEmpty }
        precondition(agent.phase == .waiting && agent.sources.count == 1)
        let firstID = agent.selectedID
        agent.submit("补充要求")
        precondition(agent.queuedCount == 1)
        agent.reply(agent.permissions[0], allow: false)
        try await wait { agent.queuedCount == 0 && !agent.permissions.isEmpty }
        precondition(agent.selectedID == firstID && agent.record?.sessionID == "fixture-session")
        agent.reply(agent.permissions[0], allow: true)
        try await wait { agent.phase == .completed }
        precondition(agent.record?.messages.filter { $0.role == "user" }.count == 2)
        let persisted = try String(contentsOf: store.root.appendingPathComponent("tasks.json"))
        precondition(!persisted.contains("fixture-key"))
        agent.receiveVoice("新的语音任务", selection: "")
        try await wait { !agent.permissions.isEmpty }
        precondition(agent.selectedID != firstID, "fresh voice must start a new task")
        agent.stop(); precondition(agent.phase == .stopped && agent.permissions.isEmpty)
        agent.consume(["type": "result", "ok": true, "text": "stale"])
        precondition(agent.phase == .stopped, "late results must not revive cancellation")
        let restored = AgentSession(store: store, runtime: runtime)
        precondition(restored.records.count == 2)
        restored.clearHistory(); precondition(restored.records.isEmpty)
        let voice = VoiceModel(library: LibraryStore(root: root.appendingPathComponent("voice")),
                               sessionRoot: root.appendingPathComponent("recordings"),
                               transcriptionOperation: { _, _, _ in "语音任务" })
        var handedOff = false
        voice.onAgentRequest = { text, _ in precondition(text == "语音任务"); handedOff = true }
        voice.raw = "语音任务"; voice.mode = .ask; voice.polish()
        try await wait { handedOff && !voice.busy }
        precondition(!voice.showAnswer, "Agent requests must not open legacy answer panel or auto-paste")
        print("PASS: Agent configuration privacy, search callback, approvals, queue, resume, cancellation and persistence")
    }
    @MainActor
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        fatalError("Agent condition timed out")
    }
}
