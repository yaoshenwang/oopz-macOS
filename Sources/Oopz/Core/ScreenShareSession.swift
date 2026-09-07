import Foundation
import AppKit
import AgoraRtcKit

enum SharePhase: String {
    case idle, preparing, publishing, notifying, active, stopping, failed
    var busy: Bool { ![.idle, .failed].contains(self) }
}

/// The business channel, voice RTC room and sharing RTC room are distinct identities.
/// All publisher operations retain their original context across awaits.
@MainActor
final class ScreenShareSession {
    private unowned let app: AppModel
    private var generation = UUID()
    private var startTask: Task<Bool, Never>?
    private var stopTask: Task<Void, Never>?
    private var connection: AgoraRtcConnection?
    private var delegate: ShareRTCDelegate?
    private var context: Context?
    private var injector: MediaInjector?
    private var customTrack: UInt?
    private var audioTrack = -1
    private let audio = SystemAudioCapturer()
    private var watchGeneration = UUID()
    private var leaveTask: Task<Void, Never>?
    private var watching: UInt32?
    private var subscribedAudio: UInt32?
    private(set) var roomId = ""
    private(set) var publishConfirmed = false
    private(set) var encoded = false
    private var failure: String?
    struct Context {
        let area: String, channel: String, dimensions: String, userId: String
        let fps: Int, uid: UInt32
    }
    init(app: AppModel) { self.app = app }

