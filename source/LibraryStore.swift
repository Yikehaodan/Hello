import Foundation
import Combine

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var raw: String
    var text: String
    var duration: Double
    var application: String
    var mode = "dictate"
    var succeeded = true
    var cancelled = false
    var audioFileName: String?
    var language = "auto"
    var targetLanguage = "English"
    var contextCaptureStatus: String? = nil
    var contextInputText: String? = nil
    var contextWindowTitle: String? = nil
    var contextScreenshotFileName: String? = nil
}

extension HistoryEntry {
    private enum CodingKeys: String, CodingKey {
        case id, date, raw, text, duration, application, mode, succeeded, cancelled, audioFileName, language, targetLanguage, contextCaptureStatus, contextInputText, contextWindowTitle, contextScreenshotFileName
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        raw = try values.decode(String.self, forKey: .raw)
        text = try values.decode(String.self, forKey: .text)
        duration = try values.decode(Double.self, forKey: .duration)
        application = try values.decode(String.self, forKey: .application)
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "dictate"
        succeeded = try values.decodeIfPresent(Bool.self, forKey: .succeeded) ?? true
        cancelled = try values.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        audioFileName = try values.decodeIfPresent(String.self, forKey: .audioFileName)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "English"
        contextCaptureStatus = try values.decodeIfPresent(String.self, forKey: .contextCaptureStatus)
        contextInputText = try values.decodeIfPresent(String.self, forKey: .contextInputText)
        contextWindowTitle = try values.decodeIfPresent(String.self, forKey: .contextWindowTitle)
        contextScreenshotFileName = try values.decodeIfPresent(String.self, forKey: .contextScreenshotFileName)
    }
}

struct DictionaryWord: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case manual, automatic }
    var id = UUID()
    var text: String
    var date = Date()
    var source: Source = .manual
}

enum HistoryRetention: String, Codable, CaseIterable, Identifiable {
    case forever, year, month, week, day, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forever: return "永久保留"
        case .year: return "1 年"
        case .month: return "1 个月"
        case .week: return "1 周"
        case .day: return "1 天"
        case .never: return "不保存"
        }
    }
    func cutoff(before date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .forever, .never: return nil
        case .year: return calendar.date(byAdding: .year, value: -1, to: date)
        case .month: return calendar.date(byAdding: .month, value: -1, to: date)
        case .week: return calendar.date(byAdding: .day, value: -7, to: date)
        case .day: return calendar.date(byAdding: .day, value: -1, to: date)
        }
    }
}

