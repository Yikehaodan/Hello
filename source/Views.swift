import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// Shared adaptive colors for the native macOS interface.
private enum LVTheme {
    static let background = color(0xFFFFFF, 0x242121)
    static let text = color(0x111111, 0xFFFFFF)
    static let panel = color(0xFFFFFF, 0x3C3B3B)
    static let thin = Color.gray.opacity(0.05)
    static let hover = Color.gray.opacity(0.07)
    static let selected = Color.gray.opacity(0.15)
    static let border = Color.gray.opacity(0.12)
    static let accent = Color(red: 31 / 255, green: 93 / 255, blue: 242 / 255)
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }))
    }
}

private enum MainPage: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings, workbench
    var id: String { rawValue }
    var title: String {
        switch self { case .home: return "首页"; case .history: return "历史记录"; case .dictionary: return "词典"; case .settings: return "设置"; case .workbench: return "文本工作台" }
    }
    var symbol: String {
        switch self { case .home: return "house"; case .history: return "clock.arrow.circlepath"; case .dictionary: return "book.closed"; case .settings: return "gearshape"; case .workbench: return "text.alignleft" }
    }
}

struct MainView: View {
    @ObservedObject var model: VoiceModel
    let enableShortcut: () -> Void
    var previewPage: String? = nil
    var body: some View {
        MainShell(model: model, library: model.library, enableShortcut: enableShortcut, previewPage: previewPage)
            .preferredColorScheme(model.appearance == "light" ? .light : model.appearance == "dark" ? .dark : nil)
    }
}

private struct MainShell: View {
    @ObservedObject var model: VoiceModel
    @ObservedObject var library: LibraryStore
    let enableShortcut: () -> Void
    @State private var page: MainPage
    @ObservedObject private var preferences: AppPreferences
    @State private var showPermissions: Bool

    init(model: VoiceModel, library: LibraryStore, enableShortcut: @escaping () -> Void, previewPage: String?) {
        self.model = model
        self.library = library
        self.enableShortcut = enableShortcut
        self.preferences = model.preferences
        _showPermissions = State(initialValue: previewPage == nil && !model.preferences.permissionIntroDismissed)
        _page = State(initialValue: previewPage == "studio" ? .workbench : MainPage(rawValue: previewPage ?? "home") ?? .home)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                if preferences.needsRequiredPermissions {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield")
                        Text("完成权限设置，即可用 Fn 开口并自动输入。").font(.system(size: 12))
                        Spacer()
                        Button("查看权限") { showPermissions = true }.buttonStyle(.link)
                    }.padding(12).background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 24).padding(.bottom, 20)
                }
                Group {
                    switch page {
                    case .home: HomePage(model: model, library: library, openWorkbench: { page = .workbench }, openHistory: { page = .history }, openSettings: { page = .settings })
                    case .history: HistoryPage(model: model, library: library)
                    case .dictionary: DictionaryPage(library: library)
                    case .settings: HomePage(model: model, library: library, openWorkbench: { page = .workbench }, openHistory: { page = .history }, openSettings: { page = .settings })
                    case .workbench: WorkbenchPage(model: model, back: { page = .home })
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let error = library.errorMessage { InlineError(text: error).padding(.horizontal, 24).padding(.top, 8) }
                if page == .workbench {
                    VoiceControlBar(model: model)
                        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 12)
                }
            }.padding(.top, 44)
        }
        .font(.system(size: 14)).foregroundStyle(LVTheme.text)
        .background(LVTheme.background)
        .frame(minWidth: 1000, minHeight: 700)
        .overlay {
            if page == .settings {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { page = .home }
                    SettingsPage(model: model, library: library, enableShortcut: enableShortcut, close: { page = .home })
                        .frame(maxWidth: 940, maxHeight: 652)
                        .background(LVTheme.background, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LVTheme.border))
                        .shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 12)
                        .padding(40)
                }
            }
        }
        .sheet(isPresented: $showPermissions, onDismiss: preferences.dismissPermissionIntro) {
            PermissionWelcome(preferences: preferences, enableShortcut: enableShortcut) {
                preferences.dismissPermissionIntro()
                showPermissions = false
            }
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 21, weight: .semibold))
                Text("Knock").font(.system(size: 18, weight: .semibold))
            }.padding(.horizontal, 12).padding(.top, 48).padding(.bottom, 18)
            VStack(spacing: 2) {
                sidebarItem(.home)
                sidebarItem(.history)
                sidebarItem(.dictionary)
            }
            Spacer(minLength: 24)
            sidebarItem(.settings)
            Divider().overlay(LVTheme.border).padding(.vertical, 14).padding(.horizontal, 8)
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LVTheme.selected)
                    Image(systemName: "person.fill").font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.65))
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("本机工作空间").font(.system(size: 12, weight: .medium))
                    Text("Knock \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 10)).foregroundStyle(LVTheme.text.opacity(0.55))
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.bottom, 8)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(width: 202).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 20))
        .padding(.leading, 8).padding(.vertical, 8)
    }

    private func sidebarItem(_ item: MainPage) -> some View {
        Button { page = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).resizable().scaledToFit().frame(width: 16, height: 16)
                Text(item.title).font(.system(size: 14))
                Spacer()
            }.foregroundStyle(LVTheme.text.opacity(page == item ? 1 : 0.65))
                .padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(selected: page == item)).accessibilityLabel(item.title)
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(selected ? LVTheme.selected : (hover || configuration.isPressed ? LVTheme.hover : .clear), in: RoundedRectangle(cornerRadius: 8))
            .onHover { hover = $0 }
    }
}

private struct SurfaceButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 13).frame(height: 34)
            .foregroundStyle(prominent ? Color.white : LVTheme.text)
            .background(prominent ? Color(red: 29 / 255, green: 26 / 255, blue: 26 / 255).opacity(hover ? 0.85 : 1) : (hover ? LVTheme.hover : LVTheme.panel), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent ? Color.clear : LVTheme.border))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .onHover { hover = $0 }
    }
}

