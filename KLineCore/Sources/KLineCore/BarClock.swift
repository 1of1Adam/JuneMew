//
//  BarClock.swift
//  KLineCore
//

import Foundation

/// 一根 K 线。
public struct Bar: Equatable, Sendable {
    public let opens: Date
    /// 已被时段收盘截断后的收线时刻。
    public let closes: Date
    /// 本根因时段收盘而提前结束（不足一个完整周期）。
    public let isTruncated: Bool
    /// 距收线的剩余秒数。值域 `1...period`，**永不为 0**。
    public let remainingSeconds: Int
}

public enum BarClock {

    /// 时段锚定的 K 线定位。**这是全项目唯一的 K 线边界真理来源。**
    ///
    /// 公式：`barStart = sessionOpen + floor((t − sessionOpen) / P) × P`
    ///
    /// 为什么不用看起来更简单的 `t − (t mod P)`：
    ///
    /// 设时段开盘 Unix 时刻为 `S`、周期 `P` 秒。当且仅当 `3600 | S` 且 `P | 3600` 时，
    /// 两者恒等（`P | 3600 ∧ 3600 | S ⟹ P | S ⟹ (t−S) mod P = t mod P`）。
    ///
    /// CME Globex 满足 `3600 | S`（18:00 ET 在 EST 下 = 23:00 UTC、EDT 下 = 22:00 UTC，
    /// 都是 UTC 整点），但 `P | 3600` 对 7200 和 14400 **不成立**：
    ///
    /// - 4h：全部采样点都错。正确边界是 18:00/22:00/02:00/06:00/10:00/14:00 ET，
    ///       取模给出的是 15:00/19:00/23:00/… ET，且这套错误边界还随 DST 漂移。
    /// - 2h：EDT 下碰巧对（22:00 UTC 是偶数小时），EST 下错（23:00 UTC）。
    ///       同一份代码半年对半年错 —— 三月之前根本发现不了。
    ///
    /// 所以这里只实现通用公式，不做「`P | 3600` 就走快路径」的优化。
    /// 两者的等价性由单元测试断言，而不是由生产代码依赖。
    public static func bar(
        at instant: Date,
        period: BarPeriod,
        session: TradingSession
    ) throws -> Bar {

        guard session.contains(instant) else {
            throw KLineCoreError.instantOutsideSession(
                instant: instant,
                sessionOpens: session.opens,
                sessionCloses: session.closes
            )
        }

        let now   = Int(instant.timeIntervalSince1970.rounded(.down))
        let open  = Int(session.opens.timeIntervalSince1970)
        let close = Int(session.closes.timeIntervalSince1970)
        let p     = period.seconds

        let barStart    = open + floorDiv(now - open, p) * p
        let untruncated = barStart + p
        // Globex 时段 23 小时，23 ÷ 4 = 5.75 —— 4h 周期的最后一根只有 3 小时。
        let barEnd      = min(untruncated, close)

        // 由 session.contains(instant) 保证：instant < closes ⟹ now < close，
        // 且 barStart ≤ now < barStart + p，故 barEnd > now。
        assert(barEnd > now, "invariant violated: barEnd=\(barEnd) now=\(now)")

        return Bar(
            opens: Date(timeIntervalSince1970: TimeInterval(barStart)),
            closes: Date(timeIntervalSince1970: TimeInterval(barEnd)),
            isTruncated: untruncated != barEnd,
            // ceil 语义：值域 1...p。
            // 距收线 0.4 秒时显示 00:01 而不是 00:00 —— 新 K 线开始的瞬间
            // 直接跳回 05:00，00:00 永远不出现。这是产品决策，不是 off-by-one。
            remainingSeconds: barEnd - now
        )
    }

    /// 把剩余秒数格式化成显示文本。
    ///
    /// 4h 周期最多 14400 秒 = 240 分钟，`MM:SS` 会溢出成 `240:00`，
    /// 所以 ≥ 1 小时时切到 `H:MM:SS`。
    public static func format(remainingSeconds seconds: Int) -> String {
        precondition(seconds >= 0, "remaining seconds must be non-negative, got \(seconds)")
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 给定周期在显示上可能出现的最宽字符串，用于预留固定宽度。
    ///
    /// 刘海宽度必须在一根 K 线内保持恒定，否则每秒都会因数字宽度变化而抖动。
    public static func widthTemplate(for period: BarPeriod) -> String {
        period.seconds >= 3600 ? "0:00:00" : "00:00"
    }
}