    private func phase(_ phase: SharePhase) {
        app.voice.sharePhase = phase
        app.voice.shareActive = phase == .active
        app.log("share phase=\(phase.rawValue) session=\(generation) room=\(roomId)")
    }
    private func check(_ id: UUID) throws {
        guard id == generation, !Task.isCancelled else { throw CancellationError() }
        if let failure { throw OopzError.apiError("SHARE_RTC", failure) }
    }
    private func wait(_ id: UUID, seconds: Double = 12, until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() {
            try check(id)
            guard Date() < deadline else { throw OopzError.apiError("SHARE_TIMEOUT", "共享连接或编码超时") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(id)
    }
    private func options(publish: Bool) -> AgoraRtcChannelMediaOptions {
        let o = AgoraRtcChannelMediaOptions()
        o.clientRoleType = .broadcaster
        ShareAudioRouting.configure(o, publish: publish, track: audioTrack,
            enabled: app.voice.shareAudioEnabled, headless: RunMode.headless)
        o.publishCameraTrack = false
        o.publishScreenTrack = publish && customTrack == nil
        o.publishCustomVideoTrack = publish && customTrack != nil
        if let customTrack { o.customVideoTrackId = Int(customTrack) }
        o.autoSubscribeVideo = watching != nil
        return o
    }

    func start(displayId: UInt32? = nil, windowId: UInt32? = nil,
               dimension: String = "", fps: Int = 30, systemAudio: Bool = false,
               pattern: Bool = false) async -> Bool {
        guard RunMode.headless || app.permissions.ready else { return false }
        guard !app.voice.sharePhase.busy, stopTask == nil, startTask == nil,
              app.voice.joined, app.voice.agoraUid != 0 else { return false }
        let id = UUID(); generation = id
        app.voice.shareError = nil; failure = nil
        app.voice.shareAudioError = nil
        app.voice.shareAudioAvailable = false
        app.voice.shareAudioEnabled = false
        encoded = false; publishConfirmed = false
        let c = Context(area: app.voice.areaId, channel: app.voice.channelId,
                        dimensions: dimension, userId: app.api.session?.uid ?? "", fps: fps, uid: app.voice.agoraUid)
        context = c
        phase(.preparing)
        let task = Task { @MainActor in
            do {
                guard windowId == nil || !systemAudio else {
                    throw OopzError.apiError("WINDOW_AUDIO", "窗口共享暂不支持声音，请选择整个屏幕")
                }
                // Never obtain a voice token here or manufacture a room suffix.
                let credentials = try await app.api.screenShareCredentials(channel: c.channel,
                    sending: true, dimension: c.dimensions, fps: c.fps)
                try check(id)
                let engine = try app.agora.testEngine()
                engine.enableVideo()
                let dimensions = ScreenShareTier.parseDimensions(c.dimensions)
                if pattern {
                    guard RunMode.headless else { throw OopzError.apiError("TEST_ONLY", "测试图案仅限无头模式") }
                    let track = engine.createCustomVideoTrack()
                    customTrack = UInt(track)
                    engine.setExternalVideoSource(true, useTexture: false, sourceType: .videoFrame)
                    let cfg = AgoraVideoEncoderConfiguration()
                    cfg.dimensions = CGSize(width: MediaSynth.videoW, height: MediaSynth.videoH)
                    cfg.frameRate = 15
                    engine.setVideoEncoderConfiguration(cfg)
                    let source = MediaInjector()
                    source.attach(engine: engine, audioTrackId: -1, videoTrackId: UInt(track))
                    injector = source
                } else {
                    guard !RunMode.headless else { throw OopzError.apiError("DEVICE_FORBIDDEN", "无头验证不采集真实屏幕") }
                    guard app.permissions.ready else { throw CancellationError() }
                    let params = AgoraScreenCaptureParameters()
                    params.frameRate = c.fps; params.dimensions = dimensions
                    let rc: Int32
                    if let windowId {
                        rc = engine.startScreenCapture(byWindowId: windowId, regionRect: .zero, captureParams: params)
                    } else {
                        let display = displayId ?? CGMainDisplayID()
                        rc = engine.startScreenCapture(byDisplayId: display, regionRect: CGDisplayBounds(display), captureParams: params)
                    }
                    guard rc == 0 else { throw OopzError.apiError("CAPTURE_\(rc)", "屏幕采集启动失败（\(rc)），请重试") }
                }
                if systemAudio && !RunMode.headless {
                    audioTrack = Int(engine.createCustomAudioTrack(ShareAudioRouting.trackType,
                        config: ShareAudioRouting.trackConfig()))
                    guard audioTrack >= 0 else { throw OopzError.apiError("AUDIO_TRACK", "无法创建共享声音轨") }
                    let volumeRC = engine.adjustCustomAudioPublishVolume(audioTrack, volume: app.voice.shareAudioVolume)
                    guard volumeRC == 0 else { throw OopzError.apiError("AUDIO_VOLUME", "无法设置共享声音音量（\(volumeRC)）") }
                    let track = audioTrack
                    audio.setMuted(false)
                    audio.onFailure = { [weak self] error in
                        guard let self, self.generation == id else { return }
                        guard self.app.voice.shareActive else {
                            self.failure = "共享声音采集在准备阶段中断"
                            return
                        }
                        self.setSystemAudioEnabled(false)
                        self.app.voice.shareAudioAvailable = false
                        self.app.voice.shareAudioError = "共享声音采集中断，请停止后重新共享"
                        self.app.log("share audio capture stopped: \(error.localizedDescription)")
                        self.app.showToast("共享声音采集中断，语音和画面继续")
                    }
                    audio.onSampleBuffer = { sample in
                        guard let converted = PCMConverter.int16Stereo48k(from: sample) else { return }
                        converted.data.withUnsafeBytes { bytes in
                            guard let p = bytes.baseAddress else { return }
                            _ = engine.pushExternalAudioFrameRawData(UnsafeMutableRawPointer(mutating: p),
                                samples: Int(converted.samplesPerChannel), sampleRate: 48000, channels: 2, trackId: track, timestamp: 0)
                        }
                    }
                    try await audio.start(displayID: displayId ?? CGMainDisplayID())
                    try check(id)
                    app.voice.shareAudioAvailable = true
                    app.voice.shareAudioEnabled = true
                    app.log("share audio: direct track; localPlayback=false; microphone=false; excludeOwnAudio=true")
                }
                phase(.publishing)
                if connection?.channelId != credentials.roomId {
                    await leaveConnection()
                    try check(id)
                }
                if connection == nil {
                    let conn = AgoraRtcConnection(channelId: credentials.roomId, localUid: Int(c.uid))
                    let d = ShareRTCDelegate(owner: self, id: id, connection: conn)
                    connection = conn; delegate = d; roomId = credentials.roomId
                    let rc = engine.joinChannelEx(byToken: credentials.signPid, connection: conn,
                        delegate: d, mediaOptions: options(publish: true), joinSuccess: nil)
                    guard rc == 0 else { throw OopzError.apiError("SHARE_JOIN_\(rc)", "无法连接共享房间") }
                } else {
                    delegate?.id = id
                    let rc = engine.updateChannelEx(with: options(publish: true), connection: connection!)
                    guard rc == 0 else { throw OopzError.apiError("SHARE_UPDATE_\(rc)", "无法发布共享流") }
                    applyPlaybackState()
                }
                injector?.start(); injector?.setVideo(true)
                try await wait(id) { self.delegate?.joined == true && self.publishConfirmed && (pattern || self.encoded) }
                phase(.notifying)
                _ = try await app.api.reportScreenShareState(areaId: c.area, channelId: c.channel,
                    open: true, dimensions: c.dimensions, framerate: String(c.fps))
                try check(id)
                try await app.api.confirmScreenShareState(areaId: c.area, channelId: c.channel, uid: c.userId, open: true)
                try check(id)
                phase(.active)
                if !RunMode.headless { ScreenFloatPanelController.shared.show(app: app) }
                return true
            } catch {
                if id == generation {
                    if !RunMode.headless && PermissionCenter.isScreenPermissionError(error) {
                        app.permissions.recordScreenFailure(error)
                    }
                    app.voice.shareError = error.localizedDescription
                    app.log("share failed: \(error.localizedDescription)")
                    await cleanupPublisher()
                    phase(.failed)
                    app.showToast("共享失败：\(error.localizedDescription)")
                }
                return false
            }
        }
        startTask = task
        let ok = await task.value
        startTask = nil
        return ok
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        guard context != nil || startTask != nil else { return }
        generation = UUID()
        phase(.stopping)
        ScreenFloatPanelController.shared.hide()
        let pending = startTask
        let task = Task { @MainActor in
            _ = await pending?.value  // OPEN must finish before CLOSE, even when cancellation races HTTP.
            await cleanupPublisher()
            phase(.idle)
        }
        stopTask = task
        await task.value
        stopTask = nil
    }
    private func cleanupPublisher() async {
        let engine = try? app.agora.testEngine()
        injector?.stop(); injector = nil
        await audio.stopAndWait()
        audio.onFailure = nil
        app.voice.shareAudioEnabled = false
        app.voice.shareAudioAvailable = false
        engine?.stopScreenCapture()
        if let connection { _ = engine?.updateChannelEx(with: options(publish: false), connection: connection) }
        applyPlaybackState()
        if let c = context {
            var closed = false
            for _ in 0..<2 {
                do {
                    _ = try await app.api.reportScreenShareState(areaId: c.area, channelId: c.channel,
                        open: false, dimensions: c.dimensions, framerate: String(c.fps))
                    try await app.api.confirmScreenShareState(areaId: c.area, channelId: c.channel, uid: c.userId, open: false)
                    app.log("share CLOSE confirmed channel=\(c.channel)")
                    closed = true; break
                } catch { app.log("share CLOSE failed: \(error.localizedDescription)") }
            }
            if !closed { app.voice.shareError = "停止上报失败，请离开频道以清理共享状态" }
        }
        if watching == nil { await leaveConnection() }
        if let customTrack { _ = engine?.destroyCustomVideoTrack(customTrack) }
        customTrack = nil
        if audioTrack >= 0 { engine?.destroyCustomAudioTrack(audioTrack) }
        audioTrack = -1; context = nil; publishConfirmed = false; encoded = false
        app.voice.shareActive = false
    }
    private func leaveConnection() async {
        if let leaveTask { await leaveTask.value; return }
        guard let c = connection else { return }
        let retainedDelegate = delegate
        connection = nil; delegate = nil; roomId = ""
        subscribedAudio = nil
        guard let engine = try? app.agora.testEngine() else { return }
        let task = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var done = false
                let finish = { @MainActor in
                    guard !done else { return }; done = true; continuation.resume()
                }
                _ = engine.leaveChannelEx(c) { _ in Task { @MainActor in finish() } }
                Task { @MainActor in try? await Task.sleep(nanoseconds: 3_000_000_000); finish() }
            }
            _ = retainedDelegate
        }
        leaveTask = task
        await task.value
        leaveTask = nil
    }
    func receive(uid: UInt32, view: NSView) async {
        guard app.voice.joined, uid != app.voice.agoraUid, view.window != nil, app.voice.watchingUid == uid else { return }
        let watchID = UUID(); watchGeneration = watchID
        if let leaveTask { await leaveTask.value }
        let channel = app.voice.channelId
        do {
            let state = app.voice.shareStates.values.first { app.agoraUid(ofOopzUid: $0.uid) == uid }
            let credentials = try await app.api.screenShareCredentials(channel: channel, sending: false,
                dimension: state?.dimensions ?? "", fps: Int(state?.framerate ?? "30") ?? 30, anchor: uid)
            guard watchGeneration == watchID, channel == app.voice.channelId, app.voice.joined, view.window != nil, app.voice.watchingUid == uid else { return }
            let engine = try app.agora.testEngine(); engine.enableVideo()
            if let previous = watching, let connection {
                let canvas = AgoraRtcVideoCanvas(); canvas.uid = UInt(previous)
                _ = engine.setupRemoteVideoEx(canvas, connection: connection)
            }
            watching = uid
            if connection == nil {
                let c = AgoraRtcConnection(channelId: credentials.roomId, localUid: Int(app.voice.agoraUid))
                let d = ShareRTCDelegate(owner: self, id: generation, connection: c)
                connection = c; delegate = d; roomId = credentials.roomId
                let rc = engine.joinChannelEx(byToken: credentials.signPid, connection: c, delegate: d,
                    mediaOptions: options(publish: false), joinSuccess: nil)
                guard rc == 0 else { throw OopzError.apiError("WATCH_\(rc)", "观看连接失败") }
            }
            guard let connection, connection.channelId == credentials.roomId else {
                throw OopzError.apiError("WATCH_ROOM", "共享房间不匹配")
            }
            let canvas = AgoraRtcVideoCanvas(); canvas.uid = UInt(uid); canvas.view = view
            _ = engine.setupRemoteVideoEx(canvas, connection: connection)
            _ = engine.updateChannelEx(with: options(publish: context != nil), connection: connection)
            app.voice.watchingUid = uid
            applyPlaybackState()
        } catch {
            guard watchGeneration == watchID else { return }
            await closeWatch(uid: uid)
            app.showToast("观看共享失败：\(error.localizedDescription)")
        }
    }
    func applyPlaybackState() {
        guard let connection, let engine = try? app.agora.testEngine() else { return }
        let target = RunMode.headless || app.voice.headsetMuted ? nil : watching
        if let previous = subscribedAudio, previous != target {
            _ = engine.muteRemoteAudioStreamEx(UInt(previous), mute: true, connection: connection)
            subscribedAudio = nil
        }
        if let target {
            let volumeRC = engine.adjustUserPlaybackSignalVolumeEx(UInt(target),
                volume: app.voice.shareListenVolumes[String(target)] ?? 100, connection: connection)
            let subscribeRC = engine.muteRemoteAudioStreamEx(UInt(target), mute: false, connection: connection)
            subscribedAudio = target
            if volumeRC != 0 || subscribeRC != 0 {
                app.log("share audio receive: volumeRC=\(volumeRC) subscribeRC=\(subscribeRC)")
            }
        }
    }

