import SwiftUI
import AppKit

struct ServiceSettingsView: View {
    @ObservedObject var model: VoiceModel
    @State private var base = Gateway.defaultBase
    @State private var key = ""
    @State private var name = Gateway.defaultModel
    @State private var message = ""
    @State private var failed = false
    @State private var checking = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var qwenKey = ""
    @State private var qwenEndpoint = CloudSpeechConfiguration.defaultQwenEndpoint
    @State private var qwenMessage = ""
    @State private var qwenFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("本地听写可以离线使用。自动整理、翻译和上下文听写需要配置文字服务。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("文字服务").font(.headline)
                    Spacer()
                    Button("使用 DeepSeek 官方") {
                        if URL(string: base)?.host?.lowercased() != "api.deepseek.com" { key = "" }
                        base = Gateway.defaultBase; name = Gateway.defaultModel; message = ""
                    }
                }
                Text("默认使用 DeepSeek 官方，也可填写其他兼容 Chat Completions 的服务。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("服务地址，例如 https://api.deepseek.com", text: $base)
                SecureField("API Key", text: $key)
                TextField("模型名称，以服务商提供的名称为准", text: $name)
            }.padding(16).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textFieldStyle(RoundedInputStyle()).disabled(checking || model.busy)
            Text("上下文截图需要模型支持图片输入。密钥仅写入当前 Mac 的配置文件；请求会发往上面填写的服务。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("保存配置") { save() }.buttonStyle(SurfaceButtonStyle(prominent: true))
                Button(checking ? "正在测试…" : "测试连接") { testConnection() }
                Button("打开配置目录") { openConfiguration() }
            }.disabled(model.busy || checking)
            Text("测试连接只发送一条固定测试文字，不会保存配置或发送历史记录。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if !message.isEmpty {
                Label(message, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(failed ? Color.orange : Color.green)
            }
            Divider()
            Text("Agent · Fn + Space").font(.headline)
            Text("Agent 可单独配置模型服务，支持 DeepSeek 的 Anthropic 兼容接口。执行进度显示在紧凑浮窗，结果在独立窗口展示，记录统一保存在历史记录。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("配置 Agent 模型") { NotificationCenter.default.post(name: .helloShowAgentSettings, object: nil) }
            Divider()
            Text("千问百炼语音 · 默认").font(.headline)
            Text("用于 Fn 口述的 Qwen3-ASR-Flash 非流式模型。停止录音后整段通过 HTTPS 提交，一次返回完整文字；会使用词典和个人记忆作为识别上下文。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                SecureField("百炼 API Key", text: $qwenKey)
                TextField("业务空间 HTTPS 地址", text: $qwenEndpoint)
            }.padding(16).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textFieldStyle(RoundedInputStyle()).disabled(model.busy)
            HStack {
                Button("保存并设为默认") { saveQwenSpeech() }.buttonStyle(SurfaceButtonStyle(prominent: true))
                Text("北京地域：¥0.00022 / 秒，输出文字不单独计费")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.disabled(model.busy)
            if !qwenMessage.isEmpty {
                Label(qwenMessage, systemImage: qwenFailed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(qwenFailed ? Color.orange : Color.green)
            }
            Divider()
            Text("豆包云端语音（可选）").font(.headline)
            Text("在配置目录放入 doubao.env，填写 DOUBAO_API_KEY，然后重新打开 Hello。未配置时使用本地模型。配置示例见仓库 examples 目录。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("配置目录").font(.headline)
            Text(AppPaths.data.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if AppPaths.gateway.deletingLastPathComponent() != AppPaths.data {
                Text("文字服务配置由环境变量指定：\(AppPaths.gateway.path)")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        }.buttonStyle(SurfaceButtonStyle(compact: true)).tint(LVTheme.accent).onAppear {
            if let gateway = try? Gateway() { base = gateway.base; key = gateway.key; name = gateway.model }
            if let qwen = CloudSpeechConfiguration.loadQwen() {
                qwenKey = qwen.apiKey
                qwenEndpoint = qwen.endpoint?.absoluteString ?? CloudSpeechConfiguration.defaultQwenEndpoint
            }
        }.onDisappear {
            connectionTask?.cancel(); connectionTask = nil; checking = false
        }
    }
    private func testConnection() {
        do {
            let gateway = try Gateway(base: base, key: key, model: name)
            checking = true; message = ""
            connectionTask = Task { @MainActor in
                defer { checking = false; connectionTask = nil }
                do {
                    try await gateway.testConnection()
                    guard !Task.isCancelled else { return }
                    failed = false; message = "连接成功，\(gateway.model) 已返回文字。修改后的配置需要点击保存。"
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true; message = error.localizedDescription
                }
            }
        } catch { failed = true; message = error.localizedDescription }
    }
    private func save() {
        do {
            try Gateway.saveConfiguration(base: base, key: key, model: name)
            failed = false
            message = "已保存，下次文字处理时生效。可在“个性化”中开启自动整理。"
        } catch { failed = true; message = error.localizedDescription }
    }
    private func saveQwenSpeech() {
        do {
            try CloudSpeechConfiguration.saveQwen(apiKey: qwenKey, endpoint: qwenEndpoint)
            model.reloadSpeechConfiguration(selectQwen: true)
            qwenFailed = false
            qwenMessage = "已保存，并将千问 3 非流式 ASR 设为默认语音模型。"
        } catch {
            qwenFailed = true; qwenMessage = error.localizedDescription
        }
    }
    private func openConfiguration() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.data, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(AppPaths.data)
        } catch { failed = true; message = "无法打开配置目录：" + error.localizedDescription }
    }
}
