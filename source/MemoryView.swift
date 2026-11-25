import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MemoryPage: View {
    @ObservedObject var store: MemoryStore
    @StateObject private var browser: RecordPager<PersonalMemory>
    @StateObject private var candidates: RecordPager<MemoryEvidence>
    @State private var search = ""
    @State private var fileError: String?
    @State private var editing: PersonalMemory?
    @State private var showingEditor = false
    @State private var original = ""
    @State private var preferred = ""
    @State private var kind = PersonalMemory.Kind.correction
    @State private var scope = PersonalMemory.Scope.person
    @State private var showCandidates = false
    init(store: MemoryStore, previewCandidates: Bool = false) {
        self.store = store
        _showCandidates = State(initialValue: previewCandidates)
        _candidates = StateObject(wrappedValue: RecordPager { _, _, offset in try await store.evidencePage(offset: offset) })
        _browser = StateObject(wrappedValue: RecordPager { query, _, offset in
            try await store.memoryPage(query: query, offset: offset)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "个人记忆", subtitle: "记住你的常用写法，让表达更贴近习惯。") { EmptyView() }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用个人记忆", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
                    .toggleStyle(.switch).font(.system(size: 15, weight: .semibold))
                Text("开启后，Hello 会通过内容变化通知和短时复查，观察听写输入后 30 秒内的局部纠正。名字与术语在两次独立纠正后自动启用，表达偏好需确认；也可手动添加并立即启用。必要片段会在空闲时交给配置的文字服务整理，记忆保存在本机，供 Fn 听写及文字处理参考。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                if store.enabled {
                    Text(store.captureStatus).font(.system(size: 12)).foregroundStyle(LVTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 8) {
                Button("记住一个写法") { editing = nil; original = ""; preferred = ""; kind = .correction; scope = .person; showingEditor = true }
                Button(store.processing ? "正在整理…" : "整理候选（\(store.pendingCount)）") { store.retry() }
                    .disabled(!store.enabled || store.processing || store.pendingCount == 0)
                Spacer()
                Button("导出记忆") {
                    do { NSWorkspace.shared.open(try store.exportFile()); fileError = nil }
                    catch { fileError = error.localizedDescription }
                }
                Button("导入记忆") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false
                    panel.message = "导入此前导出的记忆文件，将替换当前记忆与候选。"
                    if panel.runModal() == .OK, let url = panel.url { store.importFile(url) }
                }
                Button("刷新") { store.reload() }
            }.buttonStyle(SurfaceButtonStyle(compact: true))
            if let error = store.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if let fileError { Text(fileError).font(.caption).foregroundStyle(.orange) }
            Text(store.message).font(.system(size: 12)).foregroundStyle(.secondary)
            SearchBox(placeholder: "搜索全部记忆", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if browser.loading && browser.items.isEmpty { ProgressView("正在读取记忆…") }
                    else if browser.items.isEmpty && browser.error == nil {
                        EmptyLibraryView(symbol: "sparkles", title: search.isEmpty ? "还没有个人记忆" : "没有找到相关记忆",
                            detail: search.isEmpty ? "开启后照常听写，也可以手动添加常用写法。" : "换一个关键词再试。", minimumHeight: 170)
                    }
                    ForEach(browser.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(item.original) → \(item.preferred)").font(.system(size: 16, weight: .medium)).textSelection(.enabled)
                                Spacer()
                                Text(label(item)).font(.system(size: 12)).foregroundStyle(item.state == .active ? Color.green : Color.secondary)
                            }
                            Text("\(item.kind == .correction ? "名字与术语" : "表达偏好") · \(item.userConfirmed ? "你已确认" : "\(item.sessions.count) 次独立纠正") · \(scopeLabel(item.scope))")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack {
                                Button(item.state == .active ? "停用" : "确认并启用") { store.setState(item.id, item.state == .active ? .paused : .active) }
                                Button("编辑") { editing = item; original = item.original; preferred = item.preferred; kind = item.kind; scope = item.scope; showingEditor = true }
                                Spacer()
                                Button("删除并不再学习") { store.remove(item.id) }
                            }.buttonStyle(QuietButtonStyle()).font(.system(size: 12))
                        }.padding(16).background(LVTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(LVTheme.border))
                    }
                    PaginationFooter(pager: browser)
                    DisclosureGroup("捕获的候选片段（\(store.evidence.count)）", isExpanded: $showCandidates) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("片段最多保留 30 天。自动捕获只支持可读取并能确认写入范围的输入框。表达偏好需确认后启用。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            ForEach(candidates.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.before).foregroundStyle(.secondary)
                                    Text("→ " + item.after)
                                    Text(item.processed ? "已整理" : "待整理").foregroundStyle(.secondary).font(.system(size: 10))
                                }.font(.system(size: 12)).textSelection(.enabled)
                            }
                            PaginationFooter(pager: candidates)
                            Button("清空候选片段与未确认建议") { store.clearCandidates() }.buttonStyle(SurfaceButtonStyle(compact: true))
                        }.padding(.top, 10)
                    }.padding(16).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }.task(id: search) { browser.search(search) }
        .onReceive(store.$memories) { _ in browser.reload() }
        .onReceive(store.$evidence) { _ in if showCandidates { candidates.reload() } }
        .task(id: showCandidates) { if showCandidates { candidates.reload() } }
        .sheet(isPresented: $showingEditor) { editor }
        .tint(LVTheme.accent).foregroundStyle(LVTheme.text)
    }
    var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "记住一个写法" : "编辑记忆").font(.system(size: 24, weight: .semibold))
            Text("填写你常纠正的名字、术语或固定表达。例如“小雪 → 晓雪”，或“好的 → OK”。保存后视为你已确认。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("原写法", text: $original).textFieldStyle(RoundedInputStyle())
            TextField("偏好写法", text: $preferred).textFieldStyle(RoundedInputStyle())
            FormField(title: "类型") {
                ChoiceMenu(title: "记忆类型", selection: $kind, options: [(.correction, "名字与术语"), (.expression, "固定表达偏好")])
            }.onChange(of: kind) { _, value in scope = value == .expression ? .dictation : .person }
            if kind == .correction {
                FormField(title: "适用范围") {
                    ChoiceMenu(title: "适用范围", selection: $scope, options: [(.person, "人物称呼"), (.term, "专有词与术语")])
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { showingEditor = false }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.save(id: editing?.id, original: original, preferred: preferred, kind: kind, scope: scope)
                    if store.error == nil { showingEditor = false }
                }.keyboardShortcut(.defaultAction).buttonStyle(SurfaceButtonStyle(prominent: true)).disabled(original.isEmpty || preferred.isEmpty)
            }
        }.padding(28).frame(width: 470).background(LVTheme.background)
            .buttonStyle(SurfaceButtonStyle()).tint(LVTheme.accent)
    }
    private func label(_ item: PersonalMemory) -> String {
        switch item.state { case .active: return "已启用"; case .suggested: return "待确认"; case .paused: return "已暂停" }
    }
    private func scopeLabel(_ scope: PersonalMemory.Scope) -> String {
        switch scope { case .person: return "人物称呼"; case .term: return "专有词"; case .dictation: return "Fn 听写" }
    }
}

struct MemoryNotice: View {
    @ObservedObject var store: MemoryStore
    var body: some View {
        if let id = store.latestAutomaticID, let item = store.memories.first(where: { $0.id == id && $0.state == .active }) {
            HStack(spacing: 12) {
                Text("已记住：\(item.original) → \(item.preferred)")
                Button("撤销") { store.setState(id, .paused); store.latestAutomaticID = nil }.buttonStyle(QuietButtonStyle())
                Button { store.latestAutomaticID = nil } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
            }.font(.system(size: 12)).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(16)
        }
    }
}
