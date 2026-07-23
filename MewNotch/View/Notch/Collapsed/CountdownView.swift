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

    @ObservedObject private var defaults = CountdownDefaults.shared
    @ObservedObject private var alertPlayer = CandleAlertPlayer.shared

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
                iconContent()
            }
        case let .fault(fault):
            faultContent(fault)
        case .dormant:
            // hasContent 已保证走不到这里
            EmptyView()
        }
    }

    // MARK: - 图标

    @ViewBuilder
    private func iconContent() -> some View {
        if alertPlayer.isAlerting {
            // 正在响铃：图标换成脉动的铃铛，并与刘海整体一起构成「点我停止」。
            //
            // 这里用持续动画是**正当**的，且正是我一直把运动留给报警时刻的目的：
            // 常态下一切静止（数字硬切、图标不动），所以此刻的脉动在余光里
            // 极为醒目，不会被适应屏蔽。
            AlertingBell(font: iconFont)
                .offset(y: baselineNudge)
        } else {
            Image(systemName: CountdownIcon.systemName)
                .font(iconFont)
                // 固定琥珀，不跟随相位 —— 图标是锚点，数字才是信号。
                .foregroundStyle(MewNotch.CountdownColors.icon)
                .offset(y: baselineNudge)
        }
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
            .help(fault.userDescription)
    }

    private func color(for phase: CountdownPhase) -> Color {
        switch phase {
        case .normal:  return MewNotch.CountdownColors.normal
        case .warning: return MewNotch.CountdownColors.warning
        case .urgent:  return MewNotch.CountdownColors.urgent
        }
    }
}

/// 持续响铃时替代常规图标的脉动铃铛。
///
/// 脉动是这个 app 里唯一的常驻动画，这是刻意的：其余一切都保持静止
/// （数字硬切、图标不动、进度不转），所以此刻的运动在余光里格外醒目。
/// 把运动留到真正需要打断注意力的时刻 —— 这正是当初否决滚动数字的目的。
private struct AlertingBell: View {

    let font: Font

    @State private var pulsing = false

    var body: some View {
        Image(systemName: "bell.fill")
            .font(font)
            .foregroundStyle(MewNotch.CountdownColors.urgent)
            .shadow(color: MewNotch.CountdownColors.urgentGlow, radius: 4)
            // 用 opacity 而非 scale 脉动：尺寸变化会让相邻的数字跟着位移，
            // 在视野边缘读数时非常烦人。
            .opacity(pulsing ? 0.40 : 1.0)
            .animation(
                // 0.55s 一个来回接近平静心率，是「持续提醒」而非「紧急闪烁」。
                // 太快会制造焦虑，太慢又会被忽略。
                .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
            .onDisappear { pulsing = false }
            .accessibilityLabel("Alert ringing. Click the notch to stop.")
    }
}
