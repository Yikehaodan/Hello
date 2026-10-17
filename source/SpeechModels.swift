import Foundation
import Combine
import Darwin

enum SpeechModelID: String, CaseIterable, Identifiable, Codable, Sendable {
    case cloud, whisper, zipformer, sensevoice, qwen, qwenLite = "qwen-lite"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloud: return "豆包 · 云端流式"
        case .whisper: return "Whisper · 本地通用"
        case .zipformer: return "Zipformer · 中文流式"
        case .sensevoice: return "SenseVoice · 本地多语言"
        case .qwen: return "Qwen3-ASR 0.6B · 原版"
        case .qwenLite: return "Qwen3-ASR 0.6B · 轻量版"
        }
    }
    var detail: String {
        switch self {
        case .cloud: return "录音时同步转写，需要网络，按语音服务价格计费。"
        case .whisper: return "约 574 MB · 首次使用时下载。支持多语言，录音保留在本机。"
        case .zipformer: return "约 167 MB · 仅中文。边录边识别，适合快速中文输入。"
        case .sensevoice: return "约 240 MB · 中、英、日、韩和粤语。结束后完整识别。"
        case .qwen: return "约 1.88 GB · 多语言。结束后完整识别，内存占用较大，首次准备可能需要较长时间。"
        case .qwenLite: return "约 542 MB · 多语言。结束后完整识别。首次下载约 1.88 GB，完成后自动压缩。"
        }
    }
    var usesManagedRuntime: Bool { self != .cloud && self != .whisper }
    func supports(language: String) -> Bool {
        if self == .zipformer { return language == "auto" || language == "zh" }
        if self == .sensevoice { return ["auto", "zh", "en", "ja", "ko", "yue"].contains(language) }
        return true
    }
}

struct SpeechDownload: Sendable {
    let model: SpeechModelID
    var progress: Double = 0
    var stage = "准备下载"
    var received: Int64 = 0
    var total: Int64 = 0
    var paused = false
    var byteLabel: String {
        guard total > 0 else { return "" }
        return "\(ByteCountFormatter.string(fromByteCount: received, countStyle: .decimal)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal))"
    }
}

@MainActor
final class SpeechModelStore: ObservableObject {
    @Published private(set) var selected: SpeechModelID
    @Published private(set) var installed: Set<SpeechModelID> = []
    @Published private(set) var download: SpeechDownload?
    @Published private(set) var errors: [SpeechModelID: String] = [:]
    @Published var preparing: SpeechModelID?
    @Published var preparationError: String?
    var onInstalled: ((SpeechModelID) -> Void)?
    let root: URL
    let resources: URL
    let cloudAvailable: Bool
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var process: Process?
    private var processGroup: Int32?
    private var downloadToken = UUID()
    private let catalog: [String: Any]
    private let revision: Int
    static let selectionKey = "speechModel"

