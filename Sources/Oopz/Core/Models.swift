import Foundation

// MARK: - 领域模型（对齐 /area/v3/info、/client/v1/area/v1/detail/v1/channels 等实测响应）

struct PersonSelf: Decodable {
    let uid: String
    let name: String?
    let avatar: String?
    let userCommonId: String?
    let introduction: String?
    let phone: String?
}

struct AreaSummary: Decodable, Identifiable {
    let id: String
    let name: String
    let avatar: String?
    let desc: String?
    let subscribed: Bool?
    let owner: String?   // 域主 uid（实机测试仅限自有域）
}

struct ChannelSettings: Decodable {
    let maxMember: Int?
    let voiceQuality: String?
    let voiceDelay: String?
}

struct Channel: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String        // VOICE / TEXT
    let secret: Bool?
    let tag: String?
    let number: Int?
    let settings: ChannelSettings?
    let isTemp: Bool?
}

struct ChannelGroup: Decodable, Identifiable {
    let id: String
    let name: String
    let sort: Int?
    let system: Bool?
    let channels: [Channel]
}

struct AreaRole: Decodable {
    let roleID: Int
    let name: String
    let sort: Int?
    let isDisplay: Bool?
    let type: Int?
}

struct AreaDetail: Decodable {
    let id: String
    let code: String?
    let name: String
    let avatar: String?
    let banner: String?
    let desc: String?
    let subscribed: Bool?
    let roleList: [AreaRole]?
    let homePageChannelId: String?
}

struct AreaMember: Decodable, Identifiable {
    let uid: String
    var id: String { uid }
    let role: Int?
    let roleSort: Int?
    let online: Int?
}

/// 频道成员（membersByChannels / event 19/20 聚合）
/// muteKnown=false 表示尚未收到该成员的 datastream 静音快照（图标按"未知"处理，不误显闭麦）
struct VoiceMember: Identifiable, Hashable {
    let uid: String
    var name: String = ""
    var avatar: String? = nil
    var muted: Bool = true
    var muteKnown: Bool = false
    var speaking: Bool = false
    var headsetMuted: Bool = false

    var id: String { uid }
}

/// 在房成员（membersByChannels 对象数组成员）
struct ChannelMemberState {
    let uid: String
    /// "OPEN" = 正在共享（官方成员对象字段；nil = 旧格式/未上报）
    let screenSharingState: String?
    var dimensions: String = ""
    var framerate: String = ""
    var isSharing: Bool { screenSharingState == "OPEN" }
}

/// 进房响应（/area/v2/channel/enter）
struct ChannelEnterResult: Decodable {
    let now: Int64?
    let voiceQuality: String?
    let voiceDelay: String?
    let expireSeconds: Int?
    let supplier: String?
    let supplierSign: String?
    let roleSort: Int?
    let roomId: String?
    let teamEnabled: Bool?
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

struct ScreenShareTierParam: Decodable {
    let paramType: String
    let paramName: String
    let paramValue: String
    let tag: String?
    let active: Bool
    let isDefault: Bool
}

struct ScreenShareTier: Decodable {
    let type: String       // FREE / PRO / ULTRA
    let name: String
    let peopleLimit: Int
    let params: [ScreenShareTierParam]

    /// 可用清晰度（name 如 "720p"/"1080p"/"原画"，value 如 "720x1280"/"HD"）
    var dimensionOptions: [(name: String, value: String)] {
        params.filter { $0.paramType == "DIMENSIONS" && $0.active }.map { ($0.paramName, $0.paramValue) }
    }
    /// 可用帧率
    var framerateOptions: [Int] {
        params.filter { $0.paramType == "FRAMERATE" && $0.active }.compactMap { Int($0.paramValue) }.sorted()
    }

    /// "1080x1920"（短x长）→ CGSize(1920,1080)；"HD" → 原画上限盒
    static func parseDimensions(_ value: String) -> CGSize {
        if value == "HD" { return CGSize(width: 3840, height: 2160) }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return CGSize(width: 960, height: 540) }
        return parts[1] > parts[0]
            ? CGSize(width: parts[1], height: parts[0])
            : CGSize(width: parts[0], height: parts[1])
    }
}

struct ScreenShareVipStatus: Decodable {
    let isVip: Bool
    let type: String
    let peopleLimit: Int
}

// MARK: - API 门面

