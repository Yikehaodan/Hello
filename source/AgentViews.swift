import SwiftUI
import AppKit

extension Notification.Name {
    static let helloShowAgent = Notification.Name("helloShowAgent")
    static let helloShowAgentSettings = Notification.Name("helloShowAgentSettings")
}

struct AgentBubbleView: View {
    @ObservedObject var agent: AgentSession
    @State private var draft = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text("Hello Agent").font(.system(size: 16, weight: .semibold))
                if agent.busy { ProgressView().controlSize(.small) }
                Spacer()
                Menu {
                    Button("新任务") { agent.newTask() }.disabled(agent.busy)
                    ForEach(agent.records) { item in Button(item.title) { agent.select(item.id) }.disabled(agent.busy) }
                } label: { Image(systemName: "clock.arrow.circlepath") }.menuStyle(.borderlessButton).frame(width: 24).help("任务记录")
                Button { agent.showSettings = true } label: { Image(systemName: "gearshape") }.help("Agent 模型设置")
                Button { agent.visible = false } label: { Image(systemName: "xmark") }.help("隐藏气泡，任务继续执行")
            }.buttonStyle(.plain).padding(18)
            Divider()
            HStack {
                Text(agent.status).font(.system(size: 12)).foregroundStyle(agent.phase == .failed ? .orange : .secondary).lineLimit(2)
                Spacer()
                if agent.queuedCount > 0 { Text("\(agent.queuedCount) 条待继续").font(.caption) }
                if agent.busy { Button("停止") { agent.stop() }.controlSize(.small) }
            }.padding(.horizontal, 18).padding(.vertical, 10)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if agent.record == nil && agent.output.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("说出你要完成的事").font(.title3.weight(.medium))
                                Text("搜索资料、整理文件、生成内容。Fn + Space 开始录音，再按 Fn 提交。")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                Button("配置模型服务") { agent.showSettings = true }
                            }.padding(.vertical, 18)
                        }
                        ForEach(agent.record?.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(message.role == "user" ? "你" : "Hello").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if message.role == "assistant" {
                                    HStack {
                                        Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }.controlSize(.small)
                                        Button("打开工作目录") { NSWorkspace.shared.open(URL(fileURLWithPath: agent.store.configuration.workspace)) }.controlSize(.small)
                                    }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.role == "user" ? Color.blue.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if !agent.activities.isEmpty {
                            DisclosureGroup("执行过程 · \(agent.activities.count) 步") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(agent.activities.enumerated()), id: \.offset) { _, entry in
                                        Text(entry).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.system(size: 12))
                        }
                        if !agent.output.isEmpty && (agent.busy || agent.record == nil || agent.pendingSubmission != nil) {
                            Text(agent.output).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if agent.pendingSubmission != nil {
                            Button("重新提交任务") { agent.retrySubmission() }.buttonStyle(.borderedProminent)
                        }
                        ForEach(agent.permissions) { permission in
                            AgentPermissionView(permission: permission) { allow, answers in agent.reply(permission, allow: allow, answers: answers) }
                        }
                        if !agent.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("搜索来源").font(.caption.weight(.semibold))
                                ForEach(agent.sources) { source in
                                    if let url = URL(string: source.url), AnswerSource.validURL(source.url) {
                                        Link(source.title, destination: url).font(.system(size: 12)).lineLimit(2)
                                    }
                                }
                            }
                        }
                        if !agent.storageError.isEmpty { Text(agent.storageError).font(.caption).foregroundStyle(.orange) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(18)
                }.onChange(of: agent.record?.messages.count) { _, _ in scroll.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: agent.permissions.count) { _, count in if count > 0 { scroll.scrollTo("bottom", anchor: .bottom) } }
            }
            Divider()
            HStack(spacing: 10) {
                Button { agent.continueNextVoice = agent.record != nil; agent.onVoice?() } label: { Image(systemName: "mic.fill") }
                    .help("继续说 · Fn + Space")
                TextField(agent.busy ? "补充要求，将在当前步骤后继续" : "输入任务或继续追问…", text: $draft).textFieldStyle(.roundedBorder).onSubmit(send)
                Button(agent.busy ? "排队" : "发送", action: send).buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16)
        }.frame(width: 640, height: 560).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1)))
            .onExitCommand { agent.visible = false }
            .sheet(isPresented: $agent.showSettings) { AgentSettingsView(agent: agent) }
    }
    private func send() { let text = draft; draft = ""; agent.submit(text) }
}

