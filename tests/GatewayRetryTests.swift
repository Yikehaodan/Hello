import Foundation

@main
struct GatewayRetryTests {
    @MainActor static func main() async throws {
        let env = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-retry-\(UUID()).env")
        try "OPENCAS_LLM_BASE_URL=https://retry.invalid/v1\nOPENCAS_LLM_API_KEY=fixture\nKNOCK_LLM_MODEL=DeepSeek-V4.1-Flash".write(to: env, atomically: true, encoding: .utf8)
        setenv("LIGHTVOICE_ENV", env.path, 1)
        defer { try? FileManager.default.removeItem(at: env); unsetenv("LIGHTVOICE_ENV") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FaultTransport.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        var progress: [Int] = []
        let gateway = try Gateway(transport: transport, retryWait: { _ in }, onRetry: { attempt, limit in
            precondition(limit == 5); progress.append(attempt)
        })
        FaultTransport.reset([-1009, -1001, 502, 503, 429, 200])
        _ = try await gateway.polish("测试原文")
        precondition(progress == [1, 2, 3, 4, 5] && FaultTransport.requests.count == 6)
        precondition(Set(FaultTransport.requests).count == 1, "Retry must preserve the exact request body")
        print("PASS: offline/timeout/502/503/429 recover on fifth retry; identical payload, exact progress")

        progress = []; FaultTransport.reset(Array(repeating: 503, count: 8))
        do { _ = try await gateway.translate("原文", to: "English"); fatalError("must fail") }
        catch { precondition(error.localizedDescription.contains("已重试 5 次")) }
        precondition(progress == [1, 2, 3, 4, 5] && FaultTransport.requests.count == 6)
        print("PASS: translation stops after initial request plus five retries")

        for code in [400, 401, 403, 404, -999, -1202] {
            progress = []; FaultTransport.reset([code])
            do { _ = try await gateway.polish("原文"); fatalError("must fail") } catch {}
            precondition(progress.isEmpty && FaultTransport.requests.count == 1)
        }
        print("PASS: invalid request/auth/permission/cancellation/certificate errors do not loop")

        progress = []; FaultTransport.reset([500, 200])
        let answer = try await gateway.ask("问题", selectedText: "")
        precondition(answer.text == "完成" && progress == [1])
        print("PASS: assistant mode also recovers")

        progress = []; FaultTransport.reset([503, 200])
        let snapshot = VoiceContext(application: "测试编辑器", windowTitle: "草稿", inputText: "明天下午开会",
            imageDataURL: "data:image/png;base64,fixture", captureStatus: "已读取输入框 · 已获取窗口截图")
        _ = try await gateway.ask("帮我改成周五", selectedText: "", context: snapshot)
        precondition(Set(FaultTransport.requests).count == 1 && progress == [1])
        let body = try JSONSerialization.jsonObject(with: FaultTransport.requests[0]) as! [String: Any]
        precondition(body["model"] as? String == "DeepSeek-V4.1-Flash" && (body["thinking"] as? [String: String])?["type"] == "enabled" && body["reasoning_effort"] as? String == "low")
        precondition(body["max_tokens"] as? Int == 8192 && body["max_completion_tokens"] == nil)
        let messages = body["messages"] as! [[String: Any]]
        let parts = messages.last!["content"] as! [[String: Any]]
        let payload = try JSONSerialization.jsonObject(with: Data((parts[0]["text"] as! String).utf8)) as! [String: String]
        precondition(payload["focused_input_text"] == "明天下午开会" && payload["selected_text"] == "")
        precondition((parts[1]["image_url"] as? [String: String])?["url"] == snapshot.imageDataURL)
        print("PASS: multimodal context, exact DeepSeek V4.1 Flash model, low thinking for context and identical snapshot across retries")
        progress = []; FaultTransport.reset([503, 200])
        FaultTransport.plainTextFixture = "你觉得这个任务应该如何设计？"
        let dictated = try await gateway.polish("你觉得这个任务应该如何设计？", context: snapshot)
        precondition(dictated == "你觉得这个任务应该如何设计？" && progress == [1] && FaultTransport.requests.count == 2)
        precondition(FaultTransport.requests[0] == FaultTransport.requests[1])
        let dictatedBody = try JSONSerialization.jsonObject(with: FaultTransport.requests[0]) as! [String: Any]
        precondition((dictatedBody["thinking"] as? [String: String])?["type"] == "disabled" && dictatedBody["reasoning_effort"] == nil,
                     "Context dictation must disable thinking for fast transcription")
        let dictatedMessages = dictatedBody["messages"] as! [[String: Any]]
        precondition(dictatedBody["response_format"] == nil && (dictatedMessages.first?["content"] as? String ?? "").contains("本次是上下文听写"))
        let dictatedParts = dictatedMessages.last!["content"] as! [[String: Any]]
        precondition((dictatedParts[1]["image_url"] as? [String: String])?["url"] == snapshot.imageDataURL)
        print("PASS: context dictation disables thinking, retains spoken questions/images and retries the identical payload")
        FaultTransport.reset([200])
        _ = try await gateway.ask("这个页面是什么", selectedText: "", context: VoiceContext())
        let emptyBody = try JSONSerialization.jsonObject(with: FaultTransport.requests[0]) as! [String: Any]
        let emptyMessages = emptyBody["messages"] as! [[String: Any]]
        let emptyPayload = try JSONSerialization.jsonObject(with: Data((emptyMessages.last!["content"] as! String).utf8)) as! [String: String]
        precondition(emptyPayload["focused_input_text"] == "")
        FaultTransport.reset([200])
        _ = try await gateway.ask("普通提问", selectedText: "")
        precondition(!String(decoding: FaultTransport.requests[0], as: UTF8.self).contains("context_application"))
        let ordinaryBody = try JSONSerialization.jsonObject(with: FaultTransport.requests[0]) as! [String: Any]
        precondition((ordinaryBody["thinking"] as? [String: String])?["type"] == "disabled" && ordinaryBody["reasoning_effort"] == nil)
        print("PASS: missing input stays empty, missing screenshot is omitted, ordinary Ask sends no context snapshot")

        var waiting = false
        let cancellable = try Gateway(transport: transport, retryWait: { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }, onRetry: { _, _ in waiting = true })
        FaultTransport.reset([503, 200])
        let job = Task { try await cancellable.polish("取消测试") }
        while !waiting { try await Task.sleep(nanoseconds: 10_000_000) }
        job.cancel()
        do { _ = try await job.value; fatalError("must cancel") } catch is CancellationError {} catch { fatalError("unexpected cancellation error") }
        precondition(FaultTransport.requests.count == 1)
        print("PASS: cancellation interrupts retry delay without sending another request; no real network")
    }
}
