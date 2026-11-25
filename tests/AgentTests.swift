import Foundation
import CoreGraphics

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
        let legacy = Data(#"{"baseURL":"https://example.com","model":"fixture","auth":"bearer","workspace":"/tmp"}"#.utf8)
        let legacyConfig = try JSONDecoder().decode(AgentConfiguration.self, from: legacy)
        precondition(legacyConfig.permissionMode == "default" && legacyConfig.computerEnabled)
        let defaults = AgentConfiguration()
        precondition(defaults.permissionMode == "bypassPermissions" && defaults.computerEnabled)
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(defaults))
        precondition(decoded == defaults)
        let shot = AgentComputer.Snapshot(id: "fixture", display: 1, bounds: CGRect(x: -1920, y: 100, width: 1920, height: 1080), width: 1600, height: 900, date: Date())
        let center = try shot.point(x: 800, y: 450)
        precondition(center == CGPoint(x: -960, y: 640))
        for value in [-1.0, 1600, Double.nan, Double.infinity] {
            do { _ = try shot.point(x: value, y: 0); fatalError("invalid coordinate accepted") } catch {}
        }
        let combination = try AgentComputer.key("cmd+shift+l")
        precondition(combination.0 == 37 && combination.1.contains(.maskCommand) && combination.1.contains(.maskShift))
        do { _ = try AgentComputer.key("invalid+a"); fatalError("unknown modifier accepted") } catch {}
        let computer = AgentComputer()
        do { _ = try await computer.execute(["action": "screenshot"]); fatalError("disabled capture accepted") } catch {}
        print("PASS: permission compatibility, screen coordinate mapping, key validation and disabled host gate")
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
        // Real default storage must survive reopening without any Keychain access.
        let localRoot = root.appendingPathComponent("local-settings")
        let localStore = AgentConfigurationStore(root: localRoot)
        try localStore.save(config, key: "  local-fixture-key  ")
        let reopened = AgentConfigurationStore(root: localRoot)
        let localCredentials = try reopened.credentials()
        precondition(localCredentials.1 == "local-fixture-key")
        let keyFile = localRoot.appendingPathComponent("api-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let settingsAttributes = try FileManager.default.attributesOfItem(atPath: localRoot.appendingPathComponent("settings.json").path)
        precondition((settingsAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // A wrong key cannot silently accompany an old endpoint/configuration.
        try Data("wrong-key".utf8).write(to: keyFile)
        do { _ = try reopened.credentials(); fatalError("mismatched local key accepted") } catch {}
        try localStore.save(config, key: "replacement-key")
        let replacementCredentials = try reopened.credentials()
        precondition(replacementCredentials.1 == "replacement-key")
        // Old metadata alone must not attempt to read the former Keychain entry.
        try FileManager.default.removeItem(at: keyFile)
        let missingKey = try reopened.key()
        precondition(missingKey.isEmpty)
        do { _ = try reopened.credentials(); fatalError("missing local key accepted") } catch {}
        let agent = AgentSession(store: store, runtime: runtime, lookup: { kind, query in
            precondition(kind == "weather" && query == "fixture")
            return [AnswerSource(title: "Fixture", url: "https://example.com", content: "fixture")]
        })
        let snapshot = VoiceContext(application: "Fixture", windowTitle: "Window", inputText: "原始输入框",
                                    imageDataURL: "data:image/jpeg;base64,ZmFrZQ==", captureStatus: "已读取输入框与截图")
        agent.receiveVoice("测试任务", selection: "参考", context: snapshot)
        try await wait { !agent.permissions.isEmpty }
        precondition(agent.phase == .waiting && agent.sources.count == 1)
        agent.consume(["type": "activity", "tool": "WebSearch", "detail": "官方搜索"])
        precondition(agent.status.contains("DeepSeek 联网搜索"))
        agent.consume(["type": "sources", "sources": [
            ["title": "Official", "url": "https://api-docs.deepseek.com/updates/"],
            ["title": "Duplicate", "url": "https://api-docs.deepseek.com/updates/"],
            ["title": "Unsafe", "url": "javascript:alert(1)"]]])
        precondition(agent.sources.count == 2 && agent.sources.last?.title == "Official")
        let firstID = agent.selectedID
        agent.submit("补充要求", context: VoiceContext(application: "Queued", inputText: "排队快照"))
        precondition(agent.queuedCount == 1)
        agent.reply(agent.permissions[0], allow: false)
        try await wait { agent.queuedCount == 0 && !agent.permissions.isEmpty }
        precondition(agent.selectedID == firstID && agent.record?.sessionID == "fixture-session")
        agent.reply(agent.permissions[0], allow: true)
        try await wait { agent.phase == .completed }
        precondition(agent.record?.messages.filter { $0.role == "user" }.count == 2)
        let contextLines = try String(contentsOf: root.appendingPathComponent("captured-context.jsonl")).split(separator: "\n")
        let payloads = try contextLines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
        precondition(payloads.count == 2 && payloads[0]["inputText"] == snapshot.inputText)
        precondition(payloads[0]["imageDataURL"] == snapshot.imageDataURL && payloads[0]["selectedText"] == "参考")
        precondition(payloads[1]["inputText"] == "排队快照" && payloads[1]["imageDataURL"] == nil)
        precondition(agent.record?.messages.first?.contextStatus == snapshot.captureStatus)
        let persisted = String(decoding: try JSONEncoder().encode(LocalDatabase(root: store.root).all("agent", as: AgentTaskRecord.self)), as: UTF8.self)
        precondition(!persisted.contains("fixture-key"))
        agent.receiveVoice("新的语音任务", selection: "")
        try await wait { !agent.permissions.isEmpty }
        precondition(agent.selectedID != firstID, "fresh voice must start a new task")
        agent.stop(); precondition(agent.phase == .stopped && agent.permissions.isEmpty)
        agent.consume(["type": "result", "ok": true, "text": "stale"])
        precondition(agent.phase == .stopped, "late results must not revive cancellation")
        let sourceCount = agent.sources.count
        agent.consume(["type": "sources", "sources": [["title": "Late", "url": "https://late.example"]]])
        precondition(agent.sources.count == sourceCount, "late sources must not revive cancellation")
        let restored = AgentSession(store: store, runtime: runtime)
        precondition(restored.records.count == 2)
        restored.clearHistory(); precondition(restored.records.isEmpty)
        let task = AgentTaskRecord(title: "历史测试", fingerprint: "fixture", messages: [AgentMessage(role: "user", text: "历史测试"), AgentMessage(role: "assistant", text: "## 查询结果")], state: "任务完成")
        let historyStore = LibraryStore(root: root.appendingPathComponent("history"))
        let entryID = historyStore.addHistory(raw: "历史测试", text: "任务已交给 Agent", duration: 1, application: "Fixture", mode: "ask", agentTaskID: task.id)!
        let roundtrip = LibraryStore(root: root.appendingPathComponent("history"))
        precondition(roundtrip.history.first?.agentTaskID == task.id)
        let merged = UnifiedHistoryItem.merged(voice: roundtrip.history, tasks: [task])
        precondition(merged.count == 1 && merged[0].matches("查询结果"))
        if case .agent(_, let audio) = merged[0] { precondition(audio.map(\.id) == [entryID]) } else { fatalError("Agent must appear once in unified history") }
        var old = HistoryEntry(date: task.date, raw: "历史测试", text: "任务已交给 Agent，可在任务页面查看进度和结果。", duration: 1, application: "Fixture", mode: "ask")
        precondition(UnifiedHistoryItem.merged(voice: [old], tasks: [task]).count == 1)
        old.date = task.date.addingTimeInterval(-60)
        precondition(UnifiedHistoryItem.merged(voice: [old], tasks: [task]).count == 2, "Do not merge unrelated older recordings")
        precondition(UnifiedHistoryItem.merged(voice: roundtrip.history, tasks: []).count == 1, "Orphan recordings stay visible")
        let voice = VoiceModel(library: LibraryStore(root: root.appendingPathComponent("voice")),
                               sessionRoot: root.appendingPathComponent("recordings"),
                               transcriptionOperation: { _, _, _ in "语音任务" })
        var handedOff = false
        voice.onAgentRequest = { text, _, _ in precondition(text == "语音任务"); handedOff = true; return task.id }
        voice.raw = "语音任务"; voice.mode = .ask; voice.polish()
        try await wait { handedOff && !voice.busy }
        precondition(!voice.showAnswer, "Agent requests must not open legacy answer panel or auto-paste")
        precondition(voice.library.history.first?.agentTaskID == task.id, "Voice handoff must save the returned task identity")
        print("PASS: Agent configuration privacy, weather callback, unified history, approvals, queue, resume, cancellation and persistence")
    }
    @MainActor
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        fatalError("Agent condition timed out")
    }
}
