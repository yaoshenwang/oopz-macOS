import Foundation

// MARK: - 频道文字消息模型（/im/session/v2/messageBefore 响应定型，2026-09-06 实测）

/// 消息附件（图片等）。url 为服务端按次动态签名的 CDN 绝对地址（imimagecdn.oopz.cn），
/// 签名长效但非永久——显示以「本次拉取响应里的 url」为准，不落盘长期复用。
struct MsgAttachment: Hashable {
    let fileKey: String
    let url: String?
    let width: Int
    let height: Int
    let animated: Bool

    var isImage: Bool { !fileKey.isEmpty || url != nil }
}

struct ChatMessage: Identifiable, Hashable {
    let id: String                 // messageId（字符串数字）
    let clientMessageId: String
    let person: String             // 发送者 oopz uid
    let content: String
    let timestampUS: String        // 微秒字符串（服务端 16 位）
    let type: String               // TEXT / ...
    var senderName: String?        // 由 memberCache 补齐
    var senderAvatar: String?
    var images: [MsgAttachment] = []   // 图片附件（type TEXT + 内嵌 IMAGE markdown，官方即此形态）
    /// 本地乐观插入（发送中即显示，服务端回流后按 clientMessageId 合并）
    var pending = false

    var date: Date {
        let us = Double(timestampUS) ?? 0
        return Date(timeIntervalSince1970: us / 1_000_000)
    }

    // MARK: IMAGE markdown 解析

    /// 官方图片消息 content 形如 `![IMAGEw1920h918](/im/20260205/xxx.webp)`（Flutter 端序列化定型）
    static func imageMarkdown(in text: String) -> (width: Int, height: Int, path: String)? {
        guard let re = try? NSRegularExpression(pattern: #"^!\[IMAGEw(\d+)h(\d+)\]\(([^)]+)\)$"#) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 4 else { return nil }
        let w = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let h = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let path = ns.substring(with: m.range(at: 3))
        return (w, h, path)
    }

    /// 是否为纯图片消息（只有一张图、无附加文字）
    var isPureImage: Bool {
        if !images.isEmpty { return content.isEmpty || ChatMessage.imageMarkdown(in: content) != nil }
        return ChatMessage.imageMarkdown(in: content) != nil
    }

    /// 从 JSONSerialization 字典解析附件（REST Decodable 与 event 9 共用）
    static func parseAttachments(_ any: Any?) -> [MsgAttachment] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let at = d["attachmentType"] as? String, at == "IMAGE" else { return nil }
            let key = d["fileKey"] as? String ?? ""
            let url = d["url"] as? String
            guard !key.isEmpty || url != nil else { return nil }
            let w = (d["width"] as? Int) ?? Int(d["width"] as? String ?? "") ?? 0
            let h = (d["height"] as? Int) ?? Int(d["height"] as? String ?? "") ?? 0
            return MsgAttachment(fileKey: key, url: url, width: w, height: h, animated: d["animated"] as? Bool ?? false)
        }
    }
}

// MARK: - API 门面

extension OopzAPI {
    /// 进入文字频道（官方前置，建立服务端会话上下文；响应附带频道能力信息）
    func enterTextChannel(areaId: String, channelId: String) async throws {
        struct EnterData: Decodable { let voiceQuality: String? }
        let _: EnterData? = try await request("POST", "/area/v2/channel/enter", body: [
            "type": "TEXT", "area": areaId, "channel": channelId,
        ])
    }

    /// 频道消息历史（不带 messageId = 最新一页；带 = 向前翻页）
    func channelMessages(areaId: String, channelId: String, before messageId: String? = nil, size: Int = 50) async throws -> [ChatMessage] {
        var path = "/im/session/v2/messageBefore?area=\(areaId)&channel=\(channelId)&size=\(size)"
        if let messageId { path += "&messageId=\(messageId)" }
        struct Data: Decodable {
            struct M: Decodable {
                let messageId: String?
                let clientMessageId: String?
                let person: String?
                let content: String?
                let timestamp: String?
                let type: String?
                struct Att: Decodable {
                    let attachmentType: String?
                    let fileKey: String?
                    let url: String?
                    let width: Int?
                    let height: Int?
                    let animated: Bool?
                }
                let attachments: [Att]?
            }
            let messages: [M]?
        }
        let d: Data = try await request("GET", path) ?? Data(messages: nil)
        return (d.messages ?? []).compactMap { m in
            guard let id = m.messageId, let person = m.person else { return nil }
            let imgs = (m.attachments ?? []).compactMap { a -> MsgAttachment? in
                guard a.attachmentType == "IMAGE" else { return nil }
                return MsgAttachment(fileKey: a.fileKey ?? "", url: a.url, width: a.width ?? 0, height: a.height ?? 0, animated: a.animated ?? false)
            }
            return ChatMessage(
                id: id,
                clientMessageId: m.clientMessageId ?? "",
                person: person,
                content: m.content ?? "",
                timestampUS: m.timestamp ?? "0",
                type: m.type ?? "TEXT",
                images: imgs)
        }
    }

    /// 发送频道文字消息（v1 端点实测可用；timestamp 必须是带引号毫秒串、clientMessageId ≤32hex）
    func sendChannelMessage(areaId: String, channelId: String, text: String, clientMessageId: String, displayName: String) async throws -> (messageId: String, timestampUS: String) {
        struct SendData: Decodable { let messageId: String?; let timestamp: String? }
        let body: [String: Any] = [
            "area": areaId,
            "channel": channelId,
            "target": "",
            "clientMessageId": clientMessageId,
            "timestamp": String(Int64(Date.now.timeIntervalSince1970 * 1000)),
            "isMentionAll": false,
            "mentionList": [] as [[String: Any]],
            "styleTags": [] as [String],
            "animated": false,
            "displayName": displayName,
            "duration": 0,
            "content": text,
        ]
        let d: SendData = try await request("POST", "/im/session/v1/sendGimMessage?c=\(channelId)", body: body) ?? SendData(messageId: nil, timestamp: nil)
        guard let mid = d.messageId else { throw OopzError.apiError("0", "发送失败：服务端未返回 messageId") }
        return (mid, d.timestamp ?? "0")
    }

    /// 已读上报（选中频道时 + 收到新消息且正在查看时）
    func saveReadStatus(areaId: String, channelId: String, messageId: String) async {
        let body: [String: Any] = [
            "area": areaId,
            "status": [["person": session?.uid ?? "", "channel": channelId, "messageId": messageId]],
        ]
        _ = try? await requestJSON("POST", "/im/session/v1/saveReadStatus", body: body)
    }
}
