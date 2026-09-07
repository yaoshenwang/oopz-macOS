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
                WebLoginSheet(onDone: { uid, jwt in
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
        app.ensurePrivateKey()
        guard SessionStore.loadPrivateKey() != nil else {
            app.showToast("尚未配置连接所需的协议认证材料，请参阅项目的开发配置说明。")
            return
        }
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

/// 官方网页登录窗（web.oopz.cn），成功后读 localStorage session__OopzSession
struct WebLoginSheet: NSViewRepresentable {
    let onDone: (String, String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .init(x: 0, y: 0, width: 420, height: 640))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://web.oopz.cn/")!))
        container.addSubview(webView)
        context.coordinator.webView = webView

        let closeButton = NSButton(title: "取消", target: context.coordinator, action: #selector(Coordinator.cancel))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 420 - 74, y: 640 - 34, width: 60, height: 26)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(closeButton)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebLoginSheet
        var webView: WKWebView?

        init(_ parent: WebLoginSheet) { self.parent = parent }

        @objc func cancel() { parent.onCancel() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkSession(webView)
        }

        private func checkSession(_ webView: WKWebView) {
            let js = """
            (function(){
              try {
                var raw = localStorage.getItem('session__OopzSession');
                if (!raw) return '';
                var o = JSON.parse(raw);
                if (o && o.signature && o.uid) return o.uid + '|' + o.signature;
              } catch(e) {}
              return '';
            })()
            """
            webView.evaluateJavaScript(js) { result, _ in
                if let s = result as? String, s.contains("|") {
                    let parts = s.components(separatedBy: "|")
                    DispatchQueue.main.async { self.parent.onDone(parts[0], parts[1]) }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            checkSession(webView)
            decisionHandler(.allow)
        }
    }
}
