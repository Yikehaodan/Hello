import Foundation

@MainActor
private final class UnusedLoginItems: LoginItemManaging {
    var state: LoginItemState { .notRegistered }
    func register() throws { preconditionFailure("Controller test must not change login registration") }
    func unregister() throws { preconditionFailure("Controller test must not change login registration") }
    func openSettings() { preconditionFailure("Controller test must not open System Settings") }
}

@MainActor
final class PermissionGate {
    private(set) var requests = 0
    private var continuations: [CheckedContinuation<Bool, Never>?] = []

    func request() async -> Bool {
        requests += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func resolve(_ index: Int, allowed: Bool) {
        precondition(continuations.indices.contains(index) && continuations[index] != nil)
        continuations[index]?.resume(returning: allowed)
        continuations[index] = nil
    }
}

@MainActor
private final class TranscriptionGate {
    var urls: [URL] = []
    var continuations: [CheckedContinuation<String, Error>] = []
    func run(_ url: URL, language: String, dictionary: String) async throws -> String {
        urls.append(url)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
}

@MainActor
private final class ProcessingGate {
    var inputs: [(text: String, mode: InputMode, target: String, selection: String)] = []
    var continuations: [CheckedContinuation<VoiceProcessingResult, Error>] = []
    func run(_ text: String, mode: InputMode, target: String, dictionary: String, selection: String) async throws -> VoiceProcessingResult {
        inputs.append((text, mode, target, selection))
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
}

@main
struct VoiceModelTests {
    @MainActor
    static func main() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("lightvoice-controller-tests-\(UUID())")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let gate = PermissionGate()
        let library = LibraryStore(root: sandbox.appendingPathComponent("library"))
        let recordings = sandbox.appendingPathComponent("recordings")
        let preferencesSuite = "LightVoice.ControllerPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: preferencesSuite)!
        defer { defaults.removePersistentDomain(forName: preferencesSuite) }
        let preferences = AppPreferences(defaults: defaults, loginItems: UnusedLoginItems(),
            microphoneProvider: { MicrophoneSnapshot(devices: [], permission: .notDetermined) }, openURL: { _ in false })
        let model = VoiceModel(library: library, sessionRoot: recordings, preferences: preferences, requestMicrophoneAccess: { await gate.request() })
        check(model.preferences === preferences, "native preferences dependency is preserved")

        model.toggle()
        check(model.phase == .authorizing && model.busy, "toggle occupies state before yielding")
        model.cancel()
        await settle()
        check(model.phase == .ready && gate.requests == 0, "immediate cancellation prevents permission request")
        check(model.status == "已取消。" && !model.hasRecording, "queued start cannot overwrite cancellation")

        model.toggle(mode: .translate)
        model.toggle(mode: .ask)
        model.toggle()
        check(model.mode == .translate && model.phase == .authorizing, "repeated toggles cannot replace a pending session")
        await eventually("one permission request") { gate.requests == 1 }
        model.toggle()
        await settle()
        check(gate.requests == 1, "repeated toggle while authorizing does not request again")
        model.cancel()
        gate.resolve(0, allowed: true)
        await settle()
        check(model.phase == .ready && model.status == "已取消。" && !model.hasRecording, "late permission result cannot restart canceled recording")

        model.toggle(mode: .dictate)
        await eventually("second permission request") { gate.requests == 2 }
        model.cancel()
        model.toggle(mode: .translate)
        await eventually("replacement permission request") { gate.requests == 3 }
        gate.resolve(1, allowed: true)
        await settle()
        check(model.phase == .authorizing && model.mode == .translate, "old response cannot alter the replacement session")
        gate.resolve(2, allowed: false)
        await eventually("denied permission returns ready") { model.phase == .ready }
        check(model.status.contains("麦克风") && !model.hasRecording, "permission denial is reported without recording")

        model.raw = "需要整理的原文"
        model.result = "先前结果"
        model.polish()
        check(model.phase == .polishing, "polish occupies state before yielding")
        model.polish()
        model.cancel()
        await settle()
        check(model.phase == .ready && model.status == "已取消。", "immediate polish cancellation does not launch processing")
        check(model.raw == "需要整理的原文" && model.result == "先前结果", "cancellation preserves visible text")
        check(library.history.isEmpty, "canceled work does not append history")

