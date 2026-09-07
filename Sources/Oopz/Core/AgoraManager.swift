import Foundation
import AppKit
import AgoraRtcKit

/// 语音音质档位（Agora 枚举实测映射；官方 Web 有 192k 档，macOS 原生 SDK 上限 128k 立体声）
enum VoiceQuality: String, CaseIterable, Identifiable {
    case smooth = "64k"     // 流畅：48kHz 单声道 64kbps（官方默认）
    case hifi = "128k"      // 高保真：48kHz 立体声 128kbps

    var id: String { rawValue }
    var label: String { self == .hifi ? "高保真 128k" : "流畅 64k" }
    var profile: AgoraAudioProfile { self == .hifi ? .musicHighQualityStereo : .musicStandard }

    static func saved(uid: String?) -> VoiceQuality {
        let key = SessionStore.prefKey("oopz_voice_quality", uid: uid)
        if let q = VoiceQuality(rawValue: UserDefaults.standard.string(forKey: key) ?? "") { return q }
        return VoiceQuality(rawValue: UserDefaults.standard.string(forKey: "oopz_voice_quality") ?? "") ?? .smooth
    }
    func save(uid: String?) {
        UserDefaults.standard.set(rawValue, forKey: SessionStore.prefKey("oopz_voice_quality", uid: uid))
    }
}

/// Agora 连麦引擎封装：进房/上麦/静音 datastream/音量回调/屏幕视频流
final class AgoraManager: NSObject, AgoraRtcEngineDelegate {
    // 说明：SDK 回调来自 Agora 线程，内部全部经 Task { @MainActor } 跳回主线程
    private weak var app: AppModel?
    private var engine: AgoraRtcEngineKit?
    private var streamId: Int = -1
    @MainActor var smokeCompletion: ((Bool) -> Void)?
    private var persistVolumeTask: Task<Void, Never>?
    private var videoEnabled = false
    /// duo-test 观察钩子（主线程）：远端音视频/成员/音量/流消息事件
    @MainActor var duoRecorder: ((String, String) -> Void)?
    /// media-test：把音量指示转给合成观测（自定义轨 PCM observer 偶尔吃不到）
    weak var mediaProbe: MediaProbe?
    /// media-test：本端视频是否已进入编码态（state=2）——屏幕轨发布成功的硬信号
    @MainActor var mediaLocalVideoEncoded = false

    @MainActor
    init(appModel: AppModel) {
        self.app = appModel
        super.init()
    }

    // MARK: 引擎生命周期

    @MainActor
    private func ensureEngine() throws -> AgoraRtcEngineKit {
        if let engine { return engine }
        let config = AgoraRtcEngineConfig()
        config.appId = OopzAPI.agoraAppID
        config.areaCode = .CN
        // duo 双进程同写 ~/Library/Logs/agorasdk.log 会 spdlog fatal；按 pid 拆文件
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logCfg = AgoraLogConfig()
        logCfg.filePath = logDir.appendingPathComponent("agorasdk-\(ProcessInfo.processInfo.processIdentifier).log").path
        config.logConfig = logCfg
        let engine = AgoraRtcEngineKit.sharedEngine(with: config, delegate: self)
        // logConfig 只管 agorasdk.log；agoraapi.log 仍走默认路径，duo 双进程会 spdlog fatal。
        // setLogFile 把整套 SDK 日志（含 api）切到 pid 文件。
        _ = engine.setLogFile(logDir.appendingPathComponent("agorasdk-\(ProcessInfo.processInfo.processIdentifier).log").path)
        engine.setChannelProfile(.liveBroadcasting)
        engine.setClientRole(.broadcaster)
        if RunMode.headless { engine.disableAudio() } else { engine.enableAudio() }
        engine.setAudioProfile(VoiceQuality.saved(uid: app?.api.session?.uid).profile)
        engine.enableAudioVolumeIndication(150, smooth: 3, reportVad: true)
        engine.setAudioScenario(.chatRoom)
        engine.muteLocalAudioStream(true)
        if RunMode.headless {
            engine.adjustPlaybackSignalVolume(0)
            engine.muteAllRemoteAudioStreams(true)
        }
        self.engine = engine
        return engine
    }