struct AgentPermissionView: View {
    let permission: AgentPermission
    let reply: (Bool, [String: String]) -> Void
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(permission.tool == "AskUserQuestion" ? "需要补充信息" : "允许这次操作？", systemImage: "hand.raised").font(.headline)
            if permission.tool == "AskUserQuestion" {
                ForEach(Array(permission.questions.enumerated()), id: \.offset) { _, question in
                    if let title = question["question"] as? String {
                        Text(title).font(.system(size: 13))
                        let options = question["options"] as? [[String: Any]] ?? []
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            if let label = option["label"] as? String {
                                Button {
                                    if question["multiSelect"] as? Bool == true {
                                        var selected = (answers[title] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty }
                                        if selected.contains(label) { selected.removeAll { $0 == label } } else { selected.append(label) }
                                        answers[title] = selected.joined(separator: ", ")
                                    } else { answers[title] = label }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(label)
                                        if let detail = option["description"] as? String { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.bordered)
                            }
                        }
                        TextField("输入或补充回答", text: Binding(get: { answers[title] ?? "" }, set: { answers[title] = $0 })).textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let path = permission.input["file_path"] as? String {
                            Text(permission.tool == "Write" ? "写入文件" : "修改文件").font(.subheadline.weight(.medium))
                            Text(path).font(.system(size: 12)).textSelection(.enabled)
                        }
                        if permission.tool == "Write", let content = permission.input["content"] as? String {
                            Text(content).font(.system(size: 12)).textSelection(.enabled)
                        } else if permission.tool == "Edit" {
                            Text("原内容").font(.caption).foregroundStyle(.secondary)
                            Text(permission.input["old_string"] as? String ?? "").font(.system(size: 12)).textSelection(.enabled)
                            Text("替换为").font(.caption).foregroundStyle(.secondary)
                            Text(permission.input["new_string"] as? String ?? "").font(.system(size: 12)).textSelection(.enabled)
                            if permission.input["replace_all"] as? Bool == true { Text("将替换全部匹配内容").font(.caption).foregroundStyle(.orange) }
                        } else if permission.tool == "Bash" {
                            Text(permission.input["description"] as? String ?? "运行命令").font(.subheadline.weight(.medium))
                            Text(permission.input["command"] as? String ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        } else if permission.tool != "Write" {
                            Text(permission.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
            }
            HStack {
                Button("拒绝") { reply(false, [:]) }
                Button(permission.tool == "AskUserQuestion" ? "提交回答" : "允许这一次") { reply(true, answers) }
                    .buttonStyle(.borderedProminent)
                    .disabled(permission.tool == "AskUserQuestion" && permission.questions.contains { question in
                        (answers[question["question"] as? String ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
            }
        }.padding(14).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AgentSettingsView: View {
    @ObservedObject var agent: AgentSession
    @State private var config = AgentConfiguration()
    @State private var key = ""
    @State private var message = ""
    @State private var checking = false
    @State private var probe: AgentProcess?
    @State private var clearConfirmation = false
    @State private var timeout: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Agent 模型").font(.title2.weight(.semibold)); Spacer(); Button("完成") { agent.showSettings = false } }
            Text("模型服务需支持 Anthropic Messages 和工具调用。普通听写的文字服务可单独配置。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("DeepSeek") { if !config.baseURL.hasPrefix("https://api.deepseek.com/") { key = "" }; config.baseURL = "https://api.deepseek.com/anthropic"; config.model = "deepseek-flash"; config.auth = "bearer" }
                Button("Anthropic") { if config.baseURL != "https://api.anthropic.com" { key = "" }; config.baseURL = "https://api.anthropic.com"; config.model = ""; config.auth = "apiKey" }
                Button("导入 Hello 文字服务") {
                    do { let imported = try AgentConfigurationStore.importing(Gateway()); config.baseURL = imported.0.baseURL; config.model = imported.0.model; config.auth = imported.0.auth; key = imported.1; message = "已导入 DeepSeek Key，请测试并保存。" }
                    catch { message = error.localizedDescription }
                }
            }.disabled(checking || agent.busy)
            Group {
                LabeledContent("服务地址") { TextField("Base URL", text: $config.baseURL) }
                LabeledContent("API Key") { SecureField("填写服务商提供的密钥", text: $key) }
                LabeledContent("模型名称") { TextField("以服务商提供的名称为准", text: $config.model) }
                Picker("鉴权方式", selection: $config.auth) { Text("Bearer Token").tag("bearer"); Text("API Key").tag("apiKey") }
                HStack {
                    TextField("工作目录", text: $config.workspace)
                    Button("选择…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { config.workspace = url.path }
                    }
                }
            }.textFieldStyle(.roundedBorder).disabled(checking || agent.busy)
            Text("API Key 保存在 macOS 钥匙串。Agent 会向所选服务发送任务和执行所需内容；写文件和命令操作会在气泡中请求确认。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("保存") { do { try agent.store.save(config, key: key); message = "已保存，下次任务生效。" } catch { message = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(checking)
                Button(checking ? "正在验证…" : "测试模型与工具") { test() }
                if checking { Button("取消测试") { cancelTest(); message = "测试已取消。" } }
            }.disabled(agent.busy)
            Text("测试仅在临时目录读取随机测试文件，会产生少量模型用量。不会修改你的工作目录。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text("任务记录保存在此 Mac，独立于听写历史。可以继续旧任务，或清空任务记录和会话缓存。")
                .font(.caption).foregroundStyle(.secondary)
            Button("清空 Agent 任务记录…") { clearConfirmation = true }.disabled(agent.busy || checking)
        }.padding(24).frame(width: 550).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { config = agent.store.configuration; do { key = try agent.store.key() } catch { message = error.localizedDescription } }
            .onDisappear { cancelTest() }
            .alert("清空 Agent 任务记录？", isPresented: $clearConfirmation) {
                Button("取消", role: .cancel) {}; Button("清空", role: .destructive) { agent.clearHistory() }
            } message: { Text("将删除 Hello 保存的 Agent 对话和恢复会话；工作目录中的文件不会删除。") }
    }
    private func cancelTest() { timeout?.cancel(); timeout = nil; probe?.cancel(); probe = nil; checking = false }
    private func test() {
        guard !checking else { return }
        do {
            var validated = try config.validated(key: key)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hello-agent-probe-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let secret = UUID().uuidString
            try Data(secret.utf8).write(to: directory.appendingPathComponent("probe.txt"))
            validated.workspace = directory.path
            let bridge = AgentProcess(); probe = bridge; checking = true; message = "正在验证模型连接及文件读取工具……"
            var readObserved = false, resultObserved = false
            bridge.onEvent = { [weak bridge] event in
                if event["type"] as? String == "activity", event["tool"] as? String == "Read" { readObserved = true }
                if event["type"] as? String == "permission", let id = event["id"] as? String { bridge?.send(["type": "reply", "id": id, "allow": false]) }
                if event["type"] as? String == "result" {
                    resultObserved = true
                    let passed = event["ok"] as? Bool == true && readObserved && (event["text"] as? String ?? "").contains(secret)
                    message = passed ? "验证成功：模型通过工具读取了测试文件并返回正确结果。请保存配置。" : "模型未完成工具验证：" + (event["text"] as? String ?? "未返回结果")
                }
                if event["type"] as? String == "error" { resultObserved = true; message = event["text"] as? String ?? "测试失败。" }
            }
            bridge.onExit = {
                if checking && !resultObserved { message = "Agent 未正常完成测试，请检查运行组件和模型配置。" }
                checking = false; probe = nil; timeout?.cancel(); try? FileManager.default.removeItem(at: directory)
            }
            try bridge.start(["type": "start", "test": true, "prompt": "使用 Read 工具读取当前目录 probe.txt，只回复文件原文。",
                "config": ["baseURL": validated.baseURL, "key": key, "model": validated.model, "auth": validated.auth,
                    "workspace": directory.path, "stateDirectory": directory.appendingPathComponent("state").path]])
            timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                bridge.cancel(); checking = false; message = "测试超时，请检查网络或模型兼容性。"
            }
        } catch { checking = false; probe = nil; message = error.localizedDescription }
    }
}
