import Foundation
import Combine
import SwiftUI

struct PageQuery: Equatable, Hashable {
    var text: String
    var category = "all"
}

@MainActor
final class RecordPager<Item: Identifiable>: ObservableObject {
    typealias Loader = @MainActor (String, String, Int) async throws -> DatabasePage<Item>
    @Published private(set) var items: [Item] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let loader: Loader
    private var query = PageQuery(text: "")
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    var canLoadMore: Bool { items.count < total }
    init(loader: @escaping Loader) { self.loader = loader }
    deinit { task?.cancel() }
    func search(_ text: String, category: String = "all") {
        query = PageQuery(text: text, category: category)
        reload()
    }
    func invalidate() {
        generation &+= 1; task?.cancel(); task = nil
        items = []; total = 0; error = nil; loading = true
    }
    func reload() {
        invalidate()
        fetch(offset: 0)
    }
    func loadMore() {
        guard !loading, error == nil, canLoadMore else { return }
        fetch(offset: items.count)
    }
    private func fetch(offset: Int) {
        loading = true; error = nil
        let generation = generation, query = query
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if offset == 0 && !query.text.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
                let page = try await loader(query.text, query.category, offset)
                guard !Task.isCancelled, self.generation == generation else { return }
                if offset == 0 { items = page.items }
                else {
                    let ids = Set(items.map(\.id))
                    items += page.items.filter { !ids.contains($0.id) }
                }
                total = page.total; loading = false; task = nil
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.error = error.localizedDescription; loading = false; task = nil
            }
        }
    }
}

struct PaginationFooter<Item: Identifiable>: View {
    @ObservedObject var pager: RecordPager<Item>
    var body: some View {
        HStack {
            Spacer()
            if pager.loading { ProgressView().controlSize(.small) }
            else if let error = pager.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("重试") { pager.reload() }.buttonStyle(SurfaceButtonStyle(compact: true))
            } else if pager.canLoadMore {
                Button("加载更多") { pager.loadMore() }.buttonStyle(SurfaceButtonStyle(compact: true)).onAppear { pager.loadMore() }
            } else if !pager.items.isEmpty {
                Text("共 \(pager.total) 条").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.vertical, 16)
    }
}

private actor HistoryIndex {
    private let root: URL
    private var database: LocalDatabase?
    private var previous: [UnifiedHistoryItem] = []
    private var pending: ([HistoryEntry], [AgentTaskRecord]) = ([], [])
    private var failed = false
    init(root: URL) { self.root = root }
    func update(voice: [HistoryEntry], tasks: [AgentTaskRecord]) throws {
        pending = (voice, tasks)
        do { try rebuild(voice: voice, tasks: tasks); failed = false }
        catch { failed = true; throw error }
    }
    private func rebuild(voice: [HistoryEntry], tasks: [AgentTaskRecord]) throws {
        if database == nil {
            let db = try LocalDatabase(root: root, name: "history-index.sqlite")
            previous = try db.all("timeline", orderedByPosition: false)
            database = db
        }
        guard let database else { return }
        let merged = UnifiedHistoryItem.merged(voice: voice, tasks: tasks)
        try database.transaction {
            try database.sync("timeline", old: previous, new: merged) { item, _ in
                let search: String
                switch item {
                case .voice(let entry): search = [entry.raw, entry.text, entry.application].joined(separator: "\n")
                case .agent(let task, let recordings):
                    search = ([task.title] + task.messages.map(\.text) + recordings.flatMap { [$0.raw, $0.application] }).joined(separator: "\n")
                }
                return DatabaseIndex(date: item.date, category: item.isAgent ? "ask" : "dictate", search: search)
            }
        }
        previous = merged
    }
    func page(query: String, category: String, offset: Int) throws -> DatabasePage<UnifiedHistoryItem> {
        if failed { try update(voice: pending.0, tasks: pending.1) }
        guard let database else { return DatabasePage(items: [], total: 0) }
        return try database.page("timeline", query: query, category: category, offset: offset)
    }
}

@MainActor
final class HistoryBrowser: ObservableObject {
    let pager: RecordPager<UnifiedHistoryItem>
    private let index: HistoryIndex
    private var subscription: AnyCancellable?
    private var update: Task<Void, Never>?
    init(library: LibraryStore, agent: AgentSession) {
        let index = HistoryIndex(root: library.dataDirectory)
        self.index = index
        pager = RecordPager { query, category, offset in try await index.page(query: query, category: category, offset: offset) }
        subscription = library.$history.combineLatest(agent.$records).removeDuplicates { left, right in
            left.0 == right.0 && left.1 == right.1
        }.sink { [weak self] voice, tasks in
            guard let self else { return }
            update?.cancel(); pager.invalidate()
            update = Task { [weak self] in
                do {
                    try await index.update(voice: voice, tasks: tasks)
                    guard !Task.isCancelled else { return }
                    self?.pager.reload()
                } catch {
                    // The loader returns the same database error on explicit retry.
                    guard !Task.isCancelled else { return }
                    self?.pager.reload()
                }
            }
        }
    }
    deinit { update?.cancel() }
}