    /// 从当前 VoiceState 推导媒体选项（唯一事实源）。watchOnly = 仅订阅。
    /// 麦克风轨**始终发布**（官方桌面同款）：可听性只由 muteLocalAudioStream 控制。
    /// 实测（duo T1b）：入会时 publish=false 再靠 updateChannel 动态开，macOS SDK 不会启动采集。
    @MainActor
    func makeOptions(watchOnly: Bool = false) -> AgoraRtcChannelMediaOptions {
        let options = AgoraRtcChannelMediaOptions()
        let v = app?.voice
        options.autoSubscribeAudio = !RunMode.headless && !(v?.headsetMuted ?? false)
        options.enableAudioRecordingOrPlayout = !RunMode.headless
        options.autoSubscribeVideo = false
        options.publishCameraTrack = false
        options.publishScreenCaptureAudio = false
        options.publishMediaPlayerAudioTrack = false
        if watchOnly {
            options.publishMicrophoneTrack = false
            options.publishScreenTrack = false
            options.publishCustomAudioTrack = false
            return options
        }
        options.publishMicrophoneTrack = !RunMode.headless
        options.publishScreenTrack = false
        options.publishCustomAudioTrack = false
        return options
    }

    @MainActor
    private func applyOptions(watchOnly: Bool = false) {
        engine?.updateChannel(with: makeOptions(watchOnly: watchOnly))
    }

    /// 入会成功后重放闭麦 / 耳机 / 音量 / 共享轨。
    /// 麦克风可听性唯一开关 = muteLocalAudioStream（轨本身始终发布）。
    @MainActor
    private func applyJoinMediaState() {
        guard let engine, let app else { return }
        engine.muteLocalAudioStream(RunMode.headless || app.voice.micMuted)
        engine.muteAllRemoteAudioStreams(RunMode.headless || app.voice.headsetMuted)
        applyOptions()
        applySavedVolumes()
        createDataStreamIfNeeded(engine)
        sendMuteData(m: app.voice.micMuted, hm: app.voice.headsetMuted)
    }

    /// 运行中切换音质（立即生效于后续编码；持久化）
    @MainActor
    func setVoiceQuality(_ q: VoiceQuality) {
        engine?.setAudioProfile(q.profile)
        q.save(uid: app?.api.session?.uid)
        app?.showToast("音质已切换：\(q.label)")
        app?.log("voice quality -> \(q.rawValue)")
    }

    /// 测试钩子：无头验证用（引擎创建 + 音质切换，不进频道无采集副作用）
    @MainActor
    func testEngine() throws -> AgoraRtcEngineKit {
        try ensureEngine()
    }

    /// 拆引擎：只异步离房，不调 destroy()。
    func teardown() {
        guard let engine else { return }
        self.engine = nil
        engine.leaveChannel(nil)
    }

    // MARK: 进/离房

    @MainActor
    func joinRoom(app: AppModel) async throws {
        guard await smokeJoin(app: app) else { throw OopzError.apiError("RTC_TIMEOUT", "语音连接超时") }
    }

    /// 同步入会（供冒烟测试复用）。媒体选项随 join 一起提交，避免入会瞬间热麦。
    @MainActor
    @discardableResult
    func joinChannelNow(app: AppModel) throws -> Bool {
        let t0 = Date()
        let v = app.voice
        guard v.agoraUid != 0 else {
            app.log("agora join aborted: userCommonId missing")
            app.showToast("进房失败：账号缺少语音身份（userCommonId）")
            throw OopzError.apiError("RTC_ID", "账号缺少语音身份")
        }
        let engine = try ensureEngine()
        app.log("agora engine ready in \(Int(-t0.timeIntervalSinceNow*1000))ms")
        engine.muteLocalAudioStream(true)
        let options = makeOptions()
        app.log("agora calling joinChannel uid=\(UInt(v.agoraUid)) ch=\(v.agoraRoomId) micPub=always(muted=\(v.micMuted)) screen=\(options.publishScreenTrack)")
        let rc = engine.joinChannel(byToken: v.agoraToken, channelId: v.agoraRoomId, uid: UInt(v.agoraUid), mediaOptions: options) { [weak self] _, uid, elapsed in
            self?.app?.log("agora joinSuccess callback uid=\(uid) elapsed=\(elapsed)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyJoinMediaState()
                if let cb = self.smokeCompletion {
                    cb(true)
                    self.smokeCompletion = nil
                }
            }
        }
        if rc != 0 {
            throw OopzError.apiError("RTC_JOIN_\(rc)", "语音连接失败")
        }
        return true
    }

