import Foundation
import Combine
import CoreFoundation

struct TokenCount: Equatable, Sendable {
    var input = 0
    var output = 0
    var total: Int { input + output }

    /// OpenAI prompt_tokens already includes cache hits. Anthropic reports cache input separately.
    static func parse(_ usage: [String: Any]) -> TokenCount? {
        func count(_ key: String, optional: Bool = false) -> Int? {
            guard let value = usage[key] else { return optional ? 0 : nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let amount = number.doubleValue
            guard amount.isFinite, amount >= 0, amount <= 1_000_000_000_000, amount.rounded() == amount else { return nil }
            return Int(amount)
        }
        if usage["prompt_tokens"] != nil {
            guard let input = count("prompt_tokens"), let output = count("completion_tokens") else { return nil }
            return TokenCount(input: input, output: output)
        }
        guard let input = count("input_tokens"), let output = count("output_tokens"),
              let read = count("cache_read_input_tokens", optional: true),
              let created = count("cache_creation_input_tokens", optional: true) else { return nil }
        return TokenCount(input: input + read + created, output: output)
    }
}

struct TokenTrendPoint: Equatable, Sendable {
    var date: Date
    var dictation = 0
    var agent = 0
}
struct TokenBreakdown: Equatable, Sendable {
    var dictation = 0
    var agent = 0
    var points: [TokenTrendPoint] = []
}
struct TokenUsageSnapshot: Equatable, Sendable {
    var today = TokenCount()
    var month = TokenCount()
    var all = TokenCount()
    var breakdowns: [TokenBreakdown] = []
}

/// Only counters and local timestamps are saved. Queries aggregate in SQLite, never load a growing event list.
final class TokenUsageLedger: @unchecked Sendable {
    private let database: LocalDatabase
    init(root: URL) throws {
        database = try LocalDatabase(root: root, name: "usage.sqlite")
        try database.execute("CREATE TABLE IF NOT EXISTS token_usage(id TEXT PRIMARY KEY, stamp REAL NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL)")
        try database.execute("CREATE INDEX IF NOT EXISTS token_usage_stamp ON token_usage(stamp)")
    }
    func record(id: String, count: TokenCount, date: Date = Date()) throws {
        guard !id.isEmpty, id.count <= 512, count.input >= 0, count.output >= 0 else { return }
        // SDK may emit the same message again with updated usage; keep the largest final counters.
        try database.execute("INSERT INTO token_usage(id,stamp,input,output) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET input=MAX(input,excluded.input),output=MAX(output,excluded.output)",
            [id, String(date.timeIntervalSince1970), String(count.input), String(count.output)])
    }
    func snapshot(now: Date = Date(), calendar: Calendar = .current) throws -> TokenUsageSnapshot {
        func sum(since: Date) throws -> TokenCount {
            let values = [String(since.timeIntervalSince1970), String(now.timeIntervalSince1970)]
            return try TokenCount(
                input: database.scalar("SELECT COALESCE(SUM(input),0) FROM token_usage WHERE stamp>=? AND stamp<=?", values),
                output: database.scalar("SELECT COALESCE(SUM(output),0) FROM token_usage WHERE stamp>=? AND stamp<=?", values))
        }
        let day = calendar.startOfDay(for: now)
        let month = calendar.dateInterval(of: .month, for: now)!
        let first = try database.scalar("SELECT COALESCE(MIN(stamp),0) FROM token_usage WHERE stamp<=?", [String(now.timeIntervalSince1970)])
        let earliest = first == 0 ? day : calendar.startOfDay(for: Date(timeIntervalSince1970: Double(first)))
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: day)!
        func breakdown(start: Date, end: Date, buckets: Int) throws -> TokenBreakdown {
            let width = max(1, end.timeIntervalSince(start) / Double(buckets))
            let values = [String(start.timeIntervalSince1970), String(width), String(start.timeIntervalSince1970), String(now.timeIntervalSince1970)]
            // IDs have always identified the producer; this also categorizes existing saved usage.
            let rows = try database.integerRows("SELECT CAST((stamp-?)/? AS INTEGER), SUM(CASE WHEN id LIKE 'agent-%' THEN 0 ELSE input+output END), SUM(CASE WHEN id LIKE 'agent-%' THEN input+output ELSE 0 END) FROM token_usage WHERE stamp>=? AND stamp<=? GROUP BY 1 ORDER BY 1", values)
            var result = TokenBreakdown(points: (0..<buckets).map { TokenTrendPoint(date: start.addingTimeInterval(Double($0) * width)) })
            for row in rows where row.count == 3 && result.points.indices.contains(row[0]) {
                result.points[row[0]].dictation = row[1]; result.points[row[0]].agent = row[2]
                result.dictation += row[1]; result.agent += row[2]
            }
            // Future buckets are not zero-usage observations.
            result.points.removeAll { $0.date > now }
            return result
        }
        return try TokenUsageSnapshot(today: sum(since: day), month: sum(since: month.start), all: sum(since: .distantPast),
            breakdowns: [breakdown(start: day, end: endOfDay, buckets: 24),
                breakdown(start: month.start, end: month.end, buckets: calendar.range(of: .day, in: .month, for: now)!.count),
                breakdown(start: earliest, end: endOfDay, buckets: min(30, max(1, calendar.dateComponents([.day], from: earliest, to: endOfDay).day ?? 1)))])
    }
}

@MainActor
final class TokenUsageStore: ObservableObject {
    static let shared = TokenUsageStore(root: AppPaths.data)
    @Published private(set) var snapshot: TokenUsageSnapshot?
    @Published private(set) var error: String?
    private let queue = DispatchQueue(label: "hello.token-usage", qos: .utility)
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    // This box belongs exclusively to the serial worker queue, including lazy opening of SQLite.
    private final class Storage: @unchecked Sendable {
        let root: URL
        var ledger: TokenUsageLedger?
        init(root: URL) { self.root = root }
        func open() throws -> TokenUsageLedger {
            if let ledger { return ledger }
            let value = try TokenUsageLedger(root: root); ledger = value; return value
        }
    }
    private let storage: Storage
    init(root: URL, observe: Bool = true) {
        storage = Storage(root: root)
        if observe {
            observer = NotificationCenter.default.addObserver(forName: Gateway.tokenUsageNotification, object: nil, queue: nil) { [weak self] note in
                guard let usage = note.userInfo?["usage"] as? [String: Any], let count = TokenCount.parse(usage),
                      let id = note.userInfo?["id"] as? String else { return }
                // Notification delivery never blocks the API response on disk I/O.
                Task { @MainActor [weak self] in self?.record(id: id, count: count) }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }
    func record(id: String, count: TokenCount) { update { try $0.record(id: id, count: count) } }
    func refresh() { update { _ in } }
    private func update(_ operation: @escaping @Sendable (TokenUsageLedger) throws -> Void) {
        let storage = storage
        queue.async { [weak self] in
            do {
                let ledger = try storage.open()
                try operation(ledger)
                let value = try ledger.snapshot()
                DispatchQueue.main.async { self?.snapshot = value; self?.error = nil }
            } catch {
                DispatchQueue.main.async { self?.error = "暂时无法读取用量" }
            }
        }
    }
}
