import Foundation
import Darwin

/// 会话与签名私钥持久化（Application Support 文件存储，0600 权限）。
/// 文件方式避免运行时访问签名身份或系统钥匙串。
///
/// 账号隔离：当前会话仍写 `session.json`（启动默认账号）；同时镜像到
/// `accounts/<uid>/session.json`。设备 ID 按 uid 分键，避免同机双号共用一台设备。
enum SessionStore {
    static let dir: URL = {
        // Priority: explicit data directory, environment override, application default.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count, !args[i + 1].isEmpty {
            let u = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return u
        }
        // Explicit storage override; account-level integration locking still applies.
        if let custom = ProcessInfo.processInfo.environment["OOPZ_DATA_DIR"], !custom.isEmpty {
            let u = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return u
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oopz", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base
    }()

    static func _write(_ data: Data, name: String) {
        let url = dir.appendingPathComponent(name)
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            let pending = parent.appendingPathComponent(".pending-" + UUID().uuidString)
            let fd = Darwin.open(pending.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: pending) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard Darwin.rename(pending.path, url.path) == 0 else { return }
        } catch { /* Do not log account paths or serialized data. */ }
    }

    static func _read(name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func saveSession(_ s: OopzSession) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        _write(d, name: "session.json")
        if !s.uid.isEmpty && s.uid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            _write(d, name: "accounts/\(s.uid)/session.json")
        }
    }

    static func loadSession() -> OopzSession? {
        guard let d = _read(name: "session.json") else { return nil }
        return try? JSONDecoder().decode(OopzSession.self, from: d)
    }

    static func clearSession() {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("session.json"))
    }

    static func savePrivateKey(_ der: Data) {
        _write(der, name: "sign_rsa.der")
    }

    static func loadPrivateKey() -> Data? {
        _read(name: "sign_rsa.der")
    }

    /// 偏好键按账号隔离（音量/音质）；无 uid 时退回全局键以兼容旧数据。
    static func prefKey(_ base: String, uid: String?) -> String {
        guard let uid, !uid.isEmpty else { return base }
        return "\(base).\(uid)"
    }
}

/// 单实例锁：GUI 第二进程直接退出，避免同 bundle id 互踢登录态。
/// 无头测试（--smoke / --feat-test 等）不抢锁。
enum AppLock {
    private static var handle: FileHandle?

    static func acquire() -> Bool {
        let url = SessionStore.dir.appendingPathComponent("app.lock")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return true }
        if flock(fh.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            try? fh.close()
            return false
        }
        handle = fh
        return true
    }
}

/// A UID lock is shared across data directories. Never rotate credentials in two native instances.
enum AccountLock {
    private static var handle: FileHandle?
    static func acquire(uid: String) -> Bool {
        if handle != nil { return true }
        guard !uid.isEmpty, uid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
        let path = NSTemporaryDirectory() + "oopz-account-" + uid + ".lock"
        let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return false }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return true
    }
}
