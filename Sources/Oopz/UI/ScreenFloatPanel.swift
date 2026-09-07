import SwiftUI
import AppKit

/// 屏幕共享时的悬浮控制条（对齐官方 screenshare_runner 的置顶迷你窗）。
/// 可拖动（实时跟手）、位置跨会话记忆（UserDefaults），并额外提供麦克风快捷开关。
final class ScreenFloatPanelController {
    static let shared = ScreenFloatPanelController()
    var panel: NSPanel?
    private let positionKey = "oopz_float_panel_origin"

    func show(app: AppModel) {
        guard !RunMode.headless else { return }
        hide()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: FloatPanelContent(app: app) {
            self.hide()
        })
        panel.contentView = host
        // 恢复记忆位置（限制在可见屏幕内），否则默认右下角
        if let saved = savedOrigin, let screen = NSScreen.screens.first(where: { NSPointInRect(saved, $0.visibleFrame) }) {
            _ = screen
            panel.setFrameOrigin(saved)
        } else if let screen = NSScreen.main?.frame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 390, y: screen.minY + 60))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private var savedOrigin: NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: positionKey) else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }

    func saveOrigin(_ p: NSPoint) {
        UserDefaults.standard.set("\(p.x),\(p.y)", forKey: positionKey)
    }

    func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        var frame = panel.frame
        let height: CGFloat = expanded ? 406 : 46
        frame.origin.y += frame.height - height
        frame.size.height = height
        if let visible = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct FloatPanelContent: View {
    @ObservedObject var app: AppModel
    let onClose: () -> Void
    @State private var dragStartOrigin: NSPoint?
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    Text("共享中")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture)
                Button {
                    app.agora.setMic(muted: !app.voice.micMuted)
                } label: {
                    Image(systemName: app.voice.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 11))
                        .foregroundColor(app.voice.micMuted ? Theme.danger : Theme.speaking)
                }
                .buttonStyle(.plain)
                .help(app.voice.micMuted ? "开启麦克风" : "关闭麦克风")
                .accessibilityLabel(app.voice.micMuted ? "开启麦克风" : "关闭麦克风")
                Button {
                    expanded.toggle()
                    ScreenFloatPanelController.shared.setExpanded(expanded)
                } label: {
                    Label("音频", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .help("麦克风、系统声音和成员音量")
                Spacer()
                RoundActionButton(kind: .leave) {
                    app.agora.stopScreenShare()
                    onClose()
                }
                .scaleEffect(0.8)
            }
            .padding(.horizontal, 14)
            .frame(width: 360, height: 46)
            if expanded { ShareAudioControls(app: app).frame(width: 360) }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard let panel = ScreenFloatPanelController.shared.panel else { return }
                if dragStartOrigin == nil { dragStartOrigin = panel.frame.origin }
                guard let start = dragStartOrigin else { return }
                panel.setFrameOrigin(NSPoint(
                    x: start.x + value.translation.width,
                    y: start.y - value.translation.height))
            }
            .onEnded { _ in
                if let panel = ScreenFloatPanelController.shared.panel {
                    ScreenFloatPanelController.shared.saveOrigin(panel.frame.origin)
                }
                dragStartOrigin = nil
            }
    }
}
