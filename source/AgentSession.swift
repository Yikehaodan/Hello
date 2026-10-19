import AppKit
import Combine

struct AgentMessage: Codable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
}
struct AgentTaskRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var sessionID: String?
    var title: String
    var fingerprint: String
    var messages: [AgentMessage] = []
    var state = "执行中"
}
struct AgentPermission: Identifiable {
    let id: String
    let tool: String
    let input: [String: Any]
    var questions: [[String: Any]] { input["questions"] as? [[String: Any]] ?? [] }
    var detail: String {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]) else { return tool }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class AgentSession: ObservableObject {
    enum Phase { case idle, running, waiting, completed, failed, stopped }
    @Published var visible = false
    @Published var showSettings = false
    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "说出任务，让 Hello 帮你完成。"
    @Published private(set) var output = ""
    @Published private(set) var activities: [String] = []
    @Published private(set) var permissions: [AgentPermission] = []
    @Published private(set) var sources: [AnswerSource] = []
    @Published private(set) var records: [AgentTaskRecord] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var queuedCount = 0
    @Published private(set) var storageError = ""
    @Published private(set) var pendingSubmission: String?
    let store: AgentConfigurationStore
    var record: AgentTaskRecord? { records.first { $0.id == selectedID } }
    var busy: Bool { phase == .running || phase == .waiting }
    var onVoice: (() -> Void)?
    var continueNextVoice = false
    private var process: AgentProcess?
    private var runID = UUID()
    private var lookups: [String: Task<Void, Never>] = [:]
    private var queued: [(String, String)] = []
    private var activeKey = ""
    private var pendingSelection = ""
    private var pendingContinuation = false
    private var idleWatchdog: Task<Void, Never>?
    private let runtime: URL
    private let lookup: (String, String) async throws -> [AnswerSource]
    init(store: AgentConfigurationStore = AgentConfigurationStore(), runtime: URL = AgentProcess.runtime,
         lookup: ((String, String) async throws -> [AnswerSource])? = nil) {
        self.store = store; self.runtime = runtime
        self.lookup = lookup ?? { kind, value in
            let service = AnswerLookup(transport: .shared, retryWait: { attempt in
                try await Task.sleep(for: .seconds(min(attempt * 2, 8)))
            }, onRetry: nil)
            return try await kind == "weather" ? service.weather(city: value) : service.search(value)
        }
        if let data = try? Data(contentsOf: store.root.appendingPathComponent("tasks.json")),
           let stored = try? JSONDecoder().decode([AgentTaskRecord].self, from: data) {
            records = stored.map { task in
                var task = task; if task.state == "执行中" { task.state = "已中断" }; return task
            }
        }
    }
    func receiveVoice(_ text: String, selection: String) {
        submit(text, selection: selection, continuing: continueNextVoice || busy)
        continueNextVoice = false
    }
    func submit(_ text: String, selection: String = "", continuing: Bool = true) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        visible = true
        if busy || process != nil {
            queued.append((text, selection)); queuedCount = queued.count
            status = "补充已排队，当前步骤完成后继续。"
            return
        }
        do {
            let (config, key) = try store.credentials()
            try launch(text, selection: selection, config: config, key: key, continuing: continuing)
        } catch {
            phase = .failed; status = error.localizedDescription; output = text; showSettings = true
            pendingSubmission = text; pendingSelection = selection; pendingContinuation = continuing
        }
    }
    func retrySubmission() {
        guard let text = pendingSubmission else { return }
        submit(text, selection: pendingSelection, continuing: pendingContinuation)
    }
    private func launch(_ text: String, selection: String, config: AgentConfiguration, key: String, continuing: Bool) throws {
        let directory = URL(fileURLWithPath: config.workspace, isDirectory: true)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), config.workspace == AgentConfiguration().workspace {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if !isDirectory.boolValue { throw AgentError.message("工作目录不存在，请在 Agent 设置中重新选择。") }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !continuing || record == nil || record?.fingerprint != config.fingerprint {
            let item = AgentTaskRecord(title: String(text.prefix(60)), fingerprint: config.fingerprint)
            records.insert(item, at: 0); selectedID = item.id
        }
        updateRecord { $0.messages.append(AgentMessage(role: "user", text: text)); $0.state = "执行中" }
        phase = .running; status = "正在连接模型……"; output = ""; activities = []; sources = []; permissions = []
        pendingSubmission = nil
        activeKey = key; runID = UUID()
        let token = runID, bridge = AgentProcess()
        process = bridge
        bridge.onEvent = { [weak self] event in
            guard let self, self.runID == token else { return }; self.consume(event)
        }
        bridge.onExit = { [weak self] in
            guard let self, self.runID == token else { return }
            self.idleWatchdog?.cancel(); self.process = nil; self.activeKey = ""
            if self.busy { self.finish(ok: false, text: "Agent 连接意外关闭，任务未完成。") }
            if self.phase == .completed, !self.queued.isEmpty {
                let next = self.queued.removeFirst(); self.queuedCount = self.queued.count
                self.submit(next.0, selection: next.1, continuing: true)
            } else if !self.queued.isEmpty {
                let unsent = "尚未执行的补充：\n" + self.queued.map(\.0).joined(separator: "\n")
                self.output += "\n\n" + unsent
                self.updateRecord { $0.messages.append(AgentMessage(role: "user", text: unsent)) }
                self.persist()
                self.queued = []; self.queuedCount = 0
            }
        }
        var prompt = text
        if !selection.isEmpty {
            prompt += "\n\n<selected_reference>\n" + String(selection.prefix(12000)) + "\n</selected_reference>"
        }
        let payload: [String: Any] = ["type": "start", "prompt": prompt, "resume": record?.sessionID as Any? ?? NSNull(),
            "config": ["baseURL": config.baseURL, "key": key, "model": config.model, "auth": config.auth,
                       "workspace": config.workspace, "stateDirectory": store.root.appendingPathComponent("claude").path]]
        do { try bridge.start(payload, runtime: runtime); resetWatchdog() }
        catch { process = nil; activeKey = ""; finish(ok: false, text: error.localizedDescription); throw error }
        persist()
    }
    func consume(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if busy { resetWatchdog() }
        switch type {
        case "session":
            if let id = event["id"] as? String { updateRecord { $0.sessionID = id } }; status = "正在执行任务……"; persist()
        case "message_start": output = ""
        case "delta": output += redacted(event["text"] as? String ?? "")
        case "status": status = redacted(event["text"] as? String ?? "正在执行……")
        case "activity":
            let names = ["Read": "读取文件", "Write": "写入文件", "Edit": "修改文件", "Glob": "查找文件", "Grep": "搜索内容", "Bash": "执行命令", "AskUserQuestion": "等待补充", "mcp__hello__search": "联网搜索", "mcp__hello__weather": "查询天气"]
            let tool = event["tool"] as? String ?? ""
            let detail = redacted(event["detail"] as? String ?? "")
            let entry = (names[tool] ?? tool) + (detail.isEmpty ? "" : " · " + String(detail.prefix(180)))
            activities.append(entry); activities = Array(activities.suffix(30)); status = entry
        case "permission":
            guard let id = event["id"] as? String, let tool = event["tool"] as? String, let input = event["input"] as? [String: Any] else { return }
            permissions.append(AgentPermission(id: id, tool: tool, input: input)); phase = .waiting
            status = tool == "AskUserQuestion" ? "需要你补充信息" : "请确认这次操作"; visible = true; idleWatchdog?.cancel()
        case "request_cancelled":
            permissions.removeAll { $0.id == event["id"] as? String }
            if busy && permissions.isEmpty { phase = .running; resetWatchdog() }
        case "lookup": startLookup(event)
        case "result":
            if let id = event["session"] as? String { updateRecord { $0.sessionID = id } }
            finish(ok: event["ok"] as? Bool ?? false, text: redacted(event["text"] as? String ?? "任务没有返回结果。"))
        case "error": finish(ok: false, text: redacted(event["text"] as? String ?? "Agent 执行失败。")); process?.cancel()
        default: break
        }
    }
    private func startLookup(_ event: [String: Any]) {
        guard let id = event["id"] as? String, let kind = event["kind"] as? String else { return }
        let query = event[kind == "weather" ? "city" : "query"] as? String ?? ""
        let token = runID
        status = kind == "weather" ? "正在查询天气……" : "正在搜索 \(query)……"
        lookups[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.lookups[id] = nil }
            do {
                let found = try await self.lookup(kind, query)
                guard !Task.isCancelled, self.runID == token, self.busy else { return }
                for source in found where !self.sources.contains(where: { $0.url == source.url }) { self.sources.append(source) }
                let objects = found.map { ["title": $0.title, "url": $0.url, "content": $0.content] }
                self.process?.send(["type": "reply", "id": id, "sources": objects])
            } catch {
                guard !Task.isCancelled, self.runID == token else { return }
                self.process?.send(["type": "reply", "id": id, "error": self.redacted(error.localizedDescription)])
            }
        }
    }
    func reply(_ permission: AgentPermission, allow: Bool, answers: [String: String] = [:]) {
        guard permissions.contains(where: { $0.id == permission.id }) else { return }
        process?.send(["type": "reply", "id": permission.id, "allow": allow, "answers": answers])
        permissions.removeAll { $0.id == permission.id }
        phase = permissions.isEmpty ? .running : .waiting
        status = allow ? "已确认，继续执行……" : "已拒绝，等待 Agent 调整……"
        if permissions.isEmpty { resetWatchdog() }
    }
    func stop() {
        guard busy else { return }
        process?.cancel(); runID = UUID(); process = nil
        idleWatchdog?.cancel(); lookups.values.forEach { $0.cancel() }; lookups = [:]
        permissions = []; phase = .stopped; status = "任务已停止。"
        if !queued.isEmpty { output += "\n\n未执行的补充：\n" + queued.map(\.0).joined(separator: "\n") }
        queued = []; queuedCount = 0
        updateRecord { $0.state = "已停止"; if !output.isEmpty { $0.messages.append(AgentMessage(role: "assistant", text: output)) } }
        activeKey = ""; persist()
    }
    private func finish(ok: Bool, text: String) {
        guard busy else { return }
        idleWatchdog?.cancel(); permissions = []
        phase = ok ? .completed : .failed; status = ok ? "任务完成" : "任务未完成"; output = text
        updateRecord { $0.state = status; $0.messages.append(AgentMessage(role: "assistant", text: text)) }; persist()
    }
    func select(_ id: UUID) {
        guard !busy else { return }; selectedID = id; output = ""; activities = []; sources = []
        phase = .idle; status = "可以继续这个任务。"; visible = true
    }
    func newTask() {
        guard !busy else { return }; selectedID = nil; output = ""; activities = []; sources = []
        pendingSubmission = nil; pendingSelection = ""
        phase = .idle; status = "说出任务，让 Hello 帮你完成。"; continueNextVoice = false
    }
    func clearHistory() {
        guard !busy else { return }; newTask(); records = []; persist()
        do {
            let sessions = store.root.appendingPathComponent("claude")
            if FileManager.default.fileExists(atPath: sessions.path) { try FileManager.default.removeItem(at: sessions) }
        } catch { storageError = "会话缓存未完全清除：" + error.localizedDescription }
    }
    private func updateRecord(_ mutate: (inout AgentTaskRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == selectedID }) else { return }; mutate(&records[index])
    }
    private func persist() {
        do { try AgentConfigurationStore.writePrivate(JSONEncoder().encode(records), to: store.root.appendingPathComponent("tasks.json")); storageError = "" }
        catch { storageError = "任务记录未保存：" + error.localizedDescription }
    }
    private func redacted(_ text: String) -> String { activeKey.isEmpty ? text : text.replacingOccurrences(of: activeKey, with: "[已隐藏密钥]") }
    private func resetWatchdog() {
        idleWatchdog?.cancel()
        guard permissions.isEmpty else { return }
        let token = runID
        idleWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            guard let self, self.runID == token, self.busy else { return }
            self.finish(ok: false, text: "Agent 已超过 5 分钟没有返回进度。连接已停止，可检查网络后继续任务。")
            self.process?.cancel()
        }
    }
}
