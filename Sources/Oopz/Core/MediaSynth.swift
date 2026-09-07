import Foundation
import CoreMedia
import AgoraRtcKit

/// 合成媒体：不经麦克风/屏幕，向 Agora 自定义轨推 1kHz 正弦 + 纯红帧。
/// 观测端从 PCM / I420 回调里算 RMS 和像素均值，给 --media-test 做量化断言。
enum MediaSynth {
    static let sampleRate: Int = 48_000
    static let channels: Int = 2
    static let toneHz: Double = 1_000
    static let videoW: Int = 320
    static let videoH: Int = 180
    static let videoFps: Int = 15
    /// 满幅 0.4，避开编码器 AGC 把峰值削没
    static let amplitude: Double = 0.4

    // MARK: - 生成

    /// 10ms 一包：480 帧 × 2ch × int16
    static func sinePacket(phase: inout Double) -> (bytes: Data, samplesPerChannel: Int) {
        let n = sampleRate / 100
        let step = 2 * Double.pi * toneHz / Double(sampleRate)
        var buf = Data(count: n * channels * 2)
        buf.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let s = Int16(max(-1, min(1, sin(phase) * amplitude)) * 32767)
                dst[i * 2] = s
                dst[i * 2 + 1] = s
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
        }
        return (buf, n)
    }

    /// I420 纯红（BT.601 full-range 近似：Y=76, U=85, V=255）
    static func redI420Frame() -> Data {
        let ySize = videoW * videoH
        let uvSize = (videoW / 2) * (videoH / 2)
        var data = Data(count: ySize + uvSize * 2)
        data.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            memset(p, 76, ySize)
            memset(p.advanced(by: ySize), 85, uvSize)
            memset(p.advanced(by: ySize + uvSize), 255, uvSize)
        }
        return data
    }

    // MARK: - 量化

    /// int16 交错 PCM 的 RMS，归一化到 0...1
    static func rmsInt16(buffer: UnsafeRawPointer?, samplesPerChannel: Int, channels: Int) -> Double {
        guard let buffer, samplesPerChannel > 0, channels > 0 else { return 0 }
        let n = samplesPerChannel * channels
        let src = buffer.assumingMemoryBound(to: Int16.self)
        var acc: Double = 0
        for i in 0..<n {
            let v = Double(src[i]) / 32768.0
            acc += v * v
        }
        return sqrt(acc / Double(n))
    }

    /// I420 均值 RGB（BT.601 近似）。红帧应 R 高、G/B 低。
    static func meanRGB(y: UnsafePointer<UInt8>?, u: UnsafePointer<UInt8>?, v: UnsafePointer<UInt8>?,
                        width: Int, height: Int, yStride: Int, uStride: Int, vStride: Int) -> (r: Double, g: Double, b: Double)? {
        guard let y, let u, let v, width > 8, height > 8 else { return nil }
        // 抽样 8×8 网格，避免扫整帧
        var rAcc = 0.0, gAcc = 0.0, bAcc = 0.0, count = 0.0
        let stepX = max(1, width / 8)
        let stepY = max(1, height / 8)
        var yy = 0
        while yy < height {
            var xx = 0
            while xx < width {
                let Y = Double(y[yy * yStride + xx])
                let U = Double(u[(yy / 2) * uStride + (xx / 2)]) - 128
                let V = Double(v[(yy / 2) * vStride + (xx / 2)]) - 128
                // BT.601
                let R = min(255, max(0, Y + 1.402 * V))
                let G = min(255, max(0, Y - 0.344 * U - 0.714 * V))
                let B = min(255, max(0, Y + 1.772 * U))
                rAcc += R; gAcc += G; bAcc += B
                count += 1
                xx += stepX
            }
            yy += stepY
        }
        guard count > 0 else { return nil }
        return (rAcc / count, gAcc / count, bAcc / count)
    }

    static func isRed(r: Double, g: Double, b: Double) -> Bool {
        r > 140 && r > g + 40 && r > b + 40
    }

    /// 开麦窗口 RMS 下限：0.4 振幅正弦经编码/网络后通常仍 > 0.02
    static let audibleRMS: Double = 0.02
    /// 闭麦窗口 RMS 上限（底噪）
    static let silentRMS: Double = 0.008
}

