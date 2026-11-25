import Foundation

enum InputMode: String, CaseIterable, Identifiable, Codable {
    case dictate, translate, ask, context
    // Temporary shortcut preference; the ordinary dictation pipeline stays available.
    static let primaryShortcutMode = InputMode.context
    var isAssistant: Bool { self == .ask }
    var capturesContext: Bool { self == .context || self == .ask }
    var id: String { rawValue }
    var title: String {
        switch self { case .dictate: return "听写"; case .translate: return "翻译"; case .ask: return "Agent"; case .context: return "上下文听写" }
    }
    var shortcut: String {
        switch self { case .dictate: return "手动"; case .translate: return "Fn ⇧"; case .ask: return "Fn Space"; case .context: return "Fn" }
    }
}
