import Foundation

final class FaultTransport: URLProtocol {
    static var outcomes: [Int] = []
    static var requests: [Data] = []
    static var weatherFixture = false
    static var plainTextFixture: String?
    static let lock = NSLock()
    static func reset(_ codes: [Int]) {
        lock.lock(); defer { lock.unlock() }
        outcomes = codes; requests = []; weatherFixture = false; plainTextFixture = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bodyData.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        let code = Self.outcomes.isEmpty ? 200 : Self.outcomes.removeFirst()
        Self.requests.append(bodyData)
        let weatherFixture = Self.weatherFixture
        let plainTextFixture = Self.plainTextFixture
        Self.lock.unlock()
        if code < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }
        var content = plainTextFixture ?? "{\"action\":\"answer\",\"text\":\"完成\"}"
        var payload: [String: Any]?
        if weatherFixture {
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            if request.url?.host == "geocoding-api.open-meteo.com" {
                payload = ["results": [["name": "上海", "country": "中国", "latitude": 31.2, "longitude": 121.4]]]
            } else if request.url?.host == "api.open-meteo.com" {
                payload = ["current": ["time": today + "T12:00", "temperature_2m": 22], "daily": ["time": [today]], "utc_offset_seconds": 0]
            } else {
                let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
                let messages = body?["messages"] as? [[String: Any]] ?? []
                let grounded = messages.contains { ($0["content"] as? String ?? "").contains("查询资料：") }
                content = grounded ? "{\"action\":\"answer\",\"text\":\"上海今天约 22°C，具体预报请查看来源。[1]\"}" : "{\"action\":\"weather\",\"city\":\"Shanghai\"}"
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: payload ?? ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

