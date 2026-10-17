import AppKit
import AVFoundation
import Combine
import ServiceManagement
import ApplicationServices

enum LoginItemState: Equatable {
    case notRegistered, enabled, requiresApproval, notFound, unknown

    var detail: String {
        switch self {
        case .notRegistered: return "关闭。登录 Mac 后可手动打开Knock。"
        case .enabled: return "已开启，下次登录 Mac 时自动启动。"
        case .requiresApproval: return "等待系统允许。请在系统设置的登录项中开启Knock。"
        case .notFound: return "macOS 未找到此应用。请从完整的Knock.app 中打开后重试。"
        case .unknown: return "暂时无法确认登录启动状态，请检查系统设置。"
        }
    }
}

@MainActor
protocol LoginItemManaging: AnyObject {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
final class SystemLoginItemManager: LoginItemManaging {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct MicrophoneInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let isDefault: Bool
}

struct MicrophoneSnapshot: Equatable {
    let devices: [MicrophoneInfo]
    let permission: MicrophonePermission

    var defaultName: String { devices.first(where: \.isDefault)?.name ?? "未找到系统默认麦克风" }
    var detail: String {
        switch permission {
        case .denied: return "麦克风权限已关闭，请在系统设置的隐私与安全性中允许Knock。"
        case .restricted: return "麦克风受到系统或设备管理策略限制。"
        case .notDetermined: return "首次开始录音时会请求麦克风权限。当前跟随系统声音输入。"
        case .authorized:
            return devices.isEmpty ? "未发现可用麦克风，请连接设备后刷新。" : "当前跟随系统声音输入。可在系统设置中选择设备。"
        }
    }
}

enum MicrophonePermission: Equatable {
    case notDetermined, authorized, denied, restricted
    var title: String {
        switch self {
        case .notDetermined: return "尚未授权"
        case .authorized: return "已允许"
        case .denied: return "已关闭"
        case .restricted: return "系统限制"
        }
    }
}

enum MicrophoneCatalog {
    // Discovery and authorizationStatus only read state; neither starts recording nor requests permission.
    static func snapshot() -> MicrophoneSnapshot {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        var seen = Set<String>()
        let microphones = discovery.devices.filter { $0.isConnected && seen.insert($0.uniqueID).inserted }.map {
            MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let permission: MicrophonePermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .authorized
        case .denied: permission = .denied
        case .restricted: permission = .restricted
        case .notDetermined: permission = .notDetermined
        @unknown default: permission = .restricted
        }
        return MicrophoneSnapshot(devices: microphones, permission: permission)
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published private(set) var loginItemState: LoginItemState
    @Published private(set) var loginItemError: String?
    @Published var weatherCity: String {
        didSet { defaults.set(weatherCity, forKey: "weatherCity") }
    }
    @Published var contextScreenshots: Bool {
        didSet { defaults.set(contextScreenshots, forKey: "contextScreenshots") }
    }
    @Published private(set) var screenCaptureAllowed: Bool
    @Published private(set) var accessibilityAllowed: Bool
    @Published private(set) var requestingMicrophone = false
    @Published private(set) var permissionIntroDismissed: Bool
    var needsRequiredPermissions: Bool { microphones.permission != .authorized || !accessibilityAllowed }
    @Published private(set) var showDockIcon: Bool
    @Published private(set) var microphones: MicrophoneSnapshot
    @Published private(set) var settingsError: String?

    // AppDelegate owns activation policy. This callback fires only after an explicit change.
    var onDockVisibilityChange: ((Bool) -> Void)?
    var launchAtLogin: Bool { loginItemState == .enabled }
    var loginItemDetail: String { loginItemError ?? loginItemState.detail }
    var loginItemNeedsReview: Bool { loginItemState == .requiresApproval || loginItemState == .notFound || loginItemState == .unknown }

    private let defaults: UserDefaults
    private let loginItems: any LoginItemManaging
    private let microphoneProvider: () -> MicrophoneSnapshot
    private let openURL: (URL) -> Bool
    private let accessibilityProvider: () -> Bool
    private let screenCaptureProvider: () -> Bool
    private let screenCaptureRequest: () -> Bool
    private let microphoneRequest: () async -> Bool
    private static let dockKey = "showDockIcon"

    init(defaults: UserDefaults = .standard,
         loginItems: (any LoginItemManaging)? = nil,
         microphoneProvider: @escaping () -> MicrophoneSnapshot = MicrophoneCatalog.snapshot,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         accessibilityProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
         screenCaptureProvider: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         screenCaptureRequest: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         microphoneRequest: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        let service = loginItems ?? SystemLoginItemManager()
        self.defaults = defaults
        self.weatherCity = defaults.string(forKey: "weatherCity") ?? ""
        self.contextScreenshots = defaults.object(forKey: "contextScreenshots") as? Bool ?? false
        self.loginItems = service
        self.microphoneProvider = microphoneProvider
        self.openURL = openURL
        self.accessibilityProvider = accessibilityProvider
        self.screenCaptureProvider = screenCaptureProvider
        self.screenCaptureRequest = screenCaptureRequest
        self.microphoneRequest = microphoneRequest
        self.accessibilityAllowed = accessibilityProvider()
        self.screenCaptureAllowed = screenCaptureProvider()
        self.permissionIntroDismissed = defaults.bool(forKey: "knockPermissionIntroDismissed")
        self.loginItemState = service.state
        self.showDockIcon = defaults.object(forKey: Self.dockKey) as? Bool ?? true
        self.microphones = microphoneProvider()
    }

    // Safe to call when settings opens or the app becomes active. Never changes login registration.
    func refresh() {
        screenCaptureAllowed = screenCaptureProvider()
        accessibilityAllowed = accessibilityProvider()
        let updatedState = loginItems.state
        if loginItemState != updatedState { loginItemError = nil }
        loginItemState = updatedState
        microphones = microphoneProvider()
    }

    // Bind the settings toggle setter to this method. Never invoke from startup or restoration.
    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        loginItemState = loginItems.state
        if enabled && loginItemState == .requiresApproval { return }
        if enabled && loginItemState == .enabled { return }
        if !enabled && loginItemState == .notRegistered { return }
        do {
            if enabled { try loginItems.register() }
            else { try loginItems.unregister() }
            loginItemState = loginItems.state
        } catch {
            // Registration success is not equivalent to user approval. Always report actual OS state.
            loginItemState = loginItems.state
            if loginItemState == .requiresApproval {
                loginItemError = loginItemState.detail
            } else {
                let action = enabled ? "开启" : "关闭"
                loginItemError = "无法\(action)登录启动。\(error.localizedDescription)"
            }
        }
    }