private struct HomePage: View {
    @ObservedObject var model: VoiceModel
    @ObservedObject var library: LibraryStore
    let openWorkbench: () -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    @State private var showActivity = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("轻叩，开口。").font(.system(size: 48, weight: .medium)).tracking(-0.5)
                        .frame(height: 54, alignment: .leading)
                    HStack(alignment: .top, spacing: min(80, max(24, (geometry.size.width - 48) * 0.16 - 92.8))) {
                        onboarding.frame(maxWidth: .infinity, alignment: .leading)
                        homeAside.frame(width: 186).padding(.top, 12)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }.scrollIndicators(.hidden)
        }.padding(.top, -8)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 0) {
                modeShortcut(title: "口述", detail: "说出想法，整理成清晰的文字。", keys: ["Fn"], tint: nil)
                Rectangle().fill(LVTheme.border).frame(height: 1)
                modeShortcut(title: "翻译", detail: "用熟悉的语言表达，输出目标语言。", keys: ["Fn", "Shift"], tint: .indigo)
                Rectangle().fill(LVTheme.border).frame(height: 1)
                modeShortcut(title: "上下文听写", detail: "参考输入框与当前页面校对口述，只转成文字。", keys: ["Fn", "Control"], tint: .purple)
                Rectangle().fill(LVTheme.border).frame(height: 1)
                modeShortcut(title: "问任何问题", detail: "选中文字后提问，或直接说出问题。", keys: ["Fn", "Space"], tint: .green)
            }.padding(.horizontal, 16).padding(.vertical, 4)
                .background(LVTheme.panel, in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 12) {
                Text("热门使用案例").font(.system(size: 16, weight: .semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    useCase("envelope.fill", color: .orange, title: "写邮件", detail: "说清来意和重点，把口述整理成一封自然的邮件。")
                    useCase("bubble.left.and.bubble.right.fill", color: .teal, title: "团队沟通", detail: "分享进展、补充细节，让沟通跟上你的思路。")
                    useCase("sparkles", color: .purple, title: "语音提问", detail: "选中一段文字，用声音继续追问或请求修改。", mode: .ask)
                    useCase("doc.text.fill", color: .blue, title: "撰写文档", detail: "先说出段落和要点，再从文字工作台继续完善。")
                    useCase("message.fill", color: .green, title: "回复消息", detail: "把想说的话直接说出来，让日常回复更轻松。")
                    useCase("lightbulb.fill", color: .yellow, title: "梳理思路", detail: "带着一个想法开口，通过问答找到下一个方向。", mode: .ask)
                    useCase("note.text", color: .brown, title: "记录灵感", detail: "留住一闪而过的想法，在历史记录中随时找回。")
                    useCase("globe", color: .cyan, title: "跨语言交流", detail: "说出熟悉的语言，生成选定目标语言的文字。", mode: .translate)
                    useCase("checklist", color: .pink, title: "整理待办", detail: "逐项说出接下来要做的事，再把结果放进清单。")
                }
            }
            if !library.history.isEmpty {
                DisclosureGroup(isExpanded: $showActivity) {
                    insights.padding(.top, 16)
                } label: {
                    Text("输入活动与最近记录").font(.system(size: 14, weight: .medium))
                }.tint(LVTheme.text.opacity(0.65))
            }
        }.padding(12).background { DotPattern().clipShape(RoundedRectangle(cornerRadius: 20)) }
    }
    private func modeShortcut(title: String, detail: String, keys: [String], tint: Color?) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.55)).lineLimit(1)
                }.frame(width: max(220, geometry.size.width * 0.5), alignment: .leading)
                HStack(spacing: 12) {
                    ForEach(keys, id: \.self) { key in
                        Text(key).font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, key.count > 2 ? 7 : 4).frame(minWidth: 30, minHeight: 30)
                            .background {
                                RoundedRectangle(cornerRadius: 6).fill(LVTheme.panel)
                                if let tint {
                                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [.clear, .clear, tint.opacity(0.22)], startPoint: .top, endPoint: .bottom))
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LVTheme.text.opacity(0.9), lineWidth: 1))
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxHeight: .infinity, alignment: .leading)
        }.frame(height: 60)
    }
    private var insights: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActivityHeatmap(history: library.history)
                .padding(16).background(LVTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            if let recent = library.history.first {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("最近一次输入").font(.system(size: 13, weight: .medium)); Spacer(); CopyButton(text: recent.text).font(.system(size: 11)) }
                    Text(recent.text).font(.system(size: 14)).lineSpacing(5).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    HStack {
                        Text(recent.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.55))
                        Spacer()
                        Button("查看历史", action: openHistory).buttonStyle(.link).font(.system(size: 12))
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(LVTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private var homeAside: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                statistic("clock", value: durationValue, unit: durationUnit)
                statistic("mic", value: library.totalWords.formatted(), unit: "字")
                statistic("bolt", value: averageSpeed, unit: "字/分钟")
                statistic("checkmark.circle", value: library.history.filter { $0.succeeded }.count.formatted(), unit: "次完成")
                statistic("calendar", value: activeDays.formatted(), unit: "天使用")
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 20))
            asideAction(title: "文本工作台", detail: "查看转写结果，继续编辑和整理。", color: .cyan, action: openWorkbench)
            asideAction(title: "快捷键与权限", detail: "查看快捷键，准备好后轻按 Fn 开口。", color: .indigo, action: openSettings)
            Text("统计来自本机保留的历史记录。").font(.system(size: 10)).lineSpacing(4).foregroundStyle(LVTheme.text.opacity(0.4)).padding(.horizontal, 8)
        }
    }
    private func statistic(_ symbol: String, value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 16)
            (Text(value).font(.system(size: 16, weight: .semibold)) + Text(" " + unit).font(.system(size: 12, weight: .semibold)))
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(height: 20)
    }
    private func asideAction(title: String, detail: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13)).lineSpacing(5).foregroundStyle(LVTheme.text.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
            .help(title == "快捷键与权限" ? "打开设置，查看快捷键和权限" : "打开文本工作台")
    }
    private func useCase(_ symbol: String, color: Color, title: String, detail: String, mode: InputMode = .dictate) -> some View {
        Button {
            model.mode = mode
            openWorkbench()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 27, weight: .medium)).foregroundStyle(color.gradient).frame(height: 32)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.65)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
                .background(LVTheme.panel, in: RoundedRectangle(cornerRadius: 24))
                .contentShape(RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).disabled(model.busy).help("在文本工作台使用" + mode.title)
    }
    private var durationValue: String { library.totalDuration < 60 ? String(Int(library.totalDuration)) : String(format: "%.1f", library.totalDuration / 60) }
    private var durationUnit: String { library.totalDuration < 60 ? "秒" : "分钟" }
    private var averageSpeed: String { library.totalDuration > 0 ? String(Int(Double(library.totalWords) * 60 / library.totalDuration)) : "0" }
    private var activeDays: Int { Set(library.history.map { Calendar.current.startOfDay(for: $0.date) }).count }
}

private struct ActivityHeatmap: View {
    let history: [HistoryEntry]
    var body: some View {
        let calendar = Calendar.current
        let counts = Dictionary(grouping: history, by: { calendar.startOfDay(for: $0.date) }).mapValues(\.count)
        GeometryReader { geometry in
            let weeks = max(8, min(26, Int((geometry.size.width + 6) / 20)))
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("最近 \(weeks) 周").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("输入活动").font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.55))
                }
                HStack(spacing: 6) {
                    ForEach(0..<weeks, id: \.self) { week in
                        VStack(spacing: 6) {
                            ForEach(0..<7) { day in
                                let offset = week * 7 + day - (weeks * 7 - 1)
                                let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) ?? Date()
                                let count = counts[date] ?? 0
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(count == 0 ? LVTheme.thin : LVTheme.accent.opacity(min(1, 0.25 + Double(count) * 0.15)))
                                    .frame(width: 14, height: 14)
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(LVTheme.border))
                                    .help("\(date.formatted(date: .abbreviated, time: .omitted)) · \(count) 次输入")
                            }
                        }
                    }
                }
            }
        }.frame(height: 165)
    }
}

private struct DotPattern: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: CGFloat(4), through: size.width, by: 8) {
                for y in stride(from: CGFloat(4), through: size.height, by: 8) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.gray.opacity(0.25)))
                }
            }
        }.background(LVTheme.thin)
    }
}

private struct StatCard: View {
    let value: String
    let unit: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                Text(unit).font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.55))
            }
            Text(title).font(.system(size: 14)).foregroundStyle(LVTheme.text.opacity(0.55))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(LVTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ShortcutRow: View {
    let symbol: String
    let title: String
    let description: String
    let keys: [String]
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(description).font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 5) { ForEach(keys, id: \.self) { KeyCap(label: $0) } }
        }.padding(.vertical, 12)
    }
}

private struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label).font(.system(size: 15, weight: .semibold)).frame(minWidth: 30, minHeight: 30)
            .background(LVTheme.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LVTheme.text.opacity(0.22)))
            .shadow(color: .black.opacity(0.05), radius: 0, x: 0, y: 2)
    }
}

private struct PageHeading<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 36, weight: .medium))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.55))
            }
            Spacer(minLength: 18)
            trailing()
        }.padding(.top, 20).padding(.bottom, 24)
    }
}

private struct SearchBox: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.45))
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(LVTheme.text.opacity(0.35)) }.buttonStyle(.plain) }
        }.padding(.horizontal, 12).frame(height: 36)
            .background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LVTheme.border))
    }
}

private struct EmptyLibraryView: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(LVTheme.text.opacity(0.35)).padding(.bottom, 5)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.5)).multilineTextAlignment(.center).lineSpacing(4)
        }.frame(maxWidth: .infinity, minHeight: 270)
    }
}

private struct HistoryPage: View {
    @ObservedObject var model: VoiceModel
    @ObservedObject var library: LibraryStore
    @State private var search = ""
    @State private var filter = "all"
    @State private var deleting: HistoryEntry?
    private var entries: [HistoryEntry] {
        library.history.filter { entry in
            (filter == "all" || (filter == "dictate" ? entry.mode != "ask" : entry.mode == "ask")) &&
            (search.isEmpty || entry.text.localizedCaseInsensitiveContains(search) || entry.raw.localizedCaseInsensitiveContains(search) || entry.application.localizedCaseInsensitiveContains(search))
        }
    }
    private var grouped: [(date: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: entries, by: { calendar.startOfDay(for: $0.date) })
            .map { (date: $0.key, entries: $0.value) }.sorted { $0.date > $1.date }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: "历史记录", subtitle: "回顾、查找和复制你说过的话。") {
                Text("\(library.history.count) 条记录").font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.5)).padding(.top, 9)
            }
            HStack(spacing: 16) {
                SearchBox(placeholder: "搜索历史记录", text: $search)
                Picker("输入类型", selection: $filter) {
                    Text("全部记录").tag("all")
                    Text("语音输入").tag("dictate")
                    Text("语音提问").tag("ask")
                }.labelsHidden().frame(width: 116)
            }.padding(.bottom, 20)
            if let error = library.errorMessage { InlineError(text: error).padding(.bottom, 10) }
            if entries.isEmpty {
                EmptyLibraryView(symbol: "clock.arrow.circlepath", title: search.isEmpty ? "还没有历史记录" : "没有找到相关记录", detail: search.isEmpty ? "完成一次语音输入后，文字会保存在这里。" : "换一个关键词，或切换输入类型后再试。")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(grouped, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(dateTitle(group.date)).font(.system(size: 12, weight: .medium)).foregroundStyle(LVTheme.text.opacity(0.5))
                                VStack(spacing: 0) {
                                    ForEach(group.entries) { entry in
                                        HistoryRow(model: model, entry: entry,
                                                   hasAudio: library.audioURL(for: entry.id) != nil,
                                                   canRetry: library.canRetry(entry), delete: { deleting = entry })
                                        if entry.id != group.entries.last?.id { Divider().overlay(LVTheme.border).padding(.horizontal, 16) }
                                    }
                                }.background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }.padding(.bottom, 20)
                }.scrollIndicators(.hidden)
            }
        }.padding(.horizontal, 24)
            .alert("删除这条记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let deleting { library.deleteHistory(id: deleting.id) }; deleting = nil }
            } message: { Text("这条记录、录音和页面截图会一并删除，删除后将无法恢复。已输入到其他应用的文字不受影响。") }
            .onDisappear { model.stopHistoryAudio() }
    }
    private func dateTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.year().month().day().weekday())
    }
}

struct HistoryRow: View {
    @ObservedObject var model: VoiceModel
    let entry: HistoryEntry
    let hasAudio: Bool
    let canRetry: Bool
    let delete: () -> Void
    @State var expanded = false
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(entry.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                Text("·")
                Text(modeLabel(entry.mode))
                if !entry.application.isEmpty { Text("·"); Text(entry.application).lineLimit(1) }
                if !entry.succeeded { Text(entry.cancelled ? "· 已取消" : "· 待重试").foregroundStyle(.orange) }
                Spacer(minLength: 8)
                CopyButton(text: entry.text.isEmpty ? entry.raw : entry.text)
                Button(action: delete) { Image(systemName: "trash").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(LVTheme.text.opacity(0.5)).help("删除记录")
            }.font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5))
            if !entry.text.isEmpty || !entry.raw.isEmpty {
                Text(entry.text.isEmpty ? entry.raw : entry.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    .lineLimit(expanded ? nil : 4).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(hasAudio ? "录音已保留，可以重新识别。" : "没有保留可重试的录音或文字。")
                    .font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.55))
            }
            HStack(spacing: 14) {
                if let url = model.library.screenshotURL(for: entry.id) {
                    HistoryScreenshotThumbnail(url: url, title: entry.contextWindowTitle ?? entry.application)
                }
                Button(expanded ? "收起" : "查看详情") { expanded.toggle() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5))
                if model.retryingHistoryID == entry.id {
                    ProgressView().controlSize(.mini)
                    Button("取消处理") { model.cancel() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(LVTheme.accent)
                } else if !entry.succeeded && canRetry {
                    Button("重试") { model.retryHistory(id: entry.id) }.buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(LVTheme.accent).disabled(model.busy)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 12) {
                        Text(String(format: "录音 %.1f 秒", entry.duration))
                        if entry.mode == "translate" { Text("翻译为 \(entry.targetLanguage)") }
                        Spacer()
                        if hasAudio {
                            Button { model.playHistoryAudio(id: entry.id) } label: {
                                Label(model.playingHistoryID == entry.id ? "停止播放" : "播放录音",
                                      systemImage: model.playingHistoryID == entry.id ? "stop.fill" : "play.fill")
                            }.buttonStyle(.plain).foregroundStyle(LVTheme.accent).disabled(model.busy)
                        }
                        if canRetry {
                            Button("重新处理") { model.retryHistory(id: entry.id) }.buttonStyle(.plain)
                                .foregroundStyle(LVTheme.accent).disabled(model.busy)
                        }
                    }.font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5))
                    if entry.mode == "context" {
                        Text(entry.contextCaptureStatus ?? "旧记录未记录上下文读取状态")
                            .font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.55))
                        if let input = entry.contextInputText {
                            Text(input.isEmpty ? "当时未读取到输入框文字" : "当时输入框：\(input)")
                                .font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.55))
                                .lineLimit(4).textSelection(.enabled)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("识别原文").font(.system(size: 11, weight: .medium))
                        if !entry.raw.isEmpty && entry.raw == entry.text {
                            Text("与输出相同").font(.system(size: 10))
                        }
                        Spacer()
                        if !entry.raw.isEmpty { CopyButton(text: entry.raw) }
                    }.foregroundStyle(LVTheme.text.opacity(0.5)).padding(.top, 4)
                    if !entry.raw.isEmpty {
                        Text(entry.raw).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    } else {
                        Text(entry.cancelled ? "转写完成前已取消，尚无识别原文。" : "尚未获得识别原文。")
                            .font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.55))
                        if hasAudio {
                            Text("录音仍在，点击“重新处理”可再次识别。")
                                .font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.5))
                        }
                    }
                    if !hasAudio { Text("这条记录未保留录音。") .font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.45)) }
                    if ["ask", "context"].contains(entry.mode) && canRetry {
                        Text(entry.contextInputText != nil || entry.contextScreenshotFileName != nil
                             ? "重新处理会参考当时保存的输入框和页面截图。"
                             : "这条记录未保存页面上下文，重新处理仅使用识别原文。")
                            .font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.45))
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(LVTheme.hover, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(16).background(hover ? LVTheme.hover : .clear).onHover { hover = $0 }
    }
    private func modeLabel(_ mode: String) -> String { mode == "context" ? "上下文听写" : mode == "translate" ? "语音翻译" : mode == "ask" ? "语音提问" : "语音输入" }
}

