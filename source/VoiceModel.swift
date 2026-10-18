import AppKit
import AVFoundation
import ApplicationServices
import Combine

struct VoiceProcessingResult {
    var text: String
    var replacesSelection = false
}

@MainActor
final class VoiceModel: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    typealias TranscriptionOperation = @MainActor (URL, String, String) async throws -> String
    typealias ProcessingOperation = @MainActor (String, InputMode, String, String, String) async throws -> VoiceProcessingResult
    typealias RecordingFactory = @MainActor (URL, [String: Any]) throws -> any VoiceRecording
    enum Phase: String { case ready, authorizing, recording, transcribing, polishing }
    @Published var phase = Phase.ready
    @Published var raw = ""
    @Published var result = ""
    @Published private(set) var apiRetryAttempt = 0
    @Published private(set) var canRetryProcessing = false
    @Published var status = "按一次 Fn 开始，再按一次 Fn 结束。"
    @Published var shortcutStatus = "正在检查 Fn 权限……"
    // Only the waveform's frame clock reads this value. Meter samples must not invalidate
    // every view observing the session (history, settings and the main window included).
    var level: Float = 0
    @Published var seconds: Double = 0
    @Published var autoPolish = UserDefaults.standard.object(forKey: "autoPolish") as? Bool ?? ((try? Gateway()) != nil) {
        didSet { UserDefaults.standard.set(autoPolish, forKey: "autoPolish") }
    }
    @Published var autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPaste, forKey: "autoPaste") }
    }
    @Published var hasRecording = false
    @Published private(set) var playingHistoryID: UUID?
    @Published var mode = InputMode.dictate
    @Published var showAnswer = false
    @Published private(set) var answerSources: [AnswerSource] = []
    @Published private(set) var answerLookupPerformed = false
    @Published private(set) var lookupStatus = ""
    @Published private(set) var contextStatus = ""
    private var sessionContext: VoiceContext?
    private var pendingWeatherQuestion = ""
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "auto" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var targetLanguage = UserDefaults.standard.string(forKey: "targetLanguage") ?? "English" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage") }
    }
    @Published var soundEnabled = UserDefaults.standard.bool(forKey: "soundEnabled") {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var useCloudSpeech = UserDefaults.standard.object(forKey: "useCloudSpeech") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useCloudSpeech, forKey: "useCloudSpeech") }
    }
    var cloudSpeechAvailable: Bool { cloudConfiguration != nil }
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    let library: LibraryStore
    let preferences: AppPreferences
    let speechModels: SpeechModelStore
    private var recorder: (any VoiceRecording)?
    private var meter: Timer?
    private var work: Task<Void, Never>?
    private var session = UUID()
    private var audioURL: URL?
    private var player: AVAudioPlayer?
    private var sessionHistoryID: UUID?
    private var historySavePending = false
    private var sessionSucceeded = false
    private var sessionCancelled = false
    private var subscriptions = Set<AnyCancellable>()
    private var destination: TextDestination?
    private var peakPower: Float = -160
    private var sessionMode = InputMode.dictate
    private var sessionLanguage = "auto"
    private var sessionTargetLanguage = "English"
    private var asr: LocalASR
    private var residentASR: ResidentASR
    private var managedASR: ManagedSpeechASR?
    private var managedStream: ManagedSpeechStream?
    private var modelPreparation: Task<Void, Never>?
    private var sessionSpeechModel = SpeechModelID.whisper
    private let recordingFactory: RecordingFactory
    private var liveTranscription: LiveTranscription?
    private var cloudTranscription: CloudTranscription?
    private let cloudConfiguration: CloudSpeechConfiguration?
    private var liveSnapshot: Task<Void, Never>?
    private var warmup: Task<Void, Never>?
    private var gatewayWarmup: Task<Void, Never>?
    private var nextSnapshotTime: Double = 0
    private let sessionRoot: URL
    private let requestMicrophoneAccess: @MainActor () async -> Bool
    private let transcriptionOperation: TranscriptionOperation?
    private let processingOperation: ProcessingOperation?
    var busy: Bool { phase != .ready }
    var retryingHistoryID: UUID? { busy ? sessionHistoryID : nil }
    var hasUnsavedRecording: Bool { audioURL != nil && (historySavePending || sessionHistoryID == nil) }
    var timeLabel: String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }

    init(library: LibraryStore? = nil, sessionRoot: URL? = nil, preferences: AppPreferences? = nil,
         requestMicrophoneAccess: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         transcriptionOperation: TranscriptionOperation? = nil, processingOperation: ProcessingOperation? = nil,
         asrResources: URL? = nil, cloudConfiguration: CloudSpeechConfiguration? = nil, speechModels: SpeechModelStore? = nil,
         recordingFactory: @escaping RecordingFactory = { url, settings in try AVAudioRecorder(url: url, settings: settings) }) {
        self.library = library ?? LibraryStore()
        self.preferences = preferences ?? AppPreferences()
        self.sessionRoot = sessionRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("LightVoiceSessions", isDirectory: true)
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.transcriptionOperation = transcriptionOperation
        self.processingOperation = processingOperation
        let cloudAllowed = Bundle.main.bundleIdentifier == "local.lightvoice.lin" || ProcessInfo.processInfo.environment["LIGHTVOICE_CLOUD_PROBE"] == "1"
        self.cloudConfiguration = transcriptionOperation == nil ? (cloudConfiguration ?? (cloudAllowed ? CloudSpeechConfiguration.load() : nil)) : nil
        let resources = asrResources ?? Bundle.main.resourceURL!
        let models = speechModels ?? SpeechModelStore(resources: resources, cloudAvailable: self.cloudConfiguration != nil)
        self.speechModels = models
        self.asr = LocalASR(resources: resources, modelURL: models.whisperModel)
        self.residentASR = ResidentASR(resources: resources, modelURL: models.whisperModel)
        self.recordingFactory = recordingFactory
        super.init()
        try? FileManager.default.createDirectory(at: self.sessionRoot, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        LiveTranscription.cleanupAbandoned(in: self.sessionRoot, removeRecent: self.library.retention == .never)
        // 清理异常退出遗留的一天前的录音，仅限本程序的临时目录。
        for url in (try? FileManager.default.contentsOfDirectory(at: self.sessionRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard url.pathExtension == "wav", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            if self.library.retention == .never ||
                ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < Date().addingTimeInterval(-86400) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        self.library.$history.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.libraryDidChange() }
        }.store(in: &subscriptions)
        self.library.$retention.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.libraryDidChange() }
        }.store(in: &subscriptions)
        models.onInstalled = { [weak self] choice in
            guard let self else { return }
            let models = self.speechModels
            if choice == .whisper {
                let old = self.residentASR
                Task { await old.shutdown() }
                self.asr = LocalASR(resources: models.resources, modelURL: models.whisperModel)
                self.residentASR = ResidentASR(resources: models.resources, modelURL: models.whisperModel)
            }
            if !self.busy && models.selected == choice { self.prepareSpeechModel() }
        }
        if transcriptionOperation == nil && Bundle.main.bundleIdentifier == "local.lightvoice.lin" {
            prepareSpeechModel()
        }
    }
    func chooseSpeechModel(_ choice: SpeechModelID) {
        guard !busy, speechModels.selected != choice else { return }
        modelPreparation?.cancel(); modelPreparation = nil
        if let previous = managedASR { Task { await previous.shutdown() } }
        managedASR = nil
        speechModels.preparing = nil
        speechModels.select(choice)
        useCloudSpeech = choice == .cloud
        if let problem = speechModelProblem(choice, language: language) { status = problem }
        else { status = "已选择\(choice.title)。" }
        prepareSpeechModel()
    }
    private func speechModelProblem(_ choice: SpeechModelID, language: String) -> String? {
        if !choice.supports(language: language) { return "所选模型不支持当前口述语言，请切换语言或语音模型。" }
        if choice == .cloud && !cloudSpeechAvailable { return "云端语音尚未配置，请选择本地语音模型。" }
        if choice == .whisper && !asr.ready && !residentASR.ready { return "Whisper 尚未下载，请在设置中下载语音模型。" }
        if choice.usesManagedRuntime && !speechModels.isReady(choice) { return "所选语音模型尚未下载，请在设置中下载后再录音。" }
        return nil
    }
    private func backend(for choice: SpeechModelID) -> ManagedSpeechASR {
        if let backend = managedASR, backend.model == choice { return backend }
        let backend = ManagedSpeechASR(resources: speechModels.resources, root: speechModels.root, model: choice)
        managedASR = backend
        return backend
    }
    func prepareSpeechModel() {
        let choice = speechModels.selected
        guard choice.usesManagedRuntime, choice.supports(language: language), speechModels.isReady(choice), !busy else { return }
        modelPreparation?.cancel()
        let engine = backend(for: choice)
        speechModels.preparing = choice; speechModels.preparationError = nil
        let sourceLanguage = language
        modelPreparation = Task { [weak self] in
            do {
                try await engine.warmup(language: sourceLanguage)
                guard let self, !Task.isCancelled, self.speechModels.selected == choice else { return }
                self.speechModels.preparing = nil
            } catch {
                guard let self, !Task.isCancelled, self.speechModels.selected == choice else { return }
                self.speechModels.preparing = nil; self.speechModels.preparationError = error.localizedDescription
            }
        }
    }
    func toggle(mode requestedMode: InputMode? = nil) {
        switch phase {
        case .ready:
            guard preserveSessionBeforeReplacement() else { return }
            stopHistoryAudio()
            if let requestedMode { mode = requestedMode }
            canRetryProcessing = false; apiRetryAttempt = 0
            session = UUID()
            let token = session
            phase = .authorizing
            work = Task { await start(token: token) }
        case .recording: stop()
        case .authorizing, .transcribing, .polishing: break
        }
    }
    private func start(token: UUID) async {
        guard phase == .authorizing, session == token, !Task.isCancelled else { return }
        let requestedMode = mode, requestedLanguage = language, requestedTargetLanguage = targetLanguage
        let requestedSpeechModel = speechModels.selected
        showAnswer = false
        status = "正在准备麦克风……"
        let newDestination = TextDestination.capture(includeSelection: requestedMode.isAssistant || requestedMode == .context)
        let newContext: VoiceContext?
        if requestedMode == .context {
            status = "正在读取当前输入框与页面……"
            newContext = await newDestination?.captureContext(includeScreenshot: preferences.contextScreenshots)
                ?? VoiceContext(captureStatus: "未找到外部窗口 · 请在目标页面按 Fn＋Control")
        } else { newContext = nil }
        guard session == token, !Task.isCancelled else { return }
        sessionContext = newContext
        contextStatus = newContext?.captureStatus ?? ""
        let permitted = await requestMicrophoneAccess()
        preferences.refresh()
        guard session == token, !Task.isCancelled else { return }
        guard permitted else { sessionContext = nil; phase = .ready; status = "请在系统设置 → 隐私与安全性 → 麦克风中允许Hello。"; return }
        if transcriptionOperation == nil, let problem = speechModelProblem(requestedSpeechModel, language: requestedLanguage) {
            sessionContext = nil; phase = .ready; status = problem; return
        }
        let audio = sessionRoot.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            let capture = try recordingFactory(audio, settings)
            capture.delegate = self; capture.isMeteringEnabled = true
            guard capture.prepareToRecord(), capture.record() else { throw VoiceError.message("无法启动麦克风，请检查系统声音输入。") }
            discardSessionAudio()
            sessionHistoryID = nil
            historySavePending = false; sessionSucceeded = false; sessionCancelled = false
            sessionMode = requestedMode; sessionLanguage = requestedLanguage; sessionTargetLanguage = requestedTargetLanguage
            sessionSpeechModel = requestedSpeechModel
            destination = newDestination
            recorder = capture; audioURL = audio; hasRecording = false
            raw = ""; result = ""; seconds = 0; peakPower = -160
            beginLiveTranscription(token: token)
            if processingOperation == nil, sessionMode != .dictate || autoPolish {
                gatewayWarmup = Task { if let gateway = try? Gateway() { await gateway.warmupTransport() } }
            }
            phase = .recording
            if soundEnabled { NSSound(named: "Tink")?.play() }
            status = requestedMode == .context ? "正在录音 · \(contextStatus) · 再按 Fn 结束" :
                (destination.map { "正在录音 · 将输入到\($0.name) · 再按 Fn 结束" } ?? "正在录音 · 再按 Fn 结束")
            let samplingTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                // This timer is registered only on the main run loop. Avoid queueing a
                // separate Task for every audio sample, especially while tracking menus.
                MainActor.assumeIsolated { self?.sampleRecorder() }
            }
            samplingTimer.tolerance = 0.003
            meter = samplingTimer
            RunLoop.main.add(samplingTimer, forMode: .common)
        } catch {
            sessionContext = nil
            phase = .ready; status = error.localizedDescription
            try? FileManager.default.removeItem(at: audio)
        }
    }
    private func sampleRecorder() {
        guard phase == .recording, let recorder else { return }
        recorder.updateMeters()
        peakPower = max(peakPower, recorder.peakPower(forChannel: 0))
        // Average power is a stable envelope; peak power remains the silence detector.
        level = min(1, max(0, (recorder.averagePower(forChannel: 0) + 55) / 55))
        let elapsed = recorder.currentTime
        // Whole seconds are enough for labels. stop() saves the precise duration.
        if Int(elapsed) != Int(seconds) { seconds = floor(elapsed) }
        sampleLiveTranscription(elapsed: elapsed)
        if elapsed >= 120 { stop() }
    }
    private func beginLiveTranscription(token: UUID) {
        endLiveTranscription()
        nextSnapshotTime = 0.10
        if transcriptionOperation == nil, sessionSpeechModel == .cloud, useCloudSpeech, let cloudConfiguration {
            cloudTranscription = CloudTranscription(configuration: cloudConfiguration,
                mode: .select(inputMode: sessionMode, source: sessionLanguage, target: sessionTargetLanguage), language: sessionLanguage)
            return
        }
        if transcriptionOperation == nil, sessionSpeechModel.usesManagedRuntime {
            let engine = backend(for: sessionSpeechModel)
            if sessionSpeechModel == .zipformer { managedStream = ManagedSpeechStream(backend: engine, language: sessionLanguage) }
            else { let language = sessionLanguage; warmup = Task { try? await engine.warmup(language: language) } }
            return
        }
        guard transcriptionOperation == nil, residentASR.ready else { return }
        let backend = residentASR
        warmup = Task { try? await backend.warmup() }
        liveTranscription = try? LiveTranscription(
            directory: sessionRoot.appendingPathComponent("live-" + token.uuidString),
            language: sessionLanguage, dictionary: library.dictionaryPrompt,
            operation: { audio, language, dictionary in
                try await backend.transcribe(audio, language: language, dictionary: dictionary)
            })
    }
    private func sampleLiveTranscription(elapsed: Double) {
        guard elapsed >= nextSnapshotTime, liveSnapshot == nil,
              liveTranscription != nil || cloudTranscription != nil || managedStream != nil, let audio = audioURL else { return }
        nextSnapshotTime = elapsed + (cloudTranscription == nil ? 0.25 : 0.10)
        let token = session
        liveSnapshot = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { try? RecordingPCM(wav: audio, live: true) }.value
            guard let self, self.session == token, !Task.isCancelled else { return }
            self.liveSnapshot = nil
            guard self.phase == .recording, let snapshot else { return }
            self.liveTranscription?.offer(snapshot)
            self.cloudTranscription?.offer(snapshot)
            self.managedStream?.offer(snapshot)
        }
    }
    private func endLiveTranscription() {
        liveSnapshot?.cancel(); liveSnapshot = nil
        liveTranscription?.cancel(); liveTranscription = nil
        cloudTranscription?.cancel(); cloudTranscription = nil
        managedStream?.cancel(); managedStream = nil
        warmup?.cancel(); warmup = nil
        gatewayWarmup?.cancel(); gatewayWarmup = nil
    }
    private func transcribeComplete(_ audio: URL, allowCloud: Bool = true) async throws -> String {
        if sessionSpeechModel.usesManagedRuntime {
            return try await backend(for: sessionSpeechModel).transcribe(audio, language: sessionLanguage, dictionary: library.dictionaryPrompt)
        }
        if sessionSpeechModel == .cloud, allowCloud, let configuration = cloudConfiguration {
            let cloud = CloudTranscription(configuration: configuration,
                mode: .select(inputMode: sessionMode, source: sessionLanguage, target: sessionTargetLanguage), language: sessionLanguage)
            defer { cloud.cancel() }
            do { return try await cloud.finish(audio: audio).text }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); status = "连接暂不可用，正在使用 Whisper 完整识别……" }
        }
        if residentASR.ready {
            do { return try await residentASR.transcribe(audio, language: sessionLanguage, dictionary: library.dictionaryPrompt) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        return try await asr.transcribe(audio, language: sessionLanguage, dictionary: library.dictionaryPrompt)
    }
    func stop() {
        guard phase == .recording else { return }
        if sessionMode == .translate { sessionTargetLanguage = targetLanguage }
        if let recorder {
            recorder.updateMeters()
            peakPower = max(peakPower, recorder.peakPower(forChannel: 0))
            seconds = recorder.currentTime
        }
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil; level = 0
        liveSnapshot?.cancel(); liveSnapshot = nil
        if soundEnabled { NSSound(named: "Pop")?.play() }
        hasRecording = audioURL != nil
        guard seconds >= 0.35, peakPower > -55 else {
            endLiveTranscription()
            phase = .ready; status = "没有听到声音，请检查麦克风后再试。"
            if library.retention == .never { discardSessionAudio() }
            return
        }
        recognize()
    }
    func recognize() {
        guard phase == .ready || phase == .recording else { return }
        guard let audio = audioURL else { return }
        if phase == .ready {
            sessionSpeechModel = speechModels.selected
            if transcriptionOperation == nil, let problem = speechModelProblem(sessionSpeechModel, language: sessionLanguage) { status = problem; return }
        }
        let token = session
        phase = .transcribing; status = cloudTranscription == nil ? "正在本地转文字……" : "正在完成转写……"
        work = Task {
            do {
                let text: String
                if let transcriptionOperation {
                    text = try await transcriptionOperation(audio, sessionLanguage, library.dictionaryPrompt)
                } else if let cloud = cloudTranscription {
                    do { text = try await cloud.finish(audio: audio).text }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard session == token else { return }
                        cloud.cancel()
                        status = "连接暂不可用，正在本地完整识别……"
                        text = try await transcribeComplete(audio, allowCloud: false)
                    }
                } else if let managed = managedStream {
                    do { text = try await managed.finish(audio: audio) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard session == token else { return }
                        managed.cancel()
                        status = "正在使用所选模型完整识别……"
                        text = try await transcribeComplete(audio)
                    }
                } else if let stream = liveTranscription {
                    do { text = try await stream.finish(audio: audio) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard session == token else { return }
                        stream.cancel()
                        status = "正在校验并完整识别录音……"
                        text = try await transcribeComplete(audio)
                    }
                } else { text = try await transcribeComplete(audio) }
                guard session == token, !Task.isCancelled else { return }
                endLiveTranscription()
                raw = text
                guard !text.isEmpty else {
                    phase = .ready; status = "没有识别到语音，请说得靠近麦克风一些。"
                    saveHistory(succeeded: false)
                    if library.retention == .never { discardSessionAudio() }
                    return
                }
                let completed: Bool
                if sessionMode != .dictate || autoPolish { completed = await processText(text, token: token, deliver: sessionHistoryID == nil) }
                else {
                    result = text; phase = .ready
                    if sessionHistoryID == nil { deliverResult() } else { status = "重新识别完成，历史记录已更新。" }
                    completed = true
                }
                guard session == token, !Task.isCancelled else { return }
                finishHistorySave(succeeded: completed)
            } catch is CancellationError {
            } catch {
                guard session == token else { return }
                endLiveTranscription()
                phase = .ready; status = error.localizedDescription
                saveHistory(succeeded: false)
                if library.retention == .never { discardSessionAudio() }
            }
        }
    }
    func polish() {
        guard !busy, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = session
        sessionMode = mode; sessionTargetLanguage = targetLanguage
        let text = raw
        phase = .polishing
        work = Task {
            guard session == token, !Task.isCancelled else { return }
            let completed = await processText(text, token: token, deliver: false)
            guard session == token, !Task.isCancelled else { return }
            finishHistorySave(succeeded: completed)
        }
    }
    func retryProcessing() {
        guard !busy, canRetryProcessing, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = session, text = raw
        // Preserve the failed request's mode and language; never automatically paste a manual retry.
        mode = sessionMode
        canRetryProcessing = false
        phase = .polishing
        work = Task {
            let completed = await processText(text, token: token, deliver: false)
            guard session == token, !Task.isCancelled else { return }
            finishHistorySave(succeeded: completed)
        }
    }
    private func processText(_ text: String, token: UUID, deliver: Bool) async -> Bool {
        guard session == token, !Task.isCancelled else { return false }
        apiRetryAttempt = 0; canRetryProcessing = false
        answerSources = []; answerLookupPerformed = false; lookupStatus = ""
        defer { if session == token { apiRetryAttempt = 0; lookupStatus = "" } }
        phase = .polishing
        status = (sessionMode == .dictate || sessionMode == .context) ? "正在整理文字……" : sessionMode == .translate ? "正在翻译……" : "正在思考……"
        if sessionMode == .context && sessionContext == nil {
            contextStatus = "本次仅使用口述原文 · 在目标页面按 Fn＋Control 可重新获取上下文"
        }
        do {
            let output: String
            var replacesSelection = false
            if let processingOperation {
                let answer = try await processingOperation(text, sessionMode, sessionTargetLanguage,
                                                          library.dictionaryPrompt, destination?.selectedText ?? "")
                output = answer.text; replacesSelection = answer.replacesSelection
            } else {
                let gateway = try Gateway(onRetry: { [weak self] attempt, limit in
                    guard let self, self.session == token, !Task.isCancelled else { return }
                    self.apiRetryAttempt = attempt
                    self.status = "API 连接暂时失败，正在重试（\(attempt)/\(limit)）……"
                })
                switch sessionMode {
                case .dictate: output = try await gateway.polish(text, dictionary: library.dictionaryPrompt)
                case .translate: output = try await gateway.translate(text, to: sessionTargetLanguage, dictionary: library.dictionaryPrompt)
                case .context:
                    output = try await gateway.polish(text, dictionary: library.dictionaryPrompt,
                        context: sessionContext ?? VoiceContext(captureStatus: contextStatus))
                case .ask:
                    let answer = try await gateway.ask(text, selectedText: destination?.selectedText ?? "",
                        defaultCity: preferences.weatherCity, pendingQuestion: pendingWeatherQuestion,
                        onLookup: { [weak self] message in
                            guard let self, self.session == token, !Task.isCancelled else { return }
                            self.lookupStatus = message; self.status = message + "……"; self.apiRetryAttempt = 0
                        })
                    guard session == token, !Task.isCancelled else { return false }
                    answerSources = answer.sources; answerLookupPerformed = answer.lookupPerformed
                    pendingWeatherQuestion = answer.followupQuestion ?? ""
                    output = answer.text; replacesSelection = answer.replacesSelection
                }
            }
            guard session == token, !Task.isCancelled else { return false }
            let references = answerSources.enumerated().map { index, source in
                let title = source.title.replacingOccurrences(of: "[", with: "（").replacingOccurrences(of: "]", with: "）")
                    .replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\n", with: " ")
                let link = source.url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                return "[\(index + 1)] [\(title)](\(link))"
            }.joined(separator: "\n")
            result = output + (references.isEmpty ? "" : "\n\n来源：\n" + references)
            phase = .ready
            if sessionMode.isAssistant && !replacesSelection {
                status = "回答已生成。"; showAnswer = true
            } else if deliver {
                deliverResult(requireOriginalSelection: replacesSelection)
            } else { status = "处理完成，可查看或复制结果。" }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard session == token, !Task.isCancelled else { return false }
            canRetryProcessing = true
            result = text; phase = .ready
            status = "\(sessionMode.title)处理暂时失败，原文已保留，可重试。\(error.localizedDescription)"
            return false
        }
    }
    @discardableResult
    private func saveHistory(succeeded: Bool, cancelled: Bool = false) -> Bool {
        sessionSucceeded = succeeded; sessionCancelled = cancelled
        guard library.retention != .never else { historySavePending = false; return true }
        let saved: Bool
        if let sessionHistoryID {
            saved = library.updateHistory(id: sessionHistoryID, raw: raw, text: result, succeeded: succeeded,
                                          cancelled: cancelled, mode: sessionMode.rawValue, targetLanguage: sessionTargetLanguage,
                contextCaptureStatus: sessionMode == .context ? contextStatus : nil)
        } else {
            sessionHistoryID = library.addHistory(raw: raw, text: result, duration: seconds,
                application: destination?.name ?? "Hello", mode: sessionMode.rawValue,
                succeeded: succeeded, cancelled: cancelled, audio: audioURL,
                language: sessionLanguage, targetLanguage: sessionTargetLanguage,
                contextCaptureStatus: sessionMode == .context ? contextStatus : nil,
                contextInputText: sessionMode == .context ? sessionContext?.inputText : nil,
                contextWindowTitle: sessionMode == .context ? sessionContext?.windowTitle : nil,
                contextScreenshotDataURL: sessionMode == .context ? sessionContext?.imageDataURL : nil)
            saved = sessionHistoryID != nil
        }
        historySavePending = !saved
        if !saved {
            hasRecording = audioURL != nil
            status += " 历史记录未保存：\(library.errorMessage ?? "无法写入历史记录。") 当前会话仍可重试，请在退出前重新保存。"
        }
        return saved
    }
    private func finishHistorySave(succeeded: Bool) {
        let saved = saveHistory(succeeded: succeeded)
        if library.retention == .never || (succeeded && saved) {
            discardSessionAudio()
            sessionContext = nil
        }
    }
    // Never replace the only working copy merely because recognition or generation succeeded.
    private func preserveSessionBeforeReplacement() -> Bool {
        guard historySavePending || hasUnsavedRecording else { return true }
        guard saveHistory(succeeded: sessionSucceeded, cancelled: sessionCancelled) else {
            status = "当前录音或文字尚未保存，暂时无法开始新的录音或历史重试。请重试当前内容，或修复历史记录目录后再试。仅当前会话可恢复。 \(library.errorMessage ?? "")"
            return false
        }
        discardSessionAudio()
        return true
    }
    func prepareForTermination() -> Bool {
        speechModels.pauseDownload()
        modelPreparation?.cancel(); modelPreparation = nil
        speechModels.preparing = nil
        if busy { cancel(preservingRecording: true) }
        stopHistoryAudio()
        return preserveSessionBeforeReplacement()
    }
    func copyResult() {
        guard !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        status = "已复制，可按 ⌘V 粘贴。"
    }
    func pasteLastResult() -> Bool {
        guard !busy, !result.isEmpty, let target = TextDestination.capture() else { return false }
        status = target.insert(result)
        return true
    }
    private func deliverResult(requireOriginalSelection: Bool = false) {
        guard autoPaste, let destination else { copyResult(); return }
        status = destination.insert(result, requireOriginalSelection: requireOriginalSelection)
    }
    func cancel(preservingRecording: Bool = false) {
        let wasProcessing = phase == .transcribing || phase == .polishing
        let wasRecording = phase == .recording
        if wasRecording { seconds = recorder?.currentTime ?? seconds }
        canRetryProcessing = false; apiRetryAttempt = 0
        session = UUID(); work?.cancel(); work = nil
        endLiveTranscription()
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil
        phase = .ready; level = 0; status = "已取消。"
        if (wasProcessing || (wasRecording && preservingRecording)), audioURL != nil || sessionHistoryID != nil {
            let saved = saveHistory(succeeded: false, cancelled: true)
            if library.retention == .never { discardSessionAudio() }
            else {
                hasRecording = audioURL != nil
                status = saved ? "已取消处理，已有内容已保留，可在历史记录中重试。" : "已取消处理，但历史记录未保存。仅当前会话可重试，退出前请重新保存。 \(library.errorMessage ?? "")"
            }
        } else if library.retention == .never || wasRecording || !(historySavePending || hasUnsavedRecording) {
            discardSessionAudio()
        } else { status = "当前内容尚未保存，仅当前会话可重试，退出前请重新保存。" }
        showAnswer = false
        sessionContext = nil; contextStatus = ""
    }

    func retryHistory(id: UUID) {
        guard !busy, library.history.contains(where: { $0.id == id }) else { return }
        guard preserveSessionBeforeReplacement() else { return }
        guard let entry = library.history.first(where: { $0.id == id }), library.canRetry(entry) else { return }
        stopHistoryAudio()
        let retainedAudio = library.audioURL(for: id)
        var workingAudio: URL?
        if let retainedAudio {
            let copy = sessionRoot.appendingPathComponent("\(UUID().uuidString).wav")
            do {
                try FileManager.default.copyItem(at: retainedAudio, to: copy)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                workingAudio = copy
            } catch {
                try? FileManager.default.removeItem(at: copy)
                status = "无法读取保留的录音：\(error.localizedDescription)"; return
            }
        }
        canRetryProcessing = false; apiRetryAttempt = 0
        discardSessionAudio()
        session = UUID(); sessionHistoryID = id
        historySavePending = false; sessionSucceeded = entry.succeeded; sessionCancelled = entry.cancelled
        audioURL = workingAudio; hasRecording = workingAudio != nil
        destination = nil // Never reuse an old application/selection for a history retry.
        sessionContext = nil; contextStatus = "历史未保存页面上下文 · 本次仅使用口述原文"
        if entry.mode == "context", entry.contextInputText != nil || entry.contextScreenshotFileName != nil {
            let screenshot = library.screenshotURL(for: id).flatMap { try? Data(contentsOf: $0) }
            contextStatus = entry.contextCaptureStatus ?? "使用历史保存的页面上下文"
            sessionContext = VoiceContext(application: entry.application, windowTitle: entry.contextWindowTitle ?? "",
                inputText: entry.contextInputText ?? "",
                imageDataURL: screenshot.map { "data:image/jpeg;base64," + $0.base64EncodedString() }, captureStatus: contextStatus)
        }
        sessionMode = InputMode(rawValue: entry.mode) ?? .dictate; mode = sessionMode
        sessionLanguage = entry.language; sessionTargetLanguage = entry.targetLanguage
        raw = entry.raw; result = entry.text; seconds = entry.duration; showAnswer = false
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recognize()
        } else {
            let token = session, text = raw
            phase = .polishing
            status = "正在重新处理历史记录……"
            work = Task {
                guard session == token, !Task.isCancelled else { return }
                let completed = await processText(text, token: token, deliver: false)
                guard session == token, !Task.isCancelled else { return }
                finishHistorySave(succeeded: completed)
            }
        }
    }

    func playHistoryAudio(id: UUID) {
        guard !busy else { return }
        if playingHistoryID == id { stopHistoryAudio(); return }
        stopHistoryAudio()
        guard let audio = library.audioURL(for: id) else { status = "这条记录没有保留录音。"; return }
        do {
            let playback = try AVAudioPlayer(contentsOf: audio)
            playback.delegate = self
            guard playback.prepareToPlay(), playback.play() else { throw VoiceError.message("无法播放这段录音。") }
            player = playback; playingHistoryID = id
        } catch { status = "录音播放失败：\(error.localizedDescription)" }
    }

    func stopHistoryAudio() {
        player?.stop(); player = nil; playingHistoryID = nil
    }

    private func discardSessionAudio() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil; hasRecording = false
        historySavePending = false
    }

    private func libraryDidChange() {
        if let playingHistoryID, library.audioURL(for: playingHistoryID) == nil { stopHistoryAudio() }
        if let sessionHistoryID, !library.history.contains(where: { $0.id == sessionHistoryID }) {
            self.sessionHistoryID = nil
            if phase == .transcribing || phase == .polishing {
                session = UUID(); work?.cancel(); work = nil
                phase = .ready; status = "这条历史记录已删除，处理已取消。"
            }
            // An authorization request may already be preparing a new recording.
            // Removing an older entry must not strand that request in authorizing.
            if phase != .recording { discardSessionAudio() }
        }
        if library.retention == .never, !busy { discardSessionAudio() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stopHistoryAudio()
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.recorder?.stop(); self.recorder = nil
            self.endLiveTranscription()
            self.meter?.invalidate(); self.meter = nil
            self.phase = .ready; self.level = 0
            self.hasRecording = self.audioURL != nil
            self.status = "麦克风录音中断，已有录音保留，可重试识别。"
            self.saveHistory(succeeded: false)
            if self.library.retention == .never {
                self.discardSessionAudio()
                self.status = "麦克风录音中断，请重新录制。"
            }
        }
    }
}