enum LibraryStoreError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var words: [DictionaryWord] = []
    @Published private(set) var errorMessage: String?
    @Published var retention: HistoryRetention = .forever {
        didSet {
            guard !restoringRetention, retention != oldValue else { return }
            do {
                try save(history: retained(history), words: words)
            } catch {
                restoringRetention = true
                retention = oldValue
                restoringRetention = false
                report(error)
            }
        }
    }

    private struct Snapshot: Codable {
        var version = 1
        var retention: HistoryRetention
        var history: [HistoryEntry]
        var words: [DictionaryWord]
    }
    private let root: URL
    private var file: URL { root.appendingPathComponent("library.json") }
    private var audioRoot: URL { root.appendingPathComponent("recordings", isDirectory: true) }
    private var screenshotRoot: URL { root.appendingPathComponent("context-screenshots", isDirectory: true) }
    private var restoringRetention = false
    private var loadFailed = false
    private var cleanupTimer: Timer?
    private static let maximumWords = 2_000
    private static let maximumWordLength = 120
    private static let maximumHistory = 10_000
    private static let maximumTextLength = 24_000
    private static let maximumBytes = 20 * 1_024 * 1_024
    private static let maximumAudioBytes = 16 * 1_024 * 1_024

    init(root: URL? = nil) {
        self.root = root ?? AppPaths.data
        load()
        if !loadFailed {
            do { try cleanAudio(keeping: history); try cleanScreenshots(keeping: history) }
            catch { errorMessage = "部分历史附件未能清理：\(error.localizedDescription)" }
        }
        // Expire old entries even when the menu-bar app remains open for days.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneExpiredHistory() }
        }
    }

    deinit { cleanupTimer?.invalidate() }

    var totalWords: Int {
        guard let cjk = try? NSRegularExpression(pattern: "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]"),
              let expression = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’-][\\p{L}\\p{N}]+)*") else { return 0 }
        return history.filter(\.succeeded).reduce(0) { total, entry in
            // Measure what the user dictated, including questions and translation
            // input, so generated answers cannot inflate the voice-usage metric.
            let range = NSRange(entry.raw.startIndex..., in: entry.raw)
            let remainder = cjk.stringByReplacingMatches(in: entry.raw, range: range, withTemplate: " ")
            return total + cjk.numberOfMatches(in: entry.raw, range: range) +
                expression.numberOfMatches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
        }
    }

    var totalDuration: Double { history.filter(\.succeeded).reduce(0) { $0 + $1.duration } }

    /// Vocabulary only; the caller decides how to present this to its recognizer.
    var dictionaryPrompt: String { words.map(\.text).joined(separator: "、") }

    @discardableResult
    func addHistory(raw: String, text: String, duration: Double, application: String,
                    mode: String = "dictate", succeeded: Bool = true, cancelled: Bool = false,
                    audio: URL? = nil, language: String = "auto", targetLanguage: String = "English", contextCaptureStatus: String? = nil,
                    contextInputText: String? = nil, contextWindowTitle: String? = nil, contextScreenshotDataURL: String? = nil) -> UUID? {
        guard retention != .never else { return nil }
        var copiedAudio: URL?
        var savedScreenshot: URL?
        do {
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audio != nil else { return nil }
            guard raw.count <= Self.maximumTextLength, text.count <= Self.maximumTextLength,
                  duration.isFinite, duration >= 0, application.count <= 300, mode.count <= 40,
                  language.count <= 40, targetLanguage.count <= 80 else {
                throw LibraryStoreError.invalid("这条记录超过保存限制，或录音时长无效；当前文字仍保留在窗口中。")
            }
            var entries = retained(history)
            guard entries.count < Self.maximumHistory else {
                throw LibraryStoreError.invalid("历史记录已达 10,000 条，请删除部分记录后重试。")
            }
            var entry = HistoryEntry(raw: raw, text: text, duration: duration, application: application,
                                     mode: mode, succeeded: succeeded, cancelled: cancelled,
                                     language: language, targetLanguage: targetLanguage, contextCaptureStatus: contextCaptureStatus.map { String($0.prefix(300)) },
                                     contextInputText: contextInputText.map { String($0.prefix(12000)) },
                                     contextWindowTitle: contextWindowTitle.map { String($0.prefix(300)) })
            if let audio {
                copiedAudio = try preserveAudio(audio, id: entry.id)
                entry.audioFileName = copiedAudio?.lastPathComponent
            }
            if let contextScreenshotDataURL {
                savedScreenshot = try preserveScreenshot(contextScreenshotDataURL, id: entry.id)
                entry.contextScreenshotFileName = savedScreenshot?.lastPathComponent
            }
            entries.insert(entry, at: 0)
            try save(history: entries, words: words)
            return entry.id
        } catch {
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
            if let savedScreenshot { try? FileManager.default.removeItem(at: savedScreenshot) }
            report(error)
            return nil
        }
    }

    /// A retry updates its original entry; deleted/expired entries are never recreated.
    @discardableResult
    func updateHistory(id: UUID, raw: String, text: String, succeeded: Bool, cancelled: Bool = false,
                       mode: String? = nil, targetLanguage: String? = nil, contextCaptureStatus: String? = nil) -> Bool {
        guard retention != .never else { return false }
        var entries = retained(history)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        do {
            guard raw.count <= Self.maximumTextLength, text.count <= Self.maximumTextLength,
                  (mode?.count ?? 0) <= 40, (targetLanguage?.count ?? 0) <= 80 else {
                throw LibraryStoreError.invalid("处理结果超过历史记录保存限制，当前文字仍保留在窗口中。")
            }
            entries[index].raw = raw; entries[index].text = text
            entries[index].succeeded = succeeded; entries[index].cancelled = cancelled
            if let mode { entries[index].mode = mode }
            if let targetLanguage { entries[index].targetLanguage = targetLanguage }
            if let contextCaptureStatus { entries[index].contextCaptureStatus = String(contextCaptureStatus.prefix(300)) }
            try save(history: entries, words: words)
            return true
        } catch { report(error); return false }
    }

    func audioURL(for id: UUID) -> URL? {
        guard retention != .never, let entry = retained(history).first(where: { $0.id == id }),
              let name = entry.audioFileName, name == "\(id.uuidString).wav",
              audioDirectoryIsSafe else { return nil }
        let url = audioRoot.appendingPathComponent(name)
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= Self.maximumAudioBytes else { return nil }
        return url
    }

    func canRetry(_ entry: HistoryEntry) -> Bool {
        retained(history).contains(where: { $0.id == entry.id }) &&
            (!entry.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audioURL(for: entry.id) != nil)
    }

    func screenshotURL(for id: UUID) -> URL? {
        guard retention != .never, let entry = retained(history).first(where: { $0.id == id }),
              let name = entry.contextScreenshotFileName, name == "\(id.uuidString).jpg",
              screenshotDirectoryIsSafe else { return nil }
        let url = screenshotRoot.appendingPathComponent(name)
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= 4 * 1024 * 1024 else { return nil }
        return url
    }

    private var screenshotDirectoryIsSafe: Bool {
        guard let info = try? screenshotRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return info.isDirectory == true && info.isSymbolicLink != true
    }

    private func preserveScreenshot(_ dataURL: String, id: UUID) throws -> URL {
        guard !loadFailed, dataURL.hasPrefix("data:image/jpeg;base64,"), dataURL.utf8.count <= 6 * 1024 * 1024,
              let data = Data(base64Encoded: String(dataURL.dropFirst("data:image/jpeg;base64,".count))),
              data.count <= 4 * 1024 * 1024, data.starts(with: [0xff, 0xd8, 0xff]) else {
            throw LibraryStoreError.invalid("页面截图无效或超过保存限制。")
        }
        try FileManager.default.createDirectory(at: screenshotRoot, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard screenshotDirectoryIsSafe else { throw LibraryStoreError.invalid("页面截图保存目录无效。") }
        let url = screenshotRoot.appendingPathComponent("\(id.uuidString).jpg")
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    private func cleanScreenshots(keeping entries: [HistoryEntry]) throws {
        guard FileManager.default.fileExists(atPath: screenshotRoot.path) else { return }
        guard screenshotDirectoryIsSafe else { throw LibraryStoreError.invalid("页面截图目录不是普通目录。") }
        let referenced = Set(entries.compactMap(\.contextScreenshotFileName))
        for url in try FileManager.default.contentsOfDirectory(at: screenshotRoot, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "jpg", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  !referenced.contains(url.lastPathComponent) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private var audioDirectoryIsSafe: Bool {
        guard let info = try? audioRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return info.isDirectory == true && info.isSymbolicLink != true
    }

    private func preserveAudio(_ source: URL, id: UUID) throws -> URL {
        guard !loadFailed else { throw LibraryStoreError.invalid("资料文件未能读取，本次录音未写入历史。") }
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= Self.maximumAudioBytes else {
            throw LibraryStoreError.invalid("录音文件无效或超过 16 MB，未写入历史。")
        }
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard audioDirectoryIsSafe else { throw LibraryStoreError.invalid("录音保存目录无效，未写入历史。") }
        let destination = audioRoot.appendingPathComponent("\(id.uuidString).wav")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Delete only UUID-named files inside our own non-symlink recording directory.
    private func cleanAudio(keeping entries: [HistoryEntry]) throws {
        guard FileManager.default.fileExists(atPath: audioRoot.path) else { return }
        guard audioDirectoryIsSafe else {
            throw LibraryStoreError.invalid("录音目录不是普通目录，未清理其中的文件。")
        }
        let referenced = Set(entries.compactMap(\.audioFileName))
        for url in try FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "wav", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  !referenced.contains(url.lastPathComponent) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    func deleteHistory(id: UUID) {
        do { try save(history: retained(history.filter { $0.id != id }), words: words) }
        catch { report(error) }
    }

    func addWord(_ text: String) {
        do {
            let word = try validatedWord(text)
            guard !words.contains(where: { Self.key($0.text) == Self.key(word) }) else {
                throw LibraryStoreError.invalid("这个词已经在词典中。")
            }
            guard words.count < Self.maximumWords else {
                throw LibraryStoreError.invalid("词典最多保存 2,000 个词，请删除部分词条后重试。")
            }
            try save(history: retained(history), words: words + [DictionaryWord(text: word)])
        } catch { report(error) }
    }

    func updateWord(id: UUID, text: String) {
        do {
            let word = try validatedWord(text)
            guard let index = words.firstIndex(where: { $0.id == id }) else {
                throw LibraryStoreError.invalid("这个词条已不存在，请重新选择。")
            }
            guard !words.contains(where: { $0.id != id && Self.key($0.text) == Self.key(word) }) else {
                throw LibraryStoreError.invalid("这个词已经在词典中。")
            }
            var updated = words
            updated[index].text = word
            try save(history: retained(history), words: updated)
        } catch { report(error) }
    }

    func deleteWord(id: UUID) {
        do { try save(history: retained(history), words: words.filter { $0.id != id }) }
        catch { report(error) }
    }

    /// Accepts a single CSV column, optionally headed word, term, text, 词条 or 词语.
    /// Quoted commas, escaped quotes and quoted line breaks follow RFC 4180.
    @discardableResult
    func importCSV(_ text: String) throws -> Int {
        do {
            guard text.utf8.count <= 1_024 * 1_024 else {
                throw LibraryStoreError.invalid("CSV 文件过大，请使用小于 1 MB 的文件。")
            }
            var rows = try Self.csvRows(text)
            if let first = rows.first, first.count == 1,
               ["word", "term", "text", "词条", "词语"].contains(Self.key(first[0])) {
                rows.removeFirst()
            }
            var seen = Set(words.map { Self.key($0.text) })
            var updated = words
            for row in rows {
                if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
                guard row.count == 1 else {
                    throw LibraryStoreError.invalid("CSV 每行应只有一个词条；词条内含逗号时，请用双引号包住。")
                }
                let word = try validatedWord(row[0])
                if seen.insert(Self.key(word)).inserted { updated.append(DictionaryWord(text: word)) }
                guard updated.count <= Self.maximumWords else {
                    throw LibraryStoreError.invalid("导入后会超过 2,000 个词，未导入任何词条。")
                }
            }
            let count = updated.count - words.count
            try save(history: retained(history), words: updated)
            return count
        } catch {
            report(error)
            throw error
        }
    }

    private func validatedWord(_ text: String) throws -> String {
        let word = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !word.isEmpty else { throw LibraryStoreError.invalid("词条不能为空。") }
        guard word.count <= Self.maximumWordLength else {
            throw LibraryStoreError.invalid("每个词条最多 120 个字符，未保存这个词条。")
        }
        guard !word.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryStoreError.invalid("词条不能包含不可见控制字符。")
        }
        return word
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private func retained(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        if retention == .never { return [] }
        guard let cutoff = retention.cutoff(before: Date()) else { return entries }
        return entries.filter { $0.date >= cutoff }
    }

    private func pruneExpiredHistory() {
        let entries = retained(history)
        do {
            if entries.count != history.count { try save(history: entries, words: words) }
            else if !loadFailed { try cleanAudio(keeping: entries); try cleanScreenshots(keeping: entries) }
        }
        catch { report(error) }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { throw LibraryStoreError.invalid("本机资料文件超过 20 MB，未读取或覆盖原文件。") }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { throw LibraryStoreError.invalid("本机资料版本不受支持，未覆盖原文件。") }
            guard snapshot.history.count <= Self.maximumHistory, snapshot.words.count <= Self.maximumWords,
                  Set(snapshot.history.map(\.id)).count == snapshot.history.count,
                  Set(snapshot.words.map(\.id)).count == snapshot.words.count,
                  Set(snapshot.words.map { Self.key($0.text) }).count == snapshot.words.count,
                  snapshot.history.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 &&
                      $0.raw.count <= Self.maximumTextLength && $0.text.count <= Self.maximumTextLength &&
                      $0.application.count <= 300 && $0.mode.count <= 40 &&
                      $0.language.count <= 40 && $0.targetLanguage.count <= 80 &&
                      ($0.audioFileName == nil || $0.audioFileName == "\($0.id.uuidString).wav") &&
                      ($0.contextInputText?.count ?? 0) <= 12000 && ($0.contextWindowTitle?.count ?? 0) <= 300 &&
                      ($0.contextScreenshotFileName == nil || $0.contextScreenshotFileName == "\($0.id.uuidString).jpg") }) else {
                throw LibraryStoreError.invalid("本机资料格式无效，未覆盖原文件。")
            }
            for word in snapshot.words { _ = try validatedWord(word.text) }
            restoringRetention = true
            retention = snapshot.retention
            restoringRetention = false
            history = snapshot.history.sorted { $0.date > $1.date }
            words = snapshot.words
        } catch {
            loadFailed = true
            errorMessage = "读取历史和词典失败：\(error.localizedDescription) 原文件已保留，请检查 \(file.path)。"
            return
        }
        pruneExpiredHistory()
    }

    private func save(history: [HistoryEntry], words: [DictionaryWord]) throws {
        guard !loadFailed else {
            throw LibraryStoreError.invalid("资料文件此前读取失败，为保护原文件，本次更改未保存。请检查 \(file.path) 后重新打开应用。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Snapshot(retention: retention, history: history, words: words))
        guard data.count <= Self.maximumBytes else {
            throw LibraryStoreError.invalid("本机资料超过 20 MB，本次更改未保存；请删除部分历史记录后重试。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporary = root.appendingPathComponent(".library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        // Set private permissions before replacing the live file, so any failure
        // leaves the previous snapshot intact and matches the published state.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else { try FileManager.default.moveItem(at: temporary, to: file) }
        self.history = history
        self.words = words
        errorMessage = nil
        // Commit metadata first. A crash before cleanup is recovered on next load.
        // Cleanup failures do not roll back already committed retention/deletion.
        do { try cleanAudio(keeping: history); try cleanScreenshots(keeping: history) }
        catch { errorMessage = "历史记录已保存，但部分已删除附件未能清理：\(error.localizedDescription)" }
    }

    private func report(_ error: Error) { errorMessage = "保存失败：\(error.localizedDescription)" }

    private static func csvRows(_ input: String) throws -> [[String]] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let characters = Array(text)
        var rows: [[String]] = [], row: [String] = []
        var field = "", index = 0
        var quoted = false, closedQuote = false
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\""); index += 1
                    } else { quoted = false; closedQuote = true }
                } else { field.append(character) }
            } else if character == "," {
                row.append(field); field = ""; closedQuote = false
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                row.append(field); rows.append(row)
                row = []; field = ""; closedQuote = false
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else if character == "\"" {
                guard field.isEmpty, !closedQuote else { throw LibraryStoreError.invalid("CSV 引号格式错误，未导入任何词条。") }
                quoted = true
            } else {
                guard !closedQuote else { throw LibraryStoreError.invalid("CSV 闭合引号后存在多余字符，未导入任何词条。") }
                field.append(character)
            }
            index += 1
        }
        guard !quoted else { throw LibraryStoreError.invalid("CSV 存在未闭合的引号，未导入任何词条。") }
        if !field.isEmpty || !row.isEmpty || closedQuote { row.append(field); rows.append(row) }
        return rows
    }
}