struct HistoryScreenshotThumbnail: View {
    let url: URL
    let title: String
    @State private var image: NSImage?
    @State private var enlarged = false
    var body: some View {
        Button { enlarged = true } label: {
            Group {
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 64, height: 40)
            .background(LVTheme.thin)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LVTheme.border))
        }.buttonStyle(.plain).help("点击放大当时的页面截图")
            .accessibilityLabel("查看页面截图")
            .task(id: url) {
                let thumbnail = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0,
                        [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
                         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                if let thumbnail { image = NSImage(cgImage: thumbnail, size: .zero) }
            }
            .sheet(isPresented: $enlarged) { HistoryScreenshotPreview(url: url, title: title, close: { enlarged = false }) }
    }
}

struct HistoryScreenshotPreview: View {
    let url: URL
    let title: String
    let close: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title.isEmpty ? "当时的页面截图" : title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text("截图已删除或无法读取。").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(20)
            .frame(width: min(960, (NSScreen.main?.visibleFrame.width ?? 1200) - 160),
                   height: min(660, (NSScreen.main?.visibleFrame.height ?? 800) - 140))
            .foregroundStyle(LVTheme.text).background(LVTheme.background)
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(.plain).foregroundStyle(copied ? LVTheme.accent : LVTheme.text.opacity(0.55)).help("复制文字").disabled(text.isEmpty)
    }
}

private struct DictionaryPage: View {
    @ObservedObject var library: LibraryStore
    @State private var search = ""
    @State private var source = "all"
    @State private var editorPresented = false
    @State private var editing: DictionaryWord?
    @State private var word = ""
    @State private var importMessage: String?
    @State private var deleting: DictionaryWord?
    private var words: [DictionaryWord] {
        library.words.filter {
            (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) &&
            (source == "all" || (source == "manual" ? $0.source == .manual : $0.source == .automatic))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: "词典", subtitle: "让Knock记住姓名、术语和你常用的词。") {
                HStack(spacing: 8) {
                    Button(action: importCSV) { Label("导入", systemImage: "square.and.arrow.down") }.buttonStyle(SurfaceButtonStyle())
                    Button { editing = nil; word = ""; editorPresented = true } label: { Label("添加词语", systemImage: "plus") }.buttonStyle(SurfaceButtonStyle(prominent: true))
                }
            }
            HStack(spacing: 16) {
                SearchBox(placeholder: "搜索词典", text: $search)
                Picker("词语来源", selection: $source) {
                    Text("全部词语").tag("all")
                    Text("手动添加").tag("manual")
                }.labelsHidden().frame(width: 112)
            }.padding(.bottom, 18)
            if let error = library.errorMessage { InlineError(text: error).padding(.bottom, 10) }
            if let importMessage {
                HStack { Text(importMessage).font(.system(size: 12)).foregroundStyle(LVTheme.accent); Spacer(); Button { self.importMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(.bottom, 12)
            }
            if words.isEmpty {
                EmptyLibraryView(symbol: "book.closed", title: search.isEmpty ? "添加你的第一个词语" : "没有找到相关词语", detail: search.isEmpty ? "添加人名、品牌名或专业术语，提高文字整理的准确度。\n也可以导入 CSV 文件，批量添加词语。" : "换一个关键词，或切换词语来源后再试。")
                Spacer()
            } else {
                HStack {
                    Text("词语").frame(maxWidth: .infinity, alignment: .leading)
                    Text("来源").frame(width: 100, alignment: .leading)
                    Text("操作").frame(width: 58, alignment: .trailing)
                }.font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5)).padding(.horizontal, 14).padding(.vertical, 12)
                Divider().overlay(LVTheme.border)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(words) { item in
                            HStack(spacing: 12) {
                                Text(item.text).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Text(item.source == .manual ? "手动添加" : "自动学习").font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.5)).frame(width: 100, alignment: .leading)
                                HStack(spacing: 16) {
                                    Button { editing = item; word = item.text; editorPresented = true } label: { Image(systemName: "pencil") }.help("编辑词语")
                                    Button { deleting = item } label: { Image(systemName: "trash") }.help("删除词语")
                                }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.5)).frame(width: 58, alignment: .trailing)
                            }.padding(.horizontal, 14).padding(.vertical, 17)
                            Divider().overlay(LVTheme.border)
                        }
                    }
                }.scrollIndicators(.hidden)
                Text("共 \(words.count) 个词语").font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5)).padding(.top, 12)
            }
        }.padding(.horizontal, 24)
            .sheet(isPresented: $editorPresented) { wordEditor }
            .alert("删除“\(deleting?.text ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let deleting { library.deleteWord(id: deleting.id) }; deleting = nil }
            } message: { Text("该词语将从你的个人词典中移除。") }
    }
    private var wordEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editing == nil ? "添加词语" : "编辑词语").font(.system(size: 21, weight: .semibold))
            Text("输入一个姓名、术语或常用词语。词典会用于文字整理。Whisper 和 Qwen 识别时也会参考词典。").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("例如：Knock", text: $word).textFieldStyle(.roundedBorder).font(.system(size: 15)).onSubmit(saveWord)
            if let error = library.errorMessage { InlineError(text: error) }
            HStack {
                Spacer()
                Button("取消") { editorPresented = false }.keyboardShortcut(.cancelAction).buttonStyle(SurfaceButtonStyle())
                Button("保存", action: saveWord).keyboardShortcut(.defaultAction).buttonStyle(SurfaceButtonStyle(prominent: true)).disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 430).background(LVTheme.background)
    }
    private func saveWord() {
        guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let editing { library.updateWord(id: editing.id, text: word) } else { library.addWord(word) }
        if library.errorMessage == nil { editorPresented = false }
    }
    private func importCSV() {
        let panel = NSOpenPanel()
        panel.title = "导入词典"; panel.message = "选择 CSV 或文本文件，每行一个词语。"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let count = try library.importCSV(text)
            importMessage = "已导入 \(count) 个新词语。"
        } catch { importMessage = "导入失败：\(error.localizedDescription)" }
    }
}

private struct InlineError: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
}

private struct SettingsPage: View {
    @ObservedObject var model: VoiceModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var speechModels: SpeechModelStore
    let enableShortcut: () -> Void
    let close: () -> Void
    @State private var category = "设置"
    private let categories = ["权限", "服务配置", "本机数据", "设置", "语音模型", "个性化", "关于", "帮助"]

