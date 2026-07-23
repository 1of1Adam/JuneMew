//
//  NotchDashboardView.swift
//  MewNotch
//

import SwiftUI
import KLineCore

/// 点击展开的交易仪表盘 —— 一座从刘海里长出来的灵动岛。
///
/// 折叠态只回答一个问题：「这根 K 线还剩多久」。这里回答其余所有问题 ——
/// 每个周期还剩多久、今天是什么时段、接下来什么数据会动市场、时钟可不可信 ——
/// 并把盘中最常改的两个设置（周期、声音）放到手边。
///
/// # 设计语言
///
/// - **一条视觉主轴**：全部区块共享同一内容宽度与同一水平内边距，
///   左右呼吸对称；任何行都不许贴到岛的边缘。
/// - **亮度阶梯分层**（0.92 主 → 0.75 次 → 0.55 辅 → 0.38 弱）；
///   琥珀只留给「现在 / 注意」——当前周期、下一个数据、大幅意外。
///   这套体系对所有色觉类型有效，全面板不引入红绿轴。
/// - **分区靠渐变细线**，中间最亮、两端消隐 —— 岛内的分割应该是
///   呼吸的间隙，不是生硬的横杠。
/// - **面板里没有常驻动画，数字硬切。** 折叠态用几天克制换来的
///   「运动 = 报警」条件反射，不能被一个装饰性面板毁掉。
struct NotchDashboardView: View {

    @ObservedObject var notchViewModel: NotchViewModel

    /// 由 NotchView 持有的展开状态。面板里点 Settings 后要收起自己。
    @Binding var isExpanded: Bool

    @ObservedObject private var engine = CountdownEngine.shared
    @ObservedObject private var defaults = CountdownDefaults.shared

    @Environment(\.openSettings) private var openSettings

    /// 面板内容的固定宽度。
    ///
    /// **必须定宽。** 控制行里有 `Spacer`，而这棵子树最终挂在一个被提议
    /// 全屏宽度的容器里 —— 不钉住宽度，Spacer 会把黑色形体撑成一条
    /// 横贯屏幕的横幅（实测如此），而不是刘海下的一座岛。
    /// 取值以日历行为准：520 放得下中文标题与全部数值列；
    /// 周期卡片按此均分。
    static let contentWidth: CGFloat = 520

    var body: some View {
        Group {
            switch engine.presentation {
            case .counting:
                countingDashboard()
            case let .fault(fault):
                faultPanel(fault)
            case let .dormant(dormancy):
                dormantPanel(dormancy)
            }
        }
        .frame(width: Self.contentWidth)
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 13)
    }

    // MARK: - 正常计时

    /// 周期卡选中框的 matchedGeometry 命名空间 —— 切周期时琥珀框
    /// 从旧卡**滑**到新卡，而不是这边灭那边亮。
    @Namespace private var periodSelection

    /// 级联进场开关。面板每次展开都是全新的视图树（`if isExpanded`），
    /// 所以 @State 天然复位，onAppear 再翻真，三个区块依次落位。
    @State private var cascadeIn = false

    @ViewBuilder
    private func countingDashboard() -> some View {
        VStack(spacing: 10) {
            if let dashboard = engine.dashboard {
                HStack(spacing: 8) {
                    ForEach(dashboard.entries) { entry in
                        PeriodCard(
                            period: entry.period,
                            remainingText: entry.remainingText,
                            isCurrent: entry.period == defaults.period,
                            selectionNamespace: periodSelection
                        ) {
                            select(entry.period)
                        }
                    }
                }
                .cascade(0, shown: cascadeIn)
            }

            calendarBlock(startingAt: 1)

            Group {
                GradientDivider()
                controls()
            }
            .cascade(3, shown: cascadeIn)
        }
        .onAppear { cascadeIn = true }
    }

    /// 切换主周期。与设置页同一套保险：值没变不动、只夹取不重置 ——
    /// 这两条是「响铃阈值被静默重置」的修复，绕过它们等于把 bug 请回来。
    /// withAnimation 让选中框的 matchedGeometry 补间与文字变色同一事务。
    private func select(_ period: BarPeriod) {
        guard period != defaults.period else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            defaults.period = period
        }
        defaults.clampThresholdsToPeriod()
    }

    // MARK: - 经济日历

    /// 经济日历区（设置里可整体关掉）。带自己的上分割线，
    /// 关闭时连分割线一起消失，面板回到纯倒计时形态。
    @ViewBuilder
    private func calendarBlock(startingAt baseIndex: Int = 0) -> some View {
        if defaults.calendarEnabled {
            Group {
                GradientDivider()
                NotchCalendarSection()
            }
            .cascade(baseIndex, shown: cascadeIn)
        }
        if defaults.newsEnabled {
            Group {
                GradientDivider()
                NotchNewsSection()
            }
            .cascade(baseIndex + 1, shown: cascadeIn)
        }
    }

    // MARK: - 控制行

    private func controls() -> some View {
        HStack(spacing: 8) {
            HoverChip {
                defaults.soundEnabled.toggle()
            } content: {
                HStack(spacing: 5) {
                    Image(
                        systemName: defaults.soundEnabled ? "bell.fill" : "bell.slash.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(
                        defaults.soundEnabled
                            ? MewNotch.CountdownColors.icon
                            : Color.white.opacity(0.45)
                    )

                    Text(
                        defaults.soundEnabled
                            ? "收线前 \(defaults.soundThreshold) 秒响铃"
                            : "已静音"
                    )
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
                }
            }

            Spacer(minLength: 20)

            HoverChip {
                // 先收面板再开设置窗，否则设置窗抢焦点后 onHover 不再回调，
                // 面板会僵在展开态。
                isExpanded = false
                openSettings()
            } content: {
                Image(systemName: "gear")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
    }

    // MARK: - 休市

    @ViewBuilder
    private func dormantPanel(_ dormancy: Dormancy) -> some View {
        switch dormancy {
        case .featureDisabled:
            // 正常到不了这里（featureDisabled 时点击不展开）；
            // 只在「展开期间用户从菜单关掉功能」的窗口内短暂可见。
            Text("倒计时已关闭")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.5))

        case let .marketClosed(nextOpen):
            VStack(spacing: 6) {
                Label("已休市", systemImage: "moon.zzz.fill")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))

                if let nextOpen {
                    Text("开盘 \(etTime(nextOpen)) · 本地 \(localTime(nextOpen))")
                        .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.5))

                    // 每分钟刷一次相对时间。dormant 期间 presentation 不再变化
                    //（Equatable 去重），不自己刷的话这行会永远停在展开瞬间的值。
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(relativeToOpen(nextOpen, now: context.date))
                            .font(
                                .system(size: 11, weight: .semibold, design: .rounded)
                                    .monospacedDigit()
                            )
                            .foregroundStyle(MewNotch.CountdownColors.icon)
                    }
                }

                // 休市时日历反而最有用：周日晚上看「下周有什么」正是此刻
                calendarBlock()
                    .padding(.top, 3)
            }
            .onAppear { cascadeIn = true }
        }
    }

    private func etTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date) + " ET"
    }

    private func localTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }

    private func relativeToOpen(_ open: Date, now: Date) -> String {
        let seconds = max(0, Int(open.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "距开盘 \(hours) 时 \(minutes) 分"
        }
        return "距开盘 \(max(1, minutes)) 分"
    }

    // MARK: - 故障

    /// 折叠态只有一个告警字形，详情藏在 tooltip 里 —— 而 tooltip 要悬停
    /// 一秒多才出现，很多人根本不知道它存在。展开面板把同一份文案
    /// 直接摊开：展开本来就是「用户在索取信息」的时刻。
    private func faultPanel(_ fault: Fault) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MewNotch.Assets.icWarning
                .font(.system(size: 12))
                .foregroundStyle(MewNotch.CountdownColors.fault)

            VStack(alignment: .leading, spacing: 3) {
                Text("倒计时不可用")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))

                Text(fault.userDescription)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 周期卡片

