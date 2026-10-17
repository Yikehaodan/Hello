import Foundation

@MainActor
private final class FakeLoginItems: LoginItemManaging {
    var state = LoginItemState.notRegistered
    var registered = 0
    var unregistered = 0
    var openedSettings = 0
    var nextState = LoginItemState.enabled
    var failure: Error?
    func register() throws {
        registered += 1
        if let failure { throw failure }
        state = nextState
    }
    func unregister() throws {
        unregistered += 1
        if let failure { throw failure }
        state = .notRegistered
    }
    func openSettings() { openedSettings += 1 }
}

@main
private enum AppPreferencesTests {
    @MainActor static func main() async {
        let suite = "LightVoice.PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeLoginItems()
        var snapshot = MicrophoneSnapshot(devices: [], permission: .notDetermined)
        let preferences = AppPreferences(defaults: defaults, loginItems: fake, microphoneProvider: { snapshot }, openURL: { _ in false })
        precondition(!preferences.launchAtLogin && preferences.showDockIcon)
        preferences.refresh()
        precondition(fake.registered == 0 && fake.unregistered == 0)

        preferences.setLaunchAtLogin(true)
        precondition(preferences.launchAtLogin && fake.registered == 1)
        preferences.setLaunchAtLogin(true)
        precondition(fake.registered == 1)
        preferences.setLaunchAtLogin(false)
        precondition(!preferences.launchAtLogin && fake.unregistered == 1)
        preferences.setLaunchAtLogin(false)
        precondition(fake.unregistered == 1)

        fake.nextState = .requiresApproval
        preferences.setLaunchAtLogin(true)
        precondition(!preferences.launchAtLogin && preferences.loginItemNeedsReview)
        preferences.setLaunchAtLogin(true)
        precondition(fake.registered == 2)
        preferences.openLoginItemSettings()
        precondition(fake.openedSettings == 1)
        preferences.setLaunchAtLogin(false)
        precondition(fake.unregistered == 2 && preferences.loginItemState == .notRegistered)

        fake.failure = NSError(domain: "Test", code: 9, userInfo: [NSLocalizedDescriptionKey: "模拟系统拒绝"])
        preferences.setLaunchAtLogin(true)
        precondition(!preferences.launchAtLogin && preferences.loginItemError?.contains("模拟系统拒绝") == true)
        fake.state = .enabled
        preferences.refresh()
        preferences.setLaunchAtLogin(false)
        precondition(preferences.launchAtLogin && preferences.loginItemError?.contains("关闭") == true)

        var dockChanges: [Bool] = []
        preferences.onDockVisibilityChange = { dockChanges.append($0) }
        preferences.setShowDockIcon(false)
        preferences.setShowDockIcon(false)
        precondition(dockChanges == [false] && defaults.bool(forKey: "showDockIcon") == false)
        let restored = AppPreferences(defaults: defaults, loginItems: fake, microphoneProvider: { snapshot }, openURL: { _ in false })
        precondition(!restored.showDockIcon)

        snapshot = MicrophoneSnapshot(devices: [.init(id: "test-mic", name: "测试麦克风", isDefault: true)], permission: .authorized)
        preferences.refresh()
        precondition(preferences.microphones.defaultName == "测试麦克风")
        preferences.openSoundInputSettings()
        precondition(preferences.settingsError?.contains("声音") == true)
        preferences.openMicrophonePrivacySettings()
        precondition(preferences.settingsError?.contains("麦克风") == true)
        let denied = MicrophoneSnapshot(devices: [], permission: .denied)
        precondition(denied.detail.contains("权限已关闭"))
        var accessible = false, screen = false, micRequests = 0, screenRequests = 0
        var urls: [URL] = []
        snapshot = MicrophoneSnapshot(devices: [], permission: .notDetermined)
        let permissions = AppPreferences(defaults: defaults, loginItems: fake, microphoneProvider: { snapshot },
            openURL: { urls.append($0); return true }, accessibilityProvider: { accessible },
            screenCaptureProvider: { screen }, screenCaptureRequest: { screenRequests += 1; return false },
            microphoneRequest: { micRequests += 1; snapshot = MicrophoneSnapshot(devices: [], permission: .denied); return false })
        precondition(!permissions.contextScreenshots && !permissions.permissionIntroDismissed)
        permissions.refresh()
        precondition(micRequests == 0 && screenRequests == 0 && urls.isEmpty, "Read-only checks never prompt")
        await permissions.requestMicrophone()
        precondition(micRequests == 1 && permissions.microphones.permission == .denied && !permissions.requestingMicrophone)
        await permissions.requestMicrophone()
        precondition(micRequests == 1 && urls.last?.absoluteString.contains("Privacy_Microphone") == true)
        permissions.requestScreenCapture()
        precondition(screenRequests == 1 && !permissions.screenCaptureAllowed, "Settings navigation is not a grant")
        accessible = true; screen = true; snapshot = MicrophoneSnapshot(devices: [], permission: .authorized)
        permissions.refresh()
        precondition(!permissions.needsRequiredPermissions && permissions.screenCaptureAllowed)
        permissions.dismissPermissionIntro()
        precondition(defaults.bool(forKey: "knockPermissionIntroDismissed"))
        permissions.contextScreenshots = true
        let existing = AppPreferences(defaults: defaults, loginItems: fake, microphoneProvider: { snapshot })
        precondition(existing.contextScreenshots && existing.permissionIntroDismissed, "Preserve explicit preferences")
        print("PASS: permission states, denied recovery, no startup prompts, optional screenshots and onboarding persistence")
        print("PASS: login state, user-only changes, approval, failure rollback, isolated Dock persistence, microphone state")
    }
}