        model.recognize()
        check(model.phase == .ready, "retry without an audio file stays ready")
        let files = try FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil)
        check(files.isEmpty, "no microphone file was created")
        check(gate.requests == 3, "all permission requests passed through the isolated gate")

        let syntheticAudio = sandbox.appendingPathComponent("synthetic.wav")
        try Data("synthetic audio passed only to an isolated transcriber".utf8).write(to: syntheticAudio)
        let retryLibrary = LibraryStore(root: sandbox.appendingPathComponent("retry-library"))
        let retrySessions = sandbox.appendingPathComponent("retry-sessions")
        let transcription = TranscriptionGate(), processing = ProcessingGate()
        let retry = VoiceModel(library: retryLibrary, sessionRoot: retrySessions, preferences: preferences,
            requestMicrophoneAccess: { preconditionFailure("History retry must never request a microphone") },
            transcriptionOperation: { try await transcription.run($0, language: $1, dictionary: $2) },
            processingOperation: { try await processing.run($0, mode: $1, target: $2, dictionary: $3, selection: $4) })
        let retryID = retryLibrary.addHistory(raw: "", text: "", duration: 4, application: "Fixture",
            mode: "translate", succeeded: false, cancelled: true, audio: syntheticAudio,
            language: "zh", targetLanguage: "French")!
        let retainedAudio = retryLibrary.audioURL(for: retryID)!
        retry.retryHistory(id: retryID)
        check(retry.phase == .transcribing && retry.retryingHistoryID == retryID, "audio-only retry occupies processing state synchronously")
        await eventually("isolated transcription started") { transcription.urls.count == 1 }
        check(transcription.urls[0].path != retainedAudio.path && transcription.urls[0].deletingLastPathComponent().path == retrySessions.path,
              "recognizer receives a working copy, never the retained source")
        retry.cancel()
        check(retryLibrary.history.count == 1 && retryLibrary.history[0].cancelled && retry.hasRecording,
              "cancel during transcription retains one retryable audio history entry")
        transcription.continuations[0].resume(returning: "late transcription")
        await settle()
        check(retry.raw.isEmpty && retryLibrary.history[0].raw.isEmpty && processing.inputs.isEmpty,
              "late cancelled transcription cannot overwrite history or launch processing")
        check(FileManager.default.fileExists(atPath: retainedAudio.path), "cancel does not remove retained audio")

        retry.retryHistory(id: retryID)
        await eventually("replacement transcription") { transcription.urls.count == 2 }
        transcription.continuations[1].resume(returning: "明天见")
        await eventually("isolated translation started") { processing.inputs.count == 1 }
        check(processing.inputs[0].mode == .translate && processing.inputs[0].target == "French" && processing.inputs[0].selection.isEmpty,
              "history retry restores mode and target language without an old application's selection")
        retry.cancel()
        check(retryLibrary.history[0].raw == "明天见" && retryLibrary.history[0].cancelled,
              "cancel during text processing persists the already recognized raw text")
        processing.continuations[0].resume(returning: VoiceProcessingResult(text: "stale answer"))
        await settle()
        check(retry.result != "stale answer" && retryLibrary.history[0].text != "stale answer", "late cancelled result is ignored")

        retry.retryHistory(id: retryID)
        await eventually("raw text retry") { processing.inputs.count == 2 }
        check(transcription.urls.count == 2, "available raw text retries text processing without ASR")
        processing.continuations[1].resume(returning: VoiceProcessingResult(text: "À demain."))
        await eventually("retry completes") { retry.phase == .ready && retryLibrary.history[0].succeeded }
        check(retryLibrary.history.count == 1 && retryLibrary.history[0].id == retryID &&
              retryLibrary.history[0].text == "À demain." && !retryLibrary.history[0].cancelled,
              "successful retry updates the original record rather than adding duplicates")
        check(retryLibrary.totalDuration == 4 && retryLibrary.audioURL(for: retryID) != nil && !retry.hasRecording,
              "success keeps retained audio and counts duration once while removing its working copy")

