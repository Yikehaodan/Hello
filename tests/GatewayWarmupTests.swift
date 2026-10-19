import Foundation
import AVFoundation

// Holds the warmup and generation requests independently to exercise the ASR handoff.
private final class DeferredGatewayTransport: URLProtocol {
    private static let lock = NSLock()
    private static var pending: [String: DeferredGatewayTransport] = [:]
    private static var started: [String] = []
    private static var stopped: [String] = []
    static func reset() { lock.lock(); pending = [:]; started = []; stopped = []; lock.unlock() }
    static func count(_ path: String, canceled: Bool = false) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (canceled ? stopped : started).filter { $0 == path }.count
    }
    static func finish(_ path: String) {
        lock.lock(); let handler = pending.removeValue(forKey: path); lock.unlock()
        guard let handler else { preconditionFailure("No pending request for \(path)") }
        let payload = path == "/models" ? "{\"data\":[]}" : "{\"choices\":[{\"message\":{\"content\":\"完成\"}}]}"
        handler.client?.urlProtocol(handler, didReceive: HTTPURLResponse(url: handler.request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        handler.client?.urlProtocol(handler, didLoad: Data(payload.utf8))
        handler.client?.urlProtocolDidFinishLoading(handler)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/models" {
            precondition(request.httpMethod == "GET" && request.httpBody == nil,
                         "Warmup must not submit a completion or transcript")
        }
        Self.lock.lock(); Self.started.append(path); Self.pending[path] = self; Self.lock.unlock()
    }
    override func stopLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.stopped.append(path); Self.pending.removeValue(forKey: path); Self.lock.unlock()
    }
}

@MainActor private final class FixtureRecording: VoiceRecording {
    var currentTime: TimeInterval { 1 }
    var delegate: AVAudioRecorderDelegate?
    var isMeteringEnabled = false
    init(url: URL) throws { try Data("fixture audio".utf8).write(to: url) }
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { true }
    func stop() {}
    func updateMeters() {}
    func peakPower(forChannel channelNumber: Int) -> Float { -10 }
    func averagePower(forChannel channelNumber: Int) -> Float { -20 }
}

@MainActor private final class FixtureLoginItems: LoginItemManaging {
    var state: LoginItemState { .notRegistered }
    func register() throws { preconditionFailure() }
    func unregister() throws { preconditionFailure() }
    func openSettings() { preconditionFailure() }
}

@main struct GatewayWarmupTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-warmup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "GatewayWarmupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previousAutoPolish = UserDefaults.standard.object(forKey: "autoPolish")
        defer {
            defaults.removePersistentDomain(forName: suite)
            if let previousAutoPolish { UserDefaults.standard.set(previousAutoPolish, forKey: "autoPolish") }
            else { UserDefaults.standard.removeObject(forKey: "autoPolish") }
        }
        let preferences = AppPreferences(defaults: defaults, loginItems: FixtureLoginItems(),
            microphoneProvider: { .init(devices: [], permission: .authorized) },
            accessibilityProvider: { false }, screenCaptureProvider: { false })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredGatewayTransport.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        var factories = 0
        let model = VoiceModel(library: LibraryStore(root: root.appendingPathComponent("history")),
            sessionRoot: root.appendingPathComponent("sessions"), preferences: preferences,
            requestMicrophoneAccess: { true }, transcriptionOperation: { _, _, _ in "明天下午开会。" },
            recordingFactory: { url, _ in try FixtureRecording(url: url) },
            gatewayFactory: { retry in
                factories += 1
                return try Gateway(base: "https://warmup.invalid", key: "fixture", model: "fixture", transport: transport,
                    retryWait: { _ in preconditionFailure("No retries expected") }, onRetry: retry)
            })
        model.autoPolish = true
        DeferredGatewayTransport.reset()
        model.toggle(mode: .dictate)
        await eventually { model.phase == .recording && DeferredGatewayTransport.count("/models") == 1 }
        model.stop()
        await eventually { model.phase == .polishing && DeferredGatewayTransport.count("/chat/completions") == 1 }
        precondition(DeferredGatewayTransport.count("/models", canceled: true) == 0,
                     "ASR handoff must not cancel the still-running warmup")
        precondition(factories == 1, "Warmup and generation must reuse one gateway")
        print("PASS: generation starts without waiting for warmup; ASR handoff preserves the handshake and gateway")
        DeferredGatewayTransport.finish("/models")
        model.cancel()
        await eventually { DeferredGatewayTransport.count("/chat/completions", canceled: true) == 1 }
        precondition(model.phase == .ready && model.result.isEmpty)

        DeferredGatewayTransport.reset()
        model.toggle(mode: .dictate)
        await eventually { model.phase == .recording && DeferredGatewayTransport.count("/models") == 1 }
        model.cancel()
        await eventually { DeferredGatewayTransport.count("/models", canceled: true) == 1 }
        try await Task.sleep(for: .milliseconds(80))
        precondition(DeferredGatewayTransport.count("/models") == 1 && DeferredGatewayTransport.count("/chat/completions") == 0)
        precondition(factories == 2)
        print("PASS: cancel stops warmup and generation; a new recording gets a new gateway; no microphone, clipboard or network used")
    }
    @MainActor static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for warmup lifecycle")
    }
}