    init(resources: URL = Bundle.main.resourceURL!, root: URL? = nil,
         defaults: UserDefaults = .standard, cloudAvailable: Bool = false) {
        self.resources = resources; self.defaults = defaults; self.cloudAvailable = cloudAvailable
        self.root = root ?? AppPaths.speechModels
        let file = resources.appendingPathComponent("SpeechModels/models.json")
        let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        catalog = object["models"] as? [String: Any] ?? [:]; revision = object["revision"] as? Int ?? 1
        if let value = defaults.string(forKey: Self.selectionKey), let choice = SpeechModelID(rawValue: value) {
            selected = choice
        } else {
            selected = cloudAvailable && (defaults.object(forKey: "useCloudSpeech") as? Bool ?? true) ? .cloud : .whisper
        }
        refresh()
    }
    var python: URL { resources.appendingPathComponent("SpeechRuntime/python/bin/python3") }
    var worker: URL { resources.appendingPathComponent("SpeechModels/speech_worker.py") }
    var runtimeReady: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: worker.path)
    }
    func directory(_ model: SpeechModelID) -> URL { root.appendingPathComponent("Models/" + model.rawValue, isDirectory: true) }
    var whisperModel: URL? {
        let bundled = resources.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let managed = directory(.whisper).appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        return installed.contains(.whisper) ? managed : nil
    }
    func isReady(_ model: SpeechModelID) -> Bool {
        model == .cloud ? cloudAvailable : installed.contains(model) && (!model.usesManagedRuntime || runtimeReady)
    }
    func hasPendingDownload(_ model: SpeechModelID) -> Bool {
        let cache = root.appendingPathComponent("Downloads/" + model.rawValue)
        return !((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).isEmpty
    }
    func refresh() {
        var found = Set<SpeechModelID>()
        if cloudAvailable { found.insert(.cloud) }
        if ["ggml-large-v3-turbo-q5_0.bin", "ggml-small-q5_1.bin"].contains(where: { FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path) }) { found.insert(.whisper) }
        for choice in SpeechModelID.allCases where choice != .cloud {
            let folder = directory(choice)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("installed.json")),
                  let marker = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  marker["id"] as? String == choice.rawValue, marker["revision"] as? Int == revision,
                  let spec = catalog[choice.rawValue] as? [String: Any], let files = spec["files"] as? [[String: Any]], !files.isEmpty else { continue }
            let complete = files.allSatisfy { file in
                guard let name = file["name"] as? String, (name as NSString).lastPathComponent == name,
                      let size = file["bytes"] as? NSNumber,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path),
                      attrs[.type] as? FileAttributeType == .typeRegular, let actual = attrs[.size] as? NSNumber else { return false }
                return actual.int64Value == size.int64Value
            }
            if complete { found.insert(choice) }
        }
        installed = found
    }
    func select(_ choice: SpeechModelID) {
        selected = choice; defaults.set(choice.rawValue, forKey: Self.selectionKey); preparationError = nil
    }
    func downloadModel(_ choice: SpeechModelID, force: Bool = false) {
        guard choice != .cloud, download == nil, force || !isReady(choice) else { return }
        guard runtimeReady else { errors[choice] = "应用的识别组件不完整，请重新打开完整应用包。"; return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let child = Process(), pipe = Pipe()
            child.executableURL = python
            child.arguments = ["-I", "-B", resources.appendingPathComponent("SpeechModels/model_manager.py").path,
                               "--install", choice.rawValue, "--root", root.path]
            child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            downloadToken = UUID(); let token = downloadToken
            errors[choice] = nil; download = SpeechDownload(model: choice); process = child; processGroup = nil
            try child.run(); try? pipe.fileHandleForWriting.close()
            let reader = pipe.fileHandleForReading
            task = Task { [weak self] in
                let status = await Task.detached(priority: .utility) { [weak self] in
                    var pending = Data()
                    while true {
                        let bytes = reader.availableData
                        if bytes.isEmpty { break }
                        pending.append(bytes)
                        while let end = pending.firstIndex(of: 10) {
                            let line = Data(pending[..<end]); pending.removeSubrange(...end)
                            await self?.receive(line, token: token, model: choice)
                        }
                        if pending.count > 65536 { pending.removeAll() }
                    }
                    try? reader.close(); child.waitUntilExit(); return child.terminationStatus
                }.value
                self?.finished(status: status, token: token, model: choice)
            }
        } catch {
            process = nil; download = nil; errors[choice] = "无法开始下载，请重试。"
        }
    }
    private func receive(_ data: Data, token: UUID, model: SpeechModelID) {
        guard downloadToken == token, download?.model == model,
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let group = event["group"] as? Int32, group == process?.processIdentifier { processGroup = group }
        if let stage = event["stage"] as? String, download?.paused != true { download?.stage = stage }
        if let value = event["progress"] as? Double, value.isFinite { download?.progress = min(1, max(0, value)) }
        if let bytes = event["bytes"] as? Int64 { download?.received = bytes }
        if let bytes = event["total"] as? Int64 { download?.total = bytes }
        if let error = event["error"] as? String { errors[model] = error }
    }
    private func finished(status: Int32, token: UUID, model: SpeechModelID) {
        guard downloadToken == token else { return }
        let paused = download?.paused == true
        process = nil; processGroup = nil; task = nil; download = nil; refresh()
        if status == 0 && isReady(model) { errors[model] = nil; onInstalled?(model) }
        else if !paused && errors[model] == nil { errors[model] = "下载未完成，可以继续下载重试。" }
    }
    func pauseDownload() {
        guard let child = process, child.isRunning else { return }
        download?.paused = true; download?.stage = "正在暂停……"
        if processGroup == child.processIdentifier { kill(-child.processIdentifier, SIGTERM) }
        else { child.terminate() }
        let group = processGroup
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning {
                if group == child.processIdentifier { kill(-child.processIdentifier, SIGKILL) }
                else { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}