/// 矩阵里的单个周期。
///
/// 当前主周期用琥珀 tint 底 + 细描边 —— 「选中」是一种状态，不是一块
/// 更亮的灰；琥珀与折叠态图标同色，视觉上回答「刘海上那个数字是哪一格」。
/// 选中框通过 matchedGeometryEffect 在卡片间**滑动**：切周期是面板里
/// 最高频的主动操作，值得一段真正的过渡而不是两次硬切。
private struct PeriodCard: View {

    let period: BarPeriod
    let remainingText: String
    let isCurrent: Bool
    let selectionNamespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2.5) {
                Text(period.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        isCurrent ? Color.white.opacity(0.95) : Color.white.opacity(0.4)
                    )

                Text(remainingText)
                    .font(
                        .system(size: 12, weight: .semibold, design: .rounded)
                            .monospacedDigit()
                    )
                    .foregroundStyle(
                        isCurrent
                            ? MewNotch.CountdownColors.icon
                            : Color.white.opacity(0.88)
                    )
            }
            // 等分面板宽度；高度固定。maxWidth 让 HStack 把六张卡摊平，
            // 每张恒等宽 —— 整点时 "0:47:12" 变 "0:59:59" 也不会位移。
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(MewNotch.CountdownColors.icon.opacity(0.13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(
                                    MewNotch.CountdownColors.icon.opacity(0.32),
                                    lineWidth: 1
                                )
                        )
                        .matchedGeometryEffect(id: "period-selection", in: selectionNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(hovering ? 0.06 : 0))
                }
            }
            .animation(.easeOut(duration: 0.13), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isCurrent ? "当前周期" : "切换倒计时到 \(period.displayName)")
    }
}

// MARK: - 级联进场

/// 展开时面板区块依次落位：轻微上移 + 透明 → 就位。间隔 45ms ——
/// 快到读不出「排队」，只留下「岛是活的」的质感。只在进场时生效；
/// 收起走整体 panelReveal，不排队。
private struct CascadeIn: ViewModifier {
    let index: Int
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -7)
            .animation(
                .spring(response: 0.42, dampingFraction: 0.86)
                    .delay(Double(index) * 0.045),
                value: shown
            )
    }
}

extension View {
    func cascade(_ index: Int, shown: Bool) -> some View {
        modifier(CascadeIn(index: index, shown: shown))
    }
}

// MARK: - 分割线

/// 岛内分区线：中间最亮、两端消隐。全宽的实线在黑底上是一根横杠，
/// 渐隐让分区读成「呼吸的间隙」。
struct GradientDivider: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0.11), location: 0.18),
                .init(color: .white.opacity(0.11), location: 0.82),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }
}

// MARK: - 控制行按钮

/// 面板内的轻量按钮：hover 时浮出一层底色，按下即执行。
/// 不用系统 Button 样式 —— 刘海窗口永远不是 key window，
/// 系统样式的按压/聚焦态在这里表现不稳定，自绘反而简单可靠。
struct HoverChip<Content: View>: View {

    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
                )
                .animation(.easeOut(duration: 0.13), value: hovering)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
