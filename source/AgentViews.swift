import SwiftUI
import AppKit

extension Notification.Name {
    static let helloShowHistory = Notification.Name("helloShowHistory")
    static let helloShowAgentSettings = Notification.Name("helloShowAgentSettings")
}

struct AgentResultView: View {
    static let defaultSize = NSSize(width: 560, height: 580)
    static let minimumSize = NSSize(width: 480, height: 420)
    @ObservedObject var agent: AgentSession
    var close: (() -> Void)? = nil
    @State private var draft = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.busy || agent.record == nil ? "Agent" : "任务结果").font(.system(size: 19, weight: .semibold))
                    Text(agent.busy ? agent.progressTitle : agent.record == nil ? "完成后可在历史记录中查看" : agent.storageError.isEmpty ? "已保存在历史记录，可继续追问" : "记录保存失败，请复制保留结果")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(); headerActions
            }.padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if agent.record == nil && agent.output.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(LVTheme.accent)
                                    .frame(width: 64, height: 64).background(LVTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                                Text("把想做的事，说给 Hello").font(.system(size: 24, weight: .medium))
                                Text("Fn + Space 开始，再按 Fn 提交。执行进度显示在浮窗，完成后在这里阅读结果。")
                                    .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
                                Button("配置模型服务") { agent.showSettings = true }.buttonStyle(SurfaceButtonStyle())
                            }.multilineTextAlignment(.center).padding(.vertical, 42).frame(maxWidth: .infinity)
                        }
                        ForEach(agent.record?.messages ?? []) { message in
                            if message.role == "user" {
                                VStack(alignment: .leading, spacing: 9) {
                                    Label("你的任务", systemImage: "text.bubble").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    Text(message.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let context = message.contextStatus {
                                        Text(context).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }.padding(18).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            } else {
                                VStack(alignment: .leading, spacing: 22) {
                                    MarkdownView(text: message.text)
                                    if let sources = message.sources { AgentSourceCards(sources: sources) }
                                    HStack(spacing: 16) {
                                        Button { copy(message.text) } label: { Label("复制内容", systemImage: "doc.on.doc") }
                                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: agent.store.configuration.workspace)) } label: {
                                            Label("工作目录", systemImage: "folder")
                                        }
                                    }.buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).padding(.top, 2)
                                    Divider()
                                }.padding(.horizontal, 2)
                            }
                        }
                        if agent.busy && agent.visible {
                            Label(agent.progressTitle, systemImage: "sparkles").font(.system(size: 12, weight: .medium)).foregroundStyle(LVTheme.accent)
                            if !agent.output.isEmpty { MarkdownView(text: agent.output) }
                        } else if agent.pendingSubmission != nil {
                            Text(agent.status).font(.system(size: 13)).foregroundStyle(.orange)
                            Text(agent.pendingSubmission ?? "").font(.system(size: 14)).textSelection(.enabled)
                            Button("重新提交任务") { agent.retrySubmission() }.buttonStyle(SurfaceButtonStyle(prominent: true))
                        }
                        ForEach(agent.permissions) { permission in
                            AgentPermissionView(permission: permission) { allow, answers in agent.reply(permission, allow: allow, answers: answers) }
                        }
                        if !agent.activities.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(agent.activities.enumerated()), id: \.offset) { index, entry in
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(String(index + 1)).foregroundStyle(.tertiary).frame(width: 20)
                                            Text(entry).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
                            } label: {
                                Label("执行过程 · \(agent.activities.count) 步", systemImage: "list.bullet.rectangle")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            }
                        }
                        if !agent.storageError.isEmpty { Text(agent.storageError).font(.caption).foregroundStyle(.orange) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 800, alignment: .leading).padding(20).frame(maxWidth: .infinity)
                }.onChange(of: agent.permissions.count) { _, count in
                    if count > 0 && agent.visible { scroll.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button { agent.continueNextVoice = agent.record != nil; agent.onVoice?() } label: { Image(systemName: "mic.fill") }
                    .buttonStyle(IconButtonStyle()).accessibilityLabel("继续语音输入").help("继续说 · Fn + Space")
                TextField(agent.busy ? "补充要求，当前步骤后继续" : "继续追问，或输入一个新任务…", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 14)).onSubmit(send)
                if agent.busy { Button("停止") { agent.stop() }.buttonStyle(SurfaceButtonStyle()) }
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(width: 16, height: 16) }
                    .buttonStyle(SurfaceButtonStyle(prominent: true)).tint(LVTheme.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(agent.busy ? "补充任务" : "发送任务").accessibilityLabel("发送任务")
            }.padding(12).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(LVTheme.border)).padding(16)
        }.frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(LVTheme.text).background(LVTheme.background)
            .onExitCommand(perform: dismiss)
            .sheet(isPresented: $agent.showSettings) { AgentSettingsView(agent: agent) }
    }
    private var headerActions: some View {
        HStack(spacing: 8) {
            Button { dismiss(); NotificationCenter.default.post(name: .helloShowHistory, object: nil) } label: {
                Image(systemName: "clock.arrow.circlepath")
            }.buttonStyle(IconButtonStyle()).help("在历史记录中查看全部任务")
            Button { agent.newTask() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle()).disabled(agent.busy).help("新任务")
            Button { agent.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle()).accessibilityLabel("Agent 模型设置").help("Agent 模型设置")
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).accessibilityLabel("关闭 Agent 窗口").help("关闭窗口，任务保留")
        }
    }
    private func dismiss() { agent.dismissPresentation(); close?() }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func send() { let text = draft; draft = ""; agent.submit(text) }
}

