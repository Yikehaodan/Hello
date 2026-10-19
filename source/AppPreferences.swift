import AppKit
import AVFoundation
import Combine
import ServiceManagement
import ApplicationServices

enum LoginItemState: Equatable {
    case notRegistered, enabled, requiresApproval, notFound, unknown

    var detail: String {
        switch self {
        case .notRegistered: return "关闭。登录 Mac 后可手动打开Hello。"
        case .enabled: return "已开启，下次登录 Mac 时自动启动。"
        case .requiresApproval: return "等待系统允许。请在系统设置的登录项中开启Hello。"
        case .notFound: return "macOS 未找到此应用。请从完整的Hello.app 中打开后重试。"
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
        case .denied: return "麦克风权限已关闭，请在系统设置的隐私与安全性中允许Hello。"
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
    static var permission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }

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
        return MicrophoneSnapshot(devices: microphones, permission: permission)
    }
}

enum AppPermission: String, Identifiable {
    case microphone, accessibility, screenCapture
    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .accessibility: return "辅助功能"
        case .screenCapture: return "屏幕录制"
        }
    }
    var settingsPane: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .screenCapture: return "Privacy_ScreenCapture"
        }
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
    var missingPermissions: [AppPermission] {
        var missing: [AppPermission] = []
        if microphones.permission != .authorized { missing.append(.microphone) }
        if !accessibilityAllowed { missing.append(.accessibility) }
        if contextScreenshots && !screenCaptureAllowed { missing.append(.screenCapture) }
        return missing
    }
    var permissionSummary: String {
        missingPermissions.isEmpty ? "所需权限已就绪" : "待设置：" + missingPermissions.map(\.title).joined(separator: "、")
    }
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
    private let microphonePermissionProvider: () -> MicrophonePermission
    private let openURL: (URL) -> Bool
    private let accessibilityProvider: () -> Bool
    private let screenCaptureProvider: () -> Bool
    private let screenCaptureRequest: () -> Bool
    private let microphoneRequest: () async -> Bool
    private let accessibilityRequest: () -> Void
    private var permissionMonitor: Task<Void, Never>?
    private static let dockKey = "showDockIcon"

    init(defaults: UserDefaults = .standard,
         loginItems: (any LoginItemManaging)? = nil,
         microphoneProvider: (() -> MicrophoneSnapshot)? = nil,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         accessibilityProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
         screenCaptureProvider: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         screenCaptureRequest: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         microphoneRequest: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         accessibilityRequest: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         }) {
        let service = loginItems ?? SystemLoginItemManager()
        self.defaults = defaults
        self.weatherCity = defaults.string(forKey: "weatherCity") ?? ""
        self.contextScreenshots = defaults.object(forKey: "contextScreenshots") as? Bool ?? false
        self.loginItems = service
        self.microphoneProvider = microphoneProvider ?? MicrophoneCatalog.snapshot
        // Poll authorization without rediscovering audio devices every two seconds.
        self.microphonePermissionProvider = microphoneProvider.map { provider in { provider().permission } }
            ?? { MicrophoneCatalog.permission }
        self.openURL = openURL
        self.accessibilityProvider = accessibilityProvider
        self.screenCaptureProvider = screenCaptureProvider
        self.screenCaptureRequest = screenCaptureRequest
        self.microphoneRequest = microphoneRequest
        self.accessibilityRequest = accessibilityRequest
        self.accessibilityAllowed = accessibilityProvider()
        self.screenCaptureAllowed = screenCaptureProvider()
        self.permissionIntroDismissed = defaults.bool(forKey: "knockPermissionIntroDismissed")
        self.loginItemState = service.state
        self.showDockIcon = defaults.object(forKey: Self.dockKey) as? Bool ?? true
        self.microphones = self.microphoneProvider()
    }

    deinit { permissionMonitor?.cancel() }

    func startPermissionMonitoring(pollInterval: Duration = .seconds(2)) {
        guard permissionMonitor == nil else { return }
        refreshPermissions()
        permissionMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollInterval) }
                catch { return }
                guard let self else { return }
                self.refreshPermissions()
            }
        }
    }

    func stopPermissionMonitoring() {
        permissionMonitor?.cancel()
        permissionMonitor = nil
    }

    // Read-only checks also run while System Settings is in front. Publish only changes.
    func refreshPermissions() {
        let screen = screenCaptureProvider(), accessibility = accessibilityProvider()
        let microphone = microphonePermissionProvider()
        if screenCaptureAllowed != screen { screenCaptureAllowed = screen }
        if accessibilityAllowed != accessibility { accessibilityAllowed = accessibility }
        if microphones.permission != microphone {
            microphones = MicrophoneSnapshot(devices: microphones.devices, permission: microphone)
        }
    }

    // Safe to call when settings opens or the app becomes active. Never changes login registration.
    func refresh() {
        refreshPermissions()
        let updatedState = loginItems.state
        if loginItemState != updatedState { loginItemError = nil }
        if loginItemState != updatedState { loginItemState = updatedState }
        let snapshot = microphoneProvider()
        if microphones != snapshot { microphones = snapshot }
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
            openPrivacySettings(for: .screenCapture)
        }
    }

    func requestAccessibility() {
        settingsError = nil
        refreshPermissions()
        guard !accessibilityAllowed else { return }
        accessibilityRequest()
        refreshPermissions()
        if !accessibilityAllowed { openPrivacySettings(for: .accessibility) }
    }

    func openPrivacySettings(for permission: AppPermission) {
        settingsError = nil
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)")!
        if !openURL(url) {
            let pane = permission == .screenCapture ? "屏幕与系统音频录制（或屏幕录制）" : permission.title
            settingsError = "未能打开\(permission.title)设置，请手动打开系统设置 → 隐私与安全性 → \(pane)。"
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
        openPrivacySettings(for: .microphone)
    }
}
