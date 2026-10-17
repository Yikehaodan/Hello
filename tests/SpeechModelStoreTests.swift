import Foundation

@main
struct SpeechModelStoreTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lightvoice-model-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let bin = resources.appendingPathComponent("SpeechRuntime/python/bin")
        let scripts = resources.appendingPathComponent("SpeechModels")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python3")
        try FileManager.default.createSymbolicLink(at: python, withDestinationURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_PYTHON"] ?? "/usr/bin/python3"))
        try Data().write(to: scripts.appendingPathComponent("speech_worker.py"))
        let catalog: [String: Any] = ["revision": 1, "models": ["zipformer": ["files": [["name": "weights.onnx", "bytes": 4]]], "sensevoice": ["files": [["name": "weights.onnx", "bytes": 4]]]]]
        try JSONSerialization.data(withJSONObject: catalog).write(to: scripts.appendingPathComponent("models.json"))
        let installer = #"""
        import argparse,json,os,time
        from pathlib import Path
        p=argparse.ArgumentParser();p.add_argument('--install');p.add_argument('--root');a=p.parse_args()
        try:os.setsid()
        except PermissionError:pass
        print(json.dumps({'group':os.getpgrp(),'stage':'下载语音模型','progress':.4,'bytes':4,'total':10}),flush=True)
        time.sleep(.4)
        folder=Path(a.root)/'Models'/a.install;folder.mkdir(parents=True,exist_ok=True)
        (folder/'weights.onnx').write_bytes(b'test')
        (folder/'installed.json').write_text(json.dumps({'id':a.install,'revision':1}))
        print(json.dumps({'installed':True,'progress':1}),flush=True)
        """#
        try installer.write(to: scripts.appendingPathComponent("model_manager.py"), atomically: true, encoding: .utf8)
        let suite = "LightVoice.ModelStoreTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechModelStore(resources: resources, root: root.appendingPathComponent("data"), defaults: defaults, cloudAvailable: true)
        precondition(store.selected == .cloud && store.download == nil, "Opening settings must not start a download")
        defaults.set(false, forKey: "useCloudSpeech")
        let migrated = SpeechModelStore(resources: resources, root: store.root, defaults: defaults, cloudAvailable: true)
        precondition(migrated.selected == .whisper)
        store.select(.zipformer)
        precondition(!store.isReady(.zipformer))
        store.downloadModel(.zipformer)
        await until { store.download?.progress == 0.4 }
        precondition(!store.isReady(.zipformer), "Partial download must not become selectable as installed")
        store.select(.sensevoice)
        await until { store.download == nil }
        precondition(store.isReady(.zipformer) && store.selected == .sensevoice, "Completing an old download must not replace the current selection")
        let restored = SpeechModelStore(resources: resources, root: store.root, defaults: defaults, cloudAvailable: true)
        precondition(restored.selected == .sensevoice && restored.isReady(.zipformer))
        try Data([0]).write(to: store.directory(.zipformer).appendingPathComponent("weights.onnx"))
        store.refresh()
        precondition(!store.isReady(.zipformer), "Truncated model must not be marked installed")
        precondition(!SpeechModelID.zipformer.supports(language: "en") && SpeechModelID.zipformer.supports(language: "zh"))
        print("PASS: model preference migration/restoration, no implicit download, progress, atomic readiness, independent selection and missing-file checks")
    }
    @MainActor static func until(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(8)
        while !condition() { precondition(Date() < deadline, "Timed out"); try? await Task.sleep(for: .milliseconds(20)) }
    }
}
