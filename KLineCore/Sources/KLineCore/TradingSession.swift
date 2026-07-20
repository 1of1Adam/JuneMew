//
//  TradingSession.swift
//  KLineCore
//

import Foundation

/// 一个 ET 日历日。用于给交易时段命名（按结算日）以及索引假期表。
public struct YearMonthDay: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// 从 `"2026-04-03"` 解析。格式不符直接抛错 —— 假期表里出现坏日期
    /// 必须让构建/启动失败，不能当成「这天没有条目」放过去。
    public init(iso: String) throws {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else {
            throw KLineCoreError.malformedDate(iso)
        }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// ET 当日的时刻（时:分）。
public struct TimeOfDayET: Hashable, Codable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// 从 `"13:00"` 解析。
    public init(hhmm: String) throws {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m)
        else {
            throw KLineCoreError.malformedTimeOfDay(hhmm)
        }
        self.init(hour: h, minute: m)
    }

    public var description: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// 一个连续的交易窗口，半开区间 `[opens, closes)`。
///
/// CME Globex 的时段按**结算日**命名但从前一晚开始：
/// 结算于周一的时段 = 周日 18:00 ET → 周一 17:00 ET。
public struct TradingSession: Hashable, Sendable {

    public enum CloseKind: String, Hashable, Sendable {
        /// 普通交易日 17:00 ET 收盘，当晚 18:00 ET 重开
        case regular
        /// 假期提前收盘
        case early
        /// 周五收盘，之后到周日 18:00 ET 都休市
        case weekEnd
    }

    public let opens: Date
    public let closes: Date
    public let settlementDay: YearMonthDay
    public let closeKind: CloseKind

    public init(opens: Date, closes: Date, settlementDay: YearMonthDay, closeKind: CloseKind) {
        self.opens = opens
        self.closes = closes
        self.settlementDay = settlementDay
        self.closeKind = closeKind
    }

    /// 半开区间语义：`closes` 那一刻**已经收盘**。
    ///
    /// 于是 16:55 开始的 5m K 线在 17:00:00 收线：16:59:59.999 显示 `00:01`，
    /// 17:00:00.000 立即隐藏。倒计时永远不会停在 `00:00`。
    public func contains(_ instant: Date) -> Bool {
        instant >= opens && instant < closes
    }
}
