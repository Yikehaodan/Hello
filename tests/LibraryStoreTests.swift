import Foundation

@main
struct LibraryStoreTests {
    @MainActor
    static func main() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("lightvoice-library-tests-\(UUID())")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let root = sandbox.appendingPathComponent("persistence")
        let store = LibraryStore(root: root)
        store.addWord("  DeepSeek  ")
        store.addWord("轻声输入")
        store.addHistory(raw: "你好 Swift输入", text: "你好 Swift输入", duration: 12.5, application: "TextEdit")
        let reload = LibraryStore(root: root)
        check(reload.words == store.words && reload.history == store.history, "exact save and reload")
        check(reload.totalDuration == 12.5 && reload.totalWords == 5, "mixed-language statistics")
        check(reload.dictionaryPrompt == "DeepSeek、轻声输入", "recognizer vocabulary")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("library.json").path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private file permissions")

        store.addWord("deepseek")
        check(store.words.count == 2 && store.errorMessage != nil, "case-insensitive duplicate rejected")
        store.addWord("\n\t  ")
        check(store.words.count == 2 && store.errorMessage != nil, "blank rejected")
        store.addWord(String(repeating: "长", count: 121))
        check(store.words.count == 2 && store.errorMessage != nil, "oversized word rejected")
        store.updateWord(id: store.words[1].id, text: "DeepSeek")
        check(store.words[1].text == "轻声输入", "edit cannot introduce a duplicate")
        let identity = store.words[1].id
        store.updateWord(id: identity, text: "轻声")
        check(store.words[1].text == "轻声" && store.words[1].id == identity && store.errorMessage == nil, "edit keeps identity")

        let count = try store.importCSV("\u{FEFF}word\r\n\"Acme, Inc.\"\r\n\"He said \"\"hello\"\"\"\r\nDeepSeek\r\n\"multi\nline\"\r\n")
        check(count == 3, "CSV headers, CRLF, comma, quotes, multiline and duplicates")
        check(store.words.suffix(3).map(\.text) == ["Acme, Inc.", "He said \"hello\"", "multi line"], "quoted CSV contents preserved")
        let beforeCSV = store.words
        for invalid in ["new\n\"unclosed", "new\n\"closed\"junk", "new\nwrong,columns", "new\nwrong\"quote"] {
            do { _ = try store.importCSV(invalid); fatalError("Expected malformed CSV rejection") }
            catch { check(store.words == beforeCSV && store.errorMessage != nil, "malformed import is atomic") }
        }
        check(LibraryStore(root: root).words == beforeCSV, "failed import leaves disk untouched")
        store.addHistory(raw: "bad", text: "bad", duration: .nan, application: "TextEdit")
        check(store.history.count == 1 && store.errorMessage != nil, "invalid duration rejected")
        store.addHistory(raw: "failure", text: "failure", duration: 4, application: "TextEdit", succeeded: false)
        check(store.totalDuration == 12.5 && store.totalWords == 5, "failed entries excluded from usage statistics")
        store.deleteHistory(id: store.history[0].id)
        store.deleteWord(id: identity)
        check(LibraryStore(root: root).history == store.history && LibraryStore(root: root).words == store.words, "deletions persist")

        let contextStore = LibraryStore(root: sandbox.appendingPathComponent("context-metadata"))
        let contextID = contextStore.addHistory(raw: "口述", text: "口述", duration: 1, application: "Chrome", mode: "context",
            contextCaptureStatus: "已读取输入框（7 字） · 已获取窗口截图")!
        check(LibraryStore(root: sandbox.appendingPathComponent("context-metadata")).history.first?.contextCaptureStatus == "已读取输入框（7 字） · 已获取窗口截图", "context capture metadata survives reload")
        check(contextStore.updateHistory(id: contextID, raw: "口述", text: "口述", succeeded: true,
            contextCaptureStatus: "历史重新处理 · 未使用页面上下文"), "context metadata updates with retry")
        let legacy = HistoryEntry(raw: "旧记录", text: "旧记录", duration: 1, application: "Test")
        let legacyData = try JSONEncoder().encode(legacy)
        let decodedLegacy = try JSONDecoder().decode(HistoryEntry.self, from: legacyData)
        check(decodedLegacy.contextCaptureStatus == nil, "legacy records without capture metadata remain readable")
        check(decodedLegacy.contextScreenshotFileName == nil && decodedLegacy.contextInputText == nil, "legacy screenshot/context fields are optional")