    init(model: VoiceModel, library: LibraryStore, enableShortcut: @escaping () -> Void, close: @escaping () -> Void) {
        self.model = model
        self.library = library
        self.preferences = model.preferences
        self.speechModels = model.speechModels
        self.enableShortcut = enableShortcut
        self.close = close
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(categories, id: \.self) { item in
                    Button { category = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: categorySymbol(item)).resizable().scaledToFit().frame(width: 16, height: 16)
                            Text(item).font(.system(size: 14, weight: category == item ? .medium : .regular))
                            Spacer()
                        }.padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
                    }.buttonStyle(SidebarButtonStyle(selected: category == item)).accessibilityLabel(item)
                }
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 20).frame(width: 202).frame(maxHeight: .infinity).background(LVTheme.thin)
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text(category).font(.system(size: 24, weight: .medium))
                        .frame(height: 32, alignment: .leading).padding(.bottom, -12)
                    if category == "权限" { PermissionChecklist(preferences: preferences, enableShortcut: enableShortcut) }
                    else if category == "服务配置" { ServiceSettingsView(model: model) }
                    else if category == "设置" { mainSettings }
                    else if category == "语音模型" { speechModelSettings }
                    else if category == "个性化" { personalizationSettings }
                    else if category == "本机数据" { privacySettings }
                    else if category == "帮助" { shortcutHelp }
                    else { aboutSettings }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 24)
            }.scrollIndicators(.hidden).id(category)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.65)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("关闭设置").accessibilityLabel("关闭设置").padding(12)
        }
        .onAppear { preferences.refresh(); speechModels.refresh() }
    }
    private func categorySymbol(_ item: String) -> String {
        switch item {
        case "权限": return "lock.shield"
        case "服务配置": return "network"
        case "本机数据": return "externaldrive"
        case "设置": return "gearshape"
        case "语音模型": return "cpu"
        case "个性化": return "signature"
        case "关于": return "info.circle"
        default: return "questionmark.circle"
        }
    }
    private var mainSettings: some View {
        VStack(alignment: .leading, spacing: 40) {
            shortcutSettings
            languageSettings
            speechModelSettings
            audioSettings
            generalSettings
        }
    }
    private func sectionHeading(_ title: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17)).frame(width: 18)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer()
            }.foregroundStyle(LVTheme.text.opacity(0.5)).frame(height: 24)
            Rectangle().fill(LVTheme.border).frame(height: 1)
        }.padding(.bottom, 4)
    }
    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("快捷键", symbol: "keyboard")
            shortcutRow("语音输入", detail: "按下开始和停止语音输入。", keys: ["Fn"])
            shortcutRow("翻译", detail: "按 Fn＋Shift 后松开，开始语音翻译；再按 Fn 结束。", keys: ["Fn", "Shift"])
            shortcutRow("上下文听写", detail: "按 Fn＋Control 后松开，读取当前输入框与窗口；再按 Fn 结束。", keys: ["Fn", "Control"])
            shortcutRow("问一问", detail: "按住 Fn，再按空格提问；再按 Fn 结束。", keys: ["Fn", "Space"])
        }
    }
    private func shortcutRow(_ title: String, detail: String, keys: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium)).frame(height: 20)
                Text(detail).font(.system(size: 14)).foregroundStyle(LVTheme.text.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(keys, id: \.self) { key in
                        Text(key).font(.system(size: 14)).padding(.horizontal, 8).frame(minWidth: 32, minHeight: 32)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LVTheme.border))
                    }
                    Spacer(minLength: 0)
                }.padding(4).frame(width: 204, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LVTheme.text.opacity(0.16)))
                Text("固定快捷键 · 暂不支持编辑").font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.45)).frame(height: 32)
            }.accessibilityElement(children: .combine)
        }.padding(.vertical, 9).frame(height: 98, alignment: .top)
    }
    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("上下文听写", symbol: "rectangle.and.text.magnifyingglass")
            settingsRow("文字与视觉模型", detail: "使用 gateway.env 中配置的兼容服务；截图校对需要模型支持图片输入。") { Text("自定义服务").font(.system(size: 14)) }
            settingsRow("附带当前窗口截图", detail: "仅在 Fn＋Control 触发时读取输入框和当前窗口，发送给模型校对；随历史保存在本机，可点击缩略图查看。关闭后只读取输入框。") {
                Toggle("附带当前窗口截图", isOn: $preferences.contextScreenshots).labelsHidden().toggleStyle(.switch)
            }
            settingsRow("页面截图权限", detail: preferences.screenCaptureAllowed ? "已允许。读取不到输入框时也能理解当前页面。" : "尚未允许，当前只能读取可访问的输入框文字。允许后如仍无截图，请重新打开Knock。") {
                Button(preferences.screenCaptureAllowed ? "检查权限" : "允许页面截图") { preferences.requestScreenCapture() }.buttonStyle(SurfaceButtonStyle())
            }
            sectionHeading("语言", symbol: "globe")
            settingsRow("界面语言", detail: "当前版本使用简体中文界面。") {
                HStack { Text("简体中文"); Spacer(); Text("只读").font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.4)) }
                    .font(.system(size: 14)).padding(.horizontal, 12).frame(width: 200, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LVTheme.border))
            }
            settingsRow("翻译目标", detail: "在翻译模式中，生成所选语言的文字。") {
                settingsPicker("翻译目标", selection: $model.targetLanguage, values: [
                    ("English", "English"), ("简体中文", "简体中文"), ("繁體中文", "繁體中文"), ("日本語", "日本語"),
                    ("한국어", "한국어"), ("Français", "Français"), ("Deutsch", "Deutsch"), ("Español", "Español")
                ])
            }
            settingsRow("口述语言", detail: "选择说话时使用的语言，或自动检测。") {
                settingsPicker("口述语言", selection: $model.language, values: [("auto", "自动检测"), ("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어")])
            }
        }.disabled(model.busy)
    }
    private var speechModelSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("语音模型", symbol: "cpu")
            settingsRow("识别模型", detail: speechModels.selected.detail) {
                Picker("语音模型", selection: Binding(get: { speechModels.selected }, set: model.chooseSpeechModel)) {
                    ForEach(SpeechModelID.allCases) { choice in
                        Text(choice.title + (choice == .cloud ? (speechModels.cloudAvailable ? "" : " · 未配置") : (speechModels.isReady(choice) ? " · 已安装" : " · 未下载")))
                            .tag(choice).disabled(choice == .cloud && !speechModels.cloudAvailable)
                    }
                }.labelsHidden().pickerStyle(.menu).frame(width: 255)
                    .accessibilityLabel("语音模型").disabled(model.busy)
            }
            HStack(spacing: 12) {
                if speechModels.selected == .cloud {
                    Label(speechModels.cloudAvailable ? "云端语音已配置" : "云端语音未配置", systemImage: "cloud")
                } else if speechModels.isReady(speechModels.selected) {
                    if speechModels.preparing == speechModels.selected {
                        ProgressView().controlSize(.small)
                        Text("正在加载语音模型……")
                    } else {
                        Label("已安装 · 本地识别不产生语音 API 费用", systemImage: "checkmark.circle")
                    }
                } else {
                    Label(speechModels.hasPendingDownload(speechModels.selected) ? "下载尚未完成" : "此模型尚未下载", systemImage: "arrow.down.circle")
                    Spacer()
                    Button(speechModels.hasPendingDownload(speechModels.selected) ? "继续下载" : "下载模型") {
                        speechModels.downloadModel(speechModels.selected)
                    }.buttonStyle(SurfaceButtonStyle()).disabled(model.busy || speechModels.download != nil)
                        .accessibilityLabel("下载所选语音模型")
                }
                if speechModels.selected == .cloud || speechModels.isReady(speechModels.selected) { Spacer(minLength: 0) }
            }.font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.65)).padding(.vertical, 12)
            if let download = speechModels.download {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(download.model.title + " · " + download.stage)
                        Spacer()
                        Button("暂停", action: speechModels.pauseDownload).buttonStyle(.link).disabled(download.paused)
                            .accessibilityLabel("暂停模型下载")
                    }
                    ProgressView(value: download.progress).tint(LVTheme.accent)
                        .accessibilityLabel("模型下载进度")
                    HStack {
                        Text(download.byteLabel)
                        Spacer()
                        Text("\(Int(download.progress * 100))%")
                    }.foregroundStyle(LVTheme.text.opacity(0.5))
                }.font(.system(size: 12)).padding(14).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 9)).padding(.bottom, 12)
            }
            if let error = speechModels.errors[speechModels.selected] { InlineError(text: error).padding(.bottom, 12) }
            if let error = speechModels.preparationError {
                HStack {
                    InlineError(text: error)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("重新加载", action: model.prepareSpeechModel).buttonStyle(.link).disabled(model.busy)
                        Button("重新下载") { speechModels.downloadModel(speechModels.selected, force: true) }
                            .buttonStyle(.link).disabled(model.busy || speechModels.download != nil)
                    }
                }.padding(.bottom, 12)
            }
            Text("本地模型只处理语音。文字整理、翻译与上下文理解连接你配置的文字服务。")
                .font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5)).padding(.bottom, 6)
        }
    }
    private var audioSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("音频", symbol: "waveform")
            settingsRow("麦克风", detail: "\(preferences.microphones.defaultName)\n\(preferences.microphones.detail)") {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("声音输入设置", action: preferences.openSoundInputSettings).buttonStyle(SurfaceButtonStyle())
                    if preferences.microphones.permission == .denied || preferences.microphones.permission == .restricted {
                        Button("麦克风权限", action: preferences.openMicrophonePrivacySettings).buttonStyle(.link).font(.system(size: 11))
                    }
                    Button("刷新设备", action: preferences.refresh).buttonStyle(.link).font(.system(size: 11))
                }
            }
            if !preferences.microphones.devices.isEmpty {
                Text("可用设备：" + preferences.microphones.devices.map { $0.name + ($0.isDefault ? "（系统默认）" : "") }.joined(separator: "、"))
                    .font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            }
            if let error = preferences.settingsError { InlineError(text: error).padding(.vertical, 12) }
            settingsRow("提示音", detail: "开始和结束录音时播放提示音。") {
                Toggle("提示音", isOn: $model.soundEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }.disabled(model.busy)
    }
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("通用", symbol: "slider.horizontal.3")
            settingsRow("外观", detail: "选择Knock的显示主题。") {
                settingsPicker("外观", selection: $model.appearance, values: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")])
            }
            settingsRow("登录时启动", detail: preferences.loginItemDetail) {
                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("登录时启动", isOn: Binding(get: { preferences.launchAtLogin }, set: preferences.setLaunchAtLogin))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    if preferences.loginItemNeedsReview {
                        Button("打开系统设置", action: preferences.openLoginItemSettings).buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
            settingsRow("在 Dock 中显示", detail: "关闭后仍可从菜单栏打开Knock。") {
                Toggle("在 Dock 中显示", isOn: Binding(get: { preferences.showDockIcon }, set: preferences.setShowDockIcon))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            settingsRow("自动输入", detail: "完成后将文字输入到录音前的光标位置。") {
                Toggle("自动输入", isOn: $model.autoPaste).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            settingsRow("天气默认城市", detail: "未指定城市时用于天气查询；留空则先询问城市。") {
                TextField("例如：北京", text: $preferences.weatherCity).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            settingsRow("输入模式", detail: "选择口述、翻译或用声音提问。") {
                Picker("输入模式", selection: $model.mode) { ForEach(InputMode.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 200).disabled(model.busy)
            }
            Button("设置快捷键权限", action: enableShortcut).buttonStyle(SurfaceButtonStyle()).padding(.top, 16)
            Text("关闭主窗口后，仍可从菜单栏或使用 Fn 快捷键开始录音。").font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.5)).padding(.top, 16)
        }
    }
    private var personalizationSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("文字习惯", symbol: "signature")
            settingsRow("自动整理文字", detail: "为口述补充标点、去掉重复，并使用个人词典。") {
                Toggle("自动整理文字", isOn: $model.autoPolish).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy)
            }
            settingsRow("个人词典", detail: "在主窗口的「词典」中维护常用名称、术语和表达。") {
                Text("\(library.words.count) 个词语").font(.system(size: 14)).foregroundStyle(LVTheme.text.opacity(0.6))
            }
            Text("文字整理会使用你主动保存的词语。当前没有自动学习评分或云端个人画像。").font(.system(size: 12)).lineSpacing(5).foregroundStyle(LVTheme.text.opacity(0.5)).padding(.top, 16)
        }
    }
    private var shortcutHelp: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeading("录音与输入", symbol: "keyboard")
                settingsRow("取消", detail: "取消本次录音或文字处理。") { KeyCap(label: "esc") }
                settingsRow("粘贴上次结果", detail: "在当前输入框重新输入最近一次的结果。") { HStack(spacing: 5) { KeyCap(label: "⌃"); KeyCap(label: "⌘"); KeyCap(label: "V") } }
            }
            Label(model.shortcutStatus, systemImage: "keyboard").font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.6)).textSelection(.enabled)
            Button("设置 Fn 权限", action: enableShortcut).buttonStyle(SurfaceButtonStyle())
            Text("在 macOS 的隐私与安全性中允许辅助功能和麦克风。如果 Fn 同时弹出系统听写或表情面板，可在系统键盘设置中调整 Fn 的行为。")
                .font(.system(size: 12)).lineSpacing(5).foregroundStyle(LVTheme.text.opacity(0.5))
        }
    }
    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("历史记录与隐私", symbol: "lock.shield")
            settingsRow("历史记录保留时间", detail: "超过保留时间的本机记录和关联录音会被清理。") {
                Picker("历史记录保留时间", selection: $library.retention) { ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 200)
            }
            if let error = library.errorMessage { InlineError(text: error).padding(.vertical, 14) }
            VStack(alignment: .leading, spacing: 20) {
                privacyNote("waveform", title: "语音识别", detail: "本地模型在 Mac 上处理录音；选择豆包云端时，录音会发送到豆包语音服务。保留历史时也会保存录音，用于回放和重试；删除记录会一并删除录音。")
                privacyNote("rectangle.dashed", title: "上下文听写", detail: "仅在主动触发上下文听写时读取当前输入框。开启截图且获系统授权后，还会截取当前窗口。文字与截图发送到配置的文字服务，截图随历史保存在本机并遵循保留设置。")
                privacyNote("text.bubble", title: "文字整理与问答", detail: "启用文字整理、翻译或提问时，识别文字及个人词典会发送给配置的文字处理服务。提问还会发送当前选中的文字作为上下文。")
                privacyNote("externaldrive", title: "本机保存", detail: "历史记录和个人词典保存在这台 Mac。你可以单独删除记录和词语，或选择不保存新的历史记录。")
            }.padding(.top, 24)
        }
    }
    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Knock", systemImage: "waveform").font(.system(size: 26, weight: .medium))
            Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发预览"))
                .font(.system(size: 13)).foregroundStyle(LVTheme.text.opacity(0.55))
            Text("轻叩，开口。Knock 希望成为你与 Agent 之间的入口。当前版本支持 macOS 上的语音输入、翻译、上下文听写和问答；语音可选云端或本地模型。")
                .font(.system(size: 14)).lineSpacing(6).foregroundStyle(LVTheme.text.opacity(0.65))
        }
    }
    private func settingsRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 14)).foregroundStyle(LVTheme.text.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize(horizontal: true, vertical: false)
        }.padding(.vertical, 9).frame(minHeight: 64)
    }
    private func settingsPicker(_ title: String, selection: Binding<String>, values: [(String, String)]) -> some View {
        Menu {
            ForEach(values, id: \.0) { value in
                Button { selection.wrappedValue = value.0 } label: {
                    if selection.wrappedValue == value.0 { Label(value.1, systemImage: "checkmark") }
                    else { Text(value.1) }
                }
            }
        } label: {
            HStack {
                Text(values.first(where: { $0.0 == selection.wrappedValue })?.1 ?? selection.wrappedValue)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 11))
            }.font(.system(size: 14)).padding(.horizontal, 12).frame(width: 200, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LVTheme.border))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(title)
    }
    private func privacyNote(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).lineSpacing(4).foregroundStyle(LVTheme.text.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                control()
            }.padding(.vertical, 23)
            Divider().overlay(LVTheme.border)
        }
    }
}

