import AgoraRtcKit

/// Configuration regression checks only: no engine, capture, audio push, playback or preference writes.
enum ShareAudioChecks {
    static func run() -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ value: Bool) { checks.append((name, value)) }
        let cfg = ShareAudioRouting.trackConfig()
        check("共享声音不进入麦克风混音器", ShareAudioRouting.trackType == .direct)
        check("共享声音禁用本地监听与语音处理", !cfg.enableLocalPlayback && !cfg.enableAudioProcessing)
        let capture = ShareAudioRouting.captureConfig()
        check("系统采音排除本应用并保持 48k 双声道", capture.capturesAudio && capture.excludesCurrentProcessAudio && capture.sampleRate == 48000 && capture.channelCount == 2)
        if #available(macOS 15.0, *) { check("SCK 不启用第二路麦克风", !capture.captureMicrophone) }

        let options = AgoraRtcChannelMediaOptions()
        options.publishScreenTrack = true
        // Start -> mute -> resume -> stop; the same object catches stale SDK optional fields.
        for (name, publishing, enabled, track, expected) in [
            ("开始", true, true, 7, true),
            ("暂停", true, false, 7, false),
            ("恢复", true, true, 7, true),
            ("停止", false, true, 7, false),
            ("无音轨", true, true, -1, false)
        ] {
            ShareAudioRouting.configure(options, publish: publishing, track: track, enabled: enabled, headless: false)
            check("共享声音\(name)：仅自定义轨发布", options.publishCustomAudioTrack == expected && !options.publishMicrophoneTrack && !options.publishScreenCaptureAudio && !options.publishMediaPlayerAudioTrack)
            check("共享声音\(name)：不自动订阅房间音频、不修改视频", !options.autoSubscribeAudio && options.publishScreenTrack)
        }
        ShareAudioRouting.configure(options, publish: true, track: 7, enabled: true, headless: true)
        check("无头即使请求系统声音也不发布/播放音频", !options.publishCustomAudioTrack && !options.publishMicrophoneTrack && !options.autoSubscribeAudio && !options.enableAudioRecordingOrPlayout)
        return checks
    }
}
