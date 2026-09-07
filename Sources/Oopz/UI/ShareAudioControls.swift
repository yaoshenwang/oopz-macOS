import SwiftUI

/// The same live controls are available from the voice room and the floating share panel.
struct ShareAudioControls: View {
    @ObservedObject var app: AppModel

    private var members: [VoiceMember] {
        (app.channelVoiceMembers[app.voice.channelId] ?? []).filter { $0.uid != app.api.session?.uid }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("音频设置").font(.system(size: 14, weight: .semibold))
                HStack {
                    Text("我的麦克风")
                    Spacer()
                    Button(app.voice.micMuted ? "开启麦克风" : "关闭麦克风") {
                        app.agora.setMic(muted: !app.voice.micMuted)
                    }
                    .foregroundColor(app.voice.micMuted ? Theme.danger : Theme.speaking)
                }
                volumeRow("麦克风音量", volume: Binding(
                    get: { app.voice.micVolume }, set: { app.agora.setMicVolume($0) }))
                HStack {
                    Text("我听到的声音")
                    Spacer()
                    Button(app.voice.headsetMuted ? "恢复收听" : "全部静音") {
                        app.agora.setHeadset(muted: !app.voice.headsetMuted)
                    }
                    .foregroundColor(app.voice.headsetMuted ? Theme.danger : Theme.textSecondary)
                }
                volumeRow("总播放音量", volume: Binding(
                    get: { app.voice.playbackVolume }, set: { app.agora.setPlaybackVolume($0) }))

                if app.voice.shareActive {
                    Divider()
                    Toggle("向观众共享系统声音", isOn: Binding(
                        get: { app.voice.shareAudioEnabled },
                        set: { app.sharing.setSystemAudioEnabled($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(!app.voice.shareAudioAvailable)
                    if app.voice.shareAudioAvailable {
                        volumeRow("发送音量", volume: Binding(
                            get: { app.voice.shareAudioVolume },
                            set: { app.sharing.setSystemAudioVolume($0) }), maximum: 100)
                        Text("此开关只暂停共享声音，麦克风与画面继续。")
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Text("如需共享声音，请重新共享整个屏幕并勾选「系统声音」。")
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let error = app.voice.shareAudioError {
                        Text(error).foregroundColor(Theme.danger)
                    }
                }

                if let uid = app.voice.watchingUid {
                    Divider()
                    volumeRow("观看共享音量", volume: Binding(
                        get: { app.voice.shareListenVolumes[String(uid)] ?? 100 },
                        set: { app.sharing.setListenVolume(uid: uid, volume: $0) }))
                }

                Divider()
                Text("成员语音音量").fontWeight(.medium)
                if members.isEmpty {
                    Text("暂无其他成员").foregroundColor(Theme.textSecondary)
                }
                ForEach(members) { member in
                    if let uid = app.agoraUid(ofOopzUid: member.uid), uid != 0 {
                        volumeRow(member.name, volume: Binding(
                            get: { app.voice.userVolumes[String(uid)] ?? 100 },
                            set: { app.agora.setUserVolume(agoraUid: uid, volume: $0) }))
                    }
                }
                Text("成员语音与共享声音分别调节。共享音量设置在离开语音频道后重置。")
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(16)
        }
        .frame(height: 360)
        .font(.system(size: 12))
        .foregroundColor(Theme.textPrimary)
        .buttonStyle(.plain)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
    }

    private func volumeRow(_ title: String, volume: Binding<Int>, maximum: Double = 400) -> some View {
        HStack {
            Text(title).lineLimit(1).help(title)
            Spacer(minLength: 6)
            InlineVolumeSlider(volume: volume, width: 180, maximum: maximum)
                .accessibilityLabel(title)
        }
    }
}
