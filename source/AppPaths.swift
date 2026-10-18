import Foundation

enum AppPaths {
    /// Reuse legacy data in place; a new installation gets a Hello directory.
    static var data: URL {
        dataDirectory(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                      environment: ProcessInfo.processInfo.environment)
    }
    static func dataDirectory(in support: URL, environment: [String: String]) -> URL {
        if let path = environment["HELLO_DATA_DIR"] ?? environment["KNOCK_DATA_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Match the previous version's priority so an upgrade keeps the same data.
        for name in ["LightVoice", "Knock"] {
            let legacy = support.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        }
        return support.appendingPathComponent("Hello", isDirectory: true)
    }
    static var gateway: URL {
        if let path = ProcessInfo.processInfo.environment["HELLO_ENV"] ?? ProcessInfo.processInfo.environment["KNOCK_ENV"] ?? ProcessInfo.processInfo.environment["LIGHTVOICE_ENV"] {
            return URL(fileURLWithPath: path)
        }
        return data.appendingPathComponent("gateway.env")
    }
    static var speechModels: URL {
        if let path = ProcessInfo.processInfo.environment["HELLO_MODELS_DIR"] ?? ProcessInfo.processInfo.environment["KNOCK_MODELS_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return data.appendingPathComponent("SpeechModels", isDirectory: true)
    }
}