        let screenshotRoot = sandbox.appendingPathComponent("screenshot-history")
        let screenshots = LibraryStore(root: screenshotRoot)
        let imageBytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let imageURL = "data:image/jpeg;base64," + imageBytes.base64EncodedString()
        let screenshotID = screenshots.addHistory(raw: "这个字段", text: "这个字段", duration: 1, application: "Chrome", mode: "context",
            contextCaptureStatus: "已读取输入框（4 字） · 已获取窗口截图", contextInputText: "测试草稿",
            contextWindowTitle: "测试页面", contextScreenshotDataURL: imageURL)!
        let keptScreenshot = screenshots.screenshotURL(for: screenshotID)!
        check((try? Data(contentsOf: keptScreenshot)) == imageBytes, "history preserves captured screenshot bytes")
        let screenshotAttributes = try FileManager.default.attributesOfItem(atPath: keptScreenshot.path)
        check((screenshotAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "screenshots use private permissions")
        let screenshotReload = LibraryStore(root: screenshotRoot)
        check(screenshotReload.history.first?.contextInputText == "测试草稿" && screenshotReload.history.first?.contextWindowTitle == "测试页面" &&
              screenshotReload.screenshotURL(for: screenshotID) == keptScreenshot, "screenshot and focused draft survive reload")
        check(screenshotReload.updateHistory(id: screenshotID, raw: "再试", text: "再试", succeeded: true) &&
              screenshotReload.screenshotURL(for: screenshotID) == keptScreenshot, "retry preserves original screenshot identity")
        screenshotReload.deleteHistory(id: screenshotID)
        check(!FileManager.default.fileExists(atPath: keptScreenshot.path), "deleting history removes its screenshot")
        let neverScreenshotID = screenshots.addHistory(raw: "测试", text: "测试", duration: 1, application: "Chrome", contextScreenshotDataURL: imageURL)!
        let neverScreenshot = screenshots.screenshotURL(for: neverScreenshotID)!
        screenshots.retention = .never
        check(!FileManager.default.fileExists(atPath: neverScreenshot.path) && screenshots.screenshotURL(for: neverScreenshotID) == nil, "never retention removes screenshots")
        let invalidScreenshot = LibraryStore(root: sandbox.appendingPathComponent("invalid-screenshot"))
        check(invalidScreenshot.addHistory(raw: "原文", text: "原文", duration: 1, application: "Chrome", contextScreenshotDataURL: "https://invalid/image.jpg") == nil &&
              invalidScreenshot.history.isEmpty, "invalid screenshot cannot commit partial history")

        let usageRoot = sandbox.appendingPathComponent("spoken-usage")
        let usage = LibraryStore(root: usageRoot)
        usage.addHistory(raw: "为什么？", text: String(repeating: "这是很长的助手回答。", count: 100),
                         duration: 2, application: "Test", mode: "ask")
        check(usage.totalWords == 3 && usage.totalDuration == 2, "short question counts spoken input rather than long generated answer")
        usage.addHistory(raw: "明天见", text: "I look forward to seeing you tomorrow.",
                         duration: 3, application: "Test", mode: "translate")
        check(usage.totalWords == 6 && usage.totalDuration == 5, "translation counts source-language input")
        usage.addHistory(raw: "嗯，明天见。", text: "明天见。", duration: 4, application: "Test")
        check(usage.totalWords == 10 && usage.totalDuration == 9, "dictation counts spoken input before polishing")
        usage.addHistory(raw: "失败的话语", text: "失败的话语", duration: 10, application: "Test", mode: "ask", succeeded: false)
        let savedUsage = LibraryStore(root: usageRoot)
        check(savedUsage.totalWords == 10 && savedUsage.totalDuration == 9, "all successful modes share the same persisted usage scope")

        let now = Date()
        let calendar = Calendar.current
        let days = [0, 2, 10, 45, 400]
        for policy in HistoryRetention.allCases {
            let policyRoot = sandbox.appendingPathComponent(policy.rawValue)
            try fixture(at: policyRoot, dates: days.map { calendar.date(byAdding: .day, value: -$0, to: now)! })
            let subject = LibraryStore(root: policyRoot)
            subject.retention = policy
            let expected: Int
            switch policy {
            case .forever: expected = 5
            case .year: expected = 4
            case .month: expected = 3
            case .week: expected = 2
            case .day: expected = 1
            case .never: expected = 0
            }
            check(subject.history.count == expected, "\(policy.rawValue) pruning")
            let restored = LibraryStore(root: policyRoot)
            check(restored.retention == policy && restored.history == subject.history, "\(policy.rawValue) retention persists")
            if policy == .never {
                subject.addHistory(raw: "not saved", text: "not saved", duration: 1, application: "Test")
                check(LibraryStore(root: policyRoot).history.isEmpty, "never does not record new text")
                check(subject.words.count == 1, "retention does not erase vocabulary")
            }
        }
        let expiredRoot = sandbox.appendingPathComponent("expired-on-load")
        try fixture(at: expiredRoot, dates: [calendar.date(byAdding: .day, value: -2, to: now)!], retention: .day)
        check(LibraryStore(root: expiredRoot).history.isEmpty && LibraryStore(root: expiredRoot).history.isEmpty, "startup expiry persists")

        let blocked = sandbox.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocked)
        let failing = LibraryStore(root: blocked)
        failing.addWord("cannot save")
        check(failing.words.isEmpty && failing.errorMessage != nil, "write failure is visible and rolls back")
        failing.retention = .never
        check(failing.retention == .forever && failing.errorMessage != nil, "failed preference save rolls back")

