import AppKit

@main struct DatabaseMigrationTests {
    struct LibraryFixture: Codable {
        var version = 1
        var retention = HistoryRetention.forever
        var history: [HistoryEntry]
        var words: [DictionaryWord]
    }
    struct MemoryFixture: Codable {
        var version = 1
        var enabled = true
        var memories: [PersonalMemory]
        var evidence: [MemoryEvidence] = []
        var dismissed: [String] = []
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-database-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date()
        let tasks = (0..<125).map { i in AgentTaskRecord(date: stamp, title: "任务 \(i)", fingerprint: "fixture",
            messages: [AgentMessage(role: "user", text: "任务 \(i)"), AgentMessage(role: "assistant", text: "## 结果\n检索资料 \(i)")], state: "任务完成") }
        var history = (0..<126).map { i in HistoryEntry(date: stamp, raw: "口述 \(i)", text: "内容 \(i)", duration: 2, application: "Fixture", timings: HistoryTimings(total: 1, asr: 0.4, llm: 0.6)) }
        history[0].mode = "ask"; history[0].agentTaskID = tasks[0].id; history[0].raw = "关联录音检索词"
        let words = (0..<125).map { DictionaryWord(text: $0 == 124 ? "Écho 中文 %_ ' quote" : "词语\($0)", date: stamp) }
        let oldBytes = try JSONEncoder().encode(LibraryFixture(history: history, words: words))
        let legacy = root.appendingPathComponent("library.json")
        try oldBytes.write(to: legacy)
        let library = LibraryStore(root: root)
        precondition(library.errorMessage == nil && library.history.count == 126 && library.words == words)
        precondition(library.history.first!.timings?.total == 1)
        let backup = try Data(contentsOf: root.appendingPathComponent("MigrationBackups/library.json"))
        precondition(backup == oldBytes)
        var collected: [DictionaryWord] = []
        for offset in [0, 50, 100] {
            let page = try await library.wordPage(query: "", category: "all", offset: offset)
            precondition(page.items.count == (offset == 100 ? 25 : 50) && page.total == 125)
            collected += page.items
        }
        precondition(collected == words && Set(collected.map(\.id)).count == 125)
        for query in ["echo", "中文", "%_", "' quote"] {
            let page = try await library.wordPage(query: query, category: "all", offset: 0)
            precondition(page.items.map(\.id) == [words.last!.id], "Search must include records beyond page one and bind literal input")
        }
        library.deleteWord(id: words[0].id)
        library.addWord("新增词语")
        let reloaded = LibraryStore(root: root)
        precondition(reloaded.words == library.words && !reloaded.words.contains(where: { $0.id == words[0].id }))
        precondition(tryData(legacy) == oldBytes, "Legacy input remains unchanged and must never resurrect deleted records")
        print("PASS: atomic legacy library migration, exact backup, stable 50-row pages, literal Chinese/Unicode search, restart without reimport")

        let memories = (0..<125).map { PersonalMemory(kind: .correction, original: "旧词\($0)", preferred: "新词\($0)", scope: .term, state: .active, userConfirmed: true, updated: stamp) }
        let memoryJSON = try JSONEncoder().encode(MemoryFixture(memories: memories))
        let markdown = Data(("# Legacy\n```json\n" + String(decoding: memoryJSON, as: UTF8.self) + "\n```\n").utf8)
        try markdown.write(to: root.appendingPathComponent("memory.md"))
        let memory = MemoryStore(root: root)
        precondition(memory.error == nil && memory.enabled && memory.memories == memories)
        precondition(tryData(root.appendingPathComponent("MigrationBackups/memory.md")) == markdown)
        let memoryPage = try await memory.memoryPage(query: "旧词124", offset: 0)
        precondition(memoryPage.total == 1 && memoryPage.items.first?.preferred == "新词124")
        memory.remove(memories[0].id)
        precondition(MemoryStore(root: root).memories.count == 124)
        precondition(!LibraryStore(root: root).words.isEmpty, "Domain transactions must not overwrite each other")
        print("PASS: memory migration preserves rules and IDs, searches all pages, shares database safely with dictionary")

        let config = AgentConfigurationStore(root: root.appendingPathComponent("Agent"), readKey: { "" }, writeKey: { _ in })
        try AgentConfigurationStore.writePrivate(JSONEncoder().encode(tasks), to: config.root.appendingPathComponent("tasks.json"))
        let agent = AgentSession(store: config)
        precondition(agent.records.count == 125 && agent.storageError.isEmpty)
        let browser = HistoryBrowser(library: library, agent: agent)
        try await wait { !browser.pager.loading && browser.pager.total == 250 }
        precondition(browser.pager.items.count == 50)
        var ids = Set(browser.pager.items.map(\.id))
        while browser.pager.canLoadMore {
            browser.pager.loadMore(); try await wait { !browser.pager.loading }
            ids.formUnion(browser.pager.items.map(\.id))
        }
        precondition(ids.count == 250 && browser.pager.items.count == 250, "Equal timestamps cannot duplicate or skip page boundaries")
        browser.pager.search("关联录音检索词")
        try await wait { !browser.pager.loading }
        precondition(browser.pager.items.count == 1 && browser.pager.items[0].id == tasks[0].id)
        browser.pager.search("", category: "ask"); try await wait { !browser.pager.loading }
        precondition(browser.pager.total == 125 && browser.pager.items.allSatisfy(\.isAgent))
        browser.pager.search("", category: "dictate"); try await wait { !browser.pager.loading }
        precondition(browser.pager.total == 125 && browser.pager.items.allSatisfy { !$0.isAgent })
        print("PASS: unified Agent history, linked recording search, type filters and stable full pagination")

        let db = library.database!
        do {
            try db.transaction {
                try db.setMetadata("rollback-test", true)
                throw DatabaseFailure(message: "injected failure")
            }
        } catch {}
        let rolledBack: Bool? = try db.metadata("rollback-test")
        precondition(rolledBack == nil)
        let symlinkRoot = root.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("records.sqlite"), withDestinationURL: db.url)
        let refused = LibraryStore(root: symlinkRoot); refused.addWord("must not save")
        precondition(refused.errorMessage != nil && refused.words.isEmpty)
        print("PASS: transaction rollback and symlink refusal")

        var held: CheckedContinuation<DatabasePage<DictionaryWord>, Error>?
        let pager = RecordPager<DictionaryWord> { query, _, _ in
            if query == "old" { return try await withCheckedThrowingContinuation { held = $0 } }
            return DatabasePage(items: [words.last!], total: 1)
        }
        pager.search("old"); try await wait { held != nil }
        pager.search("new"); try await wait { !pager.loading }
        held!.resume(returning: DatabasePage(items: [words.first!], total: 1))
        try await Task.sleep(for: .milliseconds(30))
        precondition(pager.items.map(\.id) == [words.last!.id], "Late query completion must not overwrite newer search")
        print("PASS: stale background searches cannot replace current results")
    }
    static func tryData(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for database UI state")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