private struct WorkbenchPage: View {
    @ObservedObject var model: VoiceModel
    let back: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "文本工作台", subtitle: "查看原始转写，继续修改或整理文字。") {
                Button("返回首页", action: back).buttonStyle(SurfaceButtonStyle())
            }
            HStack(spacing: 10) {
                Button { model.polish() } label: { Label("整理原文", systemImage: "sparkles") }.buttonStyle(SurfaceButtonStyle(prominent: true)).disabled(model.busy || model.raw.isEmpty)
                Button { model.copyResult() } label: { Label("复制结果", systemImage: "doc.on.doc") }.buttonStyle(SurfaceButtonStyle()).disabled(model.result.isEmpty)
                if model.hasRecording { Button("重新识别") { model.recognize() }.buttonStyle(SurfaceButtonStyle()).disabled(model.busy) }
                Spacer()
            }
            HStack(alignment: .top, spacing: 16) {
                editor("识别原文", text: $model.raw)
                editor("整理结果", text: $model.result)
            }
        }.padding(.horizontal, 24).padding(.bottom, 10)
    }
    private func editor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Text("\(text.wrappedValue.count) 字").font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5)) }
            TextEditor(text: text).font(.system(size: 15)).lineSpacing(5).scrollContentBackground(.hidden)
                .padding(12).background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LVTheme.border)).accessibilityLabel(title).disabled(model.busy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VoiceControlBar: View {
    @ObservedObject var model: VoiceModel
    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 0) {
                Menu {
                    ForEach(InputMode.allCases) { mode in Button { model.mode = mode } label: { Label(mode.title, systemImage: modeSymbol(mode)) } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: modeSymbol(model.mode)).font(.system(size: 14)).foregroundColor(.white)
                        Text(model.mode.title).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    }.padding(.leading, 16).padding(.trailing, 14).frame(height: 46)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy)
                    .foregroundStyle(.white).tint(.white).environment(\.colorScheme, .dark)
                Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 20)
                Button { model.toggle() } label: {
                    HStack(spacing: 11) {
                        if model.phase == .recording { AudioBars(level: { model.level }).frame(width: 38, height: 23) }
                        else if model.apiRetryAttempt > 0 { Text("正在重试（\(model.apiRetryAttempt)/5）").font(.system(size: 12)).monospacedDigit() }
                        else if model.phase == .transcribing || model.phase == .polishing { ThinkingIndicator().frame(width: 76, height: 24) }
                        else if model.busy { ProgressView().controlSize(.small).tint(.white).scaleEffect(0.8).frame(width: 20, height: 20) }
                        else { Image(systemName: "mic.fill").font(.system(size: 15)) }
                        if model.phase != .transcribing && model.phase != .polishing {
                            Text(buttonTitle).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        }
                        if !model.busy { Text(model.mode.shortcut).font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 4)) }
                        if model.phase == .recording { Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)) }
                    }.padding(.horizontal, 17).frame(height: 46).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.busy && model.phase != .recording)
                if model.busy {
                    Button { model.cancel() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 30, height: 32) }
                        .buttonStyle(.plain).help("取消录音").padding(.trailing, 7)
                }
            }.foregroundStyle(.white).background(Color(red: 29 / 255, green: 26 / 255, blue: 26 / 255), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08))).shadow(color: .black.opacity(0.13), radius: 8, x: 0, y: 4).fixedSize()
            if model.canRetryProcessing && !model.busy {
                Button("重试") { model.retryProcessing() }.buttonStyle(SurfaceButtonStyle(prominent: true))
            }
            Text(model.status).font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.5)).lineLimit(2).multilineTextAlignment(.center).textSelection(.enabled).frame(minHeight: 14)
        }.frame(maxWidth: .infinity)
    }
    private var buttonTitle: String {
        switch model.phase { case .ready: return "点击开始说话"; case .recording: return model.timeLabel; case .authorizing: return "准备中"; case .transcribing: return "正在转写"; case .polishing: return model.mode.isAssistant ? "正在思考" : "正在整理" }
    }
    private func modeSymbol(_ mode: InputMode) -> String { mode == .translate ? "globe" : mode == .context ? "rectangle.and.text.magnifyingglass" : mode == .ask ? "sparkles" : "mic" }
}

