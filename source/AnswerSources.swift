import Foundation
import CryptoKit

struct AnswerSource: Equatable, Codable, Identifiable {
    var title: String
    var url: String
    var content: String
    var id: String { url }
    static func validURL(_ value: String) -> Bool {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }
}

struct AnswerLookup {
    struct Configuration: Decodable {
        let apiKey: String
        let secretKey: String
        let baseURL: String
        let bns: String
        let bnsHost: String
    }
    let transport: URLSession
    let retryWait: @Sendable (Int) async throws -> Void
    let onRetry: (@MainActor (Int, Int) -> Void)?
    var configurationURL: URL = AppPaths.data.appendingPathComponent("search.json")

    func search(_ query: String) async throws -> [AnswerSource] {
        guard let data = try? Data(contentsOf: configurationURL),
              let config = try? JSONDecoder().decode(Configuration.self, from: data), !config.apiKey.isEmpty else {
            throw VoiceError.message("联网搜索尚未配置。")
        }
        var base = config.baseURL
        if base.isEmpty {
            let name = config.bns.hasPrefix("bns://") ? String(config.bns.dropFirst(6)) : config.bns
            guard let url = URL(string: config.bnsHost + "/get_instance/service/" + name) else {
                throw VoiceError.message("搜索配置地址无效。")
            }
            let discovery = try await json(URLRequest(url: url))
            let instances = discovery["instances"] as? [[String: Any]] ?? []
            guard let instance = instances.first(where: { String(describing: $0["status"] ?? "") == "0" }) ?? instances.first,
                  let host = (instance["ip"] ?? instance["host"]) as? String, !host.isEmpty,
                  let port = instance["port"] else { throw VoiceError.message("搜索服务暂时不可用，请检查内网 / VPN。") }
            base = "http://\(host):\(port)"
        }
        guard var parts = URLComponents(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/search/api") else {
            throw VoiceError.message("搜索服务地址无效。")
        }
        let clientIP = "127.0.0.1"
        parts.queryItems = [URLQueryItem(name: "word", value: query), URLQueryItem(name: "clientip", value: clientIP)]
        guard let url = parts.url else { throw VoiceError.message("搜索词无效。") }
        let digest = Insecure.MD5.hash(data: Data((config.apiKey + query + clientIP + config.secretKey).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let characters = Array(digest)
        let signature = String([7, 3, 17, 13, 1, 21].map { characters[$0] })
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(signature, forHTTPHeaderField: "Api-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["size": ["main": 5, "video": 0, "aladdin": 0], "from": ["main": 0]])
        let payload = try await json(request)
        var items: [[String: Any]] = []
        for key in ["results", "data", "result"] {
            guard let container = payload[key] as? [String: Any] else { continue }
            if let found = container["result"] as? [[String: Any]] { items = found; break }
            if let main = container["main"] as? [String: Any] {
                for field in ["result", "items", "docs", "list"] {
                    if let found = main[field] as? [[String: Any]] { items = found; break }
                }
            }
            if !items.isEmpty { break }
        }
        var seen = Set<String>()
        return items.compactMap { item in
            guard let url = (item["url"] ?? item["link"]) as? String,
                  AnswerSource.validURL(url), seen.insert(url).inserted else { return nil }
            let sentences = (item["sentence"] as? [String])?.joined(separator: "\n") ?? item["sentence"] as? String ?? ""
            let snippet = (item["abstract"] ?? item["snippet"] ?? item["content"]) as? String ?? ""
            return AnswerSource(title: String((item["title"] as? String ?? url).prefix(200)), url: url,
                                content: String((sentences.isEmpty ? snippet : sentences).prefix(4500)))
        }
    }

    func weather(city: String) async throws -> [AnswerSource] {
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
                          URLQueryItem(name: "language", value: "zh"), URLQueryItem(name: "format", value: "json")]
        let places = try await json(URLRequest(url: geo.url!))
        guard let place = (places["results"] as? [[String: Any]])?.first,
              let latitude = place["latitude"] as? Double, let longitude = place["longitude"] as? Double else {
            throw VoiceError.message("没找到城市“\(city)”，请说出更完整的城市名后再试。")
        }
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)), URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            URLQueryItem(name: "forecast_days", value: "7")]
        let url = forecast.url!
        let data = try await json(URLRequest(url: url))
        guard let current = data["current"] as? [String: Any], let time = current["time"] as? String,
              let daily = data["daily"] as? [String: Any], let days = daily["time"] as? [String], !days.isEmpty else {
            throw VoiceError.message("天气服务没有返回有效数据，请重试。")
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let offset = data["utc_offset_seconds"] as? Int ?? 0
        let localNow = Date().addingTimeInterval(TimeInterval(offset))
        let today = String(formatter.string(from: localNow).prefix(10))
        guard time.hasPrefix(today), days.contains(today) else {
            throw VoiceError.message("天气服务返回了过期数据，请稍后重试。")
        }
        let location = [place["name"], place["admin1"], place["country"]].compactMap { $0 as? String }.joined(separator: "，")
        let payload = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        let content = "地点：\(location)。以下为 Open-Meteo 天气模型数据，并非现场实测。按请求日期读取 daily，current 仅代表当前时刻。WMO weather_code：0晴；1大致晴朗；2局部多云；3阴；45/48雾；51/53/55毛毛雨；56/57冻毛毛雨；61/63/65雨；66/67冻雨；71/73/75雪；77雪粒；80/81/82阵雨；85/86阵雪；95雷暴；96/99雷暴伴冰雹。\n" + String(decoding: payload, as: UTF8.self)
        return [AnswerSource(title: "\(location) · Open-Meteo · \(time)", url: url.absoluteString, content: content)]
    }

    private struct Transient: Error {}
    private func json(_ input: URLRequest) async throws -> [String: Any] {
        var request = input; request.timeoutInterval = 15
        for attempt in 0...5 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw Transient() }
                if [408, 429, 500, 502, 503, 504].contains(http.statusCode) { throw Transient() }
                guard (200..<300).contains(http.statusCode) else { throw VoiceError.message("查询服务返回 HTTP \(http.statusCode)，请检查网络和服务配置。") }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VoiceError.message("查询服务返回了无效数据。")
                }
                return json
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let retryable = error is Transient || ((error as? URLError).map {
                    [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet].contains($0.code)
                } ?? false)
                guard retryable else { throw error }
                guard attempt < 5 else { throw VoiceError.message("联网查询失败，已重试 5 次。请检查网络 / VPN 后重试。") }
                await onRetry?(attempt + 1, 5)
                try await retryWait(attempt + 1)
            }
        }
        throw CancellationError()
    }
}