    func connectionJoined(_ source: AgoraRtcConnection) {
        guard let connection, connection === source else { return }
        app.agora.applySavedVolumes()
        applyPlaybackState()
    }

    func remoteJoined(_ source: AgoraRtcConnection) {
        guard let connection, connection === source else { return }
        applyPlaybackState()
    }

    /// Pause sends without touching microphone capture, voice mute, or screen video.
    func setSystemAudioEnabled(_ enabled: Bool) {
        guard audioTrack >= 0, let connection, let engine = try? app.agora.testEngine() else { return }
        guard !enabled || (app.voice.shareAudioAvailable && audio.running && app.voice.shareActive) else { return }
        let previous = app.voice.shareAudioEnabled
        if !enabled { audio.setMuted(true) }
        app.voice.shareAudioEnabled = enabled
        let rc = engine.updateChannelEx(with: options(publish: app.voice.shareActive), connection: connection)
        if rc != 0 {
            // Failed disable still blocks PCM. Never accidentally resume sending.
            app.voice.shareAudioEnabled = enabled ? previous : false
            audio.setMuted(!app.voice.shareAudioEnabled)
            app.voice.shareAudioError = "共享声音设置失败（\(rc)），请重试"
            return
        }
        audio.setMuted(!enabled)
        app.voice.shareAudioError = nil
        applyPlaybackState()
        app.log("share audio enabled=\(enabled)")
    }

