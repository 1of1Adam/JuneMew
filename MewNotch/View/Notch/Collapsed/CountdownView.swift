//
//  CountdownView.swift
//  MewNotch
//

import SwiftUI
import KLineCore

struct CountdownView: View {

    /// 这个槽位画什么。图标和数字占据刘海的两侧，各自是独立的槽位实例。
    enum Role {
        case digits
        case icon
    }

    @ObservedObject var notchViewModel: NotchViewModel

    /// **必须是 @ObservedObject 引用单例，不能是 @StateObject。**
    /// 每块屏都有一个 NotchView，@StateObject 会产生 N 个引擎、N 个 timer、
    /// 以及每根 K 线 N 次响铃。
    @ObservedObject private var engine = CountdownEngine.shared

    @StateObject private var defaults = CountdownDefaults.shared

    var variant: NotchSlotVariant
    var role: Role = .digits

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

    /// 图标字体：`bold` + 1.05 缩放。
    ///
    /// 参数是实测定的，不是估的 —— 以数字 "0"（medium）为基准，把符号以
    /// 20 倍放大渲染，逐像素扫描墨迹边界与笔画宽度：
    ///
    /// ```
    ///   timer 字重/缩放     墨迹高 vs 数字    笔画 vs 数字
    ///   medium  ×1.00           1.38×            0.93×   偏细
    ///   bold    ×0.85           1.20×            1.00×   偏小
    ///   semibold×1.05           1.46×            1.07×
    ///   bold    ×1.05           1.48×            1.25×   ← 采用
    ///   bold    ×1.10           1.55×            1.32×
    /// ```
    ///
    /// 两点值得记住：
    /// 1. SF Symbol 的墨迹基线在 cap height 之上还留了空间，同 point size 下
    ///    比数字大近四成 —— 所以「喂相同字体参数」并不会让它们看起来一样大。
    /// 2. 字形越大，同样的笔画看起来越细。缩尺寸和加字重必须一起调。
    private var iconFont: Font {
        .system(size: fontSize * 1.05, weight: .bold, design: .rounded)
    }

    /// `Match_Notch` 模式下黑块比菜单栏高，垂直居中会让数字比系统时钟低一截。
    /// 图标挨着图标看不出来，但文字挨着文字非常明显。
    private var baselineNudge: CGFloat {
        let menuBar = notchViewModel.menuBarHeight
        guard notchViewModel.notchSize.height > menuBar, menuBar > 0 else { return 0 }
        return -(notchViewModel.notchSize.height - menuBar) / 2
    }

    /// 这个槽位此刻是否该有内容。
    ///
    /// **刻意不读 `defaults.isEnabled`。** 功能开关由引擎统一翻译成
    /// `.dormant(.featureDisabled)`，所有状态变化都经 `engine.presentation`
    /// 这一个通道进来，才能被 `publish` 里的 withAnimation 事务覆盖。
    /// 若这里直接读 defaults，Toggle 一按视图会立刻重绘并瞬间消失，
    /// 抢在引擎的动画事务之前，动画就白做了。
    private var hasContent: Bool {
        // notchSize 可能退化为 0（NotchedDisplayOnly + 外接屏）。
        // 原有 HUD 都是 frame(height: 0) 所以看不见，但 Text 有固有高度会溢出。
        guard notchViewModel.notchSize.height > 1 else { return false }

        switch engine.presentation {
        case .dormant:
            // 休市 / 功能关闭：**完全不渲染**，槽位消失，刘海缩回原生轮廓。
            // 不是灰字，不是 opacity(0)。
            return false
        case .counting:
            return role == .digits || defaults.showIcon
        case .fault:
            // 故障时只画告警字形，图标槽让位 —— 两个符号并排会稀释警示。
            return role == .digits
        }
    }

    var body: some View {
        Group {
            if hasContent {
                NotchSlotView(notchViewModel: notchViewModel, variant: variant) {
                    slotContent()
                }
            }
        }
        // 这里刻意不写 .animation(_:value:) —— 实测无效。
        // 该修饰符只覆盖视图自身的可动画属性，管不到槽位增删引起的
        // 父容器布局重算，刘海宽度仍会瞬间跳变。展开/收起动画由
        // CountdownEngine.publish 里的 withAnimation 事务驱动。
    }

