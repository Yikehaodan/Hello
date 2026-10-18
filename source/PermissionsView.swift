import SwiftUI
import AppKit

/// A read-only overview until the user explicitly presses an authorization button.
struct PermissionChecklist: View {
    @ObservedObject var preferences: AppPreferences
    let enableShortcut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            permissionRow("麦克风", symbol: "mic", badge: "录音必需",
                          state: preferences.microphones.permission.title,
                          allowed: preferences.microphones.permission == .authorized,
                          detail: "仅在你主动开始录音后收音。拒绝后仍可在文本工作台输入文字。",
                          actionTitle: preferences.microphones.permission == .denied ? "打开设置" : "允许麦克风") {
                Task { await preferences.requestMicrophone() }
            }
            .disabled(preferences.requestingMicrophone)
            permissionRow("辅助功能", symbol: "keyboard", badge: "跨应用输入",
                          state: preferences.accessibilityAllowed ? "已允许" : "尚未允许",
                          allowed: preferences.accessibilityAllowed,
                          detail: "用于全局 Fn 快捷键、读取当前输入框或选中文字，以及把结果写回光标位置。未授权时可用窗口按钮录音并手动复制。",
                          actionTitle: "前往授权", action: enableShortcut)
            permissionRow("屏幕录制", symbol: "rectangle.dashed.badge.record", badge: "可选",
                          state: preferences.screenCaptureAllowed ? "已允许" : "尚未允许",
                          allowed: preferences.screenCaptureAllowed,
                          detail: "开启截图选项后，仅在上下文听写时截取当前窗口。截图和输入框文字会发送到你配置的文字服务，帮助校对口述；截图可随历史保存在本机。",
                          actionTitle: "前往授权", action: preferences.requestScreenCapture)
            Toggle("上下文听写附带窗口截图", isOn: $preferences.contextScreenshots)
                .toggleStyle(.switch).font(.system(size: 13))
            Text("截图开关与系统授权相互独立。两者都开启后才会截图；不授权也能使用普通听写、翻译和语音提问。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = preferences.settingsError {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Text("系统设置 → 隐私与安全性")
                Spacer()
                Button("重新检查", action: preferences.refresh).buttonStyle(.link)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            Text("授权后返回 Hello 会自动更新状态。若仍未生效，请退出并重新打开；更新或移动应用后，可能需要重新添加 Hello。系统中屏幕权限也可能显示为“屏幕与系统音频录制”，Hello 不录制系统音频。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { preferences.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in preferences.refresh() }
    }

    private func permissionRow(_ title: String, symbol: String, badge: String, state: String,
                               allowed: Bool, detail: String, actionTitle: String,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.indigo)
                .frame(width: 38, height: 38).background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(badge).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Label(state, systemImage: allowed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11)).foregroundStyle(allowed ? Color.green : Color.secondary)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                if !allowed {
                    Button(actionTitle, action: action).controlSize(.small)
                        .accessibilityLabel(title + "：" + actionTitle)
                }
            }
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PermissionWelcome: View {
    @ObservedObject var preferences: AppPreferences
    let enableShortcut: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "door.left.hand.open").font(.system(size: 28)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 Hello").font(.system(size: 23, weight: .semibold))
                    Text("先了解权限，再开始第一句话。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            ScrollView { PermissionChecklist(preferences: preferences, enableShortcut: enableShortcut) }
            HStack {
                Text("你可以随时在“设置 → 权限”中调整。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(preferences.needsRequiredPermissions ? "稍后设置" : "开始使用", action: close)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.indigo)
            }
        }.padding(28).frame(width: 600, height: 690)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
