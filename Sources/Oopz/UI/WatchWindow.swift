import SwiftUI
import AppKit

/// 观看他人共享的独立窗口（Agora 视频渲染 NSView）。
/// Esc / 关闭按钮 / 远端停止共享 均可退出观看；关闭后记录 dismissed，本次会话不再自动弹出。
final class WatchWindowController: NSObject, NSWindowDelegate {
    static let shared = WatchWindowController()
    private var window: NSWindow?
    private weak var model: AppModel?
    private var watchUid: UInt32?
    private var requestId = UUID()
    private var escMonitor: Any?

    @MainActor
    func show(app: AppModel, uid: UInt32) {
        guard !RunMode.headless else { return }
        requestId = app.voice.watchRequestId
        if watchUid == uid, let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        model = app
        watchUid = uid
        installEscMonitor()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "正在观看屏幕共享"
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        let sharerName = app.voice.shareStates.values.first { app.agoraUid(ofOopzUid: $0.uid) == uid }?.name
        let render = AgoraRenderView(uid: uid, app: app)
        let container = VStack(spacing: 0) {
            AgoraVideoContainer(render: render)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            WatchFooterBar(app: app, uid: uid, sharerName: sharerName)
        }
        window?.contentView = NSHostingView(rootView: container)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    @MainActor
    func close() {
        if let w = window, w.isVisible {
            w.orderOut(nil)
        }
        cleanup()
    }

    /// 自有状态直接清理；对 AppModel（@MainActor）的访问经 Task 跳回主线程
    private func cleanup() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        let uid = watchUid
        let requestId = self.requestId
        let model = self.model
        watchUid = nil
        window = nil
        if let uid, let model {
            Task { @MainActor in
                guard model.voice.watchRequestId == requestId else { return }
                model.voice.watchingUid = nil
                model.agora.clearRemoteVideo(uid: uid)   // 释放渲染句柄
                model.voice.watchDismissed.insert(uid)   // 本次会话不再自动弹出
            }
        }
    }

    /// 用户点窗口关闭按钮（performClose → willClose 通知，主线程）
    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    private func installEscMonitor() {
        if escMonitor != nil { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.window != nil {
                Task { @MainActor in self.close() }
                return nil
            }
            return event
        }
    }
}

/// 观看窗底部条：共享声音只调共享连接，不改变共享者的语音音量。
/// 用内联而非悬停浮层：上方是 Agora 渲染 NSView，SwiftUI 浮层会被它压住。
struct WatchFooterBar: View {
    @ObservedObject var app: AppModel
    let uid: UInt32
    let sharerName: String?

    var body: some View {
        HStack(spacing: 14) {
            Text("共享者：\(sharerName.map { "\($0) (\(uid))" } ?? "uid \(uid)")")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            InlineVolumeSlider(volume: Binding(
                get: { app.voice.shareListenVolumes[String(uid)] ?? 100 },
                set: { app.sharing.setListenVolume(uid: uid, volume: $0) }
            ))
            .help("共享音量（0–400，100 为原始）")
            Button(app.voice.micMuted ? "开麦" : "闭麦") {
                app.agora.setMic(muted: !app.voice.micMuted)
            }
            .buttonStyle(.plain)
            .foregroundColor(app.voice.micMuted ? Theme.danger : Theme.speaking)
            Spacer()
            Text("按 Esc 或关闭窗口退出观看")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Agora 远端视频渲染容器
struct AgoraVideoContainer: NSViewRepresentable {
    let render: AgoraRenderView

    func makeNSView(context: Context) -> NSView { render }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AgoraRenderView: NSView {
    let uid: UInt32
    private weak var app: AppModel?

    init(uid: UInt32, app: AppModel) {
        self.uid = uid
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Task { @MainActor in
                self.app?.agora.setupRemoteVideo(uid: self.uid, view: self)
            }
        }
    }
}
