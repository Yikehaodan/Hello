import Foundation

/// A small, native block renderer. HTML remains text; nothing is executed or fetched.
enum MarkdownBlock: Equatable {
    case heading(Int, String), paragraph(String), item(String, String, Int), quote(String)
    case code(String, String), table([[String]]), rule
}
struct MarkdownDocument {
    let blocks: [MarkdownBlock]
    init(_ markdown: String) {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [MarkdownBlock] = [], paragraph: [String] = [], index = 0
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = trimmed.first!, count = trimmed.prefix(while: { $0 == marker }).count
                let language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []; index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.prefix(while: { $0 == marker }).count >= count && candidate.allSatisfy({ $0 == marker }) { break }
                    code.append(lines[index]); index += 1
                }
                result.append(.code(language, code.joined(separator: "\n"))); index += 1; continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush(); result.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1)))); index += 1; continue
            }
            if index + 1 < lines.count, line.contains("|"), Self.isTableDivider(lines[index + 1]) {
                flush(); var rows = [Self.cells(line)]; index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(lines[index])); index += 1
                }
                result.append(.table(rows)); continue
            }
            if ["---", "***", "___"].contains(trimmed) { flush(); result.append(.rule); index += 1; continue }
            if trimmed.hasPrefix(">") {
                flush(); result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))); index += 1; continue
            }
            if let range = trimmed.range(of: #"^([-+*]|[0-9]+[.)])\s+"#, options: .regularExpression) {
                flush()
                let marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                var text = String(trimmed[range.upperBound...])
                var bullet = ["-", "+", "*"].contains(marker) ? "•" : marker
                if text.hasPrefix("[ ] ") { bullet = "☐"; text = String(text.dropFirst(4)) }
                if text.lowercased().hasPrefix("[x] ") { bullet = "☑"; text = String(text.dropFirst(4)) }
                result.append(.item(bullet, text, min(6, line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2)))
                index += 1; continue
            }
            paragraph.append(line); index += 1
        }
        flush(); blocks = result
    }
    private static func isTableDivider(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], current = "", escaped = false, inlineCode = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character); escaped = false; continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "`" { inlineCode.toggle() }
            if character == "|" && !inlineCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces)); return cells
    }
}
