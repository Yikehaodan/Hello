import Foundation
import zlib

struct CloudSpeechConfiguration: Sendable {
    let apiKey: String
    static func load() -> Self? {
        let path = AppPaths.data.appendingPathComponent("doubao.env")
        guard let body = try? String(contentsOf: path, encoding: .utf8),
              let line = body.split(separator: "\n").first(where: { $0.hasPrefix("DOUBAO_API_KEY=") }) else { return nil }
        let key = String(line.dropFirst("DOUBAO_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 20, key.count <= 200, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return Self(apiKey: key)
    }
}

struct CloudSpeechResult: Sendable {
    let text: String
    let translationDraft: String
}

struct SpeechRecognitionOptions {
    let endpoint: String
    let language: String?
    let detectLanguages: Bool
    init(language: String) {
        // The fast duplex endpoint recognizes Chinese and English. The vendor
        // only supports the 25-language detector and forced foreign languages
        // on nostream. Keep the user's automatic-language setting accurate.
        detectLanguages = language == "auto"
        endpoint = ["zh", "en"].contains(language) ? "bigmodel_async" : "bigmodel_nostream"
        self.language = ["ja": "ja-JP", "ko": "ko-KR"][language]
    }
}

/// Field numbers come from the vendor's ast_service, au_base and rpcmeta protos.
/// Only wire types used by those messages are decoded; unknown fields are skipped.
enum SpeechProtobuf {
    static func varint(_ number: UInt64) -> Data {
        var n = number, data = Data()
        repeat { data.append(UInt8(n & 127) | (n > 127 ? 128 : 0)); n >>= 7 } while n > 0
        return data
    }
    static func integer(_ field: Int, _ value: Int) -> Data { varint(UInt64(field << 3)) + varint(UInt64(value)) }
    static func bytes(_ field: Int, _ value: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    struct Fields {
        var numbers: [Int: UInt64] = [:]
        var data: [Int: Data] = [:]
        func text(_ field: Int) -> String { String(decoding: data[field] ?? Data(), as: UTF8.self) }
    }
    static func decode(_ data: Data) throws -> Fields {
        guard data.count <= 2_097_152 else { throw VoiceError.message("语音服务返回的数据过大。") }
        var cursor = 0, result = Fields()
        func read() throws -> UInt64 {
            var n: UInt64 = 0
            for shift in stride(from: 0, to: 70, by: 7) {
                guard cursor < data.count else { throw VoiceError.message("语音服务数据不完整。") }
                let b = data[cursor]; cursor += 1
                guard shift < 63 || b <= 1 else { throw VoiceError.message("语音服务整数无效。") }
                n |= UInt64(b & 127) << shift
                if b & 128 == 0 { return n }
            }
            throw VoiceError.message("语音服务整数无效。")
        }
        while cursor < data.count {
            let key = try read(), field = Int(key >> 3)
            guard field > 0 else { throw VoiceError.message("语音服务字段无效。") }
            switch key & 7 {
            case 0: result.numbers[field] = try read()
            case 2:
                let count = try read()
                guard count <= UInt64(data.count - cursor) else { throw VoiceError.message("语音服务字段不完整。") }
                result.data[field] = Data(data[cursor..<cursor + Int(count)]); cursor += Int(count)
            case 1, 5:
                let count = key & 7 == 1 ? 8 : 4
                guard cursor + count <= data.count else { throw VoiceError.message("语音服务字段不完整。") }
                cursor += count
            default: throw VoiceError.message("语音服务字段类型无效。")
            }
        }
        return result
    }
    static func request(event: Int, session: String, source: String, target: String, pcm: Data? = nil) -> Data {
        var result = bytes(1, string(6, session)) + integer(2, event)
        if event == 100 {
            result += bytes(3, string(1, "lightvoice"))
            result += bytes(4, string(4, "wav") + string(5, "raw") + integer(7, 16000) + integer(8, 16) + integer(9, 1))
            result += bytes(6, string(1, "s2t") + string(2, source) + string(3, target))
        }
        if let pcm { result += bytes(4, bytes(14, pcm)) }
        return result
    }
}

enum SpeechASRWire {
    static func packet(_ payload: Data, audio: Bool = false, final: Bool = false) -> Data {
        var data = Data([0x11, (audio ? 0x20 : 0x10) | (final ? 2 : 0), audio ? 0 : 0x10, 0])
        let n = UInt32(payload.count)
        data.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        data.append(payload); return data
    }
    static func decode(_ data: Data) throws -> (text: String, final: Bool) {
        guard data.count >= 8, data.count <= 2_097_152, data[0] >> 4 == 1 else { throw VoiceError.message("语音服务数据头无效。") }
        var cursor = Int(data[0] & 15) * 4
        let kind = data[1] >> 4, flags = data[1] & 15
        guard cursor >= 4, cursor <= data.count, flags <= 3 else { throw VoiceError.message("语音服务数据头无效。") }
        func number() throws -> UInt32 {
            guard cursor + 4 <= data.count else { throw VoiceError.message("语音服务数据不完整。") }
            let n = data[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; cursor += 4; return n
        }
        if kind == 15 { let code = try number(); throw VoiceError.message("流式语音服务暂不可用（\(code)）。") }
        guard kind == 9 else { throw VoiceError.message("语音服务响应类型无效。") }
        if flags & 1 != 0 { _ = try number() }
        let count = try number()
        guard UInt64(count) == UInt64(data.count - cursor), data[2] >> 4 == 1 else { throw VoiceError.message("语音服务数据长度无效。") }
        var body = Data(data[cursor...])
        if data[2] & 15 == 1 { body = try gunzip(body) }
        else if data[2] & 15 != 0 { throw VoiceError.message("语音服务压缩格式无效。") }
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw VoiceError.message("语音服务结果无效。") }
        if let code = json["code"] as? Int, code != 0, code != 20000000 { throw VoiceError.message("流式语音服务暂不可用（\(code)）。") }
        let result = (json["result"] as? [String: Any]) ?? (json["result"] as? [[String: Any]])?.first ?? [:]
        return (result["text"] as? String ?? "", flags & 2 != 0)
    }
    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw VoiceError.message("无法解压语音结果。") }
        defer { inflateEnd(&stream) }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            while true {
                let code = buffer.withUnsafeMutableBytes { raw -> Int32 in
                    stream.next_out = raw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(raw.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                guard output.count <= 2_097_152 else { throw VoiceError.message("语音结果解压后过大。") }
                if code == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw VoiceError.message("语音结果压缩数据无效。") }; return
                }
                guard code == Z_OK else { throw VoiceError.message("语音结果压缩数据无效。") }
            }
        }
        return output
    }
}