/// 向自定义音/视频轨定时推合成帧。不碰设备。
final class MediaInjector {
    private weak var engine: AgoraRtcEngineKit?
    weak var probe: MediaProbe?
    private var audioTrackId: Int = -1
    private var videoTrackId: UInt = 0
    private var timer: DispatchSourceTimer?
    private var phase: Double = 0
    private var frameIndex: Int64 = 0
    private let red: Data = MediaSynth.redI420Frame()
    private let blue: Data = {
        let y = MediaSynth.videoW * MediaSynth.videoH
        return Data(repeating: 29, count: y) + Data(repeating: 255, count: y / 4) + Data(repeating: 107, count: y / 4)
    }()
    private let queue = DispatchQueue(label: "cn.oopz.media-inject")
    private(set) var pushingAudio = false
    private(set) var pushingVideo = false

    func attach(engine: AgoraRtcEngineKit, audioTrackId: Int, videoTrackId: UInt) {
        self.engine = engine
        // Synthetic audio never enters the SDK; RMS tests run in process memory.
        self.audioTrackId = -1
        self.videoTrackId = videoTrackId
    }

    func setAudio(_ on: Bool) { queue.sync { pushingAudio = on } }
    func setVideo(_ on: Bool) { queue.sync { pushingVideo = on } }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { pushingAudio = false; pushingVideo = false }
    }

    private func tick() {
        guard let engine else { return }
        if pushingAudio, audioTrackId >= 0 {  // 默认关闭：1kHz 进引擎会打到音箱
            let pkt = MediaSynth.sinePacket(phase: &phase)
            let ts = Date().timeIntervalSince1970 * 1000
            pkt.bytes.withUnsafeBytes { raw in
                if let p = raw.baseAddress {
                    let rc = engine.pushExternalAudioFrameRawData(UnsafeMutableRawPointer(mutating: p),
                                                                  samples: pkt.samplesPerChannel,
                                                                  sampleRate: MediaSynth.sampleRate,
                                                                  channels: MediaSynth.channels,
                                                                  trackId: audioTrackId,
                                                                  timestamp: ts)
                    probe?.ingestPush(rc: rc)
                    if rc != 0, frameIndex % 50 == 1 {
                        print("[oopz] pushAudio rc=\(rc) track=\(audioTrackId) samples=\(pkt.samplesPerChannel)")
                    }
                }
            }
        }
        // 15 fps ≈ 每 6–7 个 10ms tick 一帧
        frameIndex += 1
        if pushingVideo, frameIndex % 7 == 0 {
            let f = AgoraVideoFrame()
            f.format = 1 // I420
            f.strideInPixels = Int32(MediaSynth.videoW)
            f.height = Int32(MediaSynth.videoH)
            f.dataBuf = (frameIndex / 100) % 2 == 0 ? red : blue
            f.time = CMTime(value: frameIndex, timescale: 100)
            _ = engine.pushExternalVideoFrame(f, videoTrackId: videoTrackId)
        }
    }
}

/// 远端 PCM / I420 观测。SDK 回调在 Agora 线程，统计用锁。
final class MediaProbe: NSObject, AgoraAudioFrameDelegate, AgoraVideoFrameDelegate {
    struct Snap {
        var playbackFrames = 0
        var recordFrames = 0
        var peakRMS: Double = 0
        var lastRMS: Double = 0
        var rmsSum: Double = 0
        var pushOK = 0
        var pushFail = 0
        var lastPushRC: Int32 = 0
        var renderFrames = 0
        var redFrames = 0
        var lastRGB: (r: Double, g: Double, b: Double)?
        /// 本端屏幕采集帧（sourceType=screen 的 postCapture）：黑屏回归检查用
        var captureFrames = 0
        var captureLumaSum: Double = 0
        var lastCaptureRGB: (r: Double, g: Double, b: Double)?
    }

    private let lock = NSLock()
    private var snap = Snap()
    /// 只统计这个 Agora uid 的 before-mixing 帧；0 = 用 playback mix
    var targetUid: UInt = 0

    func reset() {
        lock.lock(); snap = Snap(); lock.unlock()
    }

    func snapshot() -> Snap {
        lock.lock(); defer { lock.unlock() }
        return snap
    }

