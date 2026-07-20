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

    @PrimitiveUserDefault(
        PREFIX + "SoundThreshold",
        defaultValue: 15
    )
    var soundThreshold: Int {
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

    /// 切换周期时套用推荐阈值。
    func applyRecommendedThresholds(for period: BarPeriod) {
        let recommended = CountdownThresholds.recommended(for: period)
        warningThreshold = recommended.warning
        urgentThreshold = recommended.urgent
        soundThreshold = recommended.urgent
    }
}
