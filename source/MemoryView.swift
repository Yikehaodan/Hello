import SwiftUI
import AppKit

struct MemoryPage: View {
    @ObservedObject var store: MemoryStore
    @State private var editing: PersonalMemory?
    @State private var showingEditor = false
    @State private var original = ""
    @State private var preferred = ""
    @State private var kind = PersonalMemory.Kind.correction
    @State private var scope = PersonalMemory.Scope.person
    @State private var showCandidates = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("启用个人记忆", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
                .font(.system(size: 17, weight: .semibold))
            Text("开启后，Hello 会在听写输入后的 30 秒内观察原输入框的局部纠正，并在空闲时发送必要片段给你配置的文字服务整理。记忆保存在本机 memory.md，供之后的文字处理参考。支持词典提示的本地引擎会参考正确词，记忆不会强制替换文字。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("记住一个写法") { editing = nil; original = ""; preferred = ""; kind = .correction; scope = .person; showingEditor = true }
                Button(store.processing ? "正在整理…" : "整理候选（\(store.pendingCount)）") { store.retry() }
                    .disabled(!store.enabled || store.processing || store.pendingCount == 0)
                Spacer()
                Button("打开文件") { NSWorkspace.shared.open(store.file) }.disabled(!FileManager.default.fileExists(atPath: store.file.path))
                Button("重新读取") { store.reload() }
            }.buttonStyle(.bordered)
            if let error = store.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            Text(store.message).font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.memories.isEmpty {
                        Text("还没有记忆。开启后照常听写，纠正名字或固定表达；也可以手动添加。")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(store.memories) { item in
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
                            }.buttonStyle(.borderless).font(.system(size: 12))
                        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                    DisclosureGroup("捕获的候选片段（\(store.evidence.count)）", isExpanded: $showCandidates) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("片段最多保留 30 天。自动捕获只支持可读取并能确认写入范围的输入框。表达偏好需确认后启用。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            ForEach(store.evidence.suffix(20).reversed()) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.before).foregroundStyle(.secondary)
                                    Text("→ " + item.after)
                                    Text(item.processed ? "已整理" : "待整理").foregroundStyle(.secondary).font(.system(size: 10))
                                }.font(.system(size: 12)).textSelection(.enabled)
                            }
                            Button("清空候选片段与未确认建议") { store.clearCandidates() }.buttonStyle(.bordered)
                        }.padding(.top, 10)
                    }.padding(.top, 8)
                }
            }
        }.sheet(isPresented: $showingEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editing == nil ? "记住一个写法" : "编辑记忆").font(.title2)
                Text("填写你常纠正的名字、术语或固定表达。例如“小雪 → 晓雪”，或“好的 → OK”。保存后视为你已确认。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("原写法", text: $original).textFieldStyle(.roundedBorder)
                TextField("偏好写法", text: $preferred).textFieldStyle(.roundedBorder)
                Picker("类型", selection: $kind) {
                    Text("名字与术语").tag(PersonalMemory.Kind.correction)
                    Text("固定表达偏好").tag(PersonalMemory.Kind.expression)
                }.onChange(of: kind) { _, value in scope = value == .expression ? .dictation : .person }
                if kind == .correction {
                    Picker("适用范围", selection: $scope) {
                        Text("人物称呼").tag(PersonalMemory.Scope.person)
                        Text("专有词与术语").tag(PersonalMemory.Scope.term)
                    }
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("取消") { showingEditor = false }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        store.save(id: editing?.id, original: original, preferred: preferred, kind: kind, scope: scope)
                        if store.error == nil { showingEditor = false }
                    }.keyboardShortcut(.defaultAction).disabled(original.isEmpty || preferred.isEmpty)
                }
            }.padding(24).frame(width: 470)
        }
    }
    private func label(_ item: PersonalMemory) -> String {
        switch item.state { case .active: return "已启用"; case .suggested: return "待确认"; case .paused: return "已暂停" }
    }
    private func scopeLabel(_ scope: PersonalMemory.Scope) -> String {
        switch scope { case .person: return "人物称呼"; case .term: return "专有词"; case .dictation: return "普通听写" }
    }
}

struct MemoryNotice: View {
    @ObservedObject var store: MemoryStore
    var body: some View {
        if let id = store.latestAutomaticID, let item = store.memories.first(where: { $0.id == id && $0.state == .active }) {
            HStack(spacing: 12) {
                Text("已记住：\(item.original) → \(item.preferred)")
                Button("撤销") { store.setState(id, .paused); store.latestAutomaticID = nil }
                Button { store.latestAutomaticID = nil } label: { Image(systemName: "xmark") }
            }.font(.system(size: 12)).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(16)
        }
    }
}