    @ViewBuilder
    private func slotContent() -> some View {
        switch engine.presentation {
        case let .counting(countdown):
            if role == .digits {
                countingContent(countdown)
            } else {
                iconContent(countdown)
            }
        case let .fault(fault):
            faultContent(fault)
        case .dormant:
            // hasContent 已保证走不到这里
            EmptyView()
        }
    }

    // MARK: - 图标（进度环）

    private func iconContent(_ countdown: Countdown) -> some View {
        CountdownRing(
            fractionRemaining: countdown.fractionRemaining,
            color: color(for: countdown.phase),
            diameter: fontSize * 1.35
        )
        .offset(y: baselineNudge)
    }

    // MARK: - 正常倒计时

    private func countingContent(_ countdown: Countdown) -> some View {
        // 关切圆点必须是数字的**兄弟节点**，不能塞进 overlay。
        // overlay 的内容会被约束在底层视图的尺寸内，圆点挤进去会让
        // HStack 比模板宽出「spacing + 圆点」，SwiftUI 于是压缩 Text
        // 并截断成 "01..."。
        HStack(spacing: 4) {
            // 隐形撑宽：用当前周期可能出现的最宽字符串预留宽度，
            // 保证一根 K 线内刘海宽度恒定，只有换周期时才变。
            Text(countdown.widthTemplate)
                .font(countdownFont)
                .opacity(0)
                .overlay {
                    Text(countdown.text)
                        .font(countdownFont)
                        .foregroundStyle(color(for: countdown.phase))
                        // 兜底：任何情况下都不允许倒计时被压缩成省略号。
                        // 宁可撑宽刘海，也不能显示一个看不全的数字。
                        .fixedSize()
                        .shadow(
                            color: MewNotch.CountdownColors.urgentGlow,
                            radius: countdown.phase == .urgent ? 4 : 0
                        )
                }

            concernDot(countdown.concerns)
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
        // 环的相位色：normal 用琥珀（不是数字的白）—— 环是「计时器」隐喻，
        // 常态就该是暖色的锚点；warning / urgent 与数字同色，一起变红。
        switch phase {
        case .normal:  return MewNotch.CountdownColors.icon
        case .warning: return MewNotch.CountdownColors.warning
        case .urgent:  return MewNotch.CountdownColors.urgent
        }
    }
}

/// 消耗式进度环 —— 随当前 K 线剩余比例收缩，视觉上是一个「活的计时器」。
///
/// 关键：它每秒只转 1.2°（5m 周期），在余光里基本等同静止，不触发变化检测。
/// 这与被否决的滚动数字（每秒一次离散跳变）是完全不同的刺激。
struct CountdownRing: View {

    /// 剩余比例，`0...1`。开盘约 1，收线约 0。
    let fractionRemaining: Double
    let color: Color
    let diameter: CGFloat

    private var lineWidth: CGFloat { max(1.5, diameter * 0.11) }

    var body: some View {
        ZStack {
            // 轨道：环走空后剩下的暗色底，让「消耗」看得出来
            Circle()
                .stroke(MewNotch.CountdownColors.ringTrack, lineWidth: lineWidth)

            // 进度弧：从 12 点开始，顺时针，长度 = 剩余比例
            Circle()
                .trim(from: 0, to: fractionRemaining)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // 中心点：静态锚，强化「计时器表盘」的观感
            Circle()
                .fill(color)
                .frame(width: lineWidth * 1.3, height: lineWidth * 1.3)
        }
        .frame(width: diameter, height: diameter)
        // 每秒收到一个新的剩余比例；用线性补间让环在两次 tick 之间匀速转，
        // 而不是每秒跳一下。duration 1.0 恰好衔接下一次 tick。
        // 相位变色也走这条，0.25s 太短会被 1s 覆盖 —— 但颜色渐变本身很快，
        // 观感上无碍。
        .animation(.linear(duration: 1.0), value: fractionRemaining)
        .animation(.easeInOut(duration: 0.25), value: color)
    }
}