struct StatusHUD: View {
    let message: String
    var retry: (() -> Void)? = nil
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(.white.opacity(0.7)).padding(.top, 2)
            Text(message).font(.system(size: 13)).lineSpacing(3).lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(message)
            if let retry {
                Button("重试", action: retry).buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.white.opacity(0.16), in: Capsule())
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22)
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).help("关闭提示").accessibilityLabel("关闭提示")
        }.foregroundStyle(.white).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.2)))
            .padding(3).help(message)
    }
}

struct RecordingHUD: View {
    @ObservedObject var model: VoiceModel
    var body: some View {
        Group {
            if model.phase != .ready { recordingContent }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var askAccent: Color { model.mode == .context ? Color(red: 0.78, green: 0.65, blue: 1) : Color(red: 0.32, green: 0.90, blue: 0.75) }
    private var assistantBackground: Color { model.mode == .context ? Color(red: 0.12, green: 0.07, blue: 0.20) : Color(red: 0.025, green: 0.14, blue: 0.12) }
    private var isAsking: Bool { model.mode.isAssistant }
    private var expandedHUD: Bool { isAsking || model.mode == .context }
    private var recordingContent: some View {
        VStack(spacing: 6) {
            if isAsking || model.mode == .context {
                Label(model.mode == .context ? "上下文听写 · Fn ⌃" : "问一问 · Fn ␣", systemImage: model.mode == .context ? "rectangle.and.text.magnifyingglass" : "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(askAccent)
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(assistantBackground, in: Capsule())
                    .accessibilityLabel(model.mode == .context ? "上下文听写，Fn 加 Control" : "问一问模式，Fn 加空格")
                    .help(model.mode == .context ? model.contextStatus : "语音问答")
            }
            if model.phase == .recording && model.mode == .translate {
                Menu {
                    ForEach(["English", "简体中文", "繁體中文", "日本語", "한국어", "Français", "Deutsch", "Español"], id: \.self) { language in
                        Button(language) { model.targetLanguage = language }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.targetLanguage).foregroundColor(.white)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundColor(.white)
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 10).frame(height: 20)
                        .background(Color.black, in: Capsule())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.white).tint(.white).environment(\.colorScheme, .dark)
            }
            capsule
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var capsule: some View {
        Group {
            if model.phase == .recording {
                HStack(spacing: expandedHUD ? 10 : 12) {
                    cancelButton
                    AudioBars(level: { model.level }).frame(width: 38, height: 23)
                    if isAsking || model.mode == .context {
                        Text(model.mode == .context ? "结合页面听写" : "请说出问题").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    }
                    Button { model.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 9)).foregroundStyle(.white).frame(width: 18, height: 24)
                    }.buttonStyle(.plain).help("结束录音")
                }
            } else if model.apiRetryAttempt > 0 {
                HStack(spacing: 8) {
                    cancelButton
                    Text("正在重试 \(model.apiRetryAttempt)/5").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white)
                }
            } else if model.phase == .transcribing || model.phase == .polishing {
                ThinkingIndicator(leadingInset: 22, showsProgress: true, label: isAsking ? (model.phase == .transcribing ? "识别问题" : model.lookupStatus.isEmpty ? "生成回答" : model.lookupStatus) : model.mode == .context ? "整理口述" : "Thinking")
                    .overlay(alignment: .leading) { cancelButton.padding(.leading, 10) }
            } else {
                if isAsking {
                    Text("正在准备提问…").font(.system(size: 11)).foregroundStyle(.white)
                } else { Color.clear }
            }
        }
        .frame(width: expandedHUD ? 186 : model.phase == .authorizing ? 54 : model.apiRetryAttempt > 0 ? 150 : 116,
               height: model.phase == .authorizing && !expandedHUD ? 12 : 34)
        .background(expandedHUD ? assistantBackground : Color.black, in: Capsule())
        .overlay(alignment: .top) {
            if model.mode != .dictate {
                Capsule().fill(model.mode == .translate ? Color(red: 52 / 255, green: 107 / 255, blue: 1) : Color(red: 0, green: 163 / 255, blue: 137 / 255))
                    .frame(width: 54, height: 4).blur(radius: 7)
            }
        }
        .overlay(Capsule().strokeBorder(expandedHUD ? askAccent.opacity(0.55) : .white.opacity(0.32), lineWidth: 1))
        .help(model.phase == .recording ? "录音中 \(model.timeLabel) · 再按快捷键结束" : model.phase == .transcribing ? "正在转文字" : model.phase == .authorizing ? "正在准备麦克风" : "正在处理文字")
    }
    private var cancelButton: some View {
        Button { model.cancel() } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.72)).frame(width: 14, height: 24)
        }.buttonStyle(.plain).help("取消 · Esc").accessibilityLabel("取消")
    }
}