    func setSystemAudioVolume(_ value: Int) {
        guard audioTrack >= 0, let engine = try? app.agora.testEngine() else { return }
        let volume = min(100, max(0, value))
        let rc = engine.adjustCustomAudioPublishVolume(audioTrack, volume: volume)
        guard rc == 0 else {
            app.voice.shareAudioError = "共享声音音量设置失败（\(rc)）"
            return
        }
        app.voice.shareAudioVolume = volume
        app.voice.shareAudioError = nil
    }

    func setListenVolume(uid: UInt32, volume: Int) {
        app.voice.shareListenVolumes[String(uid)] = min(400, max(0, volume))
        applyPlaybackState()
    }
    func closeWatch(uid: UInt32? = nil) async {
        if let uid, let watching, uid != watching { return }
        watchGeneration = UUID()
        if let watching, let connection, let engine = try? app.agora.testEngine() {
            let canvas = AgoraRtcVideoCanvas(); canvas.uid = UInt(watching)
            _ = engine.setupRemoteVideoEx(canvas, connection: connection)
        }
        watching = nil; app.voice.watchingUid = nil
        applyPlaybackState()
        if context == nil { await leaveConnection() }
        else if let connection {
            _ = try? app.agora.testEngine().updateChannelEx(with: options(publish: true), connection: connection)
            applyPlaybackState()
        }
    }
    func localVideo(state: AgoraVideoLocalState, source: AgoraVideoSourceType, id: UUID? = nil) {
        if let id, id != generation { return }
        guard context != nil, customTrack == nil, source == .screen else { return }
        if state == .encoding { encoded = true }
        if state == .failed || (state == .stopped && app.voice.sharePhase == .active) {
            rtcFailure("屏幕采集中断", id: generation)
        }
    }
    func published(room: String, value: Int, id: UUID) {
        guard id == generation, room == roomId else { return }
        publishConfirmed = value == 3
        app.log("share publishState=\(value) room=\(room)")
        if value != 3, app.voice.sharePhase == .active {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if id == generation, !publishConfirmed, app.voice.sharePhase == .active {
                    rtcFailure("共享发布连接中断，请重新共享", id: id)
                }
            }
        }
    }
    func rtcFailure(_ message: String, id: UUID) {
        guard id == generation else { return }
        failure = message
        if context == nil, watching != nil {
            app.showToast(message)
            WatchWindowController.shared.close()
            Task { await closeWatch() }
        }
        if app.voice.sharePhase == .active {
            app.voice.shareError = message
            Task { await stop(); phase(.failed); app.showToast(message) }
        }
    }
}

