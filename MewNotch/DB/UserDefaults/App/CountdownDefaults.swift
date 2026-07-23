//
//  CountdownDefaults.swift
//  MewNotch
//

import SwiftUI
import KLineCore

enum CountdownPosition: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left:  return "Left"
        case .right: return "Right"
        }
    }

    /// 图标占据数字的对侧 —— 刘海两边各有内容，视觉才平衡。
    /// 这也沿用了项目原有的语法：左槽放图标，右槽放数值。
    var opposite: CountdownPosition {
        self == .left ? .right : .left
    }
}

/// 收线提醒的响法。
enum AlertMode: String, Codable, CaseIterable, Identifiable {
    /// 响一声就停。
    case once
    /// 持续响到用户手动关闭 —— 适合离开屏幕、必须被叫回来的场景。
    case untilDismissed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .once:           return "Once"
        case .untilDismissed: return "Until dismissed"
        }
    }
}

/// 刘海上的倒计时图标。
///
/// 只用 `timer` 一个符号。它与 `clock` 在同一套字体参数下的墨迹高度和笔画
/// 宽度实测完全一致（高 1.48×、笔画 1.25×），所以两者可以互换而不必重新
/// 校准；换成其他符号（hourglass、chart.bar.xaxis 等）则需要各自重测。
enum CountdownIcon {
    static let systemName = "timer"
}

/// 倒计时设置。
///
/// 刻意与 `NotchDefaults` 分开：`NotchView` 订阅了 `NotchDefaults.objectWillChange`
/// 来触发 `refreshNotchSize()`，把阈值之类的高频设置混进去，会让每次调节滑块
/// 都触发一次刘海几何重算。
class CountdownDefaults: ObservableObject {

    private static var PREFIX: String = "Countdown_"

    static let shared = CountdownDefaults()

    private init() {}

    @PrimitiveUserDefault(
        PREFIX + "Enabled",
        defaultValue: true
    )
    var isEnabled: Bool {
        didSet { self.objectWillChange.send() }
    }

    @CodableUserDefault(
        PREFIX + "Period",
        defaultValue: BarPeriod.m5
    )
    var period: BarPeriod {
        didSet { self.objectWillChange.send() }
    }

    @CodableUserDefault(
        PREFIX + "Position",
        defaultValue: CountdownPosition.right
    )
    var position: CountdownPosition {
        didSet { self.objectWillChange.send() }
    }

    /// 显示 `5m 04:32` 而不是 `04:32`。默认关 —— 常态要克制。
    @PrimitiveUserDefault(
        PREFIX + "ShowPeriodLabel",
        defaultValue: false
    )
    var showPeriodLabel: Bool {
        didSet { self.objectWillChange.send() }
    }

    /// 在数字的对侧槽位显示一个图标，让刘海两边平衡。
    @PrimitiveUserDefault(
        PREFIX + "ShowIcon",
        defaultValue: true
    )
    var showIcon: Bool {
        didSet { self.objectWillChange.send() }
    }

    /// 刘海仪表盘总开关：悬停轻微放大提示可点，点击展开。
    /// 默认开 —— 两段反馈都是纯主动交互，不碰刘海就不存在，
    /// 与「常态克制」不冲突；关掉后刘海对鼠标完全无反应（响铃时除外）。
    @PrimitiveUserDefault(
        PREFIX + "DashboardEnabled",
        defaultValue: true
    )
    var dashboardEnabled: Bool {
        didSet { self.objectWillChange.send() }
    }


    /// 仪表盘里的经济日历。默认开 —— 数据发布时刻正是「这根 K 线为什么
    /// 突然拉长」的答案，和倒计时是同一件事的两面。
    /// 关掉后不再有任何对 TradingView 日历端点的网络请求。
    @PrimitiveUserDefault(
        PREFIX + "CalendarEnabled",
        defaultValue: true
    )
    var calendarEnabled: Bool {
        didSet { self.objectWillChange.send() }
    }

    /// 日历重要度档位，存 `EconomicImportance` 的 rawValue（-1 全部 / 0 中高 / 1 仅高）。
    /// 默认 0：low 档全是 MBA 周报之类的噪音，high-only 又会把 PMI 这类
    /// 盘中真会动价的中档数据滤掉。
    @PrimitiveUserDefault(
        PREFIX + "CalendarMinImportance",
        defaultValue: 0
    )
    var calendarMinImportance: Int {
        didSet { self.objectWillChange.send() }
    }