        retry.retryHistory(id: retryID)
        await eventually("retry before delete") { processing.inputs.count == 3 }
        retryLibrary.deleteHistory(id: retryID)
        await eventually("delete cancels active retry") { retry.phase == .ready && !retry.hasRecording }
        processing.continuations[2].resume(returning: VoiceProcessingResult(text: "must not resurrect"))
        await settle()
        check(retryLibrary.history.isEmpty && !FileManager.default.fileExists(atPath: retainedAudio.path),
              "deletion cancels retry and late results cannot resurrect metadata or audio")

        let neverID = retryLibrary.addHistory(raw: "再次处理", text: "", duration: 2, application: "Fixture",
            succeeded: false, audio: syntheticAudio)!
        retry.retryHistory(id: neverID)
        await eventually("retry before never retention") { processing.inputs.count == 4 }
        retryLibrary.retention = .never
        await eventually("never cancels retry") { retry.phase == .ready && !retry.hasRecording }
        processing.continuations[3].resume(returning: VoiceProcessingResult(text: "not retained"))
        await settle()
        let remainingSessions = try FileManager.default.contentsOfDirectory(atPath: retrySessions.path)
        check(retryLibrary.history.isEmpty && remainingSessions.isEmpty,
              "never retention removes both retained and working audio and blocks late writes")

        retryLibrary.retention = .forever
        let failureID = retryLibrary.addHistory(raw: "", text: "", duration: 2, application: "Fixture",
            succeeded: false, cancelled: true, audio: syntheticAudio)!
        retry.retryHistory(id: failureID)
        await eventually("failed transcription fixture") { transcription.urls.count == 3 }
        transcription.continuations[2].resume(throwing: VoiceError.message("fixture recognition failure"))
        await eventually("failure remains retryable") { retry.phase == .ready }
        check(!retryLibrary.history[0].succeeded && !retryLibrary.history[0].cancelled &&
              retryLibrary.audioURL(for: failureID) != nil && retry.hasRecording,
              "recognition failure keeps the owned recording and marks the existing item for retry")
        retryLibrary.deleteHistory(id: failureID)
        await eventually("failed retry audio cleaned") { !retry.hasRecording }

