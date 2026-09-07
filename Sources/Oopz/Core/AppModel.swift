import AppKit
import Combine

/// 全局应用状态：会话/域列表/当前域/语音房间/屏幕共享
@MainActor
final class AppModel: ObservableObject {
    enum Screen { case boot, login, main }

    lazy var sharing = ScreenShareSession(app: self)

    // 会话
    let permissions = PermissionCenter()
    let api = OopzAPI()
    lazy var ws = OopzWS(api: api) { [weak self] m in self?.log(m) }
    @Published var screen: Screen = .boot
    @Published var me: PersonSelf?
    @Published var bootMessage = "连接中…"
    @Published var toast: String?
    @Published var online: Bool = false   // WS 信令状态

    // 域与频道
    @Published var areas: [AreaSummary] = []
    @Published var currentAreaId: String?
    @Published var areaDetail: AreaDetail?
    @Published var groups: [ChannelGroup] = []
    @Published var channelVoiceMembers: [String: [VoiceMember]] = [:]   // channelId -> members
    @Published var areaRoles: [AreaRole] = []
    @Published var areaMemberList: [AreaMember] = []
    @Published var areaMemberTotal: Int = 0
    @Published var selectedChannelId: String?

    // 文字频道消息（channelId -> 升序消息列表）与未读
    @Published var channelMessages: [String: [ChatMessage]] = [:]
    @Published var channelUnread: [String: Int] = [:]
    @Published var messagesLoading = false
    @Published var draftSent = false   // 触发 UI 清空输入框

    // 语音
    @Published var voice = VoiceState()
    lazy var agora: AgoraManager = AgoraManager(appModel: self)

    init() {
        permissions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        // 嵌套 ObservableObject 转发：voice 的变化也要驱动 UI 刷新
        voice.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }
    private var cancellables = Set<AnyCancellable>()

    func log(_ m: DiagnosticMessage) {
        DiagnosticLog.write(m)
        if RunMode.headless { print("[oopz] \(m.text)") }
    }

