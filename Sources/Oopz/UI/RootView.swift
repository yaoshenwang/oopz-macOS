import SwiftUI
import AppKit

/// 主界面：严格对标官方布局 ——
/// 顶栏（logo + 音频胶囊 + 头像）｜左栏（域+频道，语音频道显示 n/上限 与成员）｜中栏（语音房区 + 文字频道内容）｜右栏（域成员·身份组分栏）
struct RootView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            GlobalTopBar(app: app)
                .zIndex(1)   // 音量浮层向下越出顶栏，必须压在内容区之上
            HStack(spacing: 0) {
                SidebarView(app: app)
                    .frame(width: 240)
                    .background(Theme.panel)
                AreaDetailView(app: app)
                    .frame(maxWidth: .infinity)
                    .background(Theme.bg)
                AreaMemberPanel(app: app)
                    .frame(width: 250)
                    .background(Theme.panel)
            }
        }
    }
}

// MARK: - 顶栏（官方同款：logo + 音频胶囊 + 头像）

struct GlobalTopBar: View {
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Oopz.")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            audioPill

            if let me = app.me {
                AsyncOopzImage(url: me.avatar, fallbackText: me.name ?? "?")
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                Text(me.name ?? "")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(app.online ? Theme.speaking : Color.gray)
                    .frame(width: 7, height: 7)
                Text(app.online ? "在线" : "连接中")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Menu {
                Button("退出登录") { app.logout() }
                Button("退出 Oopz") { AppDelegate.shared.doQuit() }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.bg)
    }

    /// 官方音频胶囊：未在语音=灰色麦克风/耳机；在语音=蓝描边胶囊 + 红色出门键。
    /// 未进语音时麦克风/耳机按钮置灰（点击无效），避免状态与实际脱节。
    /// 悬停按钮弹出音量滑条（官方同款）：麦克风=采音音量、耳机=全局播放音量。
    private var audioPill: some View {
        HStack(spacing: 22) {
            HoverVolumeSlider(title: "麦克风音量", volume: Binding(
                get: { app.voice.micVolume },
                set: { app.agora.setMicVolume($0) }
            ), enabled: app.voice.joined, anchor: .below) {
                Button {
                    app.agora.setMic(muted: !app.voice.micMuted)
                } label: {
                    Image(systemName: app.voice.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15))
                        .foregroundColor(app.voice.micMuted ? Theme.doorRed : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .disabled(!app.voice.joined)
                .opacity(app.voice.joined ? 1 : 0.35)
                .help(app.voice.joined ? (app.voice.micMuted ? "开启麦克风" : "关闭麦克风") : "加入语音后可用")
            }

            HoverVolumeSlider(title: "播放音量", volume: Binding(
                get: { app.voice.playbackVolume },
                set: { app.agora.setPlaybackVolume($0) }
            ), enabled: app.voice.joined, anchor: .below) {
                Button {
                    app.agora.setHeadset(muted: !app.voice.headsetMuted)
                } label: {
                    // 耳机静音用叠加斜线表达（SF Symbols 无 headphones.slash 变体）
                    Image(systemName: "headphones")
                        .font(.system(size: 15))
                        .foregroundColor(app.voice.headsetMuted ? Theme.danger : .white.opacity(0.9))
                        .overlay(
                            Rectangle()
                                .fill(Theme.danger)
                                .frame(width: 21, height: 1.8)
                                .rotationEffect(.degrees(-32))
                                .opacity(app.voice.headsetMuted ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!app.voice.joined)
                .opacity(app.voice.joined ? 1 : 0.35)
                .help(app.voice.joined ? (app.voice.headsetMuted ? "取消耳机静音" : "耳机静音") : "加入语音后可用")
            }

            if app.voice.joined {
                Button {
                    Task { await app.voice.leave(app: app) }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.doorRed)
                }
                .buttonStyle(.plain)
                .help("退出语音频道")
                .accessibilityLabel("退出语音频道")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.pillBg))
        .overlay(
            Capsule().strokeBorder(app.voice.joined ? Theme.pillBorder : Color.white.opacity(0.12), lineWidth: 1.5)
        )
    }
}

// MARK: - 左栏：域列表 + 频道树

struct SidebarView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.areaDetail?.name ?? "社区")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let code = app.areaDetail?.code {
                    Text("ID: \(code)")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                Button {
                    // 刷新域列表 + 当前域的频道/成员
                    Task {
                        await app.loadAreas()
                        if let id = app.currentAreaId { await app.openArea(id) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("刷新社区与频道")
            }
            .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(app.areas) { area in
                        AreaRow(area: area, selected: area.id == app.currentAreaId) {
                            Task { await app.openArea(area.id) }
                        }
                    }
                }
                .padding(.horizontal, 8)

                if app.currentAreaId != nil {
                    channelTree
                }
            }
        }
    }

    /// 频道树（分组标题 + 文字/语音频道；语音频道行下挂当前成员）
    private var channelTree: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(app.groups) { group in
                Text(group.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, 14).padding(.top, 10)
                ForEach(group.channels) { channel in
                    ChannelRow(app: app, channel: channel)
                }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 20)
    }
}

