import Foundation

@main
struct MemoryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-memory-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(root: root)
        precondition(!store.enabled && !FileManager.default.fileExists(atPath: store.file.path))
        store.setEnabled(true)
        let session1 = UUID()
        store.record(before: "明天找小雪确认一下。", after: "明天找晓雪确认一下。", session: session1)
        store.record(before: "小雪", after: "晓雪", session: session1)
        precondition(store.evidence.count == 1, "one observation per session")
        let first = store.evidence[0]
        let proposal = MemoryProposal(evidenceIDs: [first.id], kind: .correction, original: "小雪", preferred: "晓雪", scope: .person)
        store.apply([proposal], batch: [first])
        precondition(store.memories.count == 1 && store.memories[0].state == .suggested)
        store.apply([proposal], batch: [first])
        precondition(store.memories[0].sessions.count == 1)
        store.record(before: "跟小雪说一下。", after: "跟晓雪说一下。", session: UUID())
        let second = store.evidence.last!
        var repeatProposal = proposal; repeatProposal.evidenceIDs = [second.id]
        store.apply([repeatProposal], batch: [second])
        precondition(store.memories[0].state == .active && store.memories[0].sessions.count == 2)
        precondition(store.prompt(for: "找小雪", mode: "dictate").contains("晓雪"))
        precondition(store.prompt(for: "天气很好", mode: "dictate").isEmpty)
        precondition(store.speechWords == "晓雪")
        let reloaded = MemoryStore(root: root)
        precondition(reloaded.memories == store.memories && reloaded.enabled)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        print("PASS: evidence/session deduplication, repeated correction, bounded retrieval and private Markdown round trip")

        for pair in [("周三开会", "周四开会"), ("金额 300 元", "金额 500 元"), ("三百元", "五百元"), ("小雪", ""), ("小雪", "小雪") ] {
            precondition(MemoryEdit.excerpt(before: pair.0, after: pair.1) == nil)
        }
        let count = store.memories.count
        let fabricated = MemoryProposal(evidenceIDs: [UUID()], kind: .correction, original: "小雪", preferred: "晓雪", scope: .person)
        let unsupported = MemoryProposal(evidenceIDs: [first.id], kind: .correction, original: "明天", preferred: "后天", scope: .term)
        store.apply([fabricated, unsupported], batch: [first])
        precondition(store.memories.count == count)
        let emoji = MemoryInsertionAnchor(before: "😀前后", selection: NSRange(location: 3, length: 0), inserted: "小雪")!
        precondition(emoji.expected == "😀前小雪后" && emoji.fragment(in: "😀前晓雪后") == "晓雪")
        precondition(emoji.fragment(in: "另一个输入框") == nil)
        precondition(MemoryInsertionAnchor(before: "abc", selection: NSRange(location: 8, length: 2), inserted: "x") == nil)
        print("PASS: numbers/dates/deletion/no-change ignored; hallucinated evidence rejected; UTF-16 and destination anchors")

        let id = store.memories[0].id
        store.record(before: "找晓雪", after: "找小雪", session: UUID())
        precondition(store.memories[0].state == .paused && store.prompt(for: "小雪", mode: "dictate").isEmpty)
        store.remove(id)
        store.record(before: "小雪", after: "晓雪", session: UUID())
        let deletedEvidence = store.evidence.last!
        var deletedProposal = proposal; deletedProposal.evidenceIDs = [deletedEvidence.id]
        store.apply([deletedProposal], batch: [deletedEvidence])
        precondition(store.memories.isEmpty)
        for _ in 0..<2 {
            store.record(before: "好的，我来处理。", after: "OK，我来处理。", session: UUID())
            let e = store.evidence.last!
            store.apply([MemoryProposal(evidenceIDs: [e.id], kind: .expression, original: "好的", preferred: "OK", scope: .dictation)], batch: [e])
        }
        let expression = store.memories.first!
        precondition(expression.state == .suggested)
        store.setState(expression.id, .active)
        precondition(store.prompt(for: "好的", mode: "dictate").contains("OK"))
        precondition(store.prompt(for: "好的", mode: "translate").isEmpty)
        store.setEnabled(false)
        precondition(store.prompt(for: "好的", mode: "dictate").isEmpty)
        print("PASS: reversals suspend, deleted rules stay forgotten, expression requires approval and respects mode/off switch")

        let manual = MemoryStore(root: root.appendingPathComponent("manual"))
        manual.save(original: "小雪", preferred: "晓雪", kind: .correction, scope: .person)
        let previousID = manual.memories[0].id
        manual.save(original: "小雪", preferred: "筱雪", kind: .correction, scope: .person)
        precondition(manual.memories.filter { $0.state == .active }.count == 1)
        precondition(manual.memories.first { $0.id == previousID }?.state == .paused)
        print("PASS: manual choices pause conflicting spellings")

        let disk = try Data(contentsOf: store.file)
        try (String(decoding: disk, as: UTF8.self) + "\n用户在外部编辑\n").write(to: store.file, atomically: true, encoding: .utf8)
        store.setEnabled(true)
        precondition(store.error != nil && !store.enabled)
        store.reload(); store.setEnabled(true)
        precondition(store.enabled && store.error == nil)
        try "broken file".write(to: store.file, atomically: true, encoding: .utf8)
        store.reload(); store.setEnabled(true)
        let preserved = try String(contentsOf: store.file, encoding: .utf8)
        precondition(!store.enabled && preserved == "broken file")
        print("PASS: external edits require reload; corrupt memory preserved and disabled")

        let queue = MemoryStore(root: root.appendingPathComponent("queue")); queue.setEnabled(true)
        queue.record(before: "小雪", after: "晓雪", session: UUID())
        var continuation: CheckedContinuation<[MemoryProposal], Error>?
        queue.consolidator = { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let work = Task { await queue.consolidateNow() }
        while continuation == nil { await Task.yield() }
        let e = queue.evidence[0]
        queue.setEnabled(false)
        continuation?.resume(returning: [MemoryProposal(evidenceIDs: [e.id], kind: .correction, original: "小雪", preferred: "晓雪", scope: .person)])
        await work.value
        precondition(queue.memories.isEmpty && queue.pendingCount == 1 && !queue.processing)
        print("PASS: disabled/in-flight consolidation cannot write late results")

        // Exercise the real Gateway request with an isolated transport and synthetic text only.
        let configFile = root.appendingPathComponent("gateway.env")
        try Gateway.saveConfiguration(base: "https://memory.invalid/v1", key: "fixture", model: "fixture-model", to: configFile)
        setenv("HELLO_ENV", configFile.path, 1); defer { unsetenv("HELLO_ENV") }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FaultTransport.self]
        let transport = URLSession(configuration: configuration); defer { transport.invalidateAndCancel() }
        let gateway = try Gateway(transport: transport, retryWait: { _ in })
        FaultTransport.reset([200]); FaultTransport.plainTextFixture = "{\"proposals\":[]}"
        _ = try await gateway.consolidateMemory([first], existing: [])
        let body = try JSONSerialization.jsonObject(with: FaultTransport.requests[0]) as! [String: Any]
        precondition(body["model"] as? String == "fixture-model")
        let messages = body["messages"] as! [[String: String]]
        precondition(messages.last!["content"]!.contains(first.id.uuidString))
        FaultTransport.reset([503, 200])
        do { _ = try await gateway.consolidateMemory([first], existing: []); fatalError("expected failure") } catch {}
        precondition(FaultTransport.requests.count == 1)
        FaultTransport.reset([200]); FaultTransport.plainTextFixture = "明天找晓雪。"
        _ = try await gateway.polish("明天找小雪。", memory: "PERSONAL_MEMORY_FIXTURE")
        precondition(String(decoding: FaultTransport.requests[0], as: UTF8.self).contains("PERSONAL_MEMORY_FIXTURE"))
        print("PASS: configured LLM used, evidence attached, background failures do not retry, memory reaches existing processing request")

        var field: String? = "前小雪后", captured: [(String, String)] = []
        let anchor = MemoryInsertionAnchor(before: "前后", selection: NSRange(location: 1, length: 0), inserted: "小雪")!
        let observer = MemoryCapture(anchor: anchor, read: { field }, complete: { captured.append(($0, $1)) })
        observer.start()
        try await Task.sleep(for: .milliseconds(650)); field = "前晓雪后"
        try await Task.sleep(for: .seconds(2)); observer.finish()
        precondition(captured.count == 1 && captured[0].0 == "小雪" && captured[0].1 == "晓雪")
        observer.finish(); precondition(captured.count == 1)
        field = "前小雪后"
        let undo = MemoryCapture(anchor: anchor, read: { field }, complete: { captured.append(($0, $1)) })
        undo.start(); try await Task.sleep(for: .milliseconds(650)); field = "前晓雪后"
        try await Task.sleep(for: .milliseconds(650)); field = "前小雪后"
        try await Task.sleep(for: .seconds(2)); undo.finish()
        precondition(captured.count == 1)
        field = "从未写入"
        let failedPaste = MemoryCapture(anchor: anchor, read: { field }, complete: { captured.append(($0, $1)) })
        failedPaste.start(); try await Task.sleep(for: .milliseconds(2200)); failedPaste.finish()
        precondition(captured.count == 1)
        print("PASS: verified paste + stable correction learned once; undo and failed paste never learned")
    }
}