    /// 仪表盘里的快讯流（FinancialJuice）。关掉后不再有任何对
    /// 新闻端点的网络请求。
    @PrimitiveUserDefault(
        PREFIX + "NewsEnabled",
        defaultValue: true
    )
    var newsEnabled: Bool {
        didSet { self.objectWillChange.send() }
    }

    /// 快讯标题中文化（DeepSeek）。构建未注入 key 时此开关无效，
    /// 始终显示英文原文。
    @PrimitiveUserDefault(
        PREFIX + "NewsTranslationEnabled",
        defaultValue: true
    )
    var newsTranslationEnabled: Bool {
        didSet { self.objectWillChange.send() }
    }

    @PrimitiveUserDefault(
        PREFIX + "WarningThreshold",
        defaultValue: 60
    )
    var warningThreshold: Int {
        didSet { self.objectWillChange.send() }
    }

    @PrimitiveUserDefault(
        PREFIX + "UrgentThreshold",
        defaultValue: 15
    )
    var urgentThreshold: Int {
        didSet { self.objectWillChange.send() }
    }

    /// 默认关闭：5 分钟周期 = 每交易日约 288 次。
    /// 让用户主动打开，而不是让他们先被吵一天再去关。
    @PrimitiveUserDefault(
        PREFIX + "SoundEnabled",
        defaultValue: false
    )
    var soundEnabled: Bool {
        didSet { self.objectWillChange.send() }
    }

    /// 系统音名。避开 Glass —— 它是很多人的默认提示音，混淆风险高。
    @PrimitiveUserDefault(
        PREFIX + "SoundName",
        defaultValue: "Funk"
    )
    var soundName: String {
        didSet { self.objectWillChange.send() }
    }

    /// 提前多少秒响。默认 30 秒 —— 15 秒对「看一眼图再决定动不动手」太紧。
    @PrimitiveUserDefault(
        PREFIX + "SoundThreshold",
        defaultValue: 30
    )
    var soundThreshold: Int {
        didSet { self.objectWillChange.send() }
    }

    /// 响一次还是持续响到手动关闭。
    @CodableUserDefault(
        PREFIX + "AlertMode",
        defaultValue: AlertMode.once
    )
    var alertMode: AlertMode {
        didSet { self.objectWillChange.send() }
    }

    /// 联网校准系统时钟。关掉后只剩单调钟哨兵，
    /// 对「开机就慢 45 秒且从不同步」这种静态偏差完全失明。
    @PrimitiveUserDefault(
        PREFIX + "ClockCalibrationEnabled",
        defaultValue: true
    )
    var clockCalibrationEnabled: Bool {
        didSet { self.objectWillChange.send() }
    }

    // MARK: - 派生

    /// 阈值可能被历史设置或手动改动弄成非法组合（`CountdownThresholds` 会
    /// precondition 失败）。这里做一次夹取，保证 `0 < urgent < warning < period`。
    var thresholds: CountdownThresholds {
        let periodSeconds = period.seconds
        let urgent = max(1, min(urgentThreshold, periodSeconds - 2))
        let warning = max(urgent + 1, min(warningThreshold, periodSeconds - 1))
        return CountdownThresholds(warning: warning, urgent: urgent)
    }

    /// 切换周期后，把阈值夹进新周期的合法范围。
    ///
    /// **刻意不套用推荐值。** 曾经这里是无条件 `applyRecommendedThresholds`，
    /// 结果用户手调的阈值会被静默重置回默认值 —— 而且 SwiftUI 的 Picker 在
    /// 视图重建或重复选中同一项时也会触发 setter，让设置莫名其妙地变回去。
    /// 这正是「响铃阈值改成 30 秒却还是 15 秒响」的根因。
    ///
    /// 阈值是绝对秒数（反应窗口不随周期缩放），所以只在放不下时才压缩。
    func clampThresholdsToPeriod() {
        let clamped = CountdownThresholds(
            warning: max(2, warningThreshold),
            urgent: max(1, min(urgentThreshold, max(1, warningThreshold - 1)))
        ).clamped(toPeriodSeconds: period.seconds)

        if warningThreshold != clamped.warning { warningThreshold = clamped.warning }
        if urgentThreshold != clamped.urgent { urgentThreshold = clamped.urgent }

        // 响铃阈值独立于变色阈值，单独夹取到周期内
        let clampedSound = min(max(1, soundThreshold), period.seconds - 1)
        if soundThreshold != clampedSound { soundThreshold = clampedSound }
    }
}
