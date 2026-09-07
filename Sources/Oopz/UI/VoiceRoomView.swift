import SwiftUI
import AppKit
import ScreenCaptureKit

/// 语音房区（严格对标官方）：频道标题行（麦克风圆图标 + 名称 + NN/上限 + 加入/邀请/分享）+ 共享横幅 + 成员大卡片网格。
/// 卡片：上部头像画、下部深色信息条（昵称 / 麦克风状态 / 耳机 / 红色出门键）；自己的卡片青蓝描边，说话绿描边。
struct VoiceRoomSection: View {
    @ObservedObject var app: AppModel
    let channel: Channel
    @Binding var showPicker: Bool
    @State private var showAudio = false

    private var members: [VoiceMember] {
        app.channelVoiceMembers[channel.id] ?? []
    }
    private var maxDisplay: String {
        let max = channel.settings?.maxMember ?? 50
        return max >= 2_000_000_000 ? "∞" : String(max)
    }
    private var inThisRoom: Bool {
        app.voice.joined && app.voice.channelId == channel.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 频道标题行
            HStack(spacing: 10) {
                Image(systemName: "mic.circle")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.textSecondary)
                Text(channel.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(String(format: "%02d", members.count) + "/" + maxDisplay)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.countGray)
                invitePill
                Spacer()
                if !inThisRoom {
                    // 显式加入入口（双击频道行之外的可见按钮）
                    Button {
                        Task { await app.voice.toggleJoin(channel: channel, app: app) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "phone.fill")
                            Text("加入语音")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("加入语音频道 \(channel.name)")
                    .disabled(app.voice.joining)
                } else {
                    Button { showAudio.toggle() } label: {
                        Label("音频", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAudio) { ShareAudioControls(app: app).frame(width: 340) }
                    // 屏幕共享入口（官方 Windows 客户端同款能力；Web 端被门控故截图里没有）
                    Button {
                        if app.voice.sharePhase.busy {
                            app.agora.stopScreenShare()
                            ScreenFloatPanelController.shared.hide()
                        } else if app.preflightScreenShare() {
                            showPicker = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: app.voice.shareActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                            Text(app.voice.sharePhase.busy ? (app.voice.shareActive ? "停止共享" : "取消共享") : "共享屏幕")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(app.voice.shareActive ? .white : Theme.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(app.voice.shareActive ? Theme.doorRed : Theme.card))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(app.voice.shareActive ? "停止屏幕共享" : "共享屏幕")
                    // 音质切换（64k/128k，持久化，下次进房沿用）
                    Menu {
                        ForEach(VoiceQuality.allCases) { q in
                            Button(q.label + (q == VoiceQuality.saved(uid: app.api.session?.uid) ? " ✓" : "")) {
                                app.agora.setVoiceQuality(q)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                            Text("音质")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("切换语音音质（当前 \(VoiceQuality.saved(uid: app.api.session?.uid).label)）")
                    HStack(spacing: 5) {
                        Circle().fill(Theme.speaking).frame(width: 6, height: 6)
                        Text("语音中")
                            .font(.system(size: 11)).foregroundColor(Theme.speaking)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)

            // 共享横幅：频道内他人共享（event 33 聚合），可手动（重新）观看
            if !app.voice.shareStates.isEmpty {
                VStack(spacing: 6) {
                    ForEach(app.voice.shareStates.values.sorted { $0.uid < $1.uid }) { s in
                        shareBanner(s)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 10)
            }

            // 成员卡片网格
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 300), spacing: 16)], spacing: 16) {
                    ForEach(members) { m in
                        VoiceMemberCard(app: app, member: m, channel: channel)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 16)
            }
        }
    }

    private func shareBanner(_ s: VoiceState.ShareState) -> some View {
        let agoraUid = app.agoraUid(ofOopzUid: s.uid)
        let watching = agoraUid != nil && app.voice.watchingUid == agoraUid
        return HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.accent)
            Text("\(s.name) 正在共享屏幕\(s.dimensions.isEmpty ? "" : " · \(s.dimensions)")")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            if let agoraUid {
                Button(watching ? "观看中" : "观看") {
                    if watching {
                        WatchWindowController.shared.close()
                        app.voice.watchingUid = nil
                    } else {
                        // 手动打开（覆盖"本会话不再自动弹出"标记）
                        app.voice.watchingUid = agoraUid
                        WatchWindowController.shared.show(app: app, uid: agoraUid)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(watching ? Theme.textSecondary : Theme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
    }

    private var invitePill: some View {
        Button {
            Task { await app.copyInviteLink(channelId: channel.id) }
        } label: {
            Text("邀请/分享")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        }
        .buttonStyle(.plain)
        .help("生成官方邀请链接并复制")
    }
}

/// 官方同款语音成员大卡片；滑条只控制成员语音，共享声音在观看窗独立控制。
struct VoiceMemberCard: View {
    @ObservedObject var app: AppModel
    let member: VoiceMember
    let channel: Channel
    @State private var hover = false

    private var isSelf: Bool { member.uid == app.api.session?.uid }
    private var inThisRoom: Bool { app.voice.joined && app.voice.channelId == channel.id }
    private var memberAgoraUid: UInt32? { app.agoraUid(ofOopzUid: member.uid) }
    private var micStateText: String {
        guard member.muteKnown else { return "自由发言" }
        return member.muted ? "已闭麦" : "自由发言"
    }

    var body: some View {
        if !isSelf && inThisRoom, let agoraUid = memberAgoraUid {
            HoverVolumeSlider(title: "\(member.name) 音量", volume: userVolumeBinding(agoraUid), anchor: .overBottom, width: 220) {
                cardBody
            }
        } else {
            cardBody
        }
    }

    private func userVolumeBinding(_ agoraUid: UInt32) -> Binding<Int> {
        Binding(
            get: { app.voice.userVolumes[String(agoraUid)] ?? 100 },
            set: { app.agora.setUserVolume(agoraUid: agoraUid, volume: $0) })
    }

    private var cardBody: some View {
        VStack(spacing: 0) {
            // 上部：头像画
            AsyncOopzImage(url: member.avatar, fallbackText: member.name)
                .frame(height: 148)
                .frame(maxWidth: .infinity)
                .clipped()

            // 下部：深色信息条
            VStack(alignment: .leading, spacing: 8) {
                Text(member.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: member.muteKnown && member.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12))
                        .foregroundColor(member.muteKnown && member.muted ? Theme.doorRed : .white.opacity(0.85))
                    Text(micStateText)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                    Spacer()
                    if isSelf && inThisRoom {
                        Button {
                            app.agora.setMic(muted: !app.voice.micMuted)
                        } label: {
                            Image(systemName: app.voice.micMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 13))
                                .foregroundColor(app.voice.micMuted ? Theme.doorRed : .white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help(app.voice.micMuted ? "开启麦克风" : "关闭麦克风")
                        Button {
                            app.agora.setHeadset(muted: !app.voice.headsetMuted)
                        } label: {
                            Image(systemName: "headphones")
                                .font(.system(size: 13))
                                .foregroundColor(app.voice.headsetMuted ? Theme.danger : .white.opacity(0.85))
                                .overlay(
                                    Rectangle().fill(Theme.danger)
                                        .frame(width: 17, height: 1.5)
                                        .rotationEffect(.degrees(-32))
                                        .opacity(app.voice.headsetMuted ? 1 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(app.voice.headsetMuted ? "取消耳机静音" : "耳机静音")
                        Button {
                            Task { await app.voice.leave(app: app) }
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.doorRed)
                        }
                        .buttonStyle(.plain)
                        .help("退出频道")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.cardDark)
        }
        .frame(maxWidth: 300)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelf && inThisRoom ? Theme.selfBorder : (member.speaking ? Theme.speaking : Color.white.opacity(hover ? 0.14 : 0.05)),
                    lineWidth: (isSelf && inThisRoom) || member.speaking ? 2 : 1
                )
        )
        .onHover { hover = $0 }
    }
}

/// 共享发起选择器：屏幕 / 窗口两个 tab + 档位驱动的清晰度/帧率 + 系统声音开关。
/// 入口页完成权限检查；来源枚举失败区分真实拒绝与普通错误。
struct SharePickerView: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var displays: [DisplayItem] = []
    @State private var windows: [WindowItem] = []
    @State private var tab = 0
    @State private var loadError: String?
    @State private var selDims: String = ""
    @State private var selFps: Int = 15
    @State private var shareSystemAudio = false

    struct DisplayItem: Identifiable {
        let id: UInt32
        let name: String
        var image: NSImage?
    }
    struct WindowItem: Identifiable {
        let id: UInt32
        let name: String
        var image: NSImage?
    }

    private var dimsOptions: [(name: String, value: String)] { app.myShareTier?.dimensionOptions ?? [] }
    private var fpsOptions: [Int] { app.myShareTier?.framerateOptions ?? [15] }
    private var dimsLabel: String {
        dimsOptions.first { $0.value == selDims }?.name ?? (selDims == "HD" ? "原画" : "默认")
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("整个屏幕").tag(0)
                Text("窗口").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14).padding(.top, 14)

            // 画质选项（档位参数驱动；服务端锁定的选项自动隐藏——如 FREE 档无清晰度选择）
            if !fpsOptions.isEmpty || !dimsOptions.isEmpty {
                HStack(spacing: 12) {
                    if !dimsOptions.isEmpty {
                        Menu {
                            ForEach(dimsOptions, id: \.value) { o in
                                Button(o.name) { selDims = o.value }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.and.text.magnifyingglass").font(.system(size: 11))
                                Text("画质 \(dimsLabel)")
                            }
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Menu {
                        ForEach(fpsOptions, id: \.self) { f in
                            Button("\(f) 帧") { selFps = f }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "speedometer").font(.system(size: 11))
                            Text("\(selFps) 帧")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Toggle(isOn: $shareSystemAudio) {
                        Text("系统声音")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(tab != 0)
                    .help(tab == 0 ? "共享其他应用的系统声音；麦克风仍由语音频道控制" : "窗口共享暂不支持声音，请切换到「整个屏幕」")

                    Spacer()

                    if let vip = app.shareVip {
                        Text("\(vip.type) 档 · 观众上限 \(vip.peopleLimit)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider().overlay(Theme.card) }
            }

            if let loadError {
                VStack(spacing: 14) {
                    Text(loadError).foregroundColor(Theme.textSecondary)
                    Button("重试") { Task { await load() } }
                }.frame(minWidth: 360, minHeight: 300)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        if tab == 0 {
                            ForEach(displays) { d in
                                ShareCell(name: d.name, image: d.image) {
                                    dismiss()
                                    startShare(displayId: d.id)
                                }
                            }
                        } else {
                            ForEach(windows) { w in
                                ShareCell(name: w.name, image: w.image) {
                                    dismiss()
                                    startShare(windowId: w.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(minHeight: 300)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(12)
        }
        .background(Theme.panel)
        .onChange(of: tab) { _, value in if value != 0 { shareSystemAudio = false } }
        .task {
            await app.loadShareOptions()
            // 预选默认：清晰度取 isDefault，帧率取 isDefault
            if let tier = app.myShareTier {
                if let d = tier.params.first(where: { $0.paramType == "DIMENSIONS" && $0.active && $0.isDefault }) {
                    selDims = d.paramValue
                } else if let first = tier.dimensionOptions.first {
                    selDims = first.value
                }
                if let f = tier.params.first(where: { $0.paramType == "FRAMERATE" && $0.active && $0.isDefault }),
                   let v = Int(f.paramValue) {
                    selFps = v
                } else if let first = tier.framerateOptions.first {
                    selFps = first
                }
            }
            await load()
        }
    }

    private func startShare(displayId: UInt32? = nil, windowId: UInt32? = nil) {
        let dims = ScreenShareTier.parseDimensions(selDims)
        // 采集启动成功才进入"共享中"（悬浮条/状态位）
        Task { @MainActor in
            if await app.agora.startScreenShare(displayId: displayId, windowId: windowId,
                                                dimensions: dims, frameRate: selFps,
                                                systemAudio: windowId == nil && shareSystemAudio, dimensionValue: selDims) {
                dismiss()
            }
        }
    }

    private func load() async {
        guard app.voice.joined, app.permissions.ready else { return }
        loadError = nil
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if PermissionCenter.isScreenPermissionError(error) {
                app.permissions.recordScreenFailure(error)
                dismiss()
            } else {
                let e = error as NSError
                loadError = "无法读取共享来源：\(e.domain) (\(e.code))，请重试。"
            }
            return
        }
        if content.displays.isEmpty && content.windows.isEmpty {
            loadError = "当前没有可共享的屏幕或窗口，请解锁屏幕后重试。"
            return
        }
        let mainId = CGMainDisplayID()
        displays = content.displays.enumerated().map { _, d in
            DisplayItem(id: d.displayID, name: d.displayID == mainId ? "主屏" : "屏幕 \(d.displayID)", image: nil)
        }
        windows = content.windows
            .filter { w in (w.title ?? "").count > 0 && (w.frame.width > 120 && w.frame.height > 80) }
            .prefix(40)
            .map { WindowItem(id: $0.windowID, name: $0.title ?? "窗口", image: nil) }
        // 异步取缩略图
        let disp = content.displays
        let win = Array(content.windows.filter { w in (w.title ?? "").count > 0 && (w.frame.width > 120 && w.frame.height > 80) }.prefix(40))
        let cfg = SCStreamConfiguration()
        cfg.width = 600
        cfg.height = 360
        cfg.showsCursor = false
        Task.detached {
            for (i, d) in disp.enumerated() {
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) {
                    let ns = NSImage(cgImage: img, size: NSSize(width: 300, height: 180))
                    await MainActor.run { if i < displays.count { displays[i].image = ns } }
                }
            }
            for (idx, w) in win.enumerated() {
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) {
                    let ns = NSImage(cgImage: img, size: NSSize(width: 300, height: 180))
                    await MainActor.run { if idx < windows.count { windows[idx].image = ns } }
                }
            }
        }
    }
}

struct ShareCell: View {
    let name: String
    let image: NSImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4))
                        .aspectRatio(16/10, contentMode: .fit)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(maxWidth: .infinity).aspectRatio(16/10, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "display").foregroundColor(Theme.textTertiary)
                    }
                }
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.cardHover : Theme.card))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