    func showToast(_ t: String) {
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == t { self?.toast = nil }
        }
    }

    // MARK: 启动

    func boot() async {
        ensurePrivateKey()
        if let saved = SessionStore.loadSession() {
            api.session = saved
            bootMessage = "登录中…"
            // 网络瞬断给一次重试，避免直接踢到登录页
            for attempt in 0..<2 {
                do {
                    try await api.curTime()
                    let fresh = try await api.autoLogin(saved)
                    api.session = fresh
                    SessionStore.saveSession(fresh)
                    await enterMain()
                    return
                } catch {
                    guard attempt == 0, OopzAPI.isTransportError(error) else {
                        log("autoLogin failed: \(error.localizedDescription)")
                        if !OopzAPI.isTransportError(error) {
                            SessionStore.clearSession()
                            api.session = nil
                        }
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            }
        }
        screen = .login
    }

    /// 网页登录回采：从官方 web.oopz.cn 的 localStorage 提取会话
    func adoptWebSession(uid: String, jwt: String) async {
        var s = api.session ?? OopzSession(uid: uid, jwt: jwt, deviceId: SessionDefaults.deviceId, userCommonId: nil, name: nil, avatar: nil)
        s.uid = uid
        s.jwt = jwt
        api.session = s
        do {
            try await api.curTime()
            let detail = try await api.selfDetail()
            s.name = detail.name
            s.avatar = detail.avatar
            s.userCommonId = detail.userCommonId
            api.session = s
            SessionStore.saveSession(s)
            ensurePrivateKey()
            await enterMain()
        } catch {
            showToast("会话无效: \(error.localizedDescription)")
            api.session = nil
            screen = .login
        }
    }

    /// Authentication material is provisioned locally, never embedded in source or build artifacts.
    func ensurePrivateKey() {
        guard SessionStore.loadPrivateKey() == nil,
              let path = ProcessInfo.processInfo.environment["OOPZ_PROTOCOL_KEY_FILE"],
              let der = try? Data(contentsOf: URL(fileURLWithPath: path)),
              (try? OopzSign.secKey(fromDER: der)) != nil else { return }
        SessionStore.savePrivateKey(der)
    }

    func enterMain() async {
        do {
            me = try await api.selfDetail()
            if let me {
                memberCache[me.uid] = me
            }
            if api.session?.userCommonId == nil {
                api.session?.userCommonId = me?.userCommonId
                SessionStore.saveSession(api.session!)
            }
            screen = .main
            ws.onEvent = { [weak self] ev, body in
                Task { @MainActor in self?.handleWSEvent(ev, body) }
            }
            ws.onStateChange = { [weak self] up in
                Task { @MainActor in self?.handleWSStateChanged(up: up) }
            }
            ws.connect()
            await loadAreas()
            if let last = UserDefaults.standard.string(forKey: SessionStore.prefKey("oopz_last_area", uid: api.session?.uid)),
               areas.contains(where: { $0.id == last }) {
                await openArea(last)
            }
            if let code = pendingInviteCode {
                pendingInviteCode = nil
                await joinByInviteCode(code)
            }
        } catch {
            bootMessage = "登录失败：\(error.localizedDescription)"
            screen = .login
        }
    }

    /// WS 状态变化：重连成功后补发域订阅并刷新频道成员（订阅不随重连恢复，必须手动补）
    private func handleWSStateChanged(up: Bool) {
        online = up
        guard up else { return }
        if let id = currentAreaId {
            ws.subscribe(areaId: id, on: true)
        }
        // 连麦中切走浏览别的域时，语音所在域也必须补订，否则 event 19/20 断流、名单冻住
        if voice.joined, !voice.areaId.isEmpty, voice.areaId != currentAreaId {
            ws.subscribe(areaId: voice.areaId, on: true)
        }
        if currentAreaId != nil {
            Task { await refreshVoiceMembersOfCurrentArea() }
        }
    }

    func logout() {
        let wasJoined = voice.joined
        let leaveArea = voice.areaId
        let leaveCh = voice.channelId
        let leavingJwt = api.session?.jwt
        ws.disconnect()
        WatchWindowController.shared.close()
        ScreenFloatPanelController.shared.hide()
        // REST 退房必须赶在清 JWT 之前。UI 先切登录页；会话等退房完成再清，
        // 且只清「正在退出的那份 jwt」，避免退房窗口内重新登录被误删。
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sharing.stop()
            await self.sharing.closeWatch()
            await self.agora.leaveRoom()
            self.agora.teardown()
            if wasJoined, !leaveArea.isEmpty, !leaveCh.isEmpty {
                try? await self.api.leaveVoiceChannel(areaId: leaveArea, channelId: leaveCh)
            }
            if self.api.session?.jwt == leavingJwt {
                SessionStore.clearSession()
                self.api.session = nil
            }
        }
        areas = []
        currentAreaId = nil
        areaDetail = nil
        groups = []
        channelVoiceMembers = [:]
        channelMessages = [:]
        channelUnread = [:]
        messagePollTask?.cancel()
        areaRoles = []
        areaMemberList = []
        areaMemberTotal = 0
        selectedChannelId = nil
        memberCache = [:]
        memberNicknames = [:]
        pendingBriefs = []
        briefFlushTask?.cancel()
        briefFlushTask = nil
        me = nil
        online = false
        clearSpeakingTimers()
        voice.reset()
        screen = .login
    }

    // MARK: 域列表

    func loadAreas() async {
        // 我订阅的域（官方侧栏数据源 /trs/subscribe/v1/list）
        struct SubscribedArea: Decodable {
            let id: String
            let name: String
            let avatar: String?
            let itemType: String?
            let owner: String?
        }
        do {
            let list: [SubscribedArea] = try await api.request("GET", "/trs/subscribe/v1/list") ?? []
            areas = list.filter { $0.itemType == "AREA" || $0.itemType == nil }
                .map { AreaSummary(id: $0.id, name: $0.name, avatar: $0.avatar, desc: nil, subscribed: true, owner: $0.owner) }
        } catch {
            log("loadAreas: \(error.localizedDescription)")
        }
    }

    private var openAreaSeq = 0

    /// 打开域：全部数据加载成功后才切换 UI 状态（失败保持旧域不动，避免半开状态）；
    /// 序号守卫防止快速连点导致的乱序覆盖。
    func openArea(_ id: String) async {
        openAreaSeq += 1
        let seq = openAreaSeq
        log("openArea \(id)")
        do {
            try await api.enterArea(id)
            let i = try await api.areaInfo(id)
            let g = try await api.channels(id)
            let m = try await api.areaMembers(id)
            guard seq == openAreaSeq else { return }   // 已被更新的点击取代
            let oldAreaId = currentAreaId
            currentAreaId = id
            areaDetail = i
            areaRoles = i.roleList ?? []
            groups = g
            areaMemberList = m.members
            areaMemberTotal = m.total
            selectedChannelId = i.homePageChannelId ?? g.first?.channels.first?.id
            if let uid = api.session?.uid, !uid.isEmpty {
                UserDefaults.standard.set(id, forKey: SessionStore.prefKey("oopz_last_area", uid: uid))
            }
            // 退订旧域——但语音还连在旧域频道时保持订阅（否则成员更新会断流）
            if let old = oldAreaId, old != id, old != voice.areaId {
                ws.subscribe(areaId: old, on: false)
            }
            ws.subscribe(areaId: id, on: true)
            // 清理旧域的频道成员表（保留语音所在频道）
            let newChannelIds = Set(g.flatMap { $0.channels.map(\.id) })
            channelVoiceMembers = channelVoiceMembers.filter { newChannelIds.contains($0.key) || $0.key == voice.channelId }
            // 切域重置消息与未读（频道 ULID 全局唯一，重进频道会重新拉取）
            channelMessages = [:]
            channelUnread = [:]
            messagePollTask?.cancel()
            await refreshVoiceMembersOfCurrentArea()
            log("openArea loaded: \(i.name) groups=\(g.count)")
        } catch {
            guard seq == openAreaSeq else { return }
            log("openArea FAILED: \(error)")
            showToast("进入域失败: \(error.localizedDescription)")
        }
    }

    /// 重新拉取当前域各语音频道在房成员（openArea / WS 重连后刷新）
    private var memberRevision = 0
    func refreshVoiceMembersOfCurrentArea() async {
        let revision = memberRevision
        guard let id = currentAreaId else { return }
        let g = groups
        let voiceIds = g.flatMap { $0.channels.filter { $0.type == "VOICE" }.map(\.id) }
        guard !voiceIds.isEmpty else { return }
        do {
            let states = try await api.membersByChannelsStates(id, voiceIds)
            guard currentAreaId == id, revision == memberRevision else { return }
            let mapping = states.mapValues { $0.map(\.uid) }
            if voice.areaId == id {
                voice.shareStates = Dictionary(uniqueKeysWithValues: (states[voice.channelId] ?? []).filter { $0.screenSharingState == "OPEN" }.map { state in
                    (state.uid, VoiceState.ShareState(uid: state.uid, name: displayName(uid: state.uid), dimensions: state.dimensions, framerate: state.framerate))
                })
            }
            var vm = channelVoiceMembers
            for (cid, uids) in mapping {
                var list = uids.map { resolveMember(uid: $0) }
                // 保留已知的实时状态（静音/说话）
                let old = vm[cid] ?? []
                for idx in list.indices {
                    if let o = old.first(where: { $0.uid == list[idx].uid }) {
                        list[idx].muted = o.muted
                        list[idx].muteKnown = o.muteKnown
                        list[idx].speaking = o.speaking
                        if list[idx].name.isEmpty { list[idx].name = o.name }
                        if list[idx].avatar == nil { list[idx].avatar = o.avatar }
                    }
                }
                // 自己的静音态以本端 voice 状态为准（REST 快照不含实时静音信令）
                if voice.joined, voice.channelId == cid, let selfUid = api.session?.uid,
                   let idx = list.firstIndex(where: { $0.uid == selfUid }) {
                    list[idx].muted = voice.micMuted
                    list[idx].muteKnown = true
                }
                vm[cid] = list
                for u in uids { Task { await fetchMemberInfoIfNeeded(uid: u) } }
            }
            channelVoiceMembers = vm
        } catch {
            log("refreshVoiceMembers: \(error.localizedDescription)")
        }
    }

    var memberCache: [String: PersonSelf] = [:]
    /// 域昵称（uid → 昵称；空串=已查无昵称的负缓存）。官方成员面板显示域昵称优先于全局昵称。
    var memberNicknames: [String: String] = [:]
    private var pendingBriefs: Set<String> = []
    private var briefFlushTask: Task<Void, Never>?

    /// 显示名：域昵称 > 全局昵称 > uid 前缀
    func displayName(uid: String) -> String {
        if let nick = memberNicknames[uid], !nick.isEmpty { return nick }
        if let cached = memberCache[uid], let name = cached.name, !name.isEmpty { return name }
        return String(uid.prefix(6))
    }

    func resolveMember(uid: String) -> VoiceMember {
        VoiceMember(uid: uid, name: displayName(uid: uid), avatar: memberCache[uid]?.avatar)
    }

    /// 拉取成员资料（批量去抖：250ms 窗口内的请求合并为一次 personInfos + 一次域昵称）。
    /// 拉到后同步刷进频道成员表（memberCache 本身不驱动刷新，需 objectWillChange）。
    func fetchMemberInfoIfNeeded(uid: String) async {
        let needBrief = memberCache[uid] == nil
        let needNick = memberNicknames[uid] == nil
        guard needBrief || needNick else { return }
        pendingBriefs.insert(uid)
        briefFlushTask?.cancel()
        briefFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.flushPendingMemberInfo()
        }
    }

    private func flushPendingMemberInfo() async {
        let uids = Array(pendingBriefs)
        pendingBriefs.removeAll()
        guard !uids.isEmpty else { return }
        // 批量资料（personInfos：官方批量接口；selfDetail 会忽略 uid 永远返回自己，严禁再用）
        let missing = uids.filter { memberCache[$0] == nil }
        if !missing.isEmpty, let infos = try? await api.personInfos(uids: missing) {
            for p in infos {
                memberCache[p.uid] = p
                syncMemberInfo(uid: p.uid, name: displayName(uid: p.uid), avatar: p.avatar)
            }
        }
        // 域昵称（含负缓存，避免无昵称成员反复触发请求）
        let nickMissing = uids.filter { memberNicknames[$0] == nil }
        if !nickMissing.isEmpty, let areaId = currentAreaId,
           let nicks = try? await api.areaNicknames(areaId: areaId, uids: nickMissing) {
            for uid in nickMissing { memberNicknames[uid] = nicks[uid] ?? "" }
            for (cid, list) in channelVoiceMembers where list.contains(where: { nickMissing.contains($0.uid) }) {
                channelVoiceMembers[cid] = list.map { m in
                    guard let nick = memberNicknames[m.uid], !nick.isEmpty, m.name != nick else { return m }
                    var mm = m
                    mm.name = nick
                    return mm
                }
            }
            objectWillChange.send()
        }
    }

    private func syncMemberInfo(uid: String, name: String?, avatar: String?) {
        var touched = false
        for (cid, list) in channelVoiceMembers where list.contains(where: { $0.uid == uid }) {
            channelVoiceMembers[cid] = list.map { m in
                guard m.uid == uid else { return m }
                var mm = m
                let fallback = String(uid.prefix(6))
                if let name, mm.name.isEmpty || mm.name == fallback { mm.name = name }
                if let avatar, mm.avatar == nil { mm.avatar = avatar }
                return mm
            }
            touched = true
        }
        if touched { objectWillChange.send() }   // memberCache 变化也要驱动右栏重绘
    }

    // MARK: WS 业务事件

    /// duo/无头模式的 WS 事件入口（enterMain 之外亦可接线；handleWSEvent 的公开包装）
    func dispatchWSEvent(_ ev: OopzWS.Event, _ body: [String: Any]) {
        handleWSEvent(ev, body)
    }

    private func handleWSEvent(_ ev: OopzWS.Event, _ body: [String: Any]) {
        let area = body["area"] as? String
        let channel = body["channel"] as? String
        let persons = body["persons"] as? [String] ?? []
        switch ev {
        case .voiceJoin:
            memberRevision += 1
            // 正在连麦的域必须收事件（否则切走浏览别的域时，语音房名单冻住）
            guard area == currentAreaId || area == voice.areaId, let channel else { return }
            var vm = channelVoiceMembers[channel] ?? []
            for uid in persons where !vm.contains(where: { $0.uid == uid }) {
                vm.append(resolveMember(uid: uid))
                Task { await fetchMemberInfoIfNeeded(uid: uid) }
            }
            channelVoiceMembers[channel] = vm
            if voice.channelId == channel {
                for uid in persons where uid != api.session?.uid { Sounds.personEnter() }
            }
        case .voiceLeave:
            memberRevision += 1
            guard area == currentAreaId || area == voice.areaId, let channel else { return }
            var vm = channelVoiceMembers[channel] ?? []
            vm.removeAll { persons.contains($0.uid) }
            channelVoiceMembers[channel] = vm
            if voice.channelId == channel, persons.contains(where: { $0 != api.session?.uid }) { Sounds.personExit() }
        case .screenShareState:
            handleScreenShareEvent(body)
        case .gimMessage:
            handleGIMMessageEvent(body)
        default:
            break
        }
    }

    /// event 9：频道文字消息推送（data 内层为消息 JSON 字符串）
    private func handleGIMMessageEvent(_ body: [String: Any]) {
        guard let dataStr = body["data"] as? String,
              let data = dataStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = obj["messageId"] as? String,
              let person = obj["person"] as? String else { return }
        let channelId = obj["channel"] as? String ?? ""
        let area = obj["area"] as? String ?? ""
        guard !channelId.isEmpty else { return }
        let msg = ChatMessage(
            id: messageId,
            clientMessageId: obj["clientMessageId"] as? String ?? "",
            person: person,
            content: obj["content"] as? String ?? (obj["text"] as? String ?? ""),
            timestampUS: obj["timestamp"] as? String ?? "0",
            type: obj["type"] as? String ?? "TEXT",
            images: ChatMessage.parseAttachments(obj["attachments"]))
        appendMessage(msg, channelId: channelId, areaId: area)
    }

    /// 追加消息：合并乐观插入（clientMessageId 去重）、补齐昵称头像、未读计数、已读上报
    private func appendMessage(_ msg: ChatMessage, channelId: String, areaId: String) {
        var list = channelMessages[channelId] ?? []
        // 服务端回流合并自己的乐观消息
        if msg.person == api.session?.uid,
           let idx = list.firstIndex(where: { $0.clientMessageId == msg.clientMessageId && $0.pending }) {
            var merged = msg
            merged.senderName = list[idx].senderName
            merged.senderAvatar = list[idx].senderAvatar
            list[idx] = merged
            channelMessages[channelId] = list
            return
        }
        guard !list.contains(where: { $0.id == msg.id || (!$0.clientMessageId.isEmpty && $0.clientMessageId == msg.clientMessageId) }) else { return }
        var m = msg
        if memberCache[m.person] != nil {
            m.senderName = displayName(uid: m.person)
            m.senderAvatar = memberCache[m.person]?.avatar
        } else {
            Task { await fetchMemberInfoIfNeeded(uid: m.person) }
        }
        // 图片消息没带签名附件（event 9 少数字场景）：重拉一次历史补齐；仍缺则 UI 显示占位
        if m.images.isEmpty, ChatMessage.imageMarkdown(in: m.content) != nil {
            Task { await reloadMessages(channelId: channelId) }
        }
        list.append(m)
        list.sort { $0.timestampUS < $1.timestampUS }
        channelMessages[channelId] = list
        let isViewing = selectedChannelId == channelId && screen == .main
        if isViewing {
            Task { await api.saveReadStatus(areaId: areaId.isEmpty ? (currentAreaId ?? "") : areaId, channelId: channelId, messageId: m.id) }
        } else if m.person != api.session?.uid {
            channelUnread[channelId, default: 0] += 1
        }
    }

    // MARK: 消息轮询兜底（event 9 丢失时自愈；仅对当前查看的文字频道轻量轮询）

    private var messagePollTask: Task<Void, Never>?

    func startMessagePollingIfNeeded() {
        messagePollTask?.cancel()
        guard let cid = selectedChannelId,
              let ch = groups.flatMap({ $0.channels }).first(where: { $0.id == cid }),
              ch.type == "TEXT" else { return }
        messagePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, self.selectedChannelId == cid else { return }
                await self.reloadMessages(channelId: cid)
            }
        }
    }

    // MARK: 文字频道打开 / 历史 / 发送

    /// 选中文字频道：官方前置 enter + 拉最新一页 + 清未读
    func openTextChannel(_ channelId: String) async {
        guard let areaId = currentAreaId else { return }
        channelUnread[channelId] = 0
        do {
            try await api.enterTextChannel(areaId: areaId, channelId: channelId)
        } catch {
            log("enterTextChannel: \(error.localizedDescription)")
        }
        await reloadMessages(channelId: channelId)
    }

    func reloadMessages(channelId: String) async {
        guard let areaId = currentAreaId else { return }
        messagesLoading = true
        defer { messagesLoading = false }
        do {
            let prev = channelMessages[channelId] ?? []
            let prevLastId = prev.last?.id
            let msgs = try await api.channelMessages(areaId: areaId, channelId: channelId)
            var enriched = msgs
            for i in enriched.indices {
                enriched[i].senderName = displayName(uid: enriched[i].person)
                enriched[i].senderAvatar = memberCache[enriched[i].person]?.avatar
            }
            // 保留仍在途的乐观消息（尚未被服务端历史收录）
            let confirmedIds = Set(enriched.map(\.id))
            let confirmedCmids = Set(enriched.map(\.clientMessageId))
            let inFlight = prev.filter {
                $0.pending && !confirmedIds.contains($0.id)
                    && !(!$0.clientMessageId.isEmpty && confirmedCmids.contains($0.clientMessageId))
            }
            enriched.append(contentsOf: inFlight)
            channelMessages[channelId] = enriched.sorted { $0.timestampUS < $1.timestampUS }
            let unknown = Set(enriched.map(\.person)).filter { memberCache[$0] == nil }
            for uid in unknown { await fetchMemberInfoIfNeeded(uid: uid) }
            // 只有最新消息变化才上报已读（轮询时避免重复上报）
            if let last = enriched.last, prevLastId != last.id {
                await api.saveReadStatus(areaId: areaId, channelId: channelId, messageId: last.id)
            }
        } catch {
            log("reloadMessages: \(error.localizedDescription)")
        }
    }

    /// 向前翻页（更早消息）
    func loadOlderMessages(channelId: String) async {
        guard let areaId = currentAreaId,
              let oldest = channelMessages[channelId]?.first else { return }
        do {
            let older = try await api.channelMessages(areaId: areaId, channelId: channelId, before: oldest.id)
            guard !older.isEmpty else { return }
            var list = older
            for i in list.indices {
                list[i].senderName = displayName(uid: list[i].person)
                list[i].senderAvatar = memberCache[list[i].person]?.avatar
            }
            let existing = channelMessages[channelId] ?? []
            let existingIds = Set(existing.map(\.id))
            channelMessages[channelId] = (list.filter { !existingIds.contains($0.id) } + existing).sorted { $0.timestampUS < $1.timestampUS }
        } catch {
            log("loadOlderMessages: \(error.localizedDescription)")
        }
    }

    /// 发送（乐观插入 + 服务端确认；event 9 回流按 clientMessageId 合并）
    func sendChannelMessage(_ text: String, channelId: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let areaId = currentAreaId, let uid = api.session?.uid else { return }
        let cmid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let optimistic = ChatMessage(
            id: "pending-\(cmid)",
            clientMessageId: cmid,
            person: uid,
            content: trimmed,
            timestampUS: String(Int64(Date.now.timeIntervalSince1970 * 1_000_000)),
            type: "TEXT",
            senderName: api.session?.name ?? me?.name,
            senderAvatar: api.session?.avatar,
            pending: true)
        channelMessages[channelId, default: []].append(optimistic)
        do {
            let result = try await api.sendChannelMessage(areaId: areaId, channelId: channelId, text: trimmed, clientMessageId: cmid, displayName: api.session?.name ?? "")
            // 服务端确认：把乐观消息替换为真实 id（若 event 9 未先到）
            if var list = channelMessages[channelId],
               let idx = list.firstIndex(where: { $0.clientMessageId == cmid && $0.pending }) {
                list[idx] = ChatMessage(id: result.messageId, clientMessageId: cmid, person: uid,
                                        content: trimmed,
                                        timestampUS: result.timestampUS.isEmpty ? list[idx].timestampUS : result.timestampUS,
                                        type: "TEXT",
                                        senderName: optimistic.senderName, senderAvatar: optimistic.senderAvatar, pending: false)
                list.sort { $0.timestampUS < $1.timestampUS }
                channelMessages[channelId] = list
            }
            await api.saveReadStatus(areaId: areaId, channelId: channelId, messageId: result.messageId)
        } catch {
            channelMessages[channelId]?.removeAll { $0.id == optimistic.id }
            showToast("发送失败: \(error.localizedDescription)")
        }
    }

    /// event 33：共享开始/结束广播（uid 为 oopz uid）。填充 shareStates 供频道内横幅与观看入口使用；
    /// 流的存在性仍以 Agora didJoined/remoteVideoState 为准。
    private func handleScreenShareEvent(_ body: [String: Any]) {
        let area = body["area"] as? String
        guard voice.joined, area == voice.areaId, body["channel"] as? String == voice.channelId else { return }
        memberRevision += 1
        guard let uid = body["uid"] as? String, let state = body["state"] as? String else { return }
        if state.uppercased() == "OPEN" {
            let name = displayName(uid: uid)
            voice.shareStates[uid] = VoiceState.ShareState(
                uid: uid, name: name,
                dimensions: body["dimensions"] as? String ?? "",
                framerate: body["framerate"] as? String ?? "")
            Task { await fetchMemberInfoIfNeeded(uid: uid) }
        } else {
            voice.shareStates[uid] = nil
            if let agoraUid = agoraUid(ofOopzUid: uid), voice.watchingUid == agoraUid {
                voice.watchingUid = nil
                WatchWindowController.shared.close()
            }
        }
    }

    /// oopz uid → Agora uid（= userCommonId）
    func agoraUid(ofOopzUid uid: String) -> UInt32? {
        if uid == api.session?.uid {
            return UInt32(truncatingIfNeeded: Int64(api.session?.userCommonId ?? "0") ?? 0)
        }
        guard let num = memberCache[uid]?.userCommonId else { return nil }
        return UInt32(truncatingIfNeeded: Int64(num) ?? 0)
    }

    /// 手动/自动打开观看窗（共享横幅按钮 + Agora 流到达）
    func openWatch(agoraUid: UInt32) {
        guard !RunMode.headless else { return }
        voice.watchDismissed.remove(agoraUid)
        voice.watchRequestId = UUID()
        voice.watchingUid = agoraUid
        WatchWindowController.shared.show(app: self, uid: agoraUid)
    }

    // MARK: 说话状态（Agora 音量回调驱动，800ms 无声自动熄灭）

    private var speakingTimers: [String: Task<Void, Never>] = [:]

    func clearSpeakingTimers() {
        speakingTimers.values.forEach { $0.cancel() }
        speakingTimers.removeAll()
    }

    /// Agora uid：0 = 本地用户（SDK 头文件明确约定），其余为远端 userCommonId
    func agoraUidToMemberUid(_ uid: UInt32) -> String? {
        if uid == 0 || uid == voice.agoraUid { return api.session?.uid }
        let num = String(uid)
        for (oopzUid, person) in memberCache where person.userCommonId == num {
            return oopzUid
        }
        return nil
    }

    func updateSpeaking(uid: UInt32, on: Bool) {
        guard let key = agoraUidToMemberUid(uid) else { return }
        setSpeaking(key: key, on: on)
        speakingTimers[key]?.cancel()
        speakingTimers[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.setSpeaking(key: key, on: false)
        }
    }

    private func setSpeaking(key: String, on: Bool) {
        // 自己的说话状态只在实际开麦时有意义
        if key == api.session?.uid, voice.micMuted, on { return }
        for (cid, list) in channelVoiceMembers {
            var l = list
            var changed = false
            for i in l.indices where l[i].uid == key {
                if l[i].speaking != on { l[i].speaking = on; changed = true }
            }
            if changed { channelVoiceMembers[cid] = l }
        }
    }

    // MARK: 自己的静音状态同步（顶栏/成员表唯一事实源）

    /// setMic/setHeadset 后调用：把最新状态写进频道成员表的自己条目
    func applySelfMuteState() {
        guard voice.joined, let uid = api.session?.uid else { return }
        guard var list = channelVoiceMembers[voice.channelId] else { return }
        for i in list.indices where list[i].uid == uid {
            list[i].muted = voice.micMuted
            list[i].muteKnown = true
        }
        channelVoiceMembers[voice.channelId] = list
    }

    // MARK: RTC 凭证自动恢复 / 权限引导

    /// token 过期：重新走 REST 进房拿新 token 并 rejoin（保持闭麦等状态）
    func refreshRTC() async {
        guard voice.joined else { return }
        do {
            let result = try await api.enterVoiceChannel(areaId: voice.areaId, channelId: voice.channelId)
            voice.agoraToken = result.supplierSign ?? ""
            if let rid = result.roomId { voice.agoraRoomId = rid }
            try await agora.rejoinChannel(app: self)
            showToast("语音连接已自动恢复")
        } catch {
            showToast("语音凭证过期且自动恢复失败：\(error.localizedDescription)")
        }
    }

    /// 进房凭证无效（invalidToken）：自动恢复无望，干净退出并提示
    func handleRTCInvalidToken() {
        guard voice.joined else { return }
        Task { await voice.leave(app: self) }
        showToast("进房凭证无效，已退出频道")
    }

    // MARK: 屏幕共享服务端上报
    // 2026-09-07 R1 落地：POST /screenSharing/v1/stateSave（自官方 web_main.dart.js 逆向）。
    // 服务端收到后广播 event 33 + 写成员 screenSharingState——官方客户端由此显示「XX 正在共享」。
    func reportScreenShare(open: Bool, dimensions: String, framerate: String) async {
        guard voice.joined, !voice.areaId.isEmpty, !voice.channelId.isEmpty else {
            log("screenShare stateSave skipped: not in channel")
            return
        }
        do {
            let ok = try await api.reportScreenShareState(areaId: voice.areaId, channelId: voice.channelId,
                                                          open: open, dimensions: dimensions, framerate: framerate)
            log("screenShare stateSave \(open ? "OPEN" : "CLOSE") ok=\(ok) dims=\(dimensions) fps=\(framerate)")
        } catch {
            log("screenShare stateSave failed: \(error.localizedDescription)")
        }
    }

    /// 入口页负责授权；业务入口仅防御尚未完成的检查，不再弹模态框。
    func preflightScreenShare() -> Bool { RunMode.headless || permissions.ready }

    // 屏幕共享档位（选择器数据源）
    @Published var shareTiers: [ScreenShareTier] = []
    @Published var shareVip: ScreenShareVipStatus?
    private var shareOptionsLoaded = false

    func loadShareOptions() async {
        guard !shareOptionsLoaded else { return }
        shareTiers = (try? await api.screenShareParams()) ?? []
        shareVip = try? await api.screenShareVip()
        if !shareTiers.isEmpty && shareVip != nil { shareOptionsLoaded = true }
        if shareOptionsLoaded { log("share options: \(shareVip?.type ?? "?") \(shareTiers.count) 档") }
    }

    /// 当前账号可用的清晰度/帧率选项（按 VIP 档位过滤 active）
    var myShareTier: ScreenShareTier? {
        let t = shareVip?.type ?? "FREE"
        return shareTiers.first { $0.type == t } ?? shareTiers.last
    }

    // MARK: 邀请（官方 /uni/invite/v1/generate → https://oopz.cn/i/<code>）

    /// 解析邀请链接/深链，提取邀请码
    /// 支持：https://oopz.cn/i/<code>、https://oopz.cn/s/<code>、oopz://i/<code>、oopz://?s=<code>、裸 code
    static func inviteCode(from url: URL) -> String? {
        let host = url.host?.lowercased()
        let scheme = url.scheme?.lowercased()
        if scheme == "oopz" {
            if let code = url.host, !code.isEmpty, code != "i" && code != "s" && code != "t" { return code }
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                if ["s", "i", "t"].contains(item.name), let v = item.value, !v.isEmpty { return v }
            }
            return nil
        }
        if host == "oopz.cn" || host == "www.oopz.cn" || host == "oopz.vip" {
            let segs = url.pathComponents.filter { $0 != "/" }
            if segs.count == 2, ["i", "s", "t"].contains(segs[0].lowercased()) {
                return segs[1]
            }
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                if ["s", "i", "t"].contains(item.name), let v = item.value, !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// 通过邀请码加入域：details 解析 → 打开域 → 选中频道
    /// 响应实测定型（2026-09-06）：data.details.<code> = {itemType, areaName, status, itemId(=areaId), channelId?…}
    func joinByInviteCode(_ code: String) async {
        do {
            let obj = try await api.requestJSON("POST", "/uni/invite/v1/details", body: ["codes": [code]])
            var areaId: String?
            var channelId: String?
            if let d = obj["data"] as? [String: Any], let details = d["details"] as? [String: Any] {
                let entry = (details[code] as? [String: Any]) ?? (details.values.first as? [String: Any] ?? [:])
                let status = entry["status"] as? String ?? ""
                if status.contains("EXPIRED") || status.contains("INVALID") {
                    showToast("邀请已失效（\(status)）")
                    return
                }
                areaId = entry["itemId"] as? String ?? entry["area"] as? String ?? entry["areaId"] as? String
                channelId = entry["channelId"] as? String ?? entry["channel"] as? String
            }
            log("invite details received")
            guard let areaId else {
                showToast("邀请码无效或已过期")
                return
            }
            await loadAreas()
            await openArea(areaId)
            if let channelId {
                selectedChannelId = channelId
                if let ch = groups.flatMap({ $0.channels }).first(where: { $0.id == channelId }), ch.type == "TEXT" {
                    await openTextChannel(channelId)
                }
            }
            let areaName = areaDetail?.name ?? ""
            showToast(areaName.isEmpty ? "已通过邀请进入社区" : "已通过邀请进入「\(areaName)」")
        } catch {
            showToast("邀请码解析失败: \(error.localizedDescription)")
        }
    }

    /// 深链/URL 事件入口（oopz:// 与浏览器邀请链接）
    func handleDeepLink(_ url: URL) async {
        guard screen == .main else {
            // 未就绪：暂存，enterMain 后处理
            pendingInviteCode = Self.inviteCode(from: url)
            return
        }
        guard let code = Self.inviteCode(from: url) else { return }
        await joinByInviteCode(code)
    }

    var pendingInviteCode: String?

    func copyInviteLink(channelId: String?) async {
        guard let areaId = currentAreaId else { return }
        do {
            let link = try await api.generateInviteLink(areaId: areaId, channelId: channelId)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            showToast("邀请链接已复制")
        } catch {
            log("invite generate failed: \(error.localizedDescription)")
            // 兜底：复制域名 + 域短号（好友可通过搜索加入）
            let name = areaDetail?.name ?? "OOPZ"
            let code = areaDetail?.code ?? ""
            let text = "邀请你加入 OOPZ 域「\(name)」\(code.isEmpty ? "" : "（ID: \(code)）")— 在 OOPZ 搜索 ID 即可加入"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showToast("邀请链接生成失败，已复制域信息")
        }
    }
}

