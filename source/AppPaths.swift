import Foundation

enum AppPaths {
    /// Reuse legacy data in place; a new installation gets a Knock directory.
    static var data: URL {
        if let path = ProcessInfo.processInfo.environment["KNOCK_DATA_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("LightVoice", isDirectory: true)
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : support.appendingPathComponent("Knock", isDirectory: true)
    }
    static var gateway: URL {
        if let path = ProcessInfo.processInfo.environment["KNOCK_ENV"] ?? ProcessInfo.processInfo.environment["LIGHTVOICE_ENV"] {
            return URL(fileURLWithPath: path)
        }
        return data.appendingPathComponent("gateway.env")
    }
    static var speechModels: URL {
        if let path = ProcessInfo.processInfo.environment["KNOCK_MODELS_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return data.appendingPathComponent("SpeechModels", isDirectory: true)
    }
}
