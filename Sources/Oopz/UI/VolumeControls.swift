import SwiftUI

/// 音量浮层互斥总线：同一时刻只允许一个悬浮滑条。
/// 旧版各自为政，鼠标从麦滑到耳机时两个面板会短暂（甚至持续）同屏。
final class VolumeHoverBus: ObservableObject {
    static let shared = VolumeHoverBus()
    @Published var activeID: UUID?
    func claim(_ id: UUID) { activeID = id }
    func release(_ id: UUID) { if activeID == id { activeID = nil } }
}

/// 悬停音量滑条。浮层用 background/overlay 锚定（不进布局树尺寸）：
/// 旧版 VStack 占位会把触发图标顶离原位（顶栏图标漂进标题栏、卡片内容被推挤），
/// 且 onHover 偶发漏收 false 会让面板永久卡住——现在离开必重排隐藏任务。
/// 显示权经 VolumeHoverBus 全局互斥（同一时刻仅一个浮层）。
/// 顶栏 `.below` / 卡片 `.overBottom`。
struct HoverVolumeSlider<Trigger: View>: View {
    enum Anchor { case above, below, overBottom }

    let title: String
    @Binding var volume: Int
    var enabled: Bool = true
    var anchor: Anchor = .above
    var width: CGFloat = 210
    @ViewBuilder let trigger: () -> Trigger

    @ObservedObject private var bus = VolumeHoverBus.shared
    @State private var id = UUID()
    @State private var hideTask: Task<Void, Never>?

    private var shown: Bool { enabled && bus.activeID == id }

    private var panelHeight: CGFloat { 38 }
    /// .below 时浮层顶边到触发区顶边的距离（触发区高 + 间隙）
    private var belowGap: CGFloat { 44 }

    var body: some View {
        trigger()
            .frame(minHeight: 34)
            .background(alignment: anchor == .above ? .bottom : .top) {
                if shown, anchor == .above || anchor == .below {
                    panel
                        .padding(anchor == .below ? .top : .bottom, anchor == .below ? belowGap : 8)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if shown, anchor == .overBottom {
                    panel
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
            .onHover { setHover($0) }
            .animation(.easeOut(duration: 0.12), value: shown)
            .zIndex(shown ? 2 : 0)
            .accessibilityElement(children: .contain)
            .onDisappear {
                hideTask?.cancel()
                bus.release(id)
            }
    }

    @ViewBuilder
    private var panel: some View {
        VolumeSliderBar(volume: $volume)
            .padding(.horizontal, 10)
            .frame(width: width, height: panelHeight)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.cardHover))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
            .accessibilityLabel(title)
            .onHover { setHover($0) }
    }

    private func setHover(_ h: Bool) {
        guard enabled else { hideTask?.cancel(); bus.release(id); return }
        if h {
            hideTask?.cancel()
            hideTask = nil
            bus.claim(id)   // 互斥：立即顶掉其他浮层
        } else {
            // 离开总是重新调度隐藏（旧版只在 hideTask==nil 时调度，漏收一次就永久卡住）
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { bus.release(id) }
                hideTask = nil
            }
        }
    }
}

/// 内联音量条（始终可见，不弹层）：观看窗底部条等与 NSView 重叠、无法用浮层的位置。
struct InlineVolumeSlider: View {
    @Binding var volume: Int
    var width: CGFloat = 170

    var body: some View {
        VolumeSliderBar(volume: $volume)
            .frame(width: width)
    }
}

/// 滑条主体：喇叭（点击静音/恢复）+ 0–400 滑条 + 数值
private struct VolumeSliderBar: View {
    @Binding var volume: Int
    @State private var lastNonZero: Int = 100

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if volume == 0 {
                    volume = lastNonZero
                } else {
                    lastNonZero = volume
                    volume = 0
                }
            } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 13))
                    .foregroundColor(volume == 0 ? Theme.danger : Theme.textSecondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(volume == 0 ? "取消静音" : "静音")

            Slider(value: Binding(
                get: { Double(volume) },
                set: { newValue in
                    let v = Int(newValue.rounded())
                    if v != 0 { lastNonZero = v }
                    volume = v
                }), in: 0...400, step: 5)
                .controlSize(.small)
                .tint(Theme.accent)

            Text("\(volume)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 26, alignment: .trailing)
        }
        .onAppear { if volume != 0 { lastNonZero = volume } }
    }

    private var volumeIcon: String {
        if volume == 0 { return "speaker.slash.fill" }
        if volume < 60 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}
