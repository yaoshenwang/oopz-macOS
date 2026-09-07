import Foundation

/// Bounded local diagnostics. Never log request headers, bodies or RTC tokens.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "cn.oopz.diagnostics")
    static func write(_ message: DiagnosticMessage) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        queue.async {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Oopz")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("diagnostic-\(ProcessInfo.processInfo.processIdentifier).jsonl")
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: file)
            }
            let safe = message.text
            guard var data = try? JSONSerialization.data(withJSONObject: ["schema": "private-interpolation-v1", "time": Date().timeIntervalSince1970, "version": version, "message": safe]) else { return }
            data.append(10)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            if let handle = try? FileHandle(forWritingTo: file) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
            // Keep the newest eight process logs.
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "jsonl" }.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in files.dropFirst(8) { try? FileManager.default.removeItem(at: old) }
        }
    }
}
