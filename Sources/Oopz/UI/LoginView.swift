import SwiftUI
import WebKit

/// 登录页：深色居中卡片，主按钮 OOPZ 蓝。
/// 手机短信下发需图形验证（428），因此提供「官方网页登录」内嵌窗，登录完成后回采 localStorage 会话。
struct LoginView: View {
    @ObservedObject var app: AppModel
    @State private var showWebLogin = false
    @State private var booting = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                logo
                Text("Oopz for macOS")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("游戏开黑语音社区 · 原生客户端")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)

                VStack(spacing: 12) {
                    Button {
                        webLogin()
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("使用 OOPZ 账号登录")
                        }
                        .frame(maxWidth: 260, minHeight: 42)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(booting)

                    if booting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(app.bootMessage).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        }
                    }
                    Text("登录后会话保存在本机应用数据目录（仅当前系统用户可读）")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                Text("社区客户端 · OOPZ 服务由官方提供")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.bottom, 14)
            }
            if showWebLogin {
                WebLoginSheet(onDone: { uid, jwt, key in
                    SessionStore.savePrivateKey(key)
                    showWebLogin = false
                    booting = true
                    Task { await app.adoptWebSession(uid: uid, jwt: jwt) }
                }, onCancel: { showWebLogin = false })
                .frame(width: 420, height: 640)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 30)
            }
        }
    }

    private var logo: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 76, height: 76)
            Image(systemName: "headphones")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func webLogin() {
        booting = true
        Task {
            // 先静默尝试已有会话（用户可能已在官方网页/壳端登录过）
            if SessionStore.loadSession() != nil || SessionStore.loadPrivateKey() != nil {
                await app.boot()
                if app.screen == .main { return }
            }
            booting = false
            showWebLogin = true
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(configuration.isPressed ? Theme.accentDeep : Theme.accent)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// Isolated official login page; native messages require a trusted main-frame origin.
struct WebLoginSheet: NSViewRepresentable {
    let onDone: (String, String, Data) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .init(x: 0, y: 0, width: 420, height: 640))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: WebLoginBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "oopzLogin")
        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        context.coordinator.webView = webView
        webView.load(URLRequest(url: URL(string: "https://web.oopz.cn/")!))
        container.addSubview(webView)
        let closeButton = NSButton(title: "取消", target: context.coordinator, action: #selector(Coordinator.cancel))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 346, y: 606, width: 60, height: 26)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(closeButton)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.webView?.stopLoading()
        coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "oopzLogin")
        coordinator.webView = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let parent: WebLoginSheet
        weak var webView: WKWebView?
        private var completed = false
        init(_ parent: WebLoginSheet) { self.parent = parent }
        @objc func cancel() { completed = true; parent.onCancel() }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !completed, message.name == "oopzLogin", message.webView === webView,
                  message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.host == "web.oopz.cn",
                  message.frameInfo.securityOrigin.protocol == "https",
                  [0, 443].contains(message.frameInfo.securityOrigin.port),
                  let body = message.body as? [String: Any],
                  let uid = body["uid"] as? String, !uid.isEmpty,
                  uid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  let jwt = body["signature"] as? String, !jwt.isEmpty,
                  let encoded = body["protocolKey"] as? String, encoded.count < 16384,
                  let key = Data(base64Encoded: encoded),
                  (try? OopzSign.secKey(fromDER: key)) != nil else { return }
            completed = true
            parent.onDone(uid, jwt, key)
        }
    }
}
