import Foundation
import Security
import CryptoKit

struct AgentConfiguration: Codable, Equatable {
    var baseURL = "https://api.deepseek.com/anthropic"
    var model = "deepseek-flash"
    var auth = "bearer"
    var credentialDigest: String?
    var workspace = AppPaths.data.appendingPathComponent("AgentWorkspace").path
    var fingerprint: String { baseURL + "|" + model + "|" + workspace }

    func validated(key: String) throws -> AgentConfiguration {
        var value = self
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.baseURL), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !value.model.isEmpty, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ![value.model, key, value.baseURL].contains(where: { $0.contains("\n") || $0.contains("\r") }),
              ["bearer", "apiKey"].contains(auth), workspace.hasPrefix("/") else {
            throw AgentError.message("请填写有效的模型地址、API Key、模型名称和绝对工作目录。服务需支持 Anthropic Messages；本机服务可使用 HTTP。")
        }
        if url.path.hasSuffix("/messages") || url.path.hasSuffix("/chat/completions") {
            throw AgentError.message("请填写服务的 Base URL，不要包含 /messages 或 /chat/completions。")
        }
        return value
    }
}

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class AgentConfigurationStore {
    let root: URL
    private let readKey: () throws -> String
    private let writeKey: (String) throws -> Void
    init(root: URL = AppPaths.data.appendingPathComponent("Agent", isDirectory: true),
         readKey: @escaping () throws -> String = AgentKeychain.read,
         writeKey: @escaping (String) throws -> Void = AgentKeychain.write) {
        self.root = root; self.readKey = readKey; self.writeKey = writeKey
    }
    var configuration: AgentConfiguration {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let value = try? JSONDecoder().decode(AgentConfiguration.self, from: data) else { return AgentConfiguration() }
        return value
    }
    func credentials() throws -> (AgentConfiguration, String) {
        let config = try savedConfiguration()
        let key = try self.key()
        guard !key.isEmpty else { throw AgentError.message("请先在 Agent 设置中配置模型服务和 API Key。") }
        return (try config.validated(key: key), key)
    }
    private func savedConfiguration() throws -> AgentConfiguration {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let config = try? JSONDecoder().decode(AgentConfiguration.self, from: data) else {
            throw AgentError.message("Agent 配置缺失或无法读取，请在设置中重新保存模型配置。")
        }
        return config
    }
    private static func digest(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }
    func key() throws -> String {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path) else { return "" }
        let config = try savedConfiguration(), key = try readKey()
        guard !key.isEmpty else { return "" }
        guard config.credentialDigest == Self.digest(key) else {
            throw AgentError.message("模型配置与钥匙串密钥不匹配，请重新填写并保存，避免发送到错误的服务。")
        }
        return key
    }
    func save(_ config: AgentConfiguration, key: String) throws {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var validated = try config.validated(key: cleanKey)
        validated.credentialDigest = Self.digest(cleanKey)
        let previous = try readKey()
        try writeKey(cleanKey)
        do { try Self.writePrivate(JSONEncoder().encode(validated), to: root.appendingPathComponent("settings.json")) }
        catch { try? writeKey(previous); throw error }
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func importing(_ gateway: Gateway) throws -> (AgentConfiguration, String) {
        guard URL(string: gateway.base)?.host?.lowercased() == "api.deepseek.com" else {
            throw AgentError.message("当前文字服务使用 Chat Completions。请向服务商确认 Anthropic 兼容地址后单独填写，不能自动转换。")
        }
        return (AgentConfiguration(), gateway.key)
    }
}

enum AgentKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.hello.agent", kSecAttrAccount as String: "llm-api-key"] }
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AgentError.message("无法读取 Agent 密钥，请检查 macOS 钥匙串权限（\(status)）。")
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ key: String) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AgentError.message("无法保存 Agent 密钥（\(status)）。") }
    }
}
