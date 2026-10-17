import Foundation

@main
struct PortabilityTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knock-portability-" + UUID().uuidString)
        defer {
            unsetenv("KNOCK_DATA_DIR"); unsetenv("KNOCK_MODELS_DIR"); unsetenv("KNOCK_ENV")
            try? FileManager.default.removeItem(at: root)
        }
        setenv("KNOCK_DATA_DIR", root.path, 1)
        precondition(AppPaths.data.path == root.path)
        precondition(AppPaths.speechModels.path == root.appendingPathComponent("SpeechModels").path)
        setenv("KNOCK_MODELS_DIR", root.appendingPathComponent("models on external disk").path, 1)
        precondition(AppPaths.speechModels.lastPathComponent == "models on external disk")
        let config = root.appendingPathComponent("gateway.env")
        setenv("KNOCK_ENV", config.path, 1)
        do { _ = try Gateway(); fatalError("Missing configuration must be explained") }
        catch { precondition(error.localizedDescription.contains("尚未配置")) }
        try Gateway.saveConfiguration(base: "https://provider.example/v1", key: "test-only", model: "example-model")
        var gateway = try Gateway()
        precondition(gateway.base == "https://provider.example/v1" && gateway.model == "example-model")
        let permissions = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        try Gateway.saveConfiguration(base: "https://second.example/v1/", key: "new-fixture", model: "second-model")
        gateway = try Gateway()
        precondition(gateway.key == "new-fixture" && gateway.base == "https://second.example/v1")
        for base in ["http://provider.example/v1", "https://user:password@provider.example/v1", "https://provider.example/v1?key=bad"] {
            do { try Gateway.saveConfiguration(base: base, key: "fixture", model: "example"); fatalError("Invalid endpoint saved") }
            catch { precondition((try! Gateway()).key == "new-fixture") }
        }
        do { try Gateway.saveConfiguration(base: "https://provider.example/v1", key: "key\nINJECTED=value", model: "example"); fatalError("Multiline config saved") }
        catch { precondition((try! Gateway()).key == "new-fixture") }
        print("PASS: independent data/model paths, missing-config guidance, private config writes and replacement, endpoint validation")
    }
}