    /// token 过期自动恢复：同参数重新入会（保持闭麦/共享状态）
    @MainActor
    func rejoinChannel(app: AppModel) async throws {
        guard engine != nil else { return }
        await leaveRoom()
        streamId = -1
        try await joinRoom(app: app)
    }

    /// 仅引擎侧离房（房间状态/音效/REST 退房由 VoiceState.leave 编排）。
    @MainActor
    func leaveRoom() async {
        await app?.sharing.stop()
        await app?.sharing.closeWatch()
        guard let engine else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            engine.leaveChannel { [weak self] _ in
                DispatchQueue.main.async {
                    guard !resumed else { return }
                    resumed = true
                    self?.streamId = -1
                    cont.resume()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
        }
    }

    // MARK: 麦克风（对齐官方 datastream 语义：{m,uid,cid,hm}）

    @MainActor
    func setMic(muted: Bool) {
        guard let app, let engine else { return }
        guard muted || RunMode.headless || app.permissions.ready else { return }
        app.log("setMic muted=\(muted)")
        app.voice.micMuted = muted
        applyOptions()
        engine.muteLocalAudioStream(RunMode.headless || muted)
        app.applySelfMuteState()
        if muted { Sounds.micMute() } else { Sounds.micUnmute() }
        sendMuteData(m: muted, hm: app.voice.headsetMuted)
    }

    @MainActor
    func setHeadset(muted: Bool) {
        guard let app else { return }
        engine?.muteAllRemoteAudioStreams(RunMode.headless || muted)
        app.voice.headsetMuted = muted
        app.sharing.applyPlaybackState()
        applyOptions()
        if muted { Sounds.headsetMute() } else { Sounds.headsetUnmute() }
        sendMuteData(m: app.voice.micMuted, hm: muted)
    }

    // MARK: 音量（0–400，100=原始音量）

    static let micVolumeKey = "oopz_mic_volume"
    static let playbackVolumeKey = "oopz_playback_volume"
    static let userVolumesKey = "oopz_user_volumes"

    @MainActor
    private func volumeKey(_ base: String) -> String {
        SessionStore.prefKey(base, uid: app?.api.session?.uid)
    }

    /// 持久化的单人音量表（key = Agora uid 字符串）
    static func loadSavedUserVolumes(uid: String? = nil) -> [String: Int] {
        let key = SessionStore.prefKey(userVolumesKey, uid: uid)
        if let data = UserDefaults.standard.data(forKey: key),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            return dict
        }
        // 兼容未分账号的旧键
        if uid != nil,
           let data = UserDefaults.standard.data(forKey: userVolumesKey),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            return dict
        }
        return [:]
    }

    /// 麦克风采音音量。拖动时只打 Agora，去抖后再写 UserDefaults / @Published，避免整页重绘打断滑条。
    @MainActor
    func setMicVolume(_ v: Int, persist: Bool = true) {
        engine?.adjustRecordingSignalVolume(v)
        app?.voice.micVolume = v
        if persist { schedulePersistVolumes() }
    }

    @MainActor
    func setPlaybackVolume(_ v: Int, persist: Bool = true) {
        engine?.adjustPlaybackSignalVolume(RunMode.headless ? 0 : v)
        app?.voice.playbackVolume = v
        if persist { schedulePersistVolumes() }
    }

    @MainActor
    func setUserVolume(agoraUid uid: UInt32, volume v: Int, persist: Bool = true) {
        engine?.adjustUserPlaybackSignalVolume(UInt(uid), volume: Int32(clamping: v))
        app?.voice.userVolumes[String(uid)] = v
        app?.sharing.applyPlaybackState()
        if persist { schedulePersistVolumes() }
    }

    @MainActor
    private func schedulePersistVolumes() {
        persistVolumeTask?.cancel()
        persistVolumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.writeVolumeDefaults()
            self.persistVolumeTask = nil
        }
    }

    /// 立刻落盘（冒烟/切号用）：取消去抖窗口，把当前内存值写成偏好。
    @MainActor
    func persistVolumesNow() {
        persistVolumeTask?.cancel()
        persistVolumeTask = nil
        writeVolumeDefaults()
    }

    @MainActor
    private func writeVolumeDefaults() {
        guard let app else { return }
        UserDefaults.standard.set(app.voice.micVolume, forKey: volumeKey(Self.micVolumeKey))
        UserDefaults.standard.set(app.voice.playbackVolume, forKey: volumeKey(Self.playbackVolumeKey))
        if let data = try? JSONEncoder().encode(app.voice.userVolumes) {
            UserDefaults.standard.set(data, forKey: volumeKey(Self.userVolumesKey))
        }
    }

    /// 进房/重连后恢复持久化音量（Agora 的音量调节不跨入会保留）
    @MainActor
    func applySavedVolumes() {
        guard let engine else { return }
        if RunMode.headless { engine.disableAudio(); return }
        // 去抖窗口内是用户正在拖的值：只把内存态打进引擎，禁止用磁盘旧值盖掉。
        // 否则入会回调（didJoinChannel 可能晚于 joinSuccess）会把刚设的音量打回 100，
        // 随后去抖任务再把 100 落盘——冒烟「音量持久化」就是这么挂的。
        if persistVolumeTask != nil {
            if let app {
                engine.adjustRecordingSignalVolume(app.voice.micVolume)
                engine.adjustPlaybackSignalVolume(app.voice.playbackVolume)
                for (k, v) in app.voice.userVolumes {
                    if let u = UInt(k) { engine.adjustUserPlaybackSignalVolume(u, volume: Int32(clamping: v)) }
                }
            }
            return
        }
        let uid = app?.api.session?.uid
        let mvKey = SessionStore.prefKey(Self.micVolumeKey, uid: uid)
        let pvKey = SessionStore.prefKey(Self.playbackVolumeKey, uid: uid)
        let mv = (UserDefaults.standard.object(forKey: mvKey) as? Int)
            ?? (UserDefaults.standard.object(forKey: Self.micVolumeKey) as? Int) ?? 100
        let pv = (UserDefaults.standard.object(forKey: pvKey) as? Int)
            ?? (UserDefaults.standard.object(forKey: Self.playbackVolumeKey) as? Int) ?? 100
        engine.adjustRecordingSignalVolume(mv)
        engine.adjustPlaybackSignalVolume(pv)
        let all = Self.loadSavedUserVolumes(uid: uid)
        for (k, v) in all {
            if let u = UInt(k) { engine.adjustUserPlaybackSignalVolume(u, volume: Int32(clamping: v)) }
        }
        if let app {
            app.voice.micVolume = mv
            app.voice.playbackVolume = pv
            app.voice.userVolumes = all
        }
    }

    @MainActor
    func sendMuteData(m: Bool, hm: Bool) {
        guard let app, let engine, streamId >= 0 else { return }
        let uid = app.api.session?.uid ?? ""
        let cid = app.voice.agoraUid
        let msg = "{\"m\":\(m ? 1 : 0),\"uid\":\"\(uid)\",\"cid\":\(cid),\"hm\":\(hm ? 1 : 0)}"
        engine.sendStreamMessage(streamId, data: Data(msg.utf8))
    }

    @MainActor
    private func createDataStreamIfNeeded(_ engine: AgoraRtcEngineKit) {
        guard streamId < 0 else { return }
        var id: Int = -1
        let config = AgoraDataStreamConfig()
        config.syncWithAudio = true
        config.ordered = false
        let rc = engine.createDataStream(&id, config: config)
        if rc == 0 { streamId = id }
        sendMuteData(m: app?.voice.micMuted ?? true, hm: app?.voice.headsetMuted ?? false)
    }

    // MARK: 屏幕共享

    @MainActor
    @discardableResult
    func startScreenShare(displayId: UInt32? = nil, windowId: UInt32? = nil,
                          dimensions: CGSize? = nil, frameRate: Int? = nil,
                          systemAudio: Bool = false, dimensionValue: String? = nil) async -> Bool {
        guard let app else { return false }
        let value = dimensionValue ?? dimensions.map { "\(Int($0.width))x\(Int($0.height))" } ?? ""
        return await app.sharing.start(displayId: displayId, windowId: windowId,
            dimension: value, fps: frameRate ?? 30, systemAudio: systemAudio)
    }
    @MainActor
    func stopScreenShare(notifyServer: Bool = true) {
        guard let app else { return }
        Task { await app.sharing.stop() }
    }
    @MainActor
    func setupRemoteVideo(uid: UInt32, view: NSView) {
        guard let app else { return }
        Task { await app.sharing.receive(uid: uid, view: view) }
    }

    @MainActor
    func setupLocalPreview(view: NSView) {
        guard let engine else { return }
        let canvas = AgoraRtcVideoCanvas()
        canvas.view = view
        canvas.uid = 0
        engine.setupLocalVideo(canvas)
        engine.startPreview()
    }

    @MainActor
    func clearLocalPreview() {
        let canvas = AgoraRtcVideoCanvas()
        canvas.view = nil
        canvas.uid = 0
        engine?.setupLocalVideo(canvas)
        engine?.stopPreview()
    }

    @MainActor
    func clearRemoteVideo(uid: UInt32) {
        guard let app else { return }
        Task { await app.sharing.closeWatch(uid: uid) }
    }

    // MARK: - AgoraRtcEngineDelegate

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.app?.log("agora remote joined uid=\(uid)")
            self.duoRecorder?("remote_joined", "uid=\(uid)")
            if let v = self.app?.voice.userVolumes[String(uid)] {
                engine.adjustUserPlaybackSignalVolume(uid, volume: Int32(clamping: v))
            }
            // 对方后进房：重发自己的静音快照，避免对方永远「未知/自由发言」
            if let app = self.app {
                self.sendMuteData(m: app.voice.micMuted, hm: app.voice.headsetMuted)
            }
        }
    }

    /// 远端音频轨状态（热麦断言的核心信号：闭麦=对方根本不应看到 starting/decoding）
    func rtcEngine(_ engine: AgoraRtcEngineKit, remoteAudioStateChangedOfUid uid: UInt, state: AgoraAudioRemoteState, reason: AgoraAudioRemoteReason, elapsed: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.duoRecorder?("remote_audio", "uid=\(uid) state=\(state.rawValue) reason=\(reason.rawValue)")
        }
    }

    /// 观看模式入会（仅订阅）
    @MainActor
    func watchJoin(app: AppModel) {
        guard let engine = try? ensureEngine() else { return }
        let v = app.voice
        engine.enableVideo()
        videoEnabled = true
        let options = makeOptions(watchOnly: true)
        _ = engine.joinChannel(byToken: v.agoraToken, channelId: v.agoraRoomId, uid: UInt(v.agoraUid), mediaOptions: options, joinSuccess: nil)
        applySavedVolumes()
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        Task { @MainActor [weak self] in
            guard let self, let app = self.app else { return }
            self.duoRecorder?("remote_offline", "uid=\(uid) reason=\(reason.rawValue)")
            if app.voice.watchingUid == UInt32(truncatingIfNeeded: uid) {
                app.voice.watchingUid = nil
                WatchWindowController.shared.close()
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, localVideoStateChangedOf state: AgoraVideoLocalState, reason: AgoraLocalVideoStreamReason, sourceType: AgoraVideoSourceType) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.app?.log("local video state=\(state.rawValue) reason=\(reason.rawValue) src=\(sourceType.rawValue)")
            if state == .encoding, sourceType == .screen {
                self.mediaLocalVideoEncoded = true
            }
            self.app?.sharing.localVideo(state: state, source: sourceType)
        }
    }

    /// 远端视频流 = 对方正在共享屏幕 → 打开观看窗
    func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStateChangedOfUid uid: UInt, state: AgoraVideoRemoteState, reason: AgoraVideoRemoteReason, elapsed: Int) {
        Task { @MainActor [weak self] in
            guard let self, let app = self.app else { return }
            guard uid != UInt(app.voice.agoraUid) else { return }
            app.log("remote video uid=\(uid) state=\(state.rawValue) reason=\(reason.rawValue)")
            self.duoRecorder?("remote_video", "uid=\(uid) state=\(state.rawValue) reason=\(reason.rawValue)")
            // Voice-room video is not an OOPZ sharing announcement. Discovery uses event 33/snapshots.
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, receiveStreamMessageFromUid uid: UInt, streamId sid: Int, data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetUid = obj["uid"] as? String else { return }
        let m = (obj["m"] as? Int) ?? -1
        let hm = (obj["hm"] as? Int) ?? -1
        Task { @MainActor [weak self] in
            guard let self, let app = self.app else { return }
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "?"
            self.duoRecorder?("streammsg", "from=\(uid) \(preview)")
            for (cid, list) in app.channelVoiceMembers {
                var l = list
                var changed = false
                for i in l.indices where l[i].uid == targetUid {
                    if m >= 0 && (l[i].muted != (m == 1) || !l[i].muteKnown) {
                        l[i].muted = m == 1
                        l[i].muteKnown = true
                        changed = true
                    }
                    if hm >= 0 && l[i].headsetMuted != (hm == 1) {
                        l[i].headsetMuted = hm == 1
                        changed = true
                    }
                }
                if changed { app.channelVoiceMembers[cid] = l }
            }
            if targetUid == app.api.session?.uid && m == 1 && !app.voice.micMuted {
                engine.muteLocalAudioStream(true)
                app.voice.micMuted = true
                app.applySelfMuteState()
                app.showToast("你已被禁麦")
            }
        }
    }

    /// 本地音频采集状态（duo 探针：采集起没起、失败原因，全在这）
    func rtcEngine(_ engine: AgoraRtcEngineKit, localAudioStateChanged state: AgoraAudioLocalState, reason: AgoraAudioLocalReason) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.app?.log("local audio state=\(state.rawValue) reason=\(reason.rawValue)")
            self.duoRecorder?("local_audio", "state=\(state.rawValue) reason=\(reason.rawValue)")
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, reportAudioVolumeIndicationOfSpeakers speakers: [AgoraRtcAudioVolumeInfo], totalVolume: Int) {
        Task { @MainActor [weak self] in
            guard let self, let app = self.app else { return }
            for s in speakers {
                if s.volume > 0 {
                    self.duoRecorder?("volume", "uid=\(s.uid) vol=\(s.volume)")
                }
                if s.volume > 30 {
                    app.updateSpeaking(uid: UInt32(truncatingIfNeeded: s.uid), on: true)
                }
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        Task { @MainActor [weak self] in self?.app?.log("agora conn state=\(state.rawValue) reason=\(reason.rawValue)") }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurWarning warningCode: AgoraWarningCode) {
        Task { @MainActor [weak self] in self?.app?.log("agora warning \(warningCode.rawValue)") }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        Task { @MainActor [weak self] in
            guard let app = self?.app else { return }
            app.log("agora error \(errorCode.rawValue)")
            switch errorCode {
            case .tokenExpired:
                await app.refreshRTC()
            case .invalidToken:
                app.handleRTCInvalidToken()
            default:
                break
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.app?.log("agora joined \(channel) uid=\(uid)")
            self.applyJoinMediaState()
            if let cb = self.smokeCompletion {
                cb(true)
                self.smokeCompletion = nil
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didLeaveChannelWith stats: AgoraChannelStats) {
        Task { @MainActor [weak self] in self?.app?.log("agora left") }
    }
}

extension AgoraManager {
    /// 冒烟：异步等待入会结果（≤60s）
    @MainActor
    func smokeJoin(app: AppModel) async -> Bool {
        guard engine != nil || (try? ensureEngine()) != nil else { return false }
        return await withCheckedContinuation { cont in
            var resumed = false
            smokeCompletion = { ok in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: ok)
            }
            do { try joinChannelNow(app: app) } catch { smokeCompletion?(false); smokeCompletion = nil }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                if let cb = self.smokeCompletion {
                    cb(false)
                    self.smokeCompletion = nil
                }
            }
        }
    }
}