        let corruptRoot = sandbox.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptFile = corruptRoot.appendingPathComponent("library.json")
        let corruptBytes = Data("{malformed original}".utf8)
        try corruptBytes.write(to: corruptFile)
        let corrupt = LibraryStore(root: corruptRoot)
        check(corrupt.errorMessage != nil, "corrupt file surfaced")
        corrupt.addWord("must not overwrite")
        let bytesAfterMutation = try Data(contentsOf: corruptFile)
        check(corrupt.words.isEmpty && bytesAfterMutation == corruptBytes, "corrupt original protected")

        let audioFixture = sandbox.appendingPathComponent("synthetic.wav")
        let audioBytes = Data("synthetic non-private audio fixture".utf8)
        try audioBytes.write(to: audioFixture)
        let audioRoot = sandbox.appendingPathComponent("audio-history")
        let audioStore = LibraryStore(root: audioRoot)
        let audioID = audioStore.addHistory(raw: "", text: "", duration: 3, application: "Fixture",
            mode: "translate", succeeded: false, cancelled: true, audio: audioFixture,
            language: "zh", targetLanguage: "French")!
        let kept = audioStore.audioURL(for: audioID)!
        check(kept != audioFixture && (try? Data(contentsOf: kept)) == audioBytes, "cancelled audio-only history makes a private owned copy")
        let keptAttributes = try FileManager.default.attributesOfItem(atPath: kept.path)
        check((keptAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "retained recording has private permissions")
        check(audioStore.canRetry(audioStore.history[0]), "audio-only history can retry")
        let audioReload = LibraryStore(root: audioRoot)
        check(audioReload.history[0].cancelled && audioReload.history[0].language == "zh" &&
              audioReload.history[0].targetLanguage == "French" && audioReload.audioURL(for: audioID) != nil,
              "recording reference and processing language persist")
        check(audioStore.updateHistory(id: audioID, raw: "你好", text: "Bonjour", succeeded: true), "retry updates an existing history entry")
        check(audioStore.history.count == 1 && audioStore.history[0].id == audioID &&
              !audioStore.history[0].cancelled && audioStore.audioURL(for: audioID) == kept,
              "retry preserves identity and recording without duplicate statistics")
        audioStore.deleteHistory(id: audioID)
        check(!FileManager.default.fileExists(atPath: kept.path) && audioStore.history.isEmpty, "deleting history also deletes its recording")
        check(!audioStore.updateHistory(id: audioID, raw: "late", text: "late", succeeded: true), "late retry cannot resurrect a deleted entry")
        check(FileManager.default.fileExists(atPath: audioFixture.path), "cleanup never deletes the caller's source recording")

        let neverID = audioStore.addHistory(raw: "", text: "", duration: 1, application: "Fixture", succeeded: false, audio: audioFixture)!
        let neverAudio = audioStore.audioURL(for: neverID)!
        audioStore.retention = .never
        check(!FileManager.default.fileExists(atPath: neverAudio.path) && audioStore.history.isEmpty, "never clears retained audio as well as metadata")
        check(audioStore.addHistory(raw: "", text: "", duration: 1, application: "Fixture", audio: audioFixture) == nil,
              "never does not copy new recordings")
        let neverFiles = try FileManager.default.contentsOfDirectory(atPath: audioRoot.appendingPathComponent("recordings").path)
        check(neverFiles.isEmpty, "no audio remains under never retention")

        let oldSchemaRoot = sandbox.appendingPathComponent("old-schema")
        try fixture(at: oldSchemaRoot, dates: [Date()])
        let oldSchemaFile = oldSchemaRoot.appendingPathComponent("library.json")
        var oldSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: oldSchemaFile)) as! [String: Any]
        var oldEntry = (oldSnapshot["history"] as! [[String: Any]])[0]
        for field in ["cancelled", "audioFileName", "language", "targetLanguage", "mode", "succeeded"] { oldEntry.removeValue(forKey: field) }
        oldSnapshot["history"] = [oldEntry]
        try JSONSerialization.data(withJSONObject: oldSnapshot).write(to: oldSchemaFile)
        let old = LibraryStore(root: oldSchemaRoot)
        check(old.errorMessage == nil && old.history.count == 1 && old.history[0].succeeded &&
              !old.history[0].cancelled && old.history[0].audioFileName == nil && old.history[0].language == "auto",
              "legacy JSON missing new and optional status fields remains readable")

        let orphanRoot = sandbox.appendingPathComponent("orphan-audio")
        let orphanFolder = orphanRoot.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)
        let orphan = orphanFolder.appendingPathComponent("\(UUID()).wav")
        let unrelated = orphanFolder.appendingPathComponent("keep-user-file.wav")
        try audioBytes.write(to: orphan); try audioBytes.write(to: unrelated)
        _ = LibraryStore(root: orphanRoot)
        check(!FileManager.default.fileExists(atPath: orphan.path) && FileManager.default.fileExists(atPath: unrelated.path),
              "startup cleans only managed orphan audio after an interrupted first save")

        let linkedRoot = sandbox.appendingPathComponent("linked-audio")
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent("recordings"), withDestinationURL: orphanFolder)
        let linked = LibraryStore(root: linkedRoot)
        check(linked.addHistory(raw: "", text: "", duration: 1, application: "Fixture", audio: audioFixture) == nil &&
              linked.errorMessage != nil && linked.history.isEmpty, "symlink recording directory is rejected")
        check(FileManager.default.fileExists(atPath: unrelated.path), "rejected directory cannot clean external files")

        let expiredAudioRoot = sandbox.appendingPathComponent("expired-audio")
        let expireStore = LibraryStore(root: expiredAudioRoot)
        let expireID = expireStore.addHistory(raw: "test", text: "test", duration: 1, application: "Fixture", audio: audioFixture)!
        let expireURL = expireStore.audioURL(for: expireID)!
        let expireFile = expiredAudioRoot.appendingPathComponent("library.json")
        var expireSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: expireFile)) as! [String: Any]
        var expireEntry = (expireSnapshot["history"] as! [[String: Any]])[0]
        expireEntry["date"] = Date().addingTimeInterval(-3 * 86400).timeIntervalSinceReferenceDate
        expireSnapshot["history"] = [expireEntry]; expireSnapshot["retention"] = "day"
        try JSONSerialization.data(withJSONObject: expireSnapshot).write(to: expireFile)
        check(LibraryStore(root: expiredAudioRoot).history.isEmpty && !FileManager.default.fileExists(atPath: expireURL.path),
              "expired history removes its retained audio on reload")
        print("PASS: persistence, permissions, CSV, retention, statistics, rollback, legacy JSON, audio ownership, cancellation history, retry identity, deletion/expiry/never cleanup and symlink rejection")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), "FAIL: \(label)")
    }

    static func fixture(at root: URL, dates: [Date], retention: HistoryRetention = .forever) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = dates.enumerated().map { index, date in
            HistoryEntry(date: date, raw: "raw \(index)", text: "text \(index)", duration: 1, application: "Test")
        }
        struct Snapshot: Encodable {
            let version = 1
            let retention: HistoryRetention
            let history: [HistoryEntry]
            let words = [DictionaryWord(text: "retained vocabulary")]
        }
        let data = try JSONEncoder().encode(Snapshot(retention: retention, history: entries))
        try data.write(to: root.appendingPathComponent("library.json"))
    }
}