struct AreaRow: View {
    let area: AreaSummary
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AsyncOopzImage(url: area.avatar, fallbackText: area.name)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(area.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.sidebarSelected : (hover ? Theme.rowHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 频道行：严格对标官方 —— 文字行（气泡图标）；语音行（麦克风圆图标 + 「NN/上限」计数）+ 选中态 + 行下挂当前成员
struct ChannelRow: View {
    @ObservedObject var app: AppModel
    let channel: Channel
    @State private var hover = false

    private var isVoice: Bool { channel.type == "VOICE" }
    private var isSelected: Bool { app.selectedChannelId == channel.id }
    private var isActiveVoice: Bool { app.voice.joined && app.voice.channelId == channel.id }
    private var members: [VoiceMember] { app.channelVoiceMembers[channel.id] ?? [] }
    private var maxDisplay: String {
        let max = channel.settings?.maxMember ?? 50
        return max >= 2_000_000_000 ? "∞" : String(max)
    }
    private var countDisplay: String {
        String(format: "%02d", members.count) + "/" + maxDisplay
    }
    private var icon: String {
        if isVoice { return "mic.circle" }
        if channel.tag == "HOME_PAGE" { return "house" }
        return "text.bubble"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                app.selectedChannelId = channel.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundColor(isActiveVoice ? Theme.accent : Theme.textTertiary)
                    Text(channel.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    if !isVoice, let unread = app.channelUnread[channel.id], unread > 0 {
                        Text("\(min(unread, 99))")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.danger))
                    } else if isVoice {
                        Text(countDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.countGray)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Theme.sidebarSelected : (hover ? Theme.rowHover : .clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .onTapGesture(count: 2) {
                guard isVoice else { return }
                Task { await app.voice.toggleJoin(channel: channel, app: app) }
            }

            if isVoice && !members.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(members) { m in
                        HStack(spacing: 8) {
                            AsyncOopzImage(url: m.avatar, fallbackText: m.name)
                                .frame(width: 20, height: 20)
                                .clipShape(Circle())
                            Text(m.name)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                            if m.speaking {
                                Circle()
                                    .fill(Theme.speaking)
                                    .frame(width: 4, height: 4)
                                    .accessibilityLabel("正在说话")
                            }
                            if m.muteKnown && m.muted {
                                Image(systemName: "mic.slash.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(.leading, 30)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 中栏：语音房区（进房时置顶显示）+ 文字频道内容

struct AreaDetailView: View {
    @ObservedObject var app: AppModel
    @State private var showPicker = false

    private var selectedChannel: Channel? {
        for g in app.groups { for c in g.channels where c.id == app.selectedChannelId { return c } }
        return nil
    }
    private var showVoiceRoom: Bool {
        app.voice.joined || (selectedChannel?.type == "VOICE")
    }

    var body: some View {
        VStack(spacing: 0) {
            if showVoiceRoom, let channel = currentVoiceChannel {
                if selectedChannel?.type == "TEXT" {
                    // 边看文字频道边连麦：语音房保持固定高度，不挤压文字内容
                    VoiceRoomSection(app: app, channel: channel, showPicker: $showPicker)
                        .frame(maxHeight: 360)
                } else {
                    VoiceRoomSection(app: app, channel: channel, showPicker: $showPicker)
                        .frame(maxHeight: .infinity)
                }
                Divider().overlay(Theme.card)
            }
            channelContent
        }
        .sheet(isPresented: $showPicker) {
            SharePickerView(app: app)
        }
    }

    private var currentVoiceChannel: Channel? {
        let targetId = app.voice.joined ? app.voice.channelId : app.selectedChannelId
        for g in app.groups { for c in g.channels where c.id == targetId && c.type == "VOICE" { return c } }
        return nil
    }

    @ViewBuilder
    private var channelContent: some View {
        if let channel = selectedChannel, channel.type == "TEXT" {
            TextChannelContent(app: app, channel: channel)
        } else if selectedChannel == nil {
            VStack {
                Spacer()
                Text("选择一个社区开始")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
        }
    }
}

/// 文字频道内容：真实消息流（历史 + event9 实时 + 发送）+ 输入条
struct TextChannelContent: View {
    @ObservedObject var app: AppModel
    let channel: Channel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] { app.channelMessages[channel.id] ?? [] }
    private var myUid: String? { app.api.session?.uid }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: channel.tag == "HOME_PAGE" ? "house" : "text.bubble")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textSecondary)
                Text(channel.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if app.messagesLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            if channel.tag == "HOME_PAGE" && messages.isEmpty {
                homeWelcome
            }

            messageList

            composer
        }
        .task(id: channel.id) {
            await app.openTextChannel(channel.id)
            app.startMessagePollingIfNeeded()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if messages.count >= 30 {
                        Button {
                            Task { await app.loadOlderMessages(channelId: channel.id) }
                        } label: {
                            Text("加载更早的消息")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.accent)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(messages) { m in
                        MessageRow(app: app, message: m, isMine: m.person == myUid)
                            .id(m.id)
                    }
                    if messages.isEmpty {
                        VStack {
                            Spacer()
                            Text("还没有消息，来说第一句吧")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.top, 60)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 18)
            }
            .onChange(of: messages.last?.id) { _, last in
                if let last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var homeWelcome: some View {
        VStack(spacing: 8) {
            Text(isAreaOwner ? "游戏记忆由此开始" : "欢迎来到 \(app.areaDetail?.name ?? "这个社区")")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(isAreaOwner ? "你已成功建立域" : "在下方和大家打个招呼吧")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var isAreaOwner: Bool {
        guard let myUid = app.me?.uid else { return false }
        let ownerRoleID = app.areaRoles.first { $0.type == 1 }?.roleID
        guard let ownerRoleID else { return false }
        return app.areaMemberList.contains { $0.uid == myUid && $0.role == ownerRoleID }
    }

    /// 输入条：Enter 发送（Shift+Enter 换行）
    private var composer: some View {
        HStack(spacing: 10) {
            TextField("发送至 #\(channel.name)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { send() }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.textTertiary : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送消息")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.panel.opacity(0.5))
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await app.sendChannelMessage(text, channelId: channel.id) }
    }
}

/// 单条消息：他人=左（头像+昵称+气泡），自己=右（accent 气泡）。
/// 图片消息（官方 IMAGE markdown + attachments 签名 URL）直接渲染图片；缺附件时显示占位。
struct MessageRow: View {
    @ObservedObject var app: AppModel
    let message: ChatMessage
    let isMine: Bool

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: message.date)
    }

    /// 有签名 URL 的图片附件
    private var imageAtts: [MsgAttachment] { message.images.filter { $0.url != nil } }
    /// 纯图片 markdown 但缺附件（拉取重试后仍无签名 URL）→ 占位
    private var imagePlaceholderOnly: Bool {
        message.images.allSatisfy { $0.url == nil } && ChatMessage.imageMarkdown(in: message.content) != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                AsyncOopzImage(url: message.senderAvatar, fallbackText: message.senderName ?? message.person)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text(message.senderName ?? String(message.person.prefix(6)))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                if !imageAtts.isEmpty {
                    messageImages
                } else if imagePlaceholderOnly {
                    imagePlaceholder
                } else {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundColor(isMine ? .white : Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isMine ? Theme.accent.opacity(message.pending ? 0.45 : 0.92) : Theme.card)
                        )
                }
                Text(timeText + (message.pending ? " · 发送中" : ""))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            if !isMine { Spacer(minLength: 40) }
            if isMine {
                AsyncOopzImage(url: message.senderAvatar, fallbackText: message.senderName ?? "我")
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 3)
    }

    /// 官方同款：图片消息无文字气泡，圆角直出，按附件宽高等比缩放（上限 240×320）
    private var messageImages: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            ForEach(Array(imageAtts.enumerated()), id: \.offset) { _, att in
                MessageImageView(att: att)
            }
        }
    }

    private var imagePlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 13))
            Text("[图片]")
                .font(.system(size: 13))
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }
}

/// 消息图片：CDN 签名 URL 加载（webp），按附件声明宽高等比缩放；未知尺寸按 4:3 兜底
struct MessageImageView: View {
    let att: MsgAttachment
    @State private var img: NSImage? = nil

    private var displaySize: CGSize {
        let maxW: CGFloat = 240, maxH: CGFloat = 320
        var w: CGFloat = att.width > 0 ? CGFloat(att.width) : 0
        var h: CGFloat = att.height > 0 ? CGFloat(att.height) : 0
        if w == 0 || h == 0 {
            // 解码后已知实际尺寸；未知按 4:3
            if let s = img.map({ $0.size }) , s.width > 0, s.height > 0 { w = s.width; h = s.height }
            else { w = 200; h = 150 }
        }
        let scale = Swift.min(maxW / w, maxH / h, 1)
        return CGSize(width: max(60, w * scale), height: max(45, h * scale))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Theme.card)
            if let img {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .task(id: att.url) {
            guard let url = att.url else { return }
            img = await AvatarCache.shared.load(url)
        }
    }
}

// MARK: - 右栏：域成员（官方同款身份组分栏「域主 - 1」）

struct AreaMemberPanel: View {
    @ObservedObject var app: AppModel

    private var groups: [(name: String, members: [AreaMember])] {
        let roles = app.areaRoles.filter { $0.isDisplay == true }.sorted { ($0.sort ?? 0) > ($1.sort ?? 0) }
        var used = Set<String>()
        var out: [(String, [AreaMember])] = []
        for role in roles {
            let ms = app.areaMemberList.filter { m in
                m.role == role.roleID && !used.contains(m.uid)
            }
            if !ms.isEmpty {
                ms.forEach { used.insert($0.uid) }
                out.append(("\(role.name) - \(ms.count)", ms))
            }
        }
        let rest = app.areaMemberList.filter { !used.contains($0.uid) }
        if !rest.isEmpty { out.append(("全体成员 - \(rest.count)", rest)) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("成员 - \(max(app.areaMemberTotal, app.areaMemberList.count))")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.name) { group in
                        Text(group.name)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                            .padding(.leading, 14).padding(.top, 8)
                        ForEach(group.members) { m in
                            memberRow(m)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func memberRow(_ m: AreaMember) -> some View {
        let person = app.memberCache[m.uid]
        return HStack(spacing: 10) {
            AsyncOopzImage(url: person?.avatar, fallbackText: app.displayName(uid: m.uid))
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            Text(app.displayName(uid: m.uid))
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .task { await app.fetchMemberInfoIfNeeded(uid: m.uid) }
    }
}