private final class ShareRTCDelegate: NSObject, AgoraRtcEngineDelegate {
    weak var owner: ScreenShareSession?
    var id: UUID
    @MainActor var joined = false
    let connection: AgoraRtcConnection
    init(owner: ScreenShareSession, id: UUID, connection: AgoraRtcConnection) {
        self.owner = owner; self.id = id; self.connection = connection
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        Task { @MainActor in
            self.joined = true
            self.owner?.connectionJoined(self.connection)
        }
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        Task { @MainActor in self.owner?.remoteJoined(self.connection) }
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didVideoPublishStateChange channel: String,
                   sourceType: AgoraVideoSourceType, oldState: AgoraStreamPublishState,
                   newState: AgoraStreamPublishState, elapseSinceLastState: Int32) {
        Task { @MainActor in self.owner?.published(room: channel, value: newState.rawValue, id: self.id) }
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, localVideoStateChangedOf state: AgoraVideoLocalState,
                   reason: AgoraLocalVideoStreamReason, sourceType: AgoraVideoSourceType) {
        Task { @MainActor in self.owner?.localVideo(state: state, source: sourceType, id: self.id) }
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        Task { @MainActor in self.owner?.rtcFailure("共享 RTC 错误 \(errorCode.rawValue)", id: self.id) }
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) {
        Task { @MainActor in self.owner?.rtcFailure("共享凭证即将过期，请重新发起共享", id: self.id) }
    }
}