/// Captured PCM enters an independent sender immediately, without waiting for
/// silence or server acknowledgements. Only a completed session can be published.
@MainActor
final class CloudTranscription {
    enum Mode: Sendable {
        case recognize
        case translate(source: String, target: String)
        static func select(inputMode: InputMode, source: String, target: String) -> Self {
            let targets = ["English": "en", "简体中文": "zh", "日本語": "ja", "한국어": "ko", "Français": "fr", "Deutsch": "de", "Español": "es"]
            // Automatic source detection and target changes retain the full-text path.
            if inputMode == .translate, ["zh", "en", "ja", "ko"].contains(source), let target = targets[target], source != target,
               ["zh", "en"].contains(source) || ["zh", "en"].contains(target) { return .translate(source: source, target: target) }
            return .recognize
        }
    }
    private struct Input: Sendable { let snapshot: RecordingPCM; let final: Bool }
    private let input: AsyncStream<Input>.Continuation
    private let worker: Task<CloudSpeechResult, Error>
    private var finishing = false
    init(configuration: CloudSpeechConfiguration, mode: Mode, language: String) {
        // Every item is a cumulative prefix, so replacing queued snapshots keeps
        // all audio while bounding memory during a slow connection.
        let (stream, continuation) = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingNewest(1))
        input = continuation
        worker = Task.detached(priority: .userInitiated) { try await Self.run(stream, configuration: configuration, mode: mode, language: language) }
    }
    func offer(_ snapshot: RecordingPCM) { if !finishing { input.yield(Input(snapshot: snapshot, final: false)) } }
    func finish(audio: URL) async throws -> CloudSpeechResult {
        guard !finishing else { throw VoiceError.message("语音会话已结束。") }
        finishing = true
        let snapshot = try await Task.detached(priority: .userInitiated) { try RecordingPCM(wav: audio, live: false) }.value
        input.yield(Input(snapshot: snapshot, final: true)); input.finish()
        let worker = worker
        let timeout = Task { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { worker.cancel() } }
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        } catch {
            try Task.checkCancellation()
            throw VoiceError.message("云端语音连接暂不可用，将完整识别录音。")
        }
    }
    func cancel() { finishing = true; input.finish(); worker.cancel() }
    nonisolated private static func run(_ input: AsyncStream<Input>, configuration: CloudSpeechConfiguration, mode: Mode, language: String) async throws -> CloudSpeechResult {
        try Task.checkCancellation()
        let recognition = SpeechRecognitionOptions(language: language)
        let translating: Bool
        let path: String, resource: String, source: String, target: String
        switch mode {
        case .recognize: translating = false; path = "api/v3/sauc/" + recognition.endpoint; resource = "volc.seedasr.sauc.duration"; source = ""; target = ""
        case .translate(let from, let to): translating = true; path = "api/v4/ast/v2/translate"; resource = "volc.service_type.10053"; source = from; target = to
        }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/" + path)!)
        request.timeoutInterval = 12
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        if !translating { request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence") }
        let session = URLSession(configuration: .ephemeral), socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 2_097_152
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        let id = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            func receiveData() async throws -> Data {
                switch try await socket.receive() {
                case .data(let data): return data
                case .string: throw VoiceError.message("语音服务返回了无效格式。")
                @unknown default: throw VoiceError.message("语音服务返回了未知格式。")
                }
            }
            if translating {
                try await socket.send(.data(SpeechProtobuf.request(event: 100, session: id, source: source, target: target)))
                let started = try SpeechProtobuf.decode(await receiveData())
                guard started.numbers[2] == 150 else { throw VoiceError.message("口述翻译服务未能启动。") }
            } else {
                var audio: [String: Any] = ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1]
                if let language = recognition.language { audio["language"] = language }
                var options: [String: Any] = ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true, "enable_ddc": false, "result_type": "full"]
                if recognition.detectLanguages { options["enable_auto_lang"] = true }
                let body: [String: Any] = ["user": ["uid": "lightvoice"], "audio": audio,
                    "request": options]
                try await socket.send(.data(SpeechASRWire.packet(try JSONSerialization.data(withJSONObject: body))))
            }
            return try await withThrowingTaskGroup(of: CloudSpeechResult?.self) { group in
                group.addTask {
                    var sent = 0, committed = Data(), sawFinal = false
                    let chunkSize = translating ? 2560 : 6400
                    for await item in input {
                        try Task.checkCancellation()
                        let bytes = item.snapshot.bytes
                        guard bytes.count >= sent, bytes.prefix(sent) == committed else { throw VoiceError.message("录音前缀变化，将完整识别。") }
                        let end = item.final ? bytes.count : bytes.count / chunkSize * chunkSize
                        let previousSent = sent
                        while sent < end {
                            let count = min(chunkSize, end - sent)
                            let chunk = Data(bytes[sent..<sent + count])
                            let final = item.final && sent + count == end
                            let packet = translating ? SpeechProtobuf.request(event: 200, session: id, source: source, target: target, pcm: chunk) : SpeechASRWire.packet(chunk, audio: true, final: final)
                            try await socket.send(.data(packet)); sent += count
                        }
                        committed = Data(bytes.prefix(sent))
                        if item.final {
                            if translating { try await socket.send(.data(SpeechProtobuf.request(event: 102, session: id, source: source, target: target))) }
                            else if previousSent == end { try await socket.send(.data(SpeechASRWire.packet(Data(), audio: true, final: true))) }
                            sawFinal = true; break
                        }
                    }
                    guard sawFinal else { throw CancellationError() }
                    return nil
                }
                group.addTask {
                    var latest = "", originals: [String] = [], drafts: [String] = []
                    while true {
                        let data = try await receiveData()
                        if translating {
                            let response = try SpeechProtobuf.decode(data)
                            let event = response.numbers[2] ?? 0
                            let meta = try SpeechProtobuf.decode(response.data[1] ?? Data())
                            let code = meta.numbers[3] ?? 0
                            guard ![151, 153].contains(event), code == 0 || code == 20000000 else { throw VoiceError.message("口述翻译服务暂不可用（\(code)）。") }
                            if event == 652 { originals.append(response.text(4)) }
                            if event == 655 { drafts.append(response.text(4)) }
                            if event == 152 { return CloudSpeechResult(text: originals.joined(), translationDraft: drafts.joined(separator: " ")) }
                        } else {
                            let response = try SpeechASRWire.decode(data)
                            if !response.text.isEmpty { latest = response.text }
                            if response.final {
                                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.message("云端收尾没有返回完整文字。") }
                                return CloudSpeechResult(text: latest, translationDraft: "")
                            }
                        }
                    }
                }
                var result: CloudSpeechResult?
                do { while let next = try await group.next() { if let next { result = next } } }
                catch { group.cancelAll(); socket.cancel(with: .goingAway, reason: nil); throw error }
                guard let result, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.message("云端没有返回完整文字，将完整识别录音。") }
                return result
            }
        }, onCancel: { socket.cancel(with: .goingAway, reason: nil) })
    }
}
