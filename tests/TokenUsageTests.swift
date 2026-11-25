import Foundation

private final class UsageTransport: URLProtocol {
    static var responses: [(Int, [String: Any])] = []
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = Self.responses.removeFirst()
        let data = try! JSONSerialization.data(withJSONObject: response.1)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct TokenUsageTests {
    @MainActor static func main() async throws {
        precondition(TokenCount.parse(["prompt_tokens": 120, "completion_tokens": 20, "prompt_cache_hit_tokens": 100]) == TokenCount(input: 120, output: 20))
        precondition(TokenCount.parse(["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20]) == TokenCount(input: 130, output: 5))
        for invalid: [String: Any] in [[:], ["total_tokens": 50], ["prompt_tokens": -1, "completion_tokens": 3], ["prompt_tokens": true, "completion_tokens": 3], ["input_tokens": 1.5, "output_tokens": 1], ["input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": -1]] {
            precondition(TokenCount.parse(invalid) == nil)
        }
        print("PASS: provider token formats, cached input and missing/invalid usage")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-usage-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        let ledger = try TokenUsageLedger(root: root)
        try ledger.record(id: "previous-month", count: TokenCount(input: 100, output: 20), date: calendar.date(byAdding: .month, value: -1, to: now)!)
        try ledger.record(id: "yesterday", count: TokenCount(input: 20, output: 4), date: calendar.date(byAdding: .day, value: -1, to: now)!)
        try ledger.record(id: "agent-message", count: TokenCount(input: 30, output: 5), date: now)
        try ledger.record(id: "agent-message", count: TokenCount(input: 30, output: 5), date: now)
        try ledger.record(id: "agent-message", count: TokenCount(input: 30, output: 8), date: now)
        try ledger.record(id: "agent-message", count: TokenCount(input: 30, output: 2), date: now)
        let snapshot = try TokenUsageLedger(root: root).snapshot(now: now, calendar: calendar)
        precondition(snapshot.today == TokenCount(input: 30, output: 8))
        precondition(snapshot.month == TokenCount(input: 50, output: 12))
        precondition(snapshot.all == TokenCount(input: 150, output: 32))
        precondition(snapshot.breakdowns[0].agent == 38 && snapshot.breakdowns[0].dictation == 0)
        precondition(snapshot.breakdowns[1].dictation == 24 && snapshot.breakdowns[2].dictation == 144)
        for (index, count) in [snapshot.today, snapshot.month, snapshot.all].enumerated() {
            let item = snapshot.breakdowns[index]
            precondition(item.agent + item.dictation == count.total)
            precondition(item.points.reduce(0) { $0 + $1.agent + $1.dictation } == count.total)
            precondition(item.points.count <= 31)
        }
        let nextDay = try ledger.snapshot(now: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar)
        precondition(nextDay.today.total == 0 && nextDay.all == snapshot.all)
        print("PASS: persisted totals, local-day/month boundaries and duplicate/resumed-message protection")
        let store = TokenUsageStore(root: root.appendingPathComponent("gateway"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UsageTransport.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let gateway = try Gateway(base: "https://usage.invalid/v1", key: "test", model: "test", transport: transport, retryWait: { _ in })
        func reply(_ usage: [String: Any]?, finish: String = "stop") -> [String: Any] {
            var json: [String: Any] = ["choices": [["message": ["content": "测试文本"], "finish_reason": finish]]]
            if let usage { json["usage"] = usage }; return json
        }
        let usage: [String: Any] = ["prompt_tokens": 12, "completion_tokens": 3]
        UsageTransport.responses = [(200, reply(usage)), (503, reply(usage)), (200, reply(usage)), (200, reply(nil)), (200, reply(usage, finish: "length"))]
        await gateway.warmupTransport() // Even a malicious usage-shaped /models response isn't generation.
        _ = try await gateway.polish("重试")
        _ = try await gateway.polish("未返回用量")
        do { _ = try await gateway.polish("截断"); preconditionFailure("Should reject truncated output") } catch {}
        let deadline = Date().addingTimeInterval(3)
        while store.snapshot?.all != TokenCount(input: 24, output: 6), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(store.snapshot?.all == TokenCount(input: 24, output: 6))
        precondition(store.error == nil && UsageTransport.responses.isEmpty && UsageTransport.requests == 5)
        print("PASS: real Gateway notifications count successful HTTP usage including truncated output; exclude warmup, failed retries and unreported usage")
    }
}
