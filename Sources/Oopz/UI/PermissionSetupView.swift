import SwiftUI
import AppKit
import AVFoundation

/// 常驻入口页：权限处理完成后自动进入应用，不在入房/共享时补弹模态框。
struct PermissionSetupView: View {
    @ObservedObject var permissions: PermissionCenter

    private var micDetail: String {
        switch permissions.microphone {
        case .authorized: return "已就绪"
        case .notDetermined: return "请允许 Oopz 使用麦克风，进入语音频道前完成设置。"
        case .restricted: return "麦克风受到系统或设备管理限制，请检查设备的隐私策略。"
        default: return "请在系统设置的「麦克风」中允许 Oopz。"
        }
    }
    private var screenDetail: String {
        switch permissions.screen {
        case .checking: return "正在检查屏幕共享是否可用…"
        case .ready: return "已就绪"
        case .needsAccess: return "当前 Oopz 尚不能访问屏幕。请在「屏幕与系统音频录制」中允许此应用。"
        case .notEffective: return "系统预检显示已允许，但屏幕服务仍拒绝访问。请退出并重新打开 Oopz 后复查。"
        case .failed(let code): return "屏幕服务检查失败：\(code)。这不等于未授权，请重试。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("先准备好语音和共享")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("在进入应用时完成权限检查，就绪后自动继续。")
                .foregroundColor(Theme.textSecondary)
            row("麦克风", icon: "mic", detail: micDetail,
                ready: permissions.microphone == .authorized, action: PermissionCenter.openMicSettings)
            row("屏幕与系统音频录制", icon: "rectangle.on.rectangle", detail: screenDetail,
                ready: permissions.screen == .ready, action: PermissionCenter.openScreenSettings)
            if !permissions.ready {
                DisclosureGroup("已经允许过，但仍未就绪？") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("返回应用时会自动复查。如果系统要求重新打开应用，请退出后重新打开。若仍无法使用，请确认设置中允许的是下方这一份 Oopz，而非旧版或网页壳；必要时移除旧条目并重新添加此应用。")
                        Text(Bundle.main.bundleURL.path).textSelection(.enabled)
                        Button("在 Finder 中定位当前应用") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }.buttonStyle(.plain).foregroundColor(Theme.accent)
                    }
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(.top, 8)
                }
                .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 16) {
                Button(permissions.checking ? "正在检查…" : "重新检查并继续") {
                    Task { await permissions.refresh(requestMissing: true) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(permissions.checking)
                Button("退出 Oopz") { AppDelegate.shared.doQuit() }
                    .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
            }
        }
        .frame(maxWidth: 540).padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
    private func row(_ title: String, icon: String, detail: String, ready: Bool,
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ready ? "checkmark.circle.fill" : icon)
                .font(.system(size: 22)).foregroundColor(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if !ready {
                Button("系统设置", action: action).buttonStyle(.plain)
                    .foregroundColor(Theme.accent).disabled(permissions.checking)
            }
        }
        .padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}