    func openLoginItemSettings() { loginItems.openSettings() }

    func dismissPermissionIntro() {
        permissionIntroDismissed = true
        defaults.set(true, forKey: "knockPermissionIntroDismissed")
    }

    func requestMicrophone() async {
        guard !requestingMicrophone else { return }
        settingsError = nil
        microphones = microphoneProvider()
        switch microphones.permission {
        case .notDetermined:
            requestingMicrophone = true
            _ = await microphoneRequest()
            requestingMicrophone = false
            refresh()
        case .denied: openMicrophonePrivacySettings()
        case .restricted: settingsError = "麦克风受到系统或设备管理策略限制，请联系设备管理员。"
        case .authorized: refresh()
        }
    }

    func requestScreenCapture() {
        settingsError = nil
        screenCaptureAllowed = screenCaptureProvider()
        if screenCaptureAllowed { return }
        // A denied request stays denied; opening Settings is not proof of authorization.
        _ = screenCaptureRequest()
        screenCaptureAllowed = screenCaptureProvider()
        if !screenCaptureAllowed {
            guard openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) else {
                settingsError = "请手动打开系统设置 → 隐私与安全性 → 屏幕与系统音频录制（或屏幕录制）。"
                return
            }
        }
    }

    func setShowDockIcon(_ visible: Bool) {
        guard showDockIcon != visible else { return }
        showDockIcon = visible
        defaults.set(visible, forKey: Self.dockKey)
        onDockVisibilityChange?(visible)
    }

    func openSoundInputSettings() {
        settingsError = nil
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input"), openURL(url) else {
            settingsError = "未能打开声音设置，请手动打开系统设置 → 声音 → 输入。"
            return
        }
    }

    func openMicrophonePrivacySettings() {
        settingsError = nil
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"), openURL(url) else {
            settingsError = "未能打开麦克风设置，请手动打开系统设置 → 隐私与安全性 → 麦克风。"
            return
        }
    }
}
