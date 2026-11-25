import AppKit
import SwiftUI

struct MarkdownView: View {
    let text: String
    var body: some View {
        let blocks = MarkdownDocument(text).blocks
        VStack(alignment: .leading, spacing: 15) {
            ForEach(blocks.indices, id: \.self) { index in block(blocks[index]) }
        }.font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                AnswerSource.validURL(url.absoluteString) ? .systemAction : .discarded
            })
    }
    @ViewBuilder private func block(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, value):
            inline(value).font(.system(size: level == 1 ? 26 : level == 2 ? 21 : 17, weight: .semibold))
                .padding(.top, level < 3 ? 8 : 2).fixedSize(horizontal: false, vertical: true)
        case let .paragraph(value): inline(value).fixedSize(horizontal: false, vertical: true)
        case let .item(marker, value, indent):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                inline(value).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(indent * 16))
        case let .quote(value):
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2).fill(LVTheme.accent.opacity(0.35)).frame(width: 3)
                inline(value).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }.fixedSize(horizontal: false, vertical: true)
        case let .code(language, value):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language.isEmpty ? "代码" : language).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制代码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                        .buttonStyle(QuietButtonStyle()).foregroundStyle(LVTheme.accent)
                }.padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                ScrollView(.horizontal) { Text(value).font(.system(size: 13, design: .monospaced)).lineSpacing(4).padding(14) }
            }.background(LVTheme.thin, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LVTheme.border))
        case let .table(rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(0..<(rows.map(\.count).max() ?? 0), id: \.self) { column in
                                inline(column < rows[row].count ? rows[row][column] : "")
                                    .font(.system(size: 13, weight: row == 0 ? .semibold : .regular))
                                    .frame(minWidth: 110, maxWidth: 280, alignment: .leading).padding(12)
                                    .background(row == 0 ? LVTheme.hover : row % 2 == 0 ? LVTheme.thin : .clear)
                            }
                        }
                        if row < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LVTheme.border))
            }
        case .rule: Divider().padding(.vertical, 6)
        }
    }
    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}

struct AgentSourceCards: View {
    let sources: [AnswerSource]
    @State private var expanded = false
    private var valid: [AnswerSource] {
        var seen = Set<String>()
        return sources.filter { AnswerSource.validURL($0.url) && seen.insert($0.url).inserted }
    }
    var body: some View {
        if !valid.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical").foregroundStyle(LVTheme.accent)
                    Text("参考来源").font(.system(size: 14, weight: .semibold))
                    Text("\(valid.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array((expanded ? valid : Array(valid.prefix(4))).enumerated()), id: \.element.id) { index, source in
                        AgentSourceCard(source: source, number: index + 1)
                    }
                }
                if valid.count > 4 {
                    Button(expanded ? "收起来源" : "查看其余 \(valid.count - 4) 个来源") { expanded.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LVTheme.accent)
                }
            }.padding(.top, 6)
        }
    }
}
private struct AgentSourceCard: View {
    let source: AnswerSource
    let number: Int
    @State private var hovered = false
    var body: some View {
        if let url = URL(string: source.url) {
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(String(number)).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                            .background(LVTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(LVTheme.accent)
                        Text(source.domain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(source.displayTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(LVTheme.text)
                        .lineLimit(2).frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                    if !source.content.isEmpty {
                        Text(source.content.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(hovered ? LVTheme.hover : LVTheme.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovered ? LVTheme.accent.opacity(0.3) : LVTheme.border))
            }.buttonStyle(.plain).help(source.url).onHover { hovered = $0 }
        }
    }
}
