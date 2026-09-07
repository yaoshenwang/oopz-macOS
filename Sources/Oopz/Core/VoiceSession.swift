import Foundation
import AppKit

/// 语音进/离房编排（严格对齐官方语义）：
/// 进房 = REST enterVoiceChannel(pid=userCommonId) → Agora join → 本地把自己插入成员表；
/// 离房 = 退出音效 → REST removeFromChannel（失败重试一次）→ Agora leave → 本地把自己移除（官方不给自己广播 event 19）。
extension VoiceState {
    /// 双击语音频道 / 加入按钮：进/离房
    func toggleJoin(channel: Channel, app: AppModel) async {
        if joined && channelId == channel.id {
            await leave(app: app)
        } else {
            await join(channel: channel, app: app)
        }
    }

    func join(channel: Channel, app: AppModel) async {
        guard RunMode.headless || app.permissions.ready else { return }
        guard !joining, let sessionUid = app.api.session?.uid else { return }
        joining = true
        defer { joining = false }
        guard let areaId = app.currentAreaId else { return }
        // 已在别的频道：先完整离开旧的（官方为"切换房间"）
        if joined {
            await leave(app: app, playSound: false)
        }
        var entered = false
        do {
            // 密码频道：弹官方风格密码框，密码错误（ERR.003.00011）最多重试 3 次
            var result: ChannelEnterResult?
            if channel.secret == true {
                for _ in 0..<3 {
                    let password = promptChannelPassword(channel.name)
                    if password.isEmpty { return }   // 用户取消
                    do {
                        result = try await app.api.enterVoiceChannel(areaId: areaId, channelId: channel.id, password: password)
                        break
                    } catch let e as OopzError {
                        if case let .apiError(code, _) = e, code.contains("00011") {
                            app.showToast("密码错误，请重试")
                            continue
                        }
                        throw e
                    }
                }
                guard result != nil else { return }
            } else {
                result = try await app.api.enterVoiceChannel(areaId: areaId, channelId: channel.id)
            }
            guard let result else { return }
            entered = true
            self.areaId = areaId
            channelId = channel.id
            channelName = channel.name
            guard let room = result.roomId, !room.isEmpty, let token = result.supplierSign, !token.isEmpty else { throw OopzError.apiError("RTC_CREDENTIALS", "语音凭据不完整") }
            agoraRoomId = room
            agoraToken = token
            let common = Int64(app.api.session?.userCommonId ?? "0") ?? 0
            agoraUid = UInt32(truncatingIfNeeded: common)
            micMuted = true
            guard RunMode.headless || app.permissions.ready else { throw CancellationError() }
            try await app.agora.joinRoom(app: app)
            guard app.api.session?.uid == sessionUid, (RunMode.headless || app.screen != .login) else { throw CancellationError() }
            joined = true
            upsertSelf(app: app)
            Sounds.voiceEnter()
            app.showToast("已进入 \(channel.name)")
            await app.refreshVoiceMembersOfCurrentArea()
        } catch {
            // REST 已进房但后续失败：补 REST 退房，避免服务端幽灵成员
            if entered {
                try? await app.api.leaveVoiceChannel(areaId: areaId, channelId: channel.id)
            }
            await app.agora.leaveRoom()
            reset()
            app.showToast("进房失败: \(error.localizedDescription)")
        }
    }

    /// 密码频道输入框
    private func promptChannelPassword(_ name: String) -> String {
        let alert = NSAlert()
        alert.messageText = "「\(name)」已加密"
        alert.informativeText = "请输入频道密码"
        alert.alertStyle = .informational
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        return result == .alertFirstButtonReturn ? input.stringValue : ""
    }

    /// 离开当前语音频道（挂断 / 出门按钮 / 双击当前频道）
    func leave(app: AppModel, playSound: Bool = true) async {
        guard joined else { return }
        let area = areaId
        let ch = channelId
        if playSound { Sounds.voiceExit() }
        await app.sharing.stop()
        await app.sharing.closeWatch()
        ScreenFloatPanelController.shared.hide()
        // REST 退房（官方：DELETE removeFromChannel；失败重试一次）
        for _ in 0..<2 {
            if (try? await app.api.leaveVoiceChannel(areaId: area, channelId: ch)) != nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // 引擎离房
        await app.agora.leaveRoom()
        app.clearSpeakingTimers()
        reset()
        // 官方不给自己的离开广播 event 19：本地即时移除
        app.channelVoiceMembers[ch] = app.channelVoiceMembers[ch]?.filter { $0.uid != app.api.session?.uid }
    }

    /// 进房成功后立刻把自己插入成员表（不依赖 event 20 回流）
    func upsertSelf(app: AppModel) {
        guard let uid = app.api.session?.uid else { return }
        let nick = app.memberNicknames[uid] ?? ""
        let selfName = !nick.isEmpty ? nick
            : ((app.memberCache[uid]?.name ?? app.api.session?.name).flatMap { !$0.isEmpty ? $0 : nil }
               ?? String(uid.prefix(6)))
        let selfMember = VoiceMember(
            uid: uid,
            name: selfName,
            avatar: app.memberCache[uid]?.avatar ?? app.api.session?.avatar,
            muted: micMuted,
            muteKnown: true)
        var list = app.channelVoiceMembers[channelId] ?? []
        if !list.contains(where: { $0.uid == uid }) {
            list.append(selfMember)
        } else {
            list = list.map { $0.uid == uid ? selfMember : $0 }
        }
        app.channelVoiceMembers[channelId] = list
    }
}
