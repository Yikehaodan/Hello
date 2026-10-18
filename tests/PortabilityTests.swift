import Foundation

@main
struct PortabilityTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hello-portability-" + UUID().uuidString)
        defer {
            unsetenv("HELLO_DATA_DIR"); unsetenv("HELLO_MODELS_DIR"); unsetenv("HELLO_ENV")
            unsetenv("KNOCK_DATA_DIR"); unsetenv("KNOCK_MODELS_DIR"); unsetenv("KNOCK_ENV")
            try? FileManager.default.removeItem(at: root)
        }
        // A renamed installation must find its existing models and history.
        let support = root.appendingPathComponent("Application Support")
        precondition(AppPaths.dataDirectory(in: support, environment: [:]).lastPathComponent == "Hello")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Knock"), withIntermediateDirectories: true)
        precondition(AppPaths.dataDirectory(in: support, environment: [:]).lastPathComponent == "Knock")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("LightVoice"), withIntermediateDirectories: true)
        precondition(AppPaths.dataDirectory(in: support, environment: [:]).lastPathComponent == "LightVoice")
        precondition(AppPaths.dataDirectory(in: support, environment: ["KNOCK_DATA_DIR": root.path]).path == root.path)
        precondition(AppPaths.dataDirectory(in: support, environment: ["HELLO_DATA_DIR": root.path, "KNOCK_DATA_DIR": "/unused"]).path == root.path)
        setenv("KNOCK_MODELS_DIR", root.appendingPathComponent("legacy-models").path, 1)
        precondition(AppPaths.speechModels.lastPathComponent == "legacy-models")
        unsetenv("KNOCK_MODELS_DIR")
        setenv("KNOCK_ENV", root.appendingPathComponent("legacy.env").path, 1)
        precondition(AppPaths.gateway.lastPathComponent == "legacy.env")
        setenv("HELLO_DATA_DIR", root.path, 1)
        precondition(AppPaths.data.path == root.path)
        precondition(AppPaths.speechModels.path == root.appendingPathComponent("SpeechModels").path)
        setenv("HELLO_MODELS_DIR", root.appendingPathComponent("models on external disk").path, 1)
        precondition(AppPaths.speechModels.lastPathComponent == "models on external disk")
        let config = root.appendingPathComponent("gateway.env")
        setenv("HELLO_ENV", config.path, 1)
        precondition(AppPaths.gateway == config)
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
        try "KNOCK_LLM_BASE_URL=https://legacy.example/v1\nKNOCK_LLM_API_KEY=legacy-fixture\nKNOCK_LLM_MODEL=legacy-model\n".write(to: config, atomically: true, encoding: .utf8)
        gateway = try Gateway()
        precondition(gateway.base == "https://legacy.example/v1" && gateway.key == "legacy-fixture" && gateway.model == "legacy-model")
        print("PASS: independent data/model paths, missing-config guidance, private config writes and replacement, endpoint validation")
    }
}
