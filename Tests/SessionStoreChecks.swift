struct OopzSession: Codable {
    var uid: String
    var jwt: String
    var deviceId: String
}
let session = OopzSession(uid: "synthetic-test-user", jwt: "synthetic-session-value", deviceId: "synthetic-device")
SessionStore.saveSession(session)
precondition(SessionStore.loadSession()?.uid == session.uid)
let rootAttributes = try FileManager.default.attributesOfItem(atPath: SessionStore.dir.path)
precondition((rootAttributes[.posixPermissions] as! NSNumber).intValue == 0o700)
for relative in ["session.json", "accounts/synthetic-test-user/session.json"] {
    let attributes = try FileManager.default.attributesOfItem(atPath: SessionStore.dir.appendingPathComponent(relative).path)
    precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
}
SessionStore.saveSession(OopzSession(uid: "../outside", jwt: "synthetic", deviceId: "synthetic"))
precondition(!FileManager.default.fileExists(atPath: SessionStore.dir.appendingPathComponent("outside/session.json").path))
SessionStore.clearSession()
precondition(SessionStore.loadSession() == nil)
print("PASS: isolated session persistence, private permissions and account path rejection")
