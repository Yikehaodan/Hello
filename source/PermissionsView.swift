import SwiftUI
import AppKit

extension Notification.Name {
    static let helloShowPermissions = Notification.Name("Hello.showPermissions")
}

struct PermissionWarningBanner: View {
    @ObservedObject var preferences: AppPreferences
    let enableShortcut: () -> Void
    let showDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(preferences.permissionSummary, systemImage: "exclamationmark.shield")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("查看引导", action: showDetails).buttonStyle(.link)
            }
            HStack(spacing: 10) {
                ForEach(preferences.missingPermissions) { permission in
                    Button(permission == .microphone && preferences.microphones.permission == .restricted
                           ? "查看麦克风限制" : "设置\(permission.title)") {
                        switch permission {
                        case .microphone: Task { await preferences.requestMicrophone() }
                        case .accessibility: enableShortcut()
                        case .screenCapture: preferences.requestScreenCapture()
                        }
                    }
                    .disabled(permission == .microphone && preferences.requestingMicrophone)
                }
            }.controlSize(.small)
            if let error = preferences.settingsError {
                Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A read-only overview until the user explicitly presses an authorization button.
struct PermissionChecklist: View {
    @ObservedObject var preferences: AppPreferences
    let enableShortcut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label(preferences.permissionSummary,
                      systemImage: preferences.missingPermissions.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(preferences.missingPermissions.isEmpty ? Color.green : Color.orange)
                Text("自动检测授权状态；在系统设置中允许后，这里会自动更新。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            permissionRow("麦克风", symbol: "mic", badge: "录音必需",
                          state: preferences.microphones.permission.title,
                          allowed: preferences.microphones.permission == .authorized,
                          detail: "仅在你主动开始录音后收音。拒绝后仍可在文本工作台输入文字。",
                          guidance: microphoneGuidance,
                          actionTitle: microphoneActionTitle) {
                if preferences.microphones.permission == .authorized { preferences.openMicrophonePrivacySettings() }
                else { Task { await preferences.requestMicrophone() } }
            }
            .disabled(preferences.requestingMicrophone)
            permissionRow("辅助功能", symbol: "keyboard", badge: "跨应用输入",
                          state: preferences.accessibilityAllowed ? "已允许" : "尚未允许",
                          allowed: preferences.accessibilityAllowed,
                          detail: "用于全局 Fn 快捷键、读取当前输入框或选中文字，以及把结果写回光标位置。开启个人记忆后，还会在听写结束的 30 秒内观察原输入框的纠正。未授权时可用窗口按钮录音并手动复制。",
                          guidance: "点击前往授权，在辅助功能列表中开启 Hello。若列表没有 Hello，点击“＋”添加“应用程序”里的 Hello.app。",
                          actionTitle: preferences.accessibilityAllowed ? "打开设置" : "前往授权") {
                if preferences.accessibilityAllowed { preferences.openPrivacySettings(for: .accessibility) }
                else { enableShortcut() }
            }
            permissionRow("屏幕录制", symbol: "rectangle.dashed.badge.record", badge: "可选",
                          state: preferences.screenCaptureAllowed ? "已允许" : preferences.contextScreenshots ? "待授权" : "未授权 · 可选",
                          allowed: preferences.screenCaptureAllowed,
                          needsAttention: preferences.contextScreenshots,
                          detail: "开启截图选项后，仅在上下文听写时截取当前窗口。截图和输入框文字会发送到你配置的文字服务，帮助校对口述；截图可随历史保存在本机。",
                          guidance: "在“屏幕与系统音频录制”（或“屏幕录制”）中开启 Hello。若系统要求退出并重新打开，请按提示操作。",
                          actionTitle: preferences.screenCaptureAllowed ? "打开设置" : "前往授权") {
                if preferences.screenCaptureAllowed { preferences.openPrivacySettings(for: .screenCapture) }
                else { preferences.requestScreenCapture() }
            }
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

    private var microphoneActionTitle: String {
        switch preferences.microphones.permission {
        case .notDetermined: return preferences.requestingMicrophone ? "等待系统确认…" : "允许麦克风"
        case .denied, .authorized: return "打开设置"
        case .restricted: return "查看限制说明"
        }
    }

    private var microphoneGuidance: String {
        switch preferences.microphones.permission {
        case .notDetermined: return "点击允许麦克风，然后在系统弹窗中选择允许。"
        case .denied: return "麦克风已被拒绝。点击打开设置，在麦克风列表中开启 Hello。"
        case .restricted: return "麦克风受到系统或设备管理策略限制，需要联系设备管理员解除。"
        case .authorized: return ""
        }
    }

    private func permissionRow(_ title: String, symbol: String, badge: String, state: String,
                               allowed: Bool, needsAttention: Bool = true, detail: String,
                               guidance: String, actionTitle: String,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.indigo)
                .frame(width: 38, height: 38).background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(badge).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Label(state, systemImage: allowed ? "checkmark.circle.fill" : needsAttention ? "exclamationmark.circle.fill" : "circle")
                        .font(.system(size: 11)).foregroundStyle(allowed ? Color.green : needsAttention ? Color.orange : Color.secondary)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                if !allowed && needsAttention {
                    Text(guidance).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(actionTitle, action: action).controlSize(.small)
                    .accessibilityLabel(title + "：" + actionTitle)
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
                    Text("Hello 权限设置").font(.system(size: 23, weight: .semibold))
                    Text("查看授权状态，按需开启每项权限。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            ScrollView { PermissionChecklist(preferences: preferences, enableShortcut: enableShortcut) }
            HStack {
                Text("你可以随时在“设置 → 权限”中调整。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(preferences.missingPermissions.isEmpty ? "完成" : "稍后设置", action: close)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.indigo)
            }
        }.padding(28).frame(width: 600, height: 690)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
