//
//  CountdownView.swift
//  MewNotch
//

import SwiftUI
import KLineCore

struct CountdownView: View {

    @ObservedObject var notchViewModel: NotchViewModel

    /// **必须是 @ObservedObject 引用单例，不能是 @StateObject。**
    /// 每块屏都有一个 NotchView，@StateObject 会产生 N 个引擎、N 个 timer、
    /// 以及每根 K 线 N 次响铃。
    @ObservedObject private var engine = CountdownEngine.shared

    @StateObject private var defaults = CountdownDefaults.shared

    var variant: NotchSlotVariant

    // MARK: - 尺寸

    /// 从刘海高度派生，自动适配不同机型。
    /// h=32 时约 13.4pt，与 NSFont.menuBarFont 同级 ——
    /// 倒计时读起来是菜单栏时钟的同侪，不是喧宾夺主的横幅。
    private var fontSize: CGFloat {
        min(max(notchViewModel.notchSize.height * 0.42, 11), 16)
    }

    /// 用 `.monospacedDigit()` 而不是 `design: .monospaced`：
    /// 前者只锁数字的前进宽度（tnum 特性），冒号和字母保持 SF 的比例形态；
    /// 后者会把冒号也撑成一个完整 advance，"04:32" 白宽约 4pt。
    /// 抖动的根因只是数字宽度变化，`.monospacedDigit()` 是精确对症的修复。
    private var countdownFont: Font {
        .system(size: fontSize, weight: .medium, design: .rounded)
            .monospacedDigit()
    }

    /// `Match_Notch` 模式下黑块比菜单栏高，垂直居中会让数字比系统时钟低一截。
    /// 图标挨着图标看不出来，但文字挨着文字非常明显。
    private var baselineNudge: CGFloat {
        let menuBar = notchViewModel.menuBarHeight
        guard notchViewModel.notchSize.height > menuBar, menuBar > 0 else { return 0 }
        return -(notchViewModel.notchSize.height - menuBar) / 2
    }

    var body: some View {
        // notchSize 可能退化为 0（NotchedDisplayOnly + 外接屏）。
        // 原有 HUD 都是 frame(height: 0) 所以看不见，但 Text 有固有高度会溢出。
        if defaults.isEnabled, notchViewModel.notchSize.height > 1 {
            switch engine.presentation {
            case .dormant:
                // 休市 / 功能关闭：**完全不渲染**，槽位消失，
                // 刘海缩回原生轮廓。不是灰字，不是 opacity(0)。
                EmptyView()

            case let .counting(countdown):
                NotchSlotView(notchViewModel: notchViewModel, variant: variant) {
                    countingContent(countdown)
                }

            case let .fault(fault):
                NotchSlotView(notchViewModel: notchViewModel, variant: variant) {
                    faultContent(fault)
                }
            }
        }
    }

    // MARK: - 正常倒计时

    private func countingContent(_ countdown: Countdown) -> some View {
        // 隐形撑宽：用当前周期可能出现的最宽字符串预留宽度，
        // 保证一根 K 线内刘海宽度恒定，只有换周期时才变。
        Text(countdown.widthTemplate)
            .font(countdownFont)
            .opacity(0)
            .overlay {
                HStack(spacing: 4) {
                    Text(countdown.text)
                        .font(countdownFont)
                        .foregroundStyle(color(for: countdown.phase))
                        .shadow(
                            color: MewNotch.CountdownColors.urgentGlow,
                            radius: countdown.phase == .urgent ? 4 : 0
                        )

                    concernDot(countdown.concerns)
                }
            }
            .offset(y: baselineNudge)
            // 数字硬切。明确否决 .contentTransition(.numericText)：
            // 运动是周边视觉最强的吸引子，每秒滚一次 = 每小时 3600 次动画，
            // 会永久烧掉最后 15 秒真正需要的报警通道 —— 盯盘几天后用户会
            // 下意识屏蔽刘海区域，那时真正的收线提醒也一起被屏蔽了。
            .animation(nil, value: countdown.remainingSeconds)
            // value 绑 phase 枚举而不是秒数，否则每秒都会重跑一次 0.25s 的动画。
            // 0.25s 落在周边视觉变化检测的响应窗口（约 100–300ms）内，
            // 能被察觉为「一个事件」，又不像单帧跳变那样廉价。
            .animation(.easeInOut(duration: 0.25), value: countdown.phase)
    }

    @ViewBuilder
    private func concernDot(_ concerns: [Concern]) -> some View {
        if let severity = concernSeverity(concerns) {
            Circle()
                .fill(severity)
                .frame(width: 4, height: 4)
                .help(concernTooltip(concerns))
        }
    }

    /// 琥珀 > 灰。没有关切项时不画点。
    private func concernSeverity(_ concerns: [Concern]) -> Color? {
        guard !concerns.isEmpty else { return nil }

        for concern in concerns {
            switch concern {
            case .clockDrift, .holidayTableStale, .holidayTableUnverified:
                return MewNotch.CountdownColors.concernAmber
            case .holidayTableExpiringSoon, .clockUnverified:
                continue
            }
        }
        return MewNotch.CountdownColors.concernGray
    }

    private func concernTooltip(_ concerns: [Concern]) -> String {
        concerns.map { concern in
            switch concern {
            case let .clockDrift(seconds):
                return String(format: "System clock is off by %+.1fs", seconds)
            case let .clockUnverified(staleness):
                return "Clock not verified for \(Int(staleness / 3600))h"
            case let .holidayTableExpiringSoon(daysLeft):
                return "Holiday table expires in \(daysLeft) days"
            case let .holidayTableStale(daysStale):
                return "Holiday table expired \(daysStale) days ago"
            case .holidayTableUnverified:
                return "Holiday table has not been verified against the exchange calendar"
            }
        }
        .joined(separator: "\n")
    }

    // MARK: - 故障

    /// **不渲染任何数字。** 对交易工具来说，一个不能相信的倒计时
    /// 比没有倒计时更危险 —— 用户会照着它下单。
    private func faultContent(_ fault: Fault) -> some View {
        MewNotch.Assets.icWarning
            .font(.system(size: fontSize))
            .foregroundStyle(MewNotch.CountdownColors.fault)
            .offset(y: baselineNudge)
            .help(faultDescription(fault))
    }

    private func faultDescription(_ fault: Fault) -> String {
        switch fault {
        case let .clockOffsetExceedsTolerance(offset, threshold):
            return String(
                format: "System clock is off by %+.1fs (tolerance %.0fs). "
                    + "Countdown hidden because it cannot be trusted.",
                offset, threshold
            )
        case let .clockJumped(delta):
            return String(
                format: "System clock jumped by %+.1fs. Recalibrating…", delta
            )
        case let .holidayTableExpired(daysStale):
            return "Holiday table expired \(daysStale) days ago. "
                + "Session boundaries can no longer be trusted."
        case let .holidayTableUnreadable(detail):
            return "Holiday table could not be read: \(detail)"
        case let .calendarInconsistent(detail):
            return "Trading calendar inconsistency: \(detail)"
        }
    }

    private func color(for phase: CountdownPhase) -> Color {
        switch phase {
        case .normal:  return MewNotch.CountdownColors.normal
        case .warning: return MewNotch.CountdownColors.warning
        case .urgent:  return MewNotch.CountdownColors.urgent
        }
    }
}
