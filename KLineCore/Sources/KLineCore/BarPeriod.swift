//
//  BarPeriod.swift
//  KLineCore
//

import Foundation

/// K 线周期。
public enum BarPeriod: Int, CaseIterable, Codable, Identifiable, Sendable {
    case m1  = 60
    case m3  = 180
    case m5  = 300
    case m15 = 900
    case m30 = 1800
    case h1  = 3600
    case h4  = 14400

    public var id: Int { rawValue }
    public var seconds: Int { rawValue }

    /// v1 开放给用户的周期。
    ///
    /// 4h 被刻意排除：通用的时段锚定公式对它同样成立，但「TradingView 对 CME
    /// 4h K 线究竟锚在哪」尚未实测确认。锚错会让倒计时和用户图表差几十分钟，
    /// 这种错误比没有功能更糟，所以在核实前不开放。
    public static var userSelectable: [BarPeriod] {
        [.m1, .m3, .m5, .m15, .m30, .h1]
    }

    /// 当且仅当 `P | 3600` 时，「时段锚定」与朴素的 `t % P` 等价
    /// （前提是时段开盘落在 UTC 整点 —— CME Globex 的 18:00 ET 满足）。
    ///
    /// **只供单元测试断言使用。** 生产代码一律走 `BarClock.bar(at:period:session:)`，
    /// 不写取模快路径 —— 快路径对 2h/4h 是错的，且 2h 的错误只在冬令时出现，
    /// 半年对半年错，极难发现。
    public var dividesHour: Bool { 3600 % seconds == 0 }

    public var displayName: String {
        switch self {
        case .m1:  return "1m"
        case .m3:  return "3m"
        case .m5:  return "5m"
        case .m15: return "15m"
        case .m30: return "30m"
        case .h1:  return "1H"
        case .h4:  return "4H"
        }
    }
}

/// 向下取整的整数除法。
///
/// Swift 的 `/` 对负数是**向零截断**（`-7 / 3 == -2`，`-1 / 300 == 0`），
/// 而 K 线定位需要的是数学上的 floor。当查询时刻早于时段开盘（算距开盘倒计时、
/// 或时段查找越界）时 `a` 为负，用 `/` 会把 K 线定位到错误的格子。
@inline(__always)
public func floorDiv(_ a: Int, _ b: Int) -> Int {
    precondition(b > 0, "period must be positive, got \(b)")
    let q = a / b
    return (a % b != 0 && a < 0) ? q - 1 : q
}
