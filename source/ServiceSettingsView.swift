import SwiftUI
import AppKit

struct ServiceSettingsView: View {
    @ObservedObject var model: VoiceModel
    @State private var base = ""
    @State private var key = ""
    @State private var name = ""
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("本地听写可以离线使用。自动整理、翻译、问答和上下文听写需要配置文字服务。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("兼容 Chat Completions 的 HTTPS 服务").font(.headline)
                TextField("服务地址，例如 https://your-provider.example/v1", text: $base)
                SecureField("API Key", text: $key)
                TextField("模型名称，以服务商提供的名称为准", text: $name)
            }.textFieldStyle(.roundedBorder)
            Text("上下文截图需要模型支持图片输入。密钥仅写入当前 Mac 的配置文件；请求会发往上面填写的服务。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("保存配置") { save() }.buttonStyle(.borderedProminent)
                Button("打开配置目录") { openConfiguration() }
            }.disabled(model.busy)
            if !message.isEmpty {
                Label(message, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(failed ? Color.orange : Color.green)
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
        }.onAppear {
            if let gateway = try? Gateway() { base = gateway.base; key = gateway.key; name = gateway.model }
        }
    }
    private func save() {
        do {
            try Gateway.saveConfiguration(base: base, key: key, model: name)
            failed = false
            message = "已保存，下次文字处理时生效。可在“个性化”中开启自动整理。"
        } catch { failed = true; message = error.localizedDescription }
    }
    private func openConfiguration() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.data, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(AppPaths.data)
        } catch { failed = true; message = "无法打开配置目录：" + error.localizedDescription }
    }
}
