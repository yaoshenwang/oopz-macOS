import Foundation

/// 会话（独立文件存储，0600 权限，不使用钥匙串）
struct OopzSession: Codable {
    var uid: String
    var jwt: String
    var deviceId: String
    var userCommonId: String?
    var name: String?
    var avatar: String?
}

/// 统一响应信封
struct Envelope<T: Decodable>: Decodable {
    let status: Bool
    let data: T?
    let message: String?
    let error: String?
    let code: String?
}

/// REST 客户端：多线网关 + 统一头 + 签名
final class OopzAPI {
    static let gateways = [
        (api: "https://gateway.oopz.cn", ws: "wss://ws.oopz.cn"),
        (api: "https://gateway1.oopz.cn", ws: "wss://ws1.oopz.cn"),
        (api: "https://gateway2.oopz.cn", ws: "wss://ws2.oopz.cn"),
        (api: "https://gateway3.oopz.cn", ws: "wss://ws3.oopz.cn"),
        (api: "https://gateway-web2.oopz.cn", ws: "wss://ws-web2.oopz.cn"),
    ]
    static let appVersion = "88804"
    static let clientVersion = "0.88.804"
    static let agoraAppID = "358eebceadb94c2a9fd91ecd7b341602"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.7977.76 Safari/537.36"

    var session: OopzSession?
    var gatewayIndex = 0
    var timeOffsetMS: Int64 = 0
    private let http: URLSession
    private let decoder = JSONDecoder()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpAdditionalHeaders = ["Origin": "https://web.oopz.cn", "Referer": "https://web.oopz.cn/"]
        http = URLSession(configuration: cfg)
    }

    var apiBase: String { Self.gateways[gatewayIndex].api }
    var wsBase: String { Self.gateways[gatewayIndex].ws }

    func headers(method: String, url: URL, body: String?, authorized: Bool) throws -> [String: String] {
        let now = String(Int64(Date.now.timeIntervalSince1970 * 1000) + timeOffsetMS)
        let canonical = OopzSign.canonical(method, url: url, body: body)
        let signed = OopzSign.signedData(canonical: canonical, timeMs: now)
        let sign: String
        if let der = SessionStore.loadPrivateKey() {
            let key = try OopzSign.secKey(fromDER: der)
            sign = try OopzSign.sign(signed, privateKey: key)
        } else {
            sign = ""
        }
        guard let session else {
            if authorized { throw OopzError.notLoggedIn }
            return [
                "oopz-device-id": SessionDefaults.deviceId,
                "oopz-app-version-number": Self.appVersion,
                "oopz-platform": "macos",
                "oopz-request-id": UUID().uuidString,
                "oopz-time": now,
                "oopz-web": "true",
                "oopz-channel": "Web",
                "oopz-sign": sign,
                "content-type": "application/json;charset=utf-8",
                "accept": "*/*",
                "User-Agent": Self.userAgent,
            ]
        }
        var h = [
            "oopz-device-id": session.deviceId,
            "oopz-app-version-number": Self.appVersion,
            "oopz-platform": "macos",
            "oopz-request-id": UUID().uuidString,
            "oopz-time": now,
            "oopz-web": "true",
            "oopz-channel": "Web",
            "oopz-sign": sign,
            "content-type": "application/json;charset=utf-8",
            "accept": "*/*",
            "User-Agent": Self.userAgent,
        ]
        if authorized {
            h["oopz-signature"] = session.jwt
            h["oopz-person"] = session.uid
        }
        return h
    }

    /// 传输层错误（网络不可达/网关 5xx）判定：可切换网关重试
    static func isTransportError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case let OopzError.apiError(code, _) = error {
            if code.hasPrefix("5") || code.hasPrefix("HTTP 5") { return true }
        }
        return false
    }

    /// 带网关故障转移的请求：传输错误时切换下一个网关重试一次
    @discardableResult
    func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> T? {
        do {
            return try await requestOnce(method, path, body: body, authorized: authorized)
        } catch {
            guard Self.isTransportError(error) else { throw error }
            gatewayIndex = (gatewayIndex + 1) % Self.gateways.count
            return try await requestOnce(method, path, body: body, authorized: authorized)
        }
    }

    @discardableResult
    private func requestOnce<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> T? {
        let url = URL(string: apiBase + path)!
        let bodyStr = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = bodyStr?.data(using: .utf8)
        for (k, v) in try headers(method: method, url: url, body: bodyStr, authorized: authorized) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await http.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OopzError.apiError("0", "非 HTTP 响应") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw OopzError.notLoggedIn }
            throw OopzError.apiError(String(http.statusCode), String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard data.starts(with: [0x7B]) else { throw OopzError.apiError("0", "非 JSON 响应") }
        let env = try decoder.decode(Envelope<T>.self, from: data)
        guard env.status else { throw OopzError.apiError(env.code ?? "?", env.message ?? env.error ?? "unknown") }
        return env.data
    }

    func requestRaw(_ method: String, _ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> Data {
        do {
            return try await requestRawOnce(method, path, body: body, authorized: authorized)
        } catch {
            guard Self.isTransportError(error) else { throw error }
            gatewayIndex = (gatewayIndex + 1) % Self.gateways.count
            return try await requestRawOnce(method, path, body: body, authorized: authorized)
        }
    }

    private func requestRawOnce(_ method: String, _ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> Data {
        let url = URL(string: apiBase + path)!
        let bodyStr = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = bodyStr?.data(using: .utf8)
        for (k, v) in try headers(method: method, url: url, body: bodyStr, authorized: authorized) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await http.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw OopzError.apiError("0", "HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return data
    }

    func requestJSON(_ method: String, _ path: String, body: [String: Any]? = nil, authorized: Bool = true) async throws -> [String: Any] {
        let data = try await requestRaw(method, path, body: body, authorized: authorized)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OopzError.apiError("0", "JSON 解析失败") }
        try Self.validateEnvelope(obj)
        return obj
    }

    static func validateShareAcknowledgement(_ obj: [String: Any]) throws {
        try validateEnvelope(obj)
        guard obj["data"] as? Bool == true else {
            throw OopzError.apiError("SHARE_REJECTED", "服务器未确认共享状态")
        }
    }

    static func validateEnvelope(_ obj: [String: Any]) throws {
        guard let status = obj["status"] as? Bool, status else {
            throw OopzError.apiError(obj["code"] as? String ?? "INVALID_RESPONSE",
                                     obj["message"] as? String ?? obj["error"] as? String ?? "业务响应无效")
        }
    }
}
