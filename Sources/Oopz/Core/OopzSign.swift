import Foundation
import CryptoKit
import Security

/// OOPZ 请求签名：oopz-sign = base64( RSASSA-PKCS1-v1_5-SHA256( md5_hex(规范化串) + 毫秒时间戳 ) )
/// 规范化串（2026-09-06 实测定型，47 样本全命中）：path + "?"+query(有则拼) + body(POST 才拼)
enum OopzSign {
    static func canonical(_ method: String, url: URL, body: String?) -> String {
        var s = url.path
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, !q.isEmpty {
            s += "?" + q
        }
        if method == "POST", let b = body, !b.isEmpty { s += b }
        return s
    }

    static func signedData(canonical: String, timeMs: String) -> Data {
        let md5hex = Insecure.MD5.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return Data((md5hex + timeMs).utf8)
    }

    /// RSA-SHA256 签名；privateKey 为 PKCS#1 或 PKCS#8 DER
    static func sign(_ data: Data, privateKey: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) else {
            throw OopzError.signFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return (sig as Data).base64EncodedString()
    }

    static func secKey(fromDER der: Data) throws -> SecKey {
        // 尝试 PKCS#8 (SecKeyCreateWithData 只吃 PKCS#1)；剥离 8 头部
        if let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil) {
            return key
        }
        let stripped = try pkcs8Strip(der)
        guard let key = SecKeyCreateWithData(stripped as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil) else {
            throw OopzError.badPrivateKey
        }
        return key
    }

    /// PKCS#8 → PKCS#1 DER 剥壳
    static func pkcs8Strip(_ der: Data) throws -> Data {
        let bytes = [UInt8](der)
        var index = 0
        func field(_ tag: UInt8, limit: Int) throws -> Range<Int> {
            guard index < limit, bytes[index] == tag else { throw OopzError.badPrivateKey }
            index += 1
            guard index < limit else { throw OopzError.badPrivateKey }
            let first = Int(bytes[index]); index += 1
            var length = first
            if first >= 128 {
                let count = first & 127
                guard (1...3).contains(count), count <= limit - index else { throw OopzError.badPrivateKey }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
            }
            guard length <= limit - index else { throw OopzError.badPrivateKey }
            return index..<(index + length)
        }
        let outer = try field(0x30, limit: bytes.count)
        guard outer.upperBound == bytes.count else { throw OopzError.badPrivateKey }
        let version = try field(0x02, limit: outer.upperBound)
        guard version.count == 1, bytes[version.lowerBound] == 0 else { throw OopzError.badPrivateKey }
        index = version.upperBound
        let algorithm = try field(0x30, limit: outer.upperBound)
        index = algorithm.upperBound
        let key = try field(0x04, limit: outer.upperBound)
        guard !key.isEmpty else { throw OopzError.badPrivateKey }
        return Data(bytes[key])
    }
}

enum OopzError: LocalizedError {
    case signFailed(String)
    case badPrivateKey
    case apiError(String, String)
    case notLoggedIn
    case wsClosed

    var errorDescription: String? {
        switch self {
        case .signFailed(let m): return "签名失败: \(m)"
        case .badPrivateKey: return "RSA 私钥无效"
        case .apiError(let code, let msg): return "接口错误[\(code)] \(msg)"
        case .notLoggedIn: return "未登录"
        case .wsClosed: return "信令断开"
        }
    }
}