    func ingestPush(rc: Int32) {
        lock.lock()
        snap.lastPushRC = rc
        if rc == 0 { snap.pushOK += 1 } else { snap.pushFail += 1 }
        lock.unlock()
    }

    func ingestRecord(_ frame: AgoraAudioFrame) {
        let rms = MediaSynth.rmsInt16(buffer: frame.buffer,
                                      samplesPerChannel: frame.samplesPerChannel,
                                      channels: max(1, frame.channels))
        lock.lock()
        snap.recordFrames += 1
        snap.lastRMS = rms
        snap.rmsSum += rms
        if rms > snap.peakRMS { snap.peakRMS = rms }
        lock.unlock()
    }

    // MARK: AgoraAudioFrameDelegate

    func onRecordAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        ingestRecord(frame)
        return true
    }

    func onPlaybackAudioFrame(_ frame: AgoraAudioFrame, channelId: String) -> Bool {
        ingest(frame)
        return true
    }

    func onPlaybackAudioFrame(_ frame: AgoraAudioFrame, beforeMixing channelId: String, uid: UInt) -> Bool {
        if targetUid == 0 || uid == targetUid { ingest(frame) }
        return true
    }

    func getObservedAudioFramePosition() -> AgoraAudioFramePosition {
        [AgoraAudioFramePosition.record, AgoraAudioFramePosition.playback, AgoraAudioFramePosition.beforeMixing]
    }

    func getPlaybackAudioParams() -> AgoraAudioParams {
        let p = AgoraAudioParams()
        p.sampleRate = MediaSynth.sampleRate
        p.channel = MediaSynth.channels
        p.mode = .readOnly
        p.samplesPerCall = MediaSynth.sampleRate / 100
        return p
    }

    func getRecordAudioParams() -> AgoraAudioParams { getPlaybackAudioParams() }
    func getMixedAudioParams() -> AgoraAudioParams { getPlaybackAudioParams() }

    private func ingest(_ frame: AgoraAudioFrame) {
        let rms = MediaSynth.rmsInt16(buffer: frame.buffer,
                                      samplesPerChannel: frame.samplesPerChannel,
                                      channels: frame.channels)
        lock.lock()
        snap.playbackFrames += 1
        snap.lastRMS = rms
        snap.rmsSum += rms
        if rms > snap.peakRMS { snap.peakRMS = rms }
        lock.unlock()
    }

    // MARK: AgoraVideoFrameDelegate

    func onRenderVideoFrame(_ videoFrame: AgoraOutputVideoFrame, uid: UInt, channelId: String) -> Bool {
        if targetUid != 0 && uid != targetUid { return true }
        let rgb = MediaSynth.meanRGB(y: videoFrame.yBuffer, u: videoFrame.uBuffer, v: videoFrame.vBuffer,
                                     width: Int(videoFrame.width), height: Int(videoFrame.height),
                                     yStride: Int(videoFrame.yStride), uStride: Int(videoFrame.uStride),
                                     vStride: Int(videoFrame.vStride))
        lock.lock()
        snap.renderFrames += 1
        if let rgb {
            snap.lastRGB = rgb
            if MediaSynth.isRed(r: rgb.r, g: rgb.g, b: rgb.b) { snap.redFrames += 1 }
        }
        lock.unlock()
        return true
    }

    func getVideoFormatPreference() -> AgoraVideoFormat { .I420 }
    func getObservedFramePosition() -> AgoraVideoFramePosition { [.postCapture, .preRenderer] }

    /// 本端采集帧（屏幕共享黑屏检查）：只统计屏幕源（src=2）
    func onCapture(_ videoFrame: AgoraOutputVideoFrame, sourceType: AgoraVideoSourceType) -> Bool {
        if sourceType.rawValue != 2 { return true }
        let rgb = MediaSynth.meanRGB(y: videoFrame.yBuffer, u: videoFrame.uBuffer, v: videoFrame.vBuffer,
                                     width: Int(videoFrame.width), height: Int(videoFrame.height),
                                     yStride: Int(videoFrame.yStride), uStride: Int(videoFrame.uStride),
                                     vStride: Int(videoFrame.vStride))
        lock.lock()
        snap.captureFrames += 1
        if let rgb {
            snap.lastCaptureRGB = rgb
            snap.captureLumaSum += 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
        }
        lock.unlock()
        return true
    }
}
