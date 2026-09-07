import AgoraRtcKit
import ScreenCaptureKit

/// Sharing never joins the microphone mixer. Voice keeps its original SDK capture path.
enum ShareAudioRouting {
    static let trackType: AgoraAudioTrackType = .direct

    static func trackConfig() -> AgoraAudioTrackConfig {
        let config = AgoraAudioTrackConfig()
        config.enableLocalPlayback = false
        config.enableAudioProcessing = false // System audio must not use voice DSP.
        return config
    }

    static func captureConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        config.sampleRate = 48000
        config.channelCount = 2
        return config
    }

    static func configure(_ options: AgoraRtcChannelMediaOptions, publish: Bool,
                          track: Int, enabled: Bool, headless: Bool) {
        options.publishMicrophoneTrack = false
        options.publishScreenCaptureAudio = false // SCK custom track is the only system-audio source.
        options.publishMediaPlayerAudioTrack = false
        options.publishCustomAudioTrack = publish && track >= 0 && enabled && !headless
        if track >= 0 { options.publishCustomAudioTrackId = track }
        // Subscribe explicitly to the selected sharer, including after reconnect / late join.
        options.autoSubscribeAudio = false
        options.enableAudioRecordingOrPlayout = !headless
    }
}