extension OopzAPI {
    func curTime() async throws {
        let obj = try await requestJSON("GET", "/general/v2/curTime", authorized: false)
        if let now = (obj["data"] as? [String: Any])?["now"] as? Int64 ?? obj["data"] as? Int64 {
            timeOffsetMS = now - Int64(Date.now.timeIntervalSince1970 * 1000)
        }
    }

    func autoLogin(_ old: OopzSession) async throws -> OopzSession {
        struct LoginData: Decodable {
            let uid: String
            let signature: String
            let name: String?
        }
        let data: LoginData = try await request("POST", "/client/v1/login/v1/autoLogin", body: [
            "auto": true, "code": old.jwt, "loginType": "SIGNATURE", "phone": "",
            "autoRegister": false, "yunhaiToken": "",
            "deviceId": old.deviceId, "deviceRam": "TBD", "deviceProcessor": "0",
            "loggedIn": old.deviceId, "osEdition": "web",
            "osVersion": "web/_BrowserName.chrome", "resolution": "TBD", "graphics": "TBD",
            "clientVersion": Self.clientVersion,
        ], authorized: true) ?? { throw OopzError.notLoggedIn }()
        var s = old
        s.uid = data.uid
        s.jwt = data.signature
        s.name = data.name ?? old.name
        return s
    }

    func selfDetail() async throws -> PersonSelf {
        guard let s = session else { throw OopzError.notLoggedIn }
        let d: PersonSelf = try await request("GET", "/client/v1/person/v2/selfDetail?uid=\(s.uid)") ?? { throw OopzError.notLoggedIn }()
        return d
    }

    func areaInfo(_ areaId: String) async throws -> AreaDetail {
        try await request("GET", "/area/v3/info?area=\(areaId)") ?? { throw OopzError.apiError("0", "空数据") }()
    }

    func channels(_ areaId: String) async throws -> [ChannelGroup] {
        try await request("GET", "/client/v1/area/v1/detail/v1/channels?area=\(areaId)") ?? []
    }

    func areaMembers(_ areaId: String, max: Int = 200) async throws -> (members: [AreaMember], total: Int) {
        struct MemData: Decodable { let members: [AreaMember]; let totalCount: Int? }
        var all: [AreaMember] = []
        var total = 0
        let pageSize = 50
        while all.count < max {
            let start = all.count
            let d: MemData = try await request("GET", "/area/v3/members?area=\(areaId)&offsetStart=\(start)&offsetEnd=\(start + pageSize - 1)") ?? { throw OopzError.apiError("0", "空数据") }()
            total = d.totalCount ?? total
            all.append(contentsOf: d.members)
            if d.members.count < pageSize || all.count >= total { break }
        }
        return (all, total)
    }