        let pendingGate = PermissionGate()
        let pendingLibrary = LibraryStore(root: sandbox.appendingPathComponent("pending-library"))
        let pendingModel = VoiceModel(library: pendingLibrary, sessionRoot: sandbox.appendingPathComponent("pending-sessions"), preferences: preferences,
            requestMicrophoneAccess: { await pendingGate.request() },
            processingOperation: { _, _, _, _, _ in VoiceProcessingResult(text: "processed fixture") })
        let oldID = pendingLibrary.addHistory(raw: "old fixture", text: "", duration: 1, application: "Fixture", succeeded: false)!
        pendingModel.retryHistory(id: oldID)
        await eventually("old retry completed") { pendingModel.phase == .ready }
        pendingModel.toggle()
        await eventually("new authorization pending") { pendingGate.requests == 1 }
        pendingLibrary.deleteHistory(id: oldID)
        await settle()
        check(pendingModel.phase == .authorizing, "deleting old history does not cancel an unrelated new authorization")
        pendingGate.resolve(0, allowed: false)
        await eventually("new authorization still completes") { pendingModel.phase == .ready }
        check(gate.requests == 3, "history paths did not request microphone access")
        let protectedRoot = sandbox.appendingPathComponent("protected-library")
        let protectedBackup = sandbox.appendingPathComponent("protected-library-backup")
        let protectedLibrary = LibraryStore(root: protectedRoot)
        let protectedSessions = sandbox.appendingPathComponent("protected-sessions")
        let protectedProcessing = ProcessingGate()
        var protectedPermissionRequests = 0
        let protected = VoiceModel(library: protectedLibrary, sessionRoot: protectedSessions, preferences: preferences,
            requestMicrophoneAccess: { protectedPermissionRequests += 1; return false },
            processingOperation: { try await protectedProcessing.run($0, mode: $1, target: $2, dictionary: $3, selection: $4) })
        let protectedID = protectedLibrary.addHistory(raw: "保留录音", text: "", duration: 2, application: "Fixture",
            succeeded: false, audio: syntheticAudio)!
        let otherID = protectedLibrary.addHistory(raw: "其他记录", text: "", duration: 1, application: "Fixture", succeeded: false)!
        protected.retryHistory(id: protectedID)
        await eventually("processing before storage failure") { protectedProcessing.inputs.count == 1 }
        let protectedAudio = try FileManager.default.contentsOfDirectory(at: protectedSessions, includingPropertiesForKeys: nil).first!
        // Replace only this fixture's storage directory with a file, so metadata writes fail
        // independently of recognition success, filesystem ownership or the test user's UID.
        try FileManager.default.moveItem(at: protectedRoot, to: protectedBackup)
        try Data("blocked fixture directory".utf8).write(to: protectedRoot)
        protectedProcessing.continuations[0].resume(returning: VoiceProcessingResult(text: "已处理但未保存"))
        await eventually("successful processing with failed history commit") { protected.phase == .ready }
        check(protected.hasRecording && protected.hasUnsavedRecording && FileManager.default.fileExists(atPath: protectedAudio.path),
              "successful processing cannot delete its recording after failed history persistence")
        check(protected.result == "已处理但未保存" && protected.status.contains("当前会话"), "unsaved result remains visible with a temporary recovery warning")
        protected.cancel()
        check(protected.hasRecording && FileManager.default.fileExists(atPath: protectedAudio.path), "cancel while ready cannot silently erase an unsaved recording")
        protected.toggle()
        await settle()
        check(protected.phase == .ready && protectedPermissionRequests == 0 && protected.hasUnsavedRecording,
              "new recording is blocked before permission or capture if the previous save still fails")
        protected.retryHistory(id: otherID)
        await settle()
        check(protectedProcessing.inputs.count == 1 && protected.result == "已处理但未保存" && protected.hasRecording,
              "retrying another history entry cannot replace unsaved audio or result")
        check(!protected.prepareForTermination() && protected.hasRecording && FileManager.default.fileExists(atPath: protectedAudio.path),
              "termination requests confirmation when its final persistence attempt fails")
        try FileManager.default.removeItem(at: protectedRoot)
        try FileManager.default.moveItem(at: protectedBackup, to: protectedRoot)
        check(protected.prepareForTermination() && !protected.hasRecording && !protected.hasUnsavedRecording,
              "repaired persistence allows termination and then removes the working recording")
        check(!FileManager.default.fileExists(atPath: protectedAudio.path) &&
              protectedLibrary.history.first(where: { $0.id == protectedID })?.text == "已处理但未保存" &&
              protectedLibrary.audioURL(for: protectedID) != nil,
              "successful final save retains the original history audio and latest result")
        let reloadedProtectedLibrary = LibraryStore(root: protectedRoot)
        check(reloadedProtectedLibrary.history.first(where: { $0.id == protectedID })?.text == "已处理但未保存",
              "termination success reflects committed data that another store can reload")

        protected.retryHistory(id: protectedID)
        await eventually("busy termination fixture") { protectedProcessing.inputs.count == 2 }
        try FileManager.default.moveItem(at: protectedRoot, to: protectedBackup)
        try Data("blocked fixture directory".utf8).write(to: protectedRoot)
        check(!protected.prepareForTermination() && protected.phase == .ready && protected.hasUnsavedRecording,
              "termination cancels processing but keeps audio when cancellation cannot be persisted")
        protectedProcessing.continuations[1].resume(returning: VoiceProcessingResult(text: "late terminated result"))
        await settle()
        check(protected.result != "late terminated result", "late result cannot overwrite canceled termination state")
        try FileManager.default.removeItem(at: protectedRoot)
        try FileManager.default.moveItem(at: protectedBackup, to: protectedRoot)
        check(protected.prepareForTermination() && protectedLibrary.history.first(where: { $0.id == protectedID })?.cancelled == true,
              "a later termination attempt commits cancellation once storage recovers")

