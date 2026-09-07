import SwiftUI
import CryptoKit

/// OOPZ 视觉语言（取自官方客户端配色：主蓝 #5088F8、深色面板、圆角卡片）
enum Theme {
    static let accent = Color(red: 0.31, green: 0.53, blue: 0.97)      // #5088F8
    static let accentDeep = Color(red: 0.24, green: 0.44, blue: 0.92)
    static let danger = Color(red: 0.97, green: 0.38, blue: 0.38)      // #F86060
    static let speaking = Color(red: 0.24, green: 0.73, blue: 0.43)    // 绿色说话圈

    static let bg = Color(red: 0.075, green: 0.078, blue: 0.086)       // 主背景
    static let panel = Color(red: 0.11, green: 0.114, blue: 0.125)     // 左右栏面板
    static let card = Color(red: 0.16, green: 0.165, blue: 0.18)       // 卡片
    static let cardHover = Color(red: 0.20, green: 0.21, blue: 0.23)
    static let input = Color(red: 0.135, green: 0.14, blue: 0.155)
    // 文字色阶：全部按主背景 #131416 校验过对比度（次级 ≥ 7:1，三级 ≥ 4.6:1），
    // 0.45/0.28 透明度白在深底上曾导致"黑底黑字"不可读（v0.2.1 修复）
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.52)

    // 官方语音房取色（2026-09-06 对官方 Web 端截图取样）
    static let cardDark = Color(red: 0.106, green: 0.106, blue: 0.114)      // 卡片信息条 #1B1B1D
    static let pillBg = Color(red: 0.106, green: 0.106, blue: 0.114)
    static let pillBorder = Color(red: 0.302, green: 0.553, blue: 0.969)    // 蓝描边 #4D8DF7
    static let doorRed = Color(red: 0.898, green: 0.325, blue: 0.239)       // 出门键红 #E5533D
    static let countGray = Color.white.opacity(0.55)
    static let sidebarSelected = Color.white.opacity(0.10)
    static let selfBorder = Color(red: 0.357, green: 0.769, blue: 0.961)    // 自己的卡片青蓝描边
    static let rowHover = Color.white.opacity(0.06)

    static let radius: CGFloat = 10
}

extension View {
    func card() -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// OOPZ 圆形操作按钮（语音频道底部控制条同款样式）
struct RoundActionButton: View {
    enum Kind { case micOn, micOff, headphoneOn, headphoneOff, share, shareActive, leave }
    let kind: Kind
    var danger = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 46, height: 46)
                image
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(fore)
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var fill: Color {
        if case .leave = kind { return Theme.danger.opacity(0.92) }
        if danger { return Theme.danger.opacity(0.92) }
        return Theme.cardHover
    }
    private var fore: Color {
        if case .leave = kind { return .white }
        if danger { return .white }
        switch kind {
        case .shareActive: return Theme.accent
        default: return Theme.textPrimary
        }
    }
    private var helpText: String {
        switch kind {
        case .micOn: return "关闭麦克风"
        case .micOff: return "开启麦克风"
        case .headphoneOn: return "取消耳机静音"
        case .headphoneOff: return "静音耳机"
        case .share: return "发起屏幕共享"
        case .shareActive: return "共享中…点击停止"
        case .leave: return "退出频道"
        }
    }
    @ViewBuilder private var image: some View {
        switch kind {
        case .micOn: Image(systemName: "mic.fill")
        case .micOff: Image(systemName: "mic.slash.fill").foregroundColor(Theme.danger)
        case .headphoneOn: Image(systemName: "headphones")
        case .headphoneOff: Image(systemName: "ear.fill")
        case .share: Image(systemName: "rectangle.on.rectangle")
        case .shareActive: Image(systemName: "rectangle.on.rectangle.fill")
        case .leave: Image(systemName: "phone.down.fill")
        }
    }
}

/// 头像（含说话圈 / 静音角标），复用 OOPZ 语音成员样式
struct VoiceAvatar: View {
    let member: VoiceMember
    var size: CGFloat = 44

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncOopzImage(url: member.avatar, fallbackText: member.name)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        member.speaking ? Theme.speaking : Color.white.opacity(0.08),
                        lineWidth: member.speaking ? 2.5 : 1
                    )
                )
            if member.muteKnown && member.muted {
                ZStack {
                    Circle().fill(Color(white: 0.13)).frame(width: 16, height: 16)
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.danger)
                }
                .offset(x: 3, y: 3)
            }
        }
    }
}

/// 头像加载（OOPZ CDN webp；失败回退首字符圆底）
struct AsyncOopzImage: View {
    let url: String?
    let fallbackText: String
    @State private var img: NSImage? = nil

    var body: some View {
        ZStack {
            Circle().fill(
                LinearGradient(colors: [Theme.accent.opacity(0.75), Theme.accentDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            if let img {
                Image(nsImage: img).resizable().scaledToFill()
            } else if let ch = fallbackText.first {
                Text(String(ch))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .task(id: url) {
            img = await AvatarCache.shared.load(url)
        }
    }
}

/// 头像磁盘缓存（对齐官方 ImageCache 语义）。
/// key 用 URL 的 SHA256（String.hashValue 每次进程启动随机化，跨启动永远无法命中）；
/// 文件数超阈值时整体清空，避免无限堆积。
final class AvatarCache {
    static let shared = AvatarCache()
    private let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("oopz_avatars")
    private let mem = NSCache<NSString, NSImage>()

    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func stableKey(_ urlString: String) -> String {
        // CDN 带防盗链签名（?sign=…每次拉取都变），缓存键剥掉查询串，同一图片跨签名仍命中
        let base = urlString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? urlString
        return SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 简单容量控制：超过 500 个缓存文件时清空目录
    private func evictIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              files.count > 500 else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    func load(_ urlString: String?) async -> NSImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let hit = mem.object(forKey: urlString as NSString) { return hit }
        let file = dir.appendingPathComponent(stableKey(urlString) + ".img")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            mem.setObject(image, forKey: urlString as NSString)
            return image
        }
        guard let url = URL(string: urlString), let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        try? data.write(to: file)
        mem.setObject(image, forKey: urlString as NSString)
        evictIfNeeded()
        return image
    }
}
