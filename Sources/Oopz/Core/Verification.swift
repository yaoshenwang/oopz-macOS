import Foundation
import AppKit

/// A small gate: protocol health is never advertised as media interoperability.
@MainActor
enum Verification {
    static func login(_ app: AppModel) async throws {
        app.ensurePrivateKey()
        guard SessionStore.loadPrivateKey() != nil else { throw OopzError.badPrivateKey }
        guard let saved = SessionStore.loadSession() else { throw OopzError.notLoggedIn }
        guard AccountLock.acquire(uid: saved.uid) else { throw OopzError.apiError("ACCOUNT_BUSY", "同账号已有运行实例") }
        app.api.session = saved
        try await app.api.curTime()
        app.api.session = try await app.api.autoLogin(saved)
        let me = try await app.api.selfDetail()
        app.api.session?.userCommonId = me.userCommonId
        guard let session = app.api.session, UInt32(session.userCommonId ?? "0") ?? 0 > 0 else { throw OopzError.apiError("IDENTITY", "无有效 RTC 身份") }
        SessionStore.saveSession(session)
    }
    static func ownRoom(_ app: AppModel) async throws -> (String, Channel) {
        await app.loadAreas()
        guard let area = app.areas.first(where: { $0.owner == app.api.session?.uid }) else { throw OopzError.apiError("NO_OWN_AREA", "测试未执行：没有自有域") }
        let groups = try await app.api.channels(area.id)
        guard let channel = groups.flatMap(\.channels).first(where: { $0.type == "VOICE" && $0.secret != true }) else { throw OopzError.apiError("NO_ROOM", "测试未执行：没有自有语音频道") }
        let members = try await app.api.membersByChannels(area.id, [channel.id])
        guard members[channel.id]?.isEmpty == true else { throw OopzError.apiError("ROOM_BUSY", "自有测试频道有人，未执行媒体测试") }
        app.currentAreaId = area.id; app.groups = groups
        return (area.id, channel)
    }
    static func run(_ app: AppModel) async {
        let started = Date()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) {
            checks.append(["name": name, "pass": ok]); print("\(ok ? "✅" : "❌") \(name)")
        }
        for (name, passed) in await SmokeTest.permissionChecks() { check(name, passed) }
        check("PCM 已知采样值与缓冲寿命", PCMConverter.selfTest())
        check("HTTP 200 业务拒绝不会当成功", (try? OopzAPI.validateEnvelope(["status": false])) == nil)
        check("缺失业务状态不会当成功", (try? OopzAPI.validateEnvelope(["data": true])) == nil)
        check("共享上报 data=false 拒绝", (try? OopzAPI.validateShareAcknowledgement(["status": true, "data": false])) == nil)
        check("共享上报缺失 data 拒绝", (try? OopzAPI.validateShareAcknowledgement(["status": true])) == nil)
        check("共享上报有效确认接受", (try? OopzAPI.validateShareAcknowledgement(["status": true, "data": true])) != nil)
        var phase: Double = 0
        let pcm = MediaSynth.sinePacket(phase: &phase)
        let rms = pcm.bytes.withUnsafeBytes { MediaSynth.rmsInt16(buffer: $0.baseAddress, samplesPerChannel: pcm.samplesPerChannel, channels: 2) }
        check("音频 RMS 仅进程内计算", abs(rms - MediaSynth.amplitude / sqrt(2)) < 0.01)
        do {
            try await login(app)
            check("签名、续期、身份", true)
            let (area, ch) = try await ownRoom(app)
            check("自有空频道前置条件", true)
            await app.openArea(area)
            app.ws.connect()
            let deadline = Date().addingTimeInterval(12)
            while !app.ws.connected && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            check("WebSocket 握手", app.ws.connected)
            await app.voice.join(channel: ch, app: app)
            check("生产语音入口等待 RTC 入会回调", app.voice.joined)
            let options = app.agora.makeOptions()
            check("无头音频隔离且语音房不发布屏幕", !options.publishScreenTrack && !options.publishMicrophoneTrack && !options.autoSubscribeAudio && !options.enableAudioRecordingOrPlayout)
            if app.voice.joined {
                let credentials = try await app.api.screenShareCredentials(channel: ch.id, sending: true, dimension: "", fps: 30)
                check("共享独立鉴权与房间", !credentials.roomId.isEmpty && credentials.roomId != app.voice.agoraRoomId)
                let members = try await app.api.membersByChannelsStates(area, [ch.id])
                check("成员快照含本人", members[ch.id]?.contains(where: { $0.uid == app.api.session?.uid }) == true)
                await app.voice.leave(app: app, playSound: false)
                let after = try await app.api.membersByChannels(area, [ch.id])
                check("离房后没有本人残留", after[ch.id] != nil && after[ch.id]?.contains(app.api.session!.uid) == false)
            }
        } catch { check("协议前置或运行失败", false) }
        await app.sharing.stop()
        if app.voice.joined { await app.voice.leave(app: app, playSound: false) }
        app.ws.disconnect()
        let passed = checks.allSatisfy { $0["pass"] as? Bool == true }
        writeResult(["gate": "protocol", "pass": passed, "checks": checks, "durationSeconds": Date().timeIntervalSince(started)], name: "protocol.json")
        print("==== protocol \(passed ? "PASS" : "FAIL")（不代表官方媒体验收） ====")
        _exit(passed ? 0 : 3)
    }
    static var resultDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OOPZ_TEST_RESULTS"] ?? "/tmp/oopz-verification", isDirectory: true)
    }
    static func writeResult(_ object: [String: Any], name: String) {
        try? FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var obj = object
        obj["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        obj["time"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: resultDir.appendingPathComponent(name), options: .atomic)
        }
    }
}
