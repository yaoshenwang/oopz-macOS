import Foundation

/// OOPZ WebSocket 信令。
/// 帧格式：二进制帧（opcode=2）承载 UTF-8 JSON 信封 {"time":"<毫秒串>","event":<int>,"body":"<内层JSON字符串>"}
/// 253 握手 → 1 确认 → 254 心跳(10s) → 249 域订阅/退订；S→C: 19 离开语音 / 20 加入语音 / 33 屏幕共享状态。
/// 连接策略：无限重连（指数退避封顶 60s）；多次失败自动 autoLogin 刷新凭据；
/// 心跳看门狗（35s 无任何下行视为假死强制重连）；状态读写统一走主线程。
final class OopzWS: NSObject, URLSessionWebSocketDelegate {
    enum Event: Int {
        case handshakeAck = 1
        case gimMessage = 9        // 频道文字消息实时推送（实测 2026-09-06）
        case voiceLeave = 19
        case voiceJoin = 20
        case screenShareState = 33
        case heartbeat = 254
    }

    struct Frame {
        let event: Int
        let body: [String: Any]
        let raw: String
    }

    var onEvent: ((Event, [String: Any]) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    /// 业务事件：每一帧业务事件（含未识别编号）都会回调，先于 onEvent 分发
    var onRawFrame: ((Int, [String: Any]) -> Void)?
    /// 调试：仅记录帧到达，不记录业务数据
    var debugLogAll = false
    private(set) var connected: Bool   // 仅主线程读写

    private var task: URLSessionWebSocketTask?
    private lazy var urlSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var heartbeatTimer: Timer?
    private(set) var reconnectAttempts = 0   // 仅主线程
    private let api: OopzAPI
    private let log: (DiagnosticMessage) -> Void
    private var lastDownlinkAt = Date()      // 仅主线程
    private var intentionallyDisconnected = false
    /// 断线期间应恢复的域订阅（由 AppModel 在 onStateChange 回补，此处只负责连）
    var resubscribe: (() -> Void)?

    init(api: OopzAPI, log: @escaping (DiagnosticMessage) -> Void = { _ in }) {
        self.api = api
        self.log = log
        connected = false
        super.init()
    }

    func connect() {
        assertMainThread()
        guard let s = api.session else { return }
        intentionallyDisconnected = false
        let nonce = Int.random(in: 100...9999)
        let urlStr = "\(api.wsBase)/?v=\(OopzAPI.appVersion)&d=\(s.deviceId)&s=\(s.jwt)&p=macos&w=true&r=\(reconnectAttempts)&x=\(nonce)"
        guard let url = URL(string: urlStr) else { return }
        log("WS connect #\(reconnectAttempts)")
        let t = urlSession.webSocketTask(with: url)
        task = t
        lastDownlinkAt = Date()
        t.resume()
        receiveLoop()
        // 服务端握手后不发话：客户端必须先发 253
        sendHandshake()
    }

    func disconnect() {
        assertMainThread()
        intentionallyDisconnected = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        setConnected(false)
    }

    private func setConnected(_ v: Bool) {
        assertMainThread()
        guard connected != v else { return }
        connected = v
        onStateChange?(v)
    }

    private func assertMainThread() {
        dispatchPrecondition(condition: .onQueue(.main))
    }

    private func sendHandshake() {
        guard let s = api.session else { return }
        send(event: 253, body: [
            "person": s.uid,
            "deviceId": s.deviceId,
            "signature": s.jwt,
            "deviceName": s.deviceId,
            "platformName": "macos",
            "web": "true",
            "reconnect": reconnectAttempts,
        ])
        // 握手即启动心跳（官方节奏 10s）；顺带做看门狗检查
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tickHeartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func tickHeartbeat() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard task != nil else { return }
        // 看门狗：35s 无任何下行（含心跳应答）→ 判定假死，强制重连
        if Date().timeIntervalSince(lastDownlinkAt) > 35 {
            log("WS watchdog: 35s 无下行，强制重连")
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            setConnected(false)
            scheduleReconnect()
            return
        }
        guard let uid = api.session?.uid else { return }
        send(event: 254, body: ["person": uid])
    }

    /// 进入域页面订阅（type=1 订阅 / 0 退订）
    func subscribe(areaId: String, on: Bool = true) {
        guard let uid = api.session?.uid else { return }
        send(event: 249, body: ["areas": [areaId], "type": on ? 1 : 0, "uid": uid])
    }

    private func send(event: Int, body: [String: Any]) {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyStr = String(data: bodyData, encoding: .utf8) else { return }
        let env: [String: Any] = [
            "time": String(Int64(Date.now.timeIntervalSince1970 * 1000)),
            "body": bodyStr,
            "event": event,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: env) else { return }
        task?.send(.data(data)) { [weak self] err in
            if let err { self?.log("WS send err: \(err)") }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                DispatchQueue.main.async {
                    self.lastDownlinkAt = Date()
                    self.reconnectAttempts = 0
                    self.setConnected(true)
                    self.handleFrame(data)
                }
                self.receiveLoop()
            case .success(.string(let str)):
                DispatchQueue.main.async {
                    self.lastDownlinkAt = Date()
                    self.handleFrame(Data(str.utf8))
                }
                self.receiveLoop()
            case .success:
                self.receiveLoop()
            case .failure(let err):
                DispatchQueue.main.async {
                    self.log("WS closed: \(err.localizedDescription)")
                    self.setConnected(false)
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleFrame(_ data: Data) {
        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = env["event"] as? Int else { return }
        var body: [String: Any] = [:]
        if let bodyStr = env["body"] as? String, let b = try? JSONSerialization.jsonObject(with: Data(bodyStr.utf8)) as? [String: Any] {
            body = b
        } else if let b = env["body"] as? [String: Any] {
            body = b
        }
        if debugLogAll {
            log("WSFrame received")
        }
        if event != 254 && event != 1 {
            onRawFrame?(event, body)
        }
        switch event {
        case 1:
            log("WS handshake ack")
        case Event.gimMessage.rawValue, Event.voiceJoin.rawValue, Event.voiceLeave.rawValue, Event.screenShareState.rawValue:
            onEvent?(Event(rawValue: event)!, body)
        default:
            break
        }
    }

    private func scheduleReconnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        task = nil
        guard !intentionallyDisconnected else { return }
        reconnectAttempts += 1
        let delay = TimeInterval(min(60, reconnectAttempts * 2))
        let attempt = reconnectAttempts
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.task == nil, !self.intentionallyDisconnected else { return }
            Task { @MainActor [weak self] in
                guard let self, self.task == nil, !self.intentionallyDisconnected else { return }
                // 连续失败先刷新凭据（JWT 可能已被轮换/过期）
                if attempt > 3, let s = self.api.session {
                    if let fresh = try? await self.api.autoLogin(s) {
                        self.api.session = fresh
                        SessionStore.saveSession(fresh)
                        self.log("WS 重连前 autoLogin 刷新凭据成功")
                    }
                }
                self.connect()
            }
        }
    }
}