// MARK: - 语音房间状态

@MainActor
final class VoiceState: ObservableObject {
    @Published var joined = false
    @Published var joining = false
    @Published var areaId: String = ""
    @Published var channelId: String = ""
    @Published var channelName: String = ""
    @Published var micMuted = true
    @Published var headsetMuted = false
    // 音量（0–400，100=原始音量；跨会话持久化，进房时由 AgoraManager.applySavedVolumes 恢复）
    @Published var micVolume: Int = 100
    @Published var playbackVolume: Int = 100
    /// 单人音量（key 为 Agora uid 字符串），持久化在 UserDefaults
    @Published var userVolumes: [String: Int] = AgoraManager.loadSavedUserVolumes()
    @Published var agoraRoomId: String = ""
    @Published var agoraToken: String = ""
    @Published var agoraUid: UInt32 = 0
    @Published var shareActive = false
    @Published var sharePhase: SharePhase = .idle
    @Published var shareError: String?

    var watchRequestId = UUID()
    @Published var watchingUid: UInt32?          // 正在观看的远端共享流 uid
    /// 用户手动关闭过观看窗的共享者（本次会话内不再自动弹出，横幅仍可手动打开）
    @Published var watchDismissed: Set<UInt32> = []
    /// 频道内他人共享（event 33 聚合；key 为 oopz uid）
    @Published var shareStates: [String: ShareState] = [:]

