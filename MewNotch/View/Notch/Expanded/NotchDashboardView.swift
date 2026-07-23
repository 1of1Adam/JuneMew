//
//  NotchDashboardView.swift
//  MewNotch
//

import SwiftUI
import KLineCore

/// 悬停展开的交易仪表盘。
///
/// 折叠态只回答一个问题：「这根 K 线还剩多久」。这里回答其余所有问题 ——
/// 每个周期还剩多久、今天是什么时段、时钟可不可信 —— 并把盘中最常改的
/// 两个设置（周期、声音）放到手边。信息按「主动索取」组织：面板只在
/// 悬停时存在，常态不给刘海增加任何视觉负担。
///
/// **面板里没有常驻动画，数字硬切。** 折叠态用几天克制换来的
/// 「运动 = 报警」条件反射，不能被一个装饰性面板毁掉。
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
    /// 366 = 周期矩阵的自然宽度（6 张卡 × 56 + 5 段间距 × 6）。
    private static let contentWidth: CGFloat = 366

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
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - 正常计时

    @ViewBuilder
    private func countingDashboard() -> some View {
        VStack(spacing: 9) {
            if let dashboard = engine.dashboard {
                HStack(spacing: 6) {
                    ForEach(dashboard.entries) { entry in
                        PeriodCard(
                            period: entry.period,
                            remainingText: entry.remainingText,
                            isCurrent: entry.period == defaults.period
                        ) {
                            select(entry.period)
                        }
                    }
                }

                infoLines(dashboard)
            }

            divider()

            controls()
        }
    }

    /// 切换主周期。与设置页同一套保险：值没变不动、只夹取不重置 ——
    /// 这两条是「响铃阈值被静默重置」的修复，绕过它们等于把 bug 请回来。
    private func select(_ period: BarPeriod) {
        guard period != defaults.period else { return }
        defaults.period = period
        defaults.clampThresholdsToPeriod()
    }

    private func infoLines(_ dashboard: DashboardModel) -> some View {
        VStack(spacing: 2) {
            Text(engine.todaySessionDescription)

            Text("Session ends in \(dashboard.sessionRemainingText) · \(clockSummary)")
        }
        .font(.system(size: 10.5, weight: .regular, design: .rounded).monospacedDigit())
        .foregroundStyle(Color.white.opacity(0.5))
    }

    /// 一眼能读完的时钟状态。完整数字在设置页 Diagnostics —— 这里只回答
    /// 「要不要担心」。
    private var clockSummary: String {
        switch engine.clockTrust {
        case let .verified(offset, _, _):
            return String(format: "Clock %+.2fs", offset)
        case .unverified:
            return "Clock unverified"
        case .jumped:
            return "Clock jumped"
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
                            ? "Rings \(defaults.soundThreshold)s before close"
                            : "Sound off"
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

    private func divider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    // MARK: - 休市

    @ViewBuilder
    private func dormantPanel(_ dormancy: Dormancy) -> some View {
        switch dormancy {
        case .featureDisabled:
            // 正常到不了这里（featureDisabled 时 hover 不展开）；
            // 只在「展开期间用户从菜单关掉功能」的窗口内短暂可见。
            Text("Countdown is off")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.5))

        case let .marketClosed(nextOpen):
            VStack(spacing: 5) {
                Label("Market closed", systemImage: "moon.zzz.fill")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))

                if let nextOpen {
                    Text("Reopens \(etTime(nextOpen)) · \(localTime(nextOpen)) local")
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
            }
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
            return "opens in \(hours)h \(minutes)m"
        }
        return "opens in \(max(1, minutes))m"
    }

    // MARK: - 故障

    /// 折叠态只有一个告警字形，详情藏在 tooltip 里 —— 而 tooltip 要悬停
    /// 一秒多才出现，很多人根本不知道它存在。展开面板把同一份文案
    /// 直接摊开：悬停本来就是「用户在索取信息」的时刻。
    private func faultPanel(_ fault: Fault) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MewNotch.Assets.icWarning
                .font(.system(size: 12))
                .foregroundStyle(MewNotch.CountdownColors.fault)

            VStack(alignment: .leading, spacing: 3) {
                Text("Countdown unavailable")
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

/// 矩阵里的单个周期。当前主周期琥珀高亮 —— 与折叠态图标同色，
/// 视觉上回答「刘海上那个数字是哪一格」。
private struct PeriodCard: View {

    let period: BarPeriod
    let remainingText: String
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(period.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        isCurrent ? Color.white.opacity(0.9) : Color.white.opacity(0.45)
                    )

                Text(remainingText)
                    .font(
                        .system(size: 12, weight: .semibold, design: .rounded)
                            .monospacedDigit()
                    )
                    .foregroundStyle(
                        isCurrent
                            ? MewNotch.CountdownColors.icon
                            : MewNotch.CountdownColors.normal
                    )
            }
            // 固定尺寸：1H 的 "0:47:12" 是最宽形态，宽度必须容得下它，
            // 否则每逢整点矩阵会集体位移一次。
            .frame(width: 56, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        Color.white.opacity(
                            isCurrent ? 0.12 : (hovering ? 0.06 : 0)
                        )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isCurrent ? "Current period" : "Switch countdown to \(period.displayName)")
    }
}

// MARK: - 控制行按钮

/// 面板内的轻量按钮：hover 时浮出一层底色，按下即执行。
/// 不用系统 Button 样式 —— 刘海窗口永远不是 key window，
/// 系统样式的按压/聚焦态在这里表现不稳定，自绘反而简单可靠。
private struct HoverChip<Content: View>: View {

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
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