struct AgentProgressHUD: View {
    static let size = NSSize(width: 244, height: 340)
    @ObservedObject var agent: AgentSession
    private var recentActivities: [String] { Array(agent.activities.suffix(4)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.mint).font(.system(size: 14))
                Text("Agent").font(.system(size: 14, weight: .semibold))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(agent.startedAt ?? context.date)))
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                }
                Button { agent.dismissPresentation() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 26).contentShape(Rectangle())
                }.buttonStyle(HUDButtonStyle()).foregroundStyle(.white.opacity(0.6)).help("隐藏进度，任务继续执行")
            }
            Text(agent.record?.title ?? agent.pendingSubmission ?? "正在准备任务")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 9) {
                if agent.phase == .running { ProgressView().controlSize(.small).environment(\.colorScheme, .dark) }
                else { Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(.mint) }
                Text(agent.progressTitle).font(.system(size: 15, weight: .medium)).lineLimit(2)
            }.frame(minHeight: 24)
            VStack(alignment: .leading, spacing: 12) {
                if recentActivities.isEmpty {
                    Text(agent.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(3)
                } else {
                    ForEach(Array(recentActivities.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(index == recentActivities.count - 1 ? Color.mint : .white.opacity(0.25))
                                .frame(width: 5, height: 5).padding(.top, 5)
                            Text(entry).font(.system(size: 11)).foregroundStyle(.white.opacity(index == recentActivities.count - 1 ? 0.85 : 0.5))
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            HStack {
                Button { agent.presentDetails() } label: {
                    HStack(spacing: 5) {
                        Text(agent.phase == .waiting ? "查看并回复" : agent.pendingSubmission != nil ? "打开设置" : "双击展开对话")
                        Image(systemName: "arrow.up.right")
                    }.font(.system(size: 10)).frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(HUDButtonStyle()).foregroundStyle(.white.opacity(0.55)).accessibilityLabel("打开 Agent 对话")
                Spacer()
                if agent.busy {
                    Button { agent.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 9)).frame(width: 28, height: 28)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                    }.buttonStyle(HUDButtonStyle()).help("停止任务")
                }
            }
        }.foregroundStyle(.white).padding(18)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(red: 0.055, green: 0.06, blue: 0.07), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .onTapGesture(count: 2) { agent.presentDetails() }
    }
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
                                }.buttonStyle(SurfaceButtonStyle())
                            }
                        }
                        TextField("输入或补充回答", text: Binding(get: { answers[title] ?? "" }, set: { answers[title] = $0 })).textFieldStyle(RoundedInputStyle())
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
                Spacer()
                Button("拒绝") { reply(false, [:]) }
                Button(permission.tool == "AskUserQuestion" ? "提交回答" : "允许这一次") { reply(true, answers) }
                    .buttonStyle(SurfaceButtonStyle(prominent: true))
                    .disabled(permission.tool == "AskUserQuestion" && permission.questions.contains { question in
                        (answers[question["question"] as? String ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
            }
        }.buttonStyle(SurfaceButtonStyle(compact: true)).padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AgentSettingsView: View {
    @ObservedObject var agent: AgentSession
    @State private var config = AgentConfiguration()
    @State private var key = ""
    @State private var message = ""
    @State private var checking = false
    @State private var probe: AgentProcess?
    @State private var screenAllowed = AgentComputer.screenAllowed
    @State private var inputAllowed = AgentComputer.inputAllowed
    @State private var clearConfirmation = false
    @State private var timeout: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Agent 设置").font(.system(size: 24, weight: .semibold)); Spacer(); Button { agent.showSettings = false } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("关闭设置").accessibilityLabel("关闭 Agent 设置") }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("操作权限").font(.system(size: 15, weight: .semibold))
                        Picker("权限模式", selection: $config.permissionMode) {
                            Text("逐次确认").tag("default")
                            Text("无限制").tag("bypassPermissions")
                        }.pickerStyle(.segmented)
                        Text(config.permissionMode == "bypassPermissions" ? "自动允许文件、命令和屏幕操作，无需逐次点击确认。" : "写入文件、执行命令和屏幕操作前，请你确认。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Toggle("内置屏幕操控", isOn: $config.computerEnabled)
                        if config.computerEnabled {
                            Text("按需查看屏幕、点击、滚动和输入。macOS 系统授权仍需开启。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack {
                                Button { AgentComputer.openPermission(true) } label: {
                                    Label(screenAllowed ? "屏幕录制已授权" : "开启屏幕录制", systemImage: screenAllowed ? "checkmark.circle.fill" : "display")
                                }
                                Button { AgentComputer.openPermission(false) } label: {
                                    Label(inputAllowed ? "辅助功能已授权" : "开启辅助功能", systemImage: inputAllowed ? "checkmark.circle.fill" : "cursorarrow")
                                }
                            }
                        }
                    }.padding(16).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 18))
                        .disabled(checking || agent.busy)
                    Text("模型服务需支持 Anthropic Messages 和工具调用。普通听写的文字服务可单独配置。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button("DeepSeek V4.1 Flash") { if !config.baseURL.hasPrefix("https://api.deepseek.com/") { key = "" }; config.baseURL = "https://api.deepseek.com/anthropic"; config.model = "deepseek-flash"; config.auth = "bearer" }
                        Button("Anthropic") { if config.baseURL != "https://api.anthropic.com" { key = "" }; config.baseURL = "https://api.anthropic.com"; config.model = ""; config.auth = "apiKey" }
                        Button("导入 Hello 文字服务") {
                            do { let imported = try AgentConfigurationStore.importing(Gateway()); config.baseURL = imported.0.baseURL; config.model = imported.0.model; config.auth = imported.0.auth; key = imported.1; message = "已导入 DeepSeek Key，请测试并保存。" }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(checking || agent.busy)
                    Group {
                        FormField(title: "服务地址") { TextField("服务地址", text: $config.baseURL) }
                        FormField(title: "API Key") { SecureField("填写服务商提供的密钥", text: $key) }
                        FormField(title: "模型名称") { TextField("以服务商提供的名称为准", text: $config.model) }
                        FormField(title: "鉴权方式") {
                            ChoiceMenu(title: "鉴权方式", selection: $config.auth, options: [("bearer", "Bearer Token"), ("apiKey", "API Key")])
                        }
                        HStack {
                            TextField("工作目录", text: $config.workspace)
                            Button("选择…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url { config.workspace = url.path }
                            }
                        }
                    }.textFieldStyle(RoundedInputStyle()).disabled(checking || agent.busy)
                    if config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://api.deepseek.com/anthropic", config.model == "deepseek-flash" {
                        Text("已选择 DeepSeek 官方 V4.1 Flash，支持联网搜索和网页读取。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text("API Key 保存在本机，仅当前用户可读写。填写并保存后即可使用，操作按上方权限模式执行。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("测试仅在临时目录读取随机测试文件，会产生少量模型用量。不会修改你的工作目录。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    Divider()
                    Text("任务记录保存在此 Mac，可在历史记录中查看、继续或删除。这里也可以清空 Agent 对话和会话缓存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清空 Agent 任务记录…") { clearConfirmation = true }.disabled(agent.busy || checking)
                }.padding(2)
            }.scrollIndicators(.hidden)
                    HStack {
                        Button("保存") { do { try agent.store.save(config, key: key); message = "已保存，下次任务生效。" } catch { message = error.localizedDescription } }.buttonStyle(SurfaceButtonStyle(prominent: true)).disabled(checking)
                        Button(checking ? "正在验证…" : "测试模型与工具") { test() }
                        if checking { Button("取消测试") { cancelTest(); message = "测试已取消。" } }
                    }.disabled(agent.busy)
        }.padding(24).frame(width: 550, height: 620).background(LVTheme.background)
            .buttonStyle(SurfaceButtonStyle(compact: true)).tint(LVTheme.accent).foregroundStyle(LVTheme.text)
            .onAppear { config = agent.store.configuration; do { key = try agent.store.key() } catch { message = error.localizedDescription } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                screenAllowed = AgentComputer.screenAllowed; inputAllowed = AgentComputer.inputAllowed
            }
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
                if event["type"] as? String == "usage", let id = event["id"] as? String, let usage = event["usage"] as? [String: Any] {
                    NotificationCenter.default.post(name: Gateway.tokenUsageNotification, object: nil, userInfo: ["id": "agent-" + id, "usage": usage])
                }
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

struct AgentHistoryRow: View {
    @ObservedObject var agent: AgentSession
    @ObservedObject var model: VoiceModel
    let task: AgentTaskRecord
    let recordings: [HistoryEntry]
    let delete: () -> Void
    let deleteRecording: (HistoryEntry) -> Void
    @State private var expanded = false
    private var response: String { task.messages.last(where: { $0.role == "assistant" })?.text ?? "" }
    private var excerpt: String {
        for block in MarkdownDocument(response).blocks {
            if case .paragraph(let text) = block { return String(text.prefix(240)) }
        }
        return String(response.split(separator: "\n").prefix(2).joined(separator: " · ").prefix(240))
    }
    private var canOpen: Bool { !agent.busy || agent.selectedID == task.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(task.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                Text("·")
                Label("Agent", systemImage: "sparkles")
                Text("· \(task.state)")
                Spacer()
                if !response.isEmpty { CopyButton(text: response) }
                Button(action: delete) { Image(systemName: "trash").frame(width: 20, height: 20) }
                    .buttonStyle(IconButtonStyle()).disabled(agent.busy && agent.selectedID == task.id).help("删除记录")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Button { if agent.busy { agent.presentDetails() } else { agent.select(task.id) } } label: {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                        if !response.isEmpty {
                            Text((try? AttributedString(markdown: excerpt, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(excerpt))
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).lineLimit(3)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right.square").font(.system(size: 15)).foregroundStyle(LVTheme.accent)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canOpen).help("打开任务结果")
            if !recordings.isEmpty {
                DisclosureGroup("录音与上下文 · \(recordings.count) 条", isExpanded: $expanded) {
                    ForEach(recordings) { entry in
                        HistoryRow(model: model, entry: entry, hasAudio: model.library.audioURL(for: entry.id) != nil,
                            canRetry: model.library.canRetry(entry), delete: { deleteRecording(entry) })
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(16)
    }
}
