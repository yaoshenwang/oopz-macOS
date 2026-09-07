import AppKit
import AVFoundation

/// 进/离场与开闭麦提示音（本项目生成的原创短音）
enum Sounds {
    private static var players: [String: AVAudioPlayer] = [:]

    private static func url(_ name: String) -> URL? {
        // 1) .app Contents/Resources/sounds；2) SwiftPM 资源 bundle；3) 裸运行同目录
        if let u = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") { return u }
        if let u = Bundle.main.url(forResource: name, withExtension: "wav") { return u }
        if let resDir = Bundle.main.resourceURL {
            let u = resDir.appendingPathComponent("sounds/\(name).wav")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            for base in [exeDir.appendingPathComponent("Oopz_Oopz.bundle"), exeDir] {
                let u = base.appendingPathComponent("Contents/Resources/sounds/\(name).wav")
                if FileManager.default.fileExists(atPath: u.path) { return u }
                let u2 = base.appendingPathComponent("sounds/\(name).wav")
                if FileManager.default.fileExists(atPath: u2.path) { return u2 }
            }
        }
        return nil
    }

    static func play(_ name: String) {
        guard !RunMode.headless else { return }   // 无头测试不出声
        guard let url = url(name) else { return }
        DispatchQueue.global(qos: .utility).async {
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.volume = 0.5
                p.play()
                objc_sync_enter(players)
                players[name] = p
                objc_sync_exit(players)
            }
        }
    }

    static func voiceEnter() { play("enter_voice") }
    static func voiceExit() { play("exit_voice") }
    static func micMute() { play("microphone_mute") }
    static func micUnmute() { play("cancel_microphone_mute") }
    static func headsetMute() { play("headset_mute") }
    static func headsetUnmute() { play("cancel_headset_mute") }
    static func personEnter() { play("person_enter_voice") }
    static func personExit() { play("person_exit_voice") }
}
