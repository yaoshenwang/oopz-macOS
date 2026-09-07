import AppKit
import AVFoundation
import Combine
import CoreGraphics
import ScreenCaptureKit

/// 每次启动/返回前台重新检查，不把“向导运行过”当作授权。
/// 系统调用集中在 live backend；无头模式不查询 TCC、不弹窗、不读取屏幕内容。
@MainActor
final class PermissionCenter: ObservableObject {
    enum ScreenAccess: Equatable {
        case checking, ready, needsAccess, notEffective, failed(String)
    }
    struct Backend {
        var microphone: () -> AVAuthorizationStatus
        var requestMicrophone: () async -> Bool
        var screenPreflight: () -> Bool
        var probeScreen: () async throws -> Void
    }
    private static var live: Backend {
        Backend(
            microphone: { RunMode.headless ? .notDetermined : AVCaptureDevice.authorizationStatus(for: .audio) },
            requestMicrophone: {
                guard !RunMode.headless else { return false }
                return await AVCaptureDevice.requestAccess(for: .audio)
            },
            screenPreflight: { !RunMode.headless && CGPreflightScreenCaptureAccess() },
            probeScreen: {
                guard !RunMode.headless else { throw CancellationError() }
                // 仅枚举，不创建截图/音频/视频流；首次调用由 macOS 请求屏幕权限。
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            })
    }
    private let backend: Backend
    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var screen: ScreenAccess = .checking
    @Published private(set) var checking = false
    private(set) var started = false
    var ready: Bool { microphone == .authorized && screen == .ready }

    init(backend: Backend? = nil) { self.backend = backend ?? Self.live }

    /// 串行检查：系统弹窗引发的前后台通知不能启动第二轮授权。
    func refresh(requestMissing: Bool = false) async {
        guard !checking else { return }
        started = true
        checking = true
        defer { checking = false }
        microphone = backend.microphone()
        if requestMissing && microphone == .notDetermined {
            _ = await backend.requestMicrophone()
            microphone = backend.microphone()
        }
        let preflight = backend.screenPreflight()
        do {
            try await backend.probeScreen()
            // ScreenCaptureKit 成功优先于可能滞后的 CGPreflight；空列表也不是拒绝授权。
            screen = .ready
        } catch is CancellationError {
            return
        } catch {
            recordScreenFailure(error, preflight: preflight)
        }
    }

    static func isScreenPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userDeclined.rawValue
    }

    func recordScreenFailure(_ error: Error, preflight: Bool? = nil) {
        if Self.isScreenPermissionError(error) {
            screen = (preflight ?? backend.screenPreflight()) ? .notEffective : .needsAccess
        } else {
            let e = error as NSError
            screen = .failed("\(e.domain) (\(e.code))")
        }
    }

    static func openPrivacySettings(_ pane: String) {
        guard !RunMode.headless else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    static func openScreenSettings() { openPrivacySettings("Privacy_ScreenCapture") }
    static func openMicSettings() { openPrivacySettings("Privacy_Microphone") }
}
