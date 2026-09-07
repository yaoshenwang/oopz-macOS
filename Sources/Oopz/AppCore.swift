import AppKit
import SwiftUI

/// 进程运行态：无头模式（集成检查／导入）下抑制一切前台副作用
/// （悬浮条、音效、模态弹窗），保证测试不抢用户桌面。
enum RunMode {
    static var headless = false
}

/// 应用入口：菜单/托盘/关窗驻留（复刻官方「关闭进托盘不断麦」行为）
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
    @Published var quitting = false
    private var statusItem: NSStatusItem?
    @MainActor let model = AppModel()

    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 全应用为自定义深色主题：强制深色外观，保证分段控件/Toggle/滑条/菜单等
        // 系统控件在浅色系统设置下也不会出现"浅底浮层+深色字"或对比度混乱
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // 语音应用不能被 App Nap 节流（关窗驻留/无窗口场景）
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Oopz 语音连麦")
        // headless 模式（会话导入／协议材料导入／集成检查）：无窗口、accessory、不激活
        if SmokeTest.isHeadless() {
            RunMode.headless = true
            NSApp.setActivationPolicy(.accessory)
            let app = model
            Task { await SmokeTest.runHeadless(app: app) }
            return
        }

        NSApp.setActivationPolicy(.regular)
        // 单实例锁：同机第二个 GUI 实例会互踢登录态（同 bundle id / 同账号），
        // 直接提示退出；集成检查在启动前结束旧实例。
        guard AppLock.acquire() else {
            let alert = NSAlert()
            alert.messageText = "Oopz 已在运行"
            alert.informativeText = "同机开第二个实例会互踢登录状态。请使用已有窗口（托盘图标可唤起）。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            _exit(1)
        }
        setupMenu()
        setupTray()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Oopz"
        window.minSize = NSSize(width: 980, height: 620)
        window.contentView = NSHostingView(rootView: RootAppView(app: model))
        window.backgroundColor = NSColor(Theme.bg)
        window.isReleasedWhenClosed = false
        self.window = window
        // 记忆窗口位置/尺寸（首次无保存时居中）
        window.setFrameAutosaveName("OopzMainWindow")
        if UserDefaults.standard.string(forKey: "NSWindow Frame OopzMainWindow") == nil {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task {
            await model.permissions.refresh(requestMissing: true)
            await model.boot()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !RunMode.headless, model.permissions.started else { return }
        Task { await model.permissions.refresh() }
    }

    var window: NSWindow? {
        didSet { watchClose() }
    }

    private var closeObservation: Any?

    /// 关窗 = 隐藏（语音不断），托盘/菜单可真正退出
    private func watchClose() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillCloseNote),
            name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func windowWillCloseNote() {
        if !quitting { window?.orderOut(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 所有退出路径（菜单 ⌘Q / AppleScript / 系统注销关机）统一走优雅退出：
    /// 先 REST 退房 + 引擎离房，再 _exit(0)。
    /// 必须用 _exit：NSApp.terminate 和 exit() 都会触发 Agora 注册的
    /// willTerminate 观察者/C++ 静态析构 → IRtcEngine::release → mpq 死锁（实测 2026-09-06）。
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        Task { @MainActor in
            await self.gracefulCleanup()
            _exit(0)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// 深链入口：oopz:// 链接（注册于 Info.plist CFBundleURLTypes）
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            model.log("open url: \(url.absoluteString)")
            Task { @MainActor in await model.handleDeepLink(url) }
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model.agora.teardown()
    }

    /// 真正退出（菜单/托盘/Cmd+Q）：清理后 _exit(0)（理由见 applicationShouldTerminate）
    @MainActor
    func doQuit() {
        guard !quitting else { return }
        quitting = true
        Task { @MainActor in
            await self.gracefulCleanup()
            _exit(0)
        }
    }

    /// REST 退房 → 引擎完整离房（等 leaveChannel 回调）→ 拆引擎 → 断信令
    @MainActor
    private func gracefulCleanup() async {
        await model.sharing.stop()
        await model.sharing.closeWatch()
        if model.voice.joined {
            try? await model.api.leaveVoiceChannel(areaId: model.voice.areaId, channelId: model.voice.channelId)
            await model.agora.leaveRoom()
        }
        model.agora.teardown()
        model.ws.disconnect()
    }

    // MARK: 菜单（复制/粘贴等必需 role + About + 麦克风快捷键）

    private func setupMenu() {
        let main = NSMenu()
        let appMenu = NSMenuItem()
        main.addItem(appMenu)
        let appSub = NSMenu()
        appSub.addItem(withTitle: "关于 Oopz", action: #selector(showAbout), keyEquivalent: "").target = self
        appSub.addItem(.separator())
        appSub.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appSub.addItem(withTitle: "通过邀请链接加入…", action: #selector(joinByInvite), keyEquivalent: "").target = self
        appSub.addItem(.separator())
        let micItem = appSub.addItem(withTitle: "切换麦克风", action: #selector(toggleMic), keyEquivalent: "m")
        micItem.target = self
        micItem.keyEquivalentModifierMask = [.command, .shift]
        appSub.addItem(.separator())
        appSub.addItem(withTitle: "退出 Oopz", action: #selector(quitNow), keyEquivalent: "q").target = self
        appMenu.submenu = appSub

        let edit = NSMenuItem()
        main.addItem(edit)
        let editSub = NSMenu(title: "编辑")
        editSub.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editSub.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editSub.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editSub.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editSub

        let win = NSMenuItem()
        main.addItem(win)
        let winSub = NSMenu(title: "窗口")
        winSub.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winSub.addItem(withTitle: "关闭窗口（驻留语音）", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.submenu = winSub

        NSApp.mainMenu = main
    }

    @MainActor @objc private func showAbout() {
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Oopz for macOS"
        alert.informativeText = """
        原生客户端 \(ver) · macOS 14+

        非官方社区客户端，用于互操作性研究与自用。
        OOPZ 服务与品牌归绍兴未来山海科技所有。

        当前登录：\(model.api.session?.name ?? model.me?.name ?? "未登录")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    /// ⌘⇧M：应用内快速开闭麦
    @objc private func toggleMic() {
        Task { @MainActor in
            guard model.voice.joined else {
                model.showToast("请先加入语音频道")
                return
            }
            model.agora.setMic(muted: !model.voice.micMuted)
        }
    }

    /// 通过邀请链接/邀请码加入域（支持粘贴完整链接或裸 code）
    @MainActor @objc private func joinByInvite() {
        let alert = NSAlert()
        alert.messageText = "通过邀请加入"
        alert.informativeText = "粘贴好友发来的邀请链接（https://oopz.cn/i/…）或邀请码"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "加入")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        var code: String?
        if let url = URL(string: raw), url.scheme != nil {
            code = AppModel.inviteCode(from: url)
        }
        if code == nil {
            // 裸 code：形如路径段的直接用
            code = raw.contains("/") ? String(raw.split(separator: "/").last ?? "") : raw
        }
        guard let code, !code.isEmpty else {
            model.showToast("无法识别邀请链接")
            return
        }
        Task { @MainActor in await model.joinByInviteCode(code) }
    }

    /// 轻量检查更新：读取用户配置的 JSON（defaults write cn.oopz.mac oopz_update_url <url>）
    /// 格式 {"version":"0.1.2","url":"https://…/Oopz.dmg","notes":"…"}
    @MainActor @objc private func checkForUpdates() {
        let key = "oopz_update_url"
        guard let s = UserDefaults.standard.string(forKey: key), let url = URL(string: s), url.scheme?.hasPrefix("http") == true else {
            let alert = NSAlert()
            alert.messageText = "未配置更新源"
            alert.informativeText = """
            自用客户端暂无内置更新服务器。可在终端配置任意 HTTP JSON 更新源后使用本功能：

            defaults write cn.oopz.mac oopz_update_url "https://example.com/oopz_update.json"

            JSON 格式：{"version":"0.1.2","url":"https://…/Oopz.dmg","notes":"更新说明"}
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好的")
            NSApp.activate(ignoringOtherApps: true)
            _ = alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "检查更新"
        alert.addButton(withTitle: "好的")
        alert.addButton(withTitle: "下载")
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let remote = obj["version"] as? String ?? ""
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let isNewer = remote.compare(current, options: .numeric) == .orderedDescending
                if isNewer, let dl = obj["url"] as? String {
                    alert.messageText = "发现新版本 \(remote)"
                    alert.informativeText = (obj["notes"] as? String ?? "") + "\n\n当前版本 \(current)。"
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertSecondButtonReturn, let dlURL = URL(string: dl) {
                        NSWorkspace.shared.open(dlURL)
                    }
                } else {
                    alert.messageText = "已是最新版本"
                    alert.informativeText = "当前版本 \(current)（远端 \(remote.isEmpty ? "未知" : remote)）。"
                    NSApp.activate(ignoringOtherApps: true)
                    _ = alert.runModal()
                }
            } catch {
                alert.messageText = "检查更新失败"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                _ = alert.runModal()
            }
        }
    }

    @objc private func quitNow() {
        Task { @MainActor in
            doQuit()
        }
    }

    // MARK: 托盘

    private func setupTray() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        item.button?.image = NSImage(systemSymbolName: "headphones.circle.fill", accessibilityDescription: "Oopz")?
            .withSymbolConfiguration(config)
        let menu = NSMenu()
        menu.addItem(withTitle: "打开主窗口", action: #selector(showMain), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "切换麦克风", action: #selector(toggleMic), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quitNow), keyEquivalent: "").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func showMain() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 根视图（boot / login / main 三态）。toast 在此层渲染——登录/启动页的错误提示不再静默。
struct RootAppView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Group {
            if !app.permissions.ready {
                PermissionSetupView(permissions: app.permissions)
            } else {
                switch app.screen {
                case .boot:
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.regular)
                        Text(app.bootMessage)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                case .login:
                    LoginView(app: app)
                case .main:
                    RootView(app: app)
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .padding(.top, 56)
                    .transition(.opacity)
                    .accessibilityLabel("提示：\(toast)")
            }
        }
        .animation(.easeOut(duration: 0.18), value: app.screen)
    }
}
