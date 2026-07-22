//
//  CountdownPresentation.swift
//  KLineCore
//

import Foundation

/// 倒计时的紧迫度相位。升级只改颜色，不改字重 ——
/// 不同字重的 tabular advance 不同，切粗细会让整块宽度跳变。
public enum CountdownPhase: Int, Comparable, Sendable {
    case normal = 0
    case warning = 1
    case urgent = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 阈值是「剩余秒数小于等于」。约束由 `CountdownThresholds` 保证。
    public static func of(remainingSeconds: Int, thresholds: CountdownThresholds) -> CountdownPhase {
        if remainingSeconds <= thresholds.urgent { return .urgent }
        if remainingSeconds <= thresholds.warning { return .warning }
        return .normal
    }
}

/// 变色阈值。用绝对秒数而非周期百分比 ——
/// 交易者的反应窗口是绝对的（点一下按钮要多久，跟 K 线周期无关）。
public struct CountdownThresholds: Equatable, Sendable {
    public let warning: Int
    public let urgent: Int

    /// 非法组合直接 precondition 失败而不是悄悄纠正 ——
    /// 设置层负责保证 `0 < urgent < warning < period`。
    public init(warning: Int, urgent: Int) {
        precondition(urgent > 0, "urgent threshold must be positive, got \(urgent)")
        precondition(warning > urgent, "warning (\(warning)) must exceed urgent (\(urgent))")
        self.warning = warning
        self.urgent = urgent
    }

    /// 首次使用时的推荐默认值。上限用百分比封顶，避免 15s 在 1m 周期上
    /// 盖掉整整 1/4 根 K 线。
    ///
    /// **只用于初始化，绝不用于「换周期时重置」** —— 阈值是用户手动调的
    /// 绝对秒数，换周期时应当保留（见 `clamped(toPeriodSeconds:)`）。
    public static func recommended(for period: BarPeriod) -> CountdownThresholds {
        let warning = max(2, min(60, period.seconds / 4))
        let urgent  = max(1, min(15, period.seconds / 10))
        return CountdownThresholds(warning: warning, urgent: max(1, min(urgent, warning - 1)))
    }

    /// 把阈值夹进新周期的合法范围，**尽最大可能保留用户设定的绝对秒数**。
    ///
    /// 这是「换周期」时的正确行为。曾经的实现是无条件套用 `recommended`，
    /// 结果用户手调的阈值会被静默重置 —— 而且 SwiftUI 的 Picker 在视图重建
    /// 或重复选中同一项时也会触发 setter，导致设置莫名其妙地变回默认值。
    ///
    /// 阈值的语义是绝对秒数（交易者的反应窗口不随 K 线周期缩放），所以只要
    /// 在新周期里仍然合法就原样保留；只有放不下时才按比例压缩。
    public func clamped(toPeriodSeconds periodSeconds: Int) -> CountdownThresholds {
        precondition(periodSeconds >= 3, "period must be at least 3s, got \(periodSeconds)")

        // warning 最多占到周期的最后一秒之前；urgent 必须严格小于 warning
        let newWarning = min(warning, periodSeconds - 1)
        let newUrgent  = min(urgent, newWarning - 1)

        return CountdownThresholds(
            warning: max(2, newWarning),
            urgent: max(1, newUrgent)
        )
    }
}

/// 非致命的关切项：显示数字，但附带一个可见标记。
public enum Concern: Equatable, Sendable {
    /// 系统时钟偏差超过软阈值但未到硬阈值。
    case clockDrift(seconds: TimeInterval)
    /// 时钟从未成功校准过（网络不通等）。
    case clockUnverified(staleness: TimeInterval)
    /// 假期表即将过期。
    case holidayTableExpiringSoon(daysLeft: Int)
    /// 假期表已过期但仍在宽限期内。
    case holidayTableStale(daysStale: Int)
    /// 假期表尚未经人工核对。
    case holidayTableUnverified
}

/// 致命故障：**不渲染任何数字**，只画告警字形。
///
/// 对交易工具来说「一个你不能相信的倒计时」比「没有倒计时」更危险 ——
/// 用户会照着它下单。所以这些状态一律拒绝显示数字。
public enum Fault: Equatable, Sendable {
    case clockOffsetExceedsTolerance(offset: TimeInterval, threshold: TimeInterval)
    case clockJumped(delta: TimeInterval)
    case holidayTableExpired(daysStale: Int)
    case holidayTableUnreadable(String)
    case calendarInconsistent(String)
}

/// 休眠：刘海上**完全不渲染**，恢复原生外观。
public enum Dormancy: Equatable, Sendable {
    case marketClosed(nextOpen: Date?)
    case featureDisabled
}

public struct Countdown: Equatable, Sendable {
    public let text: String
    public let widthTemplate: String
    public let remainingSeconds: Int
    public let barOpens: Date
    public let barCloses: Date
    public let isTruncatedByClose: Bool
    public let phase: CountdownPhase
    public let concerns: [Concern]

    public init(
        text: String, widthTemplate: String, remainingSeconds: Int,
        barOpens: Date, barCloses: Date, isTruncatedByClose: Bool,
        phase: CountdownPhase, concerns: [Concern]
    ) {
        self.text = text
        self.widthTemplate = widthTemplate
        self.remainingSeconds = remainingSeconds
        self.barOpens = barOpens
        self.barCloses = barCloses
        self.isTruncatedByClose = isTruncatedByClose
        self.phase = phase
        self.concerns = concerns
    }
}

/// 引擎对外发布的唯一状态。
///
/// `dormant` 与 `fault` 刻意分开：休市是真的什么都不画，故障是画一个刺眼的字形。
/// **没有任何路径会在故障时画出一个看起来正常的数字。**
public enum CountdownPresentation: Equatable, Sendable {
    case dormant(Dormancy)
    case counting(Countdown)
    case fault(Fault)

    public var isRenderingDigits: Bool {
        if case .counting = self { return true }
        return false
    }

    /// 三种形态的标识，不含各自的载荷。
    ///
    /// 用来判断「刘海上的槽位是否需要增删」：同一形态内部的变化（倒计时每秒
    /// 递减）不改变布局，跨形态切换才会。UI 层据此决定要不要开动画事务 ——
    /// 否则每秒都会重播一次展开动画。
    public enum Kind: Equatable, Sendable {
        case dormant, counting, fault
    }

    public var kind: Kind {
        switch self {
        case .dormant:  return .dormant
        case .counting: return .counting
        case .fault:    return .fault
        }
    }
}