struct AnswerView: View {
    @ObservedObject var model: VoiceModel
    @State private var promptExpanded = false

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.mode == .context { Text(model.contextStatus).font(.system(size: 11)).foregroundStyle(LVTheme.text.opacity(0.6)).lineLimit(2) }
                if !model.raw.isEmpty { question(cardWidth: min(744, geometry.size.width - 16)) }
                answerCard
            }.padding(16).frame(maxWidth: 744, maxHeight: .infinity)
                .foregroundStyle(LVTheme.text)
                .background {
                    RoundedRectangle(cornerRadius: 16).fill(LVTheme.color(0xF2F1F0, 0x3C3B3B))
                        .shadow(color: .black.opacity(0.25), radius: 15, x: 0, y: 12.5)
                        .shadow(color: .black.opacity(0.15), radius: 10)
                }
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LVTheme.text.opacity(0.16)))
                .padding(.horizontal, 8).padding(.top, 24).padding(.bottom, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(model.appearance == "light" ? .light : model.appearance == "dark" ? .dark : nil)
        .onExitCommand { model.showAnswer = false }
        .onChange(of: model.raw) { _, _ in promptExpanded = false }
    }
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0, green: 0.55, blue: 0.44))
                Text(model.mode == .context ? "Knock · 上下文听写" : "Knock · 问一问").font(.system(size: 16, weight: .semibold))
            }.frame(maxWidth: .infinity)
            Button { model.showAnswer = false } label: {
                Image(systemName: "xmark").font(.system(size: 12)).frame(width: 24, height: 24)
            }.buttonStyle(.plain).foregroundStyle(LVTheme.text.opacity(0.55)).help("关闭回答 · Esc").accessibilityLabel("关闭回答")
        }.frame(height: 20)
    }
    private func question(cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mic").font(.system(size: 14)).foregroundStyle(LVTheme.text.opacity(0.5)).frame(width: 14, height: 22)
                Group {
                    if promptExpanded {
                        ScrollView {
                            Text(model.raw).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 132)
                    } else { Text(model.raw).lineLimit(2) }
                }.font(.system(size: 14)).lineSpacing(5).foregroundStyle(LVTheme.text.opacity(0.7))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                AnswerCopyButton(text: model.raw, label: "复制问题")
            }
            if questionExceedsTwoLines(width: max(80, cardWidth - 116)) {
                Button(promptExpanded ? "收起" : "展开问题") { promptExpanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LVTheme.text.opacity(0.65)).padding(.leading, 22)
            }
        }.padding(.leading, 16).padding(.trailing, 12)
    }
    private var answerCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 14))
                Text("回答").font(.system(size: 16, weight: .semibold))
                Text(model.answerLookupPerformed ? "已联网查询" : "未联网").font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(LVTheme.text.opacity(0.06), in: Capsule())
                    .help(model.answerLookupPerformed ? "回答下方显示本次查询的真实来源。" : "本次为普通回答或需要补充查询条件。")
                Spacer()
                AnswerCopyButton(text: String(answerText.characters), label: "复制回答")
            }.foregroundStyle(LVTheme.text.opacity(0.7)).padding(.leading, 16).padding(.trailing, 12).frame(height: 50)
            Rectangle().fill(LVTheme.border).frame(height: 1)
            ScrollView {
                Text(answerText).font(.system(size: 17)).lineSpacing(8).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LVTheme.background, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LVTheme.border))
    }
    private var answerText: AttributedString {
        (try? AttributedString(markdown: model.result, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(model.result)
    }
    private func questionExceedsTwoLines(width: CGFloat) -> Bool {
        let font = NSFont.systemFont(ofSize: 14)
        let height = (model.raw as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return height > NSLayoutManager().defaultLineHeight(for: font) * 2 + 1
    }
}

private struct AnswerCopyButton: View {
    let text: String
    let label: String
    @State private var copied = false
    @State private var copyRevision: UInt = 0
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else { return }
            copied = true
            copyRevision &+= 1
            let revision = copyRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if copyRevision == revision { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13)).frame(width: 22, height: 22)
        }.buttonStyle(.plain).foregroundStyle(copied ? Color.green : LVTheme.text.opacity(0.5))
            .help(copied ? "已复制" : label).accessibilityLabel(copied ? "已复制" : label).disabled(text.isEmpty)
            .onChange(of: text) { _, _ in copyRevision &+= 1; copied = false }
    }
}
