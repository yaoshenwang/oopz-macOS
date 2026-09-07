import Foundation
import AVFoundation
import ScreenCaptureKit

/// 真实状态机 + 注入的系统响应：无头回归不调用 TCC、设备或 UserDefaults。
@MainActor
enum PermissionChecks {
    static func run() async -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var mic: AVAuthorizationStatus = .notDetermined
        var requests = 0
        var preflight = false
        var failure: Error?
        var probes = 0
        let center = PermissionCenter(backend: .init(
            microphone: { mic },
            requestMicrophone: { requests += 1; mic = .authorized; return true },
            screenPreflight: { preflight },
            probeScreen: { probes += 1; if let failure { throw failure } }))
        result.append(("首次检查前不开放业务入口", !center.ready))
        await center.refresh(requestMissing: true)
        result.append(("启动请求麦克风；SCK成功覆盖CG预检false", center.ready && requests == 1 && probes == 1))
        await center.refresh(requestMissing: true)
        result.append(("重复进入重新检查且不重复申请已授权麦克风", center.ready && requests == 1 && probes == 2))
        mic = .denied
        await center.refresh(requestMissing: true)
        result.append(("撤销麦克风立即恢复入口页；不重复系统申请", !center.ready && requests == 1))
        mic = .authorized
        failure = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        await center.refresh()
        result.append(("真实屏幕拒绝返回入口页", center.screen == .needsAccess && !center.ready))
        preflight = true
        await center.refresh()
        result.append(("预检允许但SCK拒绝标注未生效", center.screen == .notEffective && !center.ready))
        failure = NSError(domain: "ScreenServiceTest", code: -1)
        await center.refresh()
        result.append(("普通服务错误不冒充未授权", center.screen == .failed("ScreenServiceTest (-1)")))
        result.append(("其他错误域相同错误码不误判权限", !PermissionCenter.isScreenPermissionError(NSError(domain: "Other", code: -3801))))
        failure = nil
        await center.refresh()
        result.append(("设置返回刷新后自动恢复就绪", center.ready))
        mic = .restricted
        await center.refresh(requestMissing: true)
        result.append(("系统受限不重复请求麦克风", !center.ready && requests == 1))
        var concurrentProbes = 0
        let serial = PermissionCenter(backend: .init(
            microphone: { .authorized }, requestMicrophone: { false }, screenPreflight: { false },
            probeScreen: { concurrentProbes += 1; await Task.yield() }))
        let first = Task { await serial.refresh() }
        let second = Task { await serial.refresh() }
        await first.value; await second.value
        result.append(("授权期间前台通知不并发重复探测", concurrentProbes == 1 && serial.ready))
        return result
    }
}
