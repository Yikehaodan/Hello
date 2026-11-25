import Foundation

enum UnifiedHistoryItem: Identifiable, Codable, Equatable, Sendable {
    case voice(HistoryEntry)
    case agent(AgentTaskRecord, [HistoryEntry])
    var id: UUID { switch self { case .voice(let entry): entry.id; case .agent(let task, _): task.id } }
    var date: Date { switch self { case .voice(let entry): entry.date; case .agent(let task, _): task.date } }
    var isAgent: Bool { switch self { case .voice(let entry): entry.mode == "ask"; case .agent: true } }
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        switch self {
        case .voice(let entry): return [entry.raw, entry.text, entry.application].contains { $0.localizedCaseInsensitiveContains(query) }
        case .agent(let task, let recordings):
            return ([task.title] + task.messages.map(\.text) + recordings.flatMap { [$0.raw, $0.application] })
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    static func merged(voice: [HistoryEntry], tasks: [AgentTaskRecord]) -> [UnifiedHistoryItem] {
        var linked: [UUID: [HistoryEntry]] = [:], standalone: [UnifiedHistoryItem] = []
        let ids = Set(tasks.map(\.id))
        for entry in voice {
            var taskID = entry.agentTaskID.flatMap { ids.contains($0) ? $0 : nil }
            // Older versions saved the handoff and conversation separately. Pair only
            // exact first prompts created together; leave ambiguous old data visible.
            if taskID == nil && entry.agentTaskID == nil && entry.mode == "ask" && entry.text.hasPrefix("任务已交给 Agent") {
                let matches = tasks.filter {
                    abs($0.date.timeIntervalSince(entry.date)) < 10 && $0.messages.first?.text == entry.raw
                }
                if matches.count == 1 { taskID = matches[0].id }
            }
            if let taskID { linked[taskID, default: []].append(entry) }
            else { standalone.append(.voice(entry)) }
        }
        return (standalone + tasks.map { .agent($0, linked[$0.id] ?? []) }).sorted { $0.date > $1.date }
    }
}