        // The add-history path has the same commit contract even when only typed text exists.
        let addRoot = sandbox.appendingPathComponent("blocked-new-library")
        let addLibrary = LibraryStore(root: addRoot)
        try Data("blocked new history directory".utf8).write(to: addRoot)
        let addModel = VoiceModel(library: addLibrary, sessionRoot: sandbox.appendingPathComponent("add-sessions"), preferences: preferences,
            requestMicrophoneAccess: { preconditionFailure("No capture in persistence tests") },
            processingOperation: { _, _, _, _, _ in VoiceProcessingResult(text: "new processed fixture") })
        addModel.raw = "new raw fixture"
        addModel.polish()
        await eventually("new history save fails") { addModel.phase == .ready }
        check(addLibrary.history.isEmpty && !addModel.prepareForTermination(), "failed first history insertion blocks silent termination")
        try FileManager.default.removeItem(at: addRoot)
        check(addModel.prepareForTermination() && addLibrary.history.count == 1 && addLibrary.history[0].succeeded,
              "retrying a first insertion commits one successful entry")
        check(addModel.prepareForTermination() && addLibrary.history.count == 1, "repeated termination checks do not duplicate history")

        protectedLibrary.retention = .never
        check(protected.prepareForTermination(), "explicit never retention permits termination without saving")
        var processingAttempts = 0
        let retryUI = VoiceModel(library: LibraryStore(root: sandbox.appendingPathComponent("retry-ui")),
            sessionRoot: sandbox.appendingPathComponent("retry-ui-sessions"), preferences: preferences,
            processingOperation: { _, mode, target, _, _ in
                processingAttempts += 1
                check(mode == .translate && target == "French", "manual retry keeps failed request context")
                if processingAttempts == 1 { throw VoiceError.message("API 连接失败，已重试 5 次。") }
                return VoiceProcessingResult(text: "Bonjour")
            })
        retryUI.raw = "你好"; retryUI.mode = .translate; retryUI.targetLanguage = "French"
        retryUI.polish()
        await eventually("API failure exposes retry") { retryUI.canRetryProcessing && !retryUI.busy }
        check(retryUI.raw == "你好" && retryUI.result == "你好", "API failure retains source text")
        retryUI.mode = .ask; retryUI.targetLanguage = "English"
        retryUI.retryProcessing(); retryUI.retryProcessing()
        await eventually("manual retry completes") { !retryUI.busy }
        check(processingAttempts == 2 && retryUI.result == "Bonjour" && !retryUI.canRetryProcessing,
              "retry runs once, preserves context, and clears retry button on success")

        let contextDictation = VoiceModel(library: LibraryStore(root: sandbox.appendingPathComponent("context-dictation")),
            sessionRoot: sandbox.appendingPathComponent("context-dictation-sessions"), preferences: preferences,
            processingOperation: { text, mode, _, _, _ in
                check(mode == .context, "context dictation mode survives processing")
                return VoiceProcessingResult(text: text)
            })
        contextDictation.mode = .context
        contextDictation.raw = "你觉得这个任务应该如何设计？"
        contextDictation.polish()
        await eventually("context dictation completes") { !contextDictation.busy }
        check(contextDictation.result == contextDictation.raw && !contextDictation.showAnswer,
              "context dictation retains the spoken question and never opens the answer panel")
        check(!InputMode.context.isAssistant && InputMode.ask.isAssistant,
              "only Fn Space uses assistant delivery")

        print("PASS: state ownership, permission cancellation, isolated ASR/processing cancellation, retry persistence and failed-save/termination protection, restored mode/language, no duplicate history, late result guards, deletion and never-retention cleanup; no real microphone, playback or network requests")
    }

    @MainActor
    static func eventually(_ label: String, until predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("FAIL: timed out waiting for \(label)")
    }

    static func settle() async { try? await Task.sleep(for: .milliseconds(30)) }

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), "FAIL: \(label)")
    }
}
