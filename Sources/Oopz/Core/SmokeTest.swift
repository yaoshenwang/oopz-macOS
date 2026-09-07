import Foundation

/// Supported headless commands. Raw probes, password arguments and legacy duo/watch are excluded.
enum SmokeTest {
    static func isHeadless() -> Bool {
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") && $0 != "--data-dir" }
    }
    @MainActor
    static func permissionChecks() async -> [(String, Bool)] { await PermissionChecks.run() }
    @MainActor
    static func runHeadless(app: AppModel) async {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--import-session"), index + 1 < args.count {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: args[index + 1]))
                var session = try JSONDecoder().decode(OopzSession.self, from: data)
                guard !session.uid.isEmpty, !session.jwt.isEmpty,
                      session.uid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                      AccountLock.acquire(uid: session.uid) else { throw OopzError.notLoggedIn }
                if session.deviceId.isEmpty { session.deviceId = SessionDefaults.deviceId }
                SessionStore.saveSession(session)
                guard SessionStore.loadSession()?.uid == session.uid,
                      SessionStore.loadSession()?.jwt == session.jwt else { throw OopzError.notLoggedIn }
                print("PASS: session imported into local application storage")
                _exit(0)
            } catch { print("FAIL: invalid session or account already in use"); _exit(2) }
        }
        if let index = args.firstIndex(of: "--import-protocol-key"), index + 1 < args.count {
            do {
                let der = try Data(contentsOf: URL(fileURLWithPath: args[index + 1]))
                _ = try OopzSign.secKey(fromDER: der)
                SessionStore.savePrivateKey(der)
                guard SessionStore.loadPrivateKey() == der else { throw OopzError.badPrivateKey }
                print("PASS: protocol key imported into local application storage")
                _exit(0)
            } catch { print("FAIL: invalid protocol key file"); _exit(2) }
        }
        if args.contains("--smoke") || args.contains("--feat-test") { await Verification.run(app); return }
        if MediaTest.isRequested() { await MediaTest.run(app: app); return }
        print("Headless commands: --smoke, --media-test, --import-session FILE, --import-protocol-key FILE")
        _exit(args.contains("--help") ? 0 : 2)
    }
}