    /// 分批请求（官方每页上限 50 个频道）。
    /// 响应成员是对象数组（uid/sort/enterTime/screenSharingState…，2026-09-06 实测），不再是我方早期误认的字符串数组——
    /// 按 [String] 强转会全部转型失败得空表（v0.2.2 修的 bug：语音频道只显示自己）。
    func membersByChannels(_ areaId: String, _ channelIds: [String]) async throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (k, list) in try await membersByChannelsStates(areaId, channelIds) {
            out[k] = list.map(\.uid)
        }
        return out
    }

    /// 同上，但保留成员共享态（screenSharingState: OPEN/CLOSE…）。共享可见性以此为准。
    func membersByChannelsStates(_ areaId: String, _ channelIds: [String]) async throws -> [String: [ChannelMemberState]] {
        var out: [String: [ChannelMemberState]] = [:]
        for chunk in channelIds.chunked(into: 50) {
            let obj = try await requestJSON("POST", "/area/v3/channel/membersByChannels", body: ["area": areaId, "channels": chunk])
            if let cm = obj["data"] as? [String: Any], let map = cm["channelMembers"] as? [String: Any] {
                for (k, v) in map {
                    if let list = v as? [[String: Any]] {
                        out[k] = list.compactMap { d in
                            guard let uid = d["uid"] as? String else { return nil }
                            return ChannelMemberState(uid: uid, screenSharingState: d["screenSharingState"] as? String, dimensions: d["dimensions"] as? String ?? "", framerate: d["framerate"] as? String ?? "")
                        }
                    } else if let list = v as? [String] {
                        out[k] = list.map { ChannelMemberState(uid: $0, screenSharingState: nil) }   // 兼容旧字符串数组格式
                    } else {
                        out[k] = []
                    }
                }
            }
        }
        return out
    }

    /// 批量查他人资料（POST /client/v1/person/v1/personInfos {persons:[uid]}）。
    /// ⚠️ 旧实现 personBrief 用 selfDetail?uid=<别人>，服务端忽略 uid 永远返回登录者自己（v0.2.2 修的 bug：右栏全员显示自己）。
    /// 响应含 uid/name/avatar(带签名绝对地址)/userCommonId，支持批量、去重、含自己。
    func personInfos(uids: [String]) async throws -> [PersonSelf] {
        guard !uids.isEmpty else { return [] }
        struct Raw: Decodable {
            let uid: String
            let name: String?
            let avatar: String?
            let userCommonId: String?
        }
        let list: [Raw] = try await request("POST", "/client/v1/person/v1/personInfos", body: ["persons": uids]) ?? []
        return list.map { PersonSelf(uid: $0.uid, name: $0.name, avatar: $0.avatar, userCommonId: $0.userCommonId, introduction: nil, phone: nil) }
    }

    /// 域昵称批量查询（POST /area/v2/getUserAreaNicknames {area, uids}）→ uid: 昵称。
    /// 官方成员面板显示的是域昵称（设置了才返回；未设置显示全局昵称）。
    func areaNicknames(areaId: String, uids: [String]) async throws -> [String: String] {
        guard !uids.isEmpty else { return [:] }
        struct Raw: Decodable { let nicknames: [String: String]? }
        let d: Raw = try await request("POST", "/area/v2/getUserAreaNicknames", body: ["area": areaId, "uids": uids]) ?? Raw(nicknames: nil)
        return d.nicknames ?? [:]
    }

    func enterArea(_ areaId: String) async throws {
        struct Joined: Decodable { let joined: Bool? }
        let _: Joined? = try await request("POST", "/client/v1/area/v1/enter?recover=false", body: ["area": areaId, "recover": false])
    }

    func enterVoiceChannel(areaId: String, channelId: String, password: String = "") async throws -> ChannelEnterResult {
        struct EnterData: Decodable { let enter: ChannelEnterResult? }
        // /area/v2/channel/enter 的 data 直接就是 enter 结果
        let data: ChannelEnterResult = try await request("POST", "/area/v2/channel/enter", body: [
            "type": "VOICE", "area": areaId, "channel": channelId,
            "fromChannel": "", "fromArea": "", "password": password, "sign": 1,
            "pid": session?.userCommonId ?? "0",
        ]) ?? { throw OopzError.apiError("0", "空数据") }()
        return data
    }

    func leaveVoiceChannel(areaId: String, channelId: String) async throws {
        guard let uid = session?.uid else { throw OopzError.notLoggedIn }
        struct BoolData: Decodable { let d: Bool }
        // data 可能是 bool
        let _: Data = try await requestRaw("DELETE", "/client/v1/area/v1/member/v1/removeFromChannel?area=\(areaId)&channel=\(channelId)&target=\(uid)")
    }

    func screenShareParams() async throws -> [ScreenShareTier] {
        try await request("GET", "/screenSharing/v2/params") ?? []
    }

    /// 屏幕共享状态上报（官方 web/桌面同款，2026-09-07 自 web_main.dart.js 逆向定位）：
    /// POST /screenSharing/v1/stateSave {area, channel, state: "OPEN"|"CLOSE", framerate, dimensions}
    /// 服务端据此广播 WS event 33（areaChannelScreenShareReceivedState）并写成员 screenSharingState——
    /// 不上报则官方客户端永远看不到我们的共享（v0.3.1 用户实测「共享无反应」的根因）。
    @discardableResult
    func reportScreenShareState(areaId: String, channelId: String, open: Bool,
                                dimensions: String, framerate: String) async throws -> Bool {
        // 实测响应 data 为 bool（true），不能按字典解码
        let obj = try await requestJSON("POST", "/screenSharing/v1/stateSave", body: [
            "area": areaId, "channel": channelId,
            "state": open ? "OPEN" : "CLOSE",
            "framerate": framerate, "dimensions": dimensions,
        ])
        try Self.validateShareAcknowledgement(obj)
        return true
    }

    /// stateSave acknowledgement can precede the member snapshot update.
    /// Confirm discovery state with a bounded condition wait, never treat a missing member as CLOSE.
    func confirmScreenShareState(areaId: String, channelId: String, uid: String,
                                 open: Bool) async throws {
        let expected = open ? "OPEN" : "CLOSE"
        let deadline = Date().addingTimeInterval(4)
        var observed = "missing"
        repeat {
            let snapshot = try await membersByChannelsStates(areaId, [channelId])
            observed = snapshot[channelId]?.first(where: { $0.uid == uid })?.screenSharingState ?? "missing"
            if observed == expected { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw OopzError.apiError("SHARE_STATE_TIMEOUT", "共享成员状态未确认：预期 \(expected)，实际 \(observed)")
    }

    func screenShareVip() async throws -> ScreenShareVipStatus {
        try await request("GET", "/screenSharing/v1/vipStatus") ?? ScreenShareVipStatus(isVip: false, type: "FREE", peopleLimit: 3)
    }

    /// 官方邀请链接生成（实测 2026-09-06）：
    /// POST /uni/invite/v1/generate {area, channel, talkRoomId} → data.url = "https://oopz.cn/i/<code>"
    func generateInviteLink(areaId: String, channelId: String?) async throws -> String {
        var body: [String: Any] = ["area": areaId, "channel": channelId ?? "", "talkRoomId": ""]
        if channelId == nil { body.removeValue(forKey: "channel") }
        let obj = try await requestJSON("POST", "/uni/invite/v1/generate", body: body)
        if let d = obj["data"] {
            if let dict = d as? [String: Any] {
                // 实测首选：完整链接
                if let url = dict["url"] as? String, url.hasPrefix("http") { return url }
                for key in ["code", "inviteCode", "shareCode"] {
                    if let v = dict[key] as? String, !v.isEmpty { return "https://oopz.cn/i/\(v)" }
                }
                if let list = dict["codes"] as? [String], let first = list.first { return "https://oopz.cn/i/\(first)" }
            }
            if let s = d as? String {
                return s.hasPrefix("http") ? s : "https://oopz.cn/i/\(s)"
            }
            if let list = d as? [String], let first = list.first {
                return first.hasPrefix("http") ? first : "https://oopz.cn/i/\(first)"
            }
        }
        throw OopzError.apiError("0", "邀请链接解析失败")
    }
}


struct ScreenShareCredentials: Decodable {
    let sign: String
    let signPid: String
    let roomId: String
}

extension OopzAPI {
    func screenShareCredentials(channel: String, sending: Bool, dimension: String, fps: Int,
                                anchor: UInt32? = nil) async throws -> ScreenShareCredentials {
        guard let pid = session?.userCommonId, let numericPid = UInt32(pid), numericPid > 0 else {
            throw OopzError.apiError("IDENTITY", "缺少语音身份")
        }
        // 官方默认清晰度：空串分量均为 -1，乘积为 1；不是高画质授权。
        let parts = dimension.split(separator: "x").compactMap { Int($0) }
        guard (1...60).contains(fps), dimension.isEmpty || dimension == "HD" || dimension == "original" ||
            (parts.count == 2 && parts.allSatisfy { (1...8192).contains($0) }) else {
            throw OopzError.apiError("SHARE_PARAMETERS", "共享参数无效")
        }
        let pixels = (dimension == "HD" || dimension == "original") ? 3840 * 2160 : (parts.count == 2 ? parts[0] * parts[1] : 1)
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "optType", value: sending ? "SEND" : "RECEIVE"),
                        URLQueryItem(name: "channel", value: channel),
                        URLQueryItem(name: "dimensions", value: String(pixels)),
                        URLQueryItem(name: "framerate", value: String(fps)),
                        URLQueryItem(name: "pid", value: pid)]
        if let anchor { c.queryItems?.append(URLQueryItem(name: "anchor", value: String(anchor))) }
        let result: ScreenShareCredentials? = try await request("GET", "/screenSharing/v2/sign?" + (c.percentEncodedQuery ?? ""))
        guard let result, !result.roomId.isEmpty, !result.signPid.isEmpty, !result.sign.isEmpty else {
            throw OopzError.apiError("SHARE_TOKEN", "共享凭证不完整")
        }
        return result
    }
}