    struct ShareState: Identifiable {
        let uid: String
        var name: String
        var dimensions: String
        var framerate: String
        var id: String { uid }
    }

    @Published var areaMembers: [AreaMember] = []

    func reset() {
        joined = false
        joining = false
        areaId = ""
        channelId = ""
        channelName = ""
        micMuted = true
        headsetMuted = false
        shareActive = false
        sharePhase = .idle
        shareError = nil
        agoraRoomId = ""
        agoraToken = ""
        agoraUid = 0
        watchingUid = nil
        watchDismissed = []
        shareStates = [:]
    }
}

/// 设备默认值（首次生成持久化）。按数据目录隔离：duo 的 --data-dir 不能跟 GUI 共用一台设备号，
/// 否则 autoLogin 会互踢（ERR.003 / 428）。
enum SessionDefaults {
    static var deviceId: String {
        // 自定义 --data-dir / OOPZ_DATA_DIR：只认该目录自己的 device_id，
        // 绝不能读全局 UserDefaults（否则 duo 跟 GUI 共用一台设备号，autoLogin 互踢）。
        let file = SessionStore.dir.appendingPathComponent("device_id")
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let key = "oopz_device_id"
        let isCustomDir: Bool = {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count, !args[i + 1].isEmpty { return true }
            if let custom = ProcessInfo.processInfo.environment["OOPZ_DATA_DIR"], !custom.isEmpty { return true }
            return false
        }()
        if !isCustomDir, let s = UserDefaults.standard.string(forKey: key), !s.isEmpty {
            try? s.write(to: file, atomically: true, encoding: .utf8)
            return s
        }
        let id = UUID().uuidString
        try? id.write(to: file, atomically: true, encoding: .utf8)
        if !isCustomDir { UserDefaults.standard.set(id, forKey: key) }
        return id
    }
}
