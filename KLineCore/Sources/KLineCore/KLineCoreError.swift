//
//  KLineCoreError.swift
//  KLineCore
//

import Foundation

/// 领域层的全部失败模式。
///
/// 刻意不提供任何「出错返回默认值」的路径：把 `[]`（今天没有交易时段）和
/// 「日历数据坏了」混为一谈，会让用户在假期看到一个静默错误的倒计时。
/// 每一种失败都必须能一路冒泡到 UI 变成可见的告警字形。
public enum KLineCoreError: Error, Equatable, CustomStringConvertible {

    /// 请求的时刻不在给定时段内。调用方应先用日历确认时段。
    case instantOutsideSession(instant: Date, sessionOpens: Date, sessionCloses: Date)

    /// 查询落在假期表已核验范围之外 —— 不是「这天正常交易」，是「根本没查过」。
    case outsideVerifiedCoverage(queried: Date, verifiedFrom: YearMonthDay, verifiedThrough: YearMonthDay)

    /// 假期表 JSON 无法读取或解码。
    case holidayTableUnreadable(String)

    /// 假期表里的日期字符串格式不对。
    case malformedDate(String)

    /// 假期表里的时刻字符串格式不对。
    case malformedTimeOfDay(String)

    /// 生成出了退化的时段（收盘不晚于开盘）。数据自相矛盾时抛出。
    case degenerateSession(settlementDay: YearMonthDay, opens: Date, closes: Date)

    /// 生成的时段列表出现重叠或乱序。不变量被破坏，说明规则或数据有 bug。
    case overlappingSessions(String)

    /// `Calendar` 无法表示某个 ET 本地时刻。
    /// 17:00 / 18:00 / 13:00 永远不会落进 DST 空洞，真出现说明前提被打破了。
    case unrepresentableLocalTime(String)

    public var description: String {
        switch self {
        case let .instantOutsideSession(instant, opens, closes):
            return "instant \(instant) is outside session [\(opens), \(closes))"
        case let .outsideVerifiedCoverage(queried, from, through):
            return "\(queried) falls outside verified holiday coverage \(from)...\(through)"
        case let .holidayTableUnreadable(detail):
            return "holiday table unreadable: \(detail)"
        case let .malformedDate(raw):
            return "malformed date in holiday table: \"\(raw)\""
        case let .malformedTimeOfDay(raw):
            return "malformed time-of-day in holiday table: \"\(raw)\""
        case let .degenerateSession(day, opens, closes):
            return "degenerate session for \(day): opens \(opens) but closes \(closes)"
        case let .overlappingSessions(detail):
            return "session invariant violated: \(detail)"
        case let .unrepresentableLocalTime(detail):
            return "unrepresentable ET local time: \(detail)"
        }
    }
}
