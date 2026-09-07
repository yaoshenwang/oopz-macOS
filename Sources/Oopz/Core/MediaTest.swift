import Foundation

/// Local publisher integration. The official Web picture check remains a separate manual gate.
enum MediaTest {
    static func isRequested() -> Bool { CommandLine.arguments.contains("--media-test") }
    @MainActor
    static func run(app: AppModel) async {
        let started = Date()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) {
            checks.append(["name": name, "pass": ok]); print("\(ok ? "✅" : "❌") \(name)")
        }
        do {
            try await Verification.login(app)
            let (area, channel) = try await Verification.ownRoom(app)
            await app.openArea(area)
            await app.voice.join(channel: channel, app: app)
            guard app.voice.joined else { throw OopzError.apiError("JOIN", "发布者进房失败") }
            let uid = app.api.session!.uid
            func state(_ open: Bool) async throws -> Bool {
                try await app.api.confirmScreenShareState(areaId: area, channelId: channel.id, uid: uid, open: open)
                return true
            }
            let bad = await app.sharing.start(fps: 999, pattern: true)
            check("参数失败不显示共享成功", !bad && !app.voice.shareActive && app.voice.sharePhase == .failed)
            let first = await app.sharing.start(pattern: true)
            check("生产发布入口：独立共享房间、发布回调、OPEN", first && app.sharing.publishConfirmed && app.sharing.roomId != app.voice.agoraRoomId && !app.sharing.roomId.isEmpty)
            check("成员快照 OPEN", try await state(true))
            await app.sharing.stop()
            check("停止后 CLOSE 且仍在语音房", try await state(false) && !app.voice.shareActive && app.voice.joined && app.sharing.roomId.isEmpty)
            let pending = Task { await app.sharing.start(pattern: true) }
            try await Task.sleep(nanoseconds: 50_000_000)
            await app.sharing.stop()
            _ = await pending.value
            check("启动中取消不会迟到 OPEN", try await state(false) && !app.voice.shareActive && app.voice.sharePhase == .idle)
            let second = await app.sharing.start(pattern: true)
            check("停止/取消后可重新发布", second && app.voice.shareActive && app.sharing.publishConfirmed)
            await app.sharing.stop()
            check("第二次停止清理完整", try await state(false) && app.sharing.roomId.isEmpty)
            await app.voice.leave(app: app, playSound: false)
            let after = try await app.api.membersByChannels(area, [channel.id])
            check("离房无残留", after[channel.id] != nil && after[channel.id]?.contains(uid) == false)
        } catch { check("发布端前置或运行失败", false) }
        await app.sharing.stop()
        if app.voice.joined { await app.voice.leave(app: app, playSound: false) }
        app.ws.disconnect()
        let passed = checks.allSatisfy { $0["pass"] as? Bool == true }
        Verification.writeResult(["gate": "publisher", "pass": passed, "source": "synthetic-video",
            "checks": checks, "durationSeconds": Date().timeIntervalSince(started),
            "officialWeb": "pending-manual", "physicalCapture": "not-tested"], name: "publisher.json")
        print("==== publisher \(passed ? "PASS" : "FAIL")；官方 Web 实际画面待人工验收 ====")
        _exit(passed ? 0 : 3)
    }
}
