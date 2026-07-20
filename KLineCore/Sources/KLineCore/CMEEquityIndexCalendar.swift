//
//  CMEEquityIndexCalendar.swift
//  KLineCore
//

import Foundation

public protocol TradingCalendar: Sendable {
    /// 假期数据经人工核验的时间区间。
    var verifiedCoverage: DateInterval { get }
    /// 假期表的核验状态，供 UI 显示告警。
    var verificationStatus: VerificationStatus { get }

    /// 列出与给定区间相交的全部交易时段。
    ///
    /// 有意 `throws`：数据损坏绝不能和「市场休市」共用 `[]` 这个返回值。
    func sessions(overlapping interval: DateInterval) throws -> [TradingSession]
}

extension TradingCalendar {

    /// 包含给定时刻的交易时段；休市返回 nil。
    public func session(containing instant: Date) throws -> TradingSession? {
        try sessions(
            overlapping: DateInterval(start: instant.addingTimeInterval(-1), duration: 2)
        ).first { $0.contains(instant) }
    }

    public func isOpen(at instant: Date) throws -> Bool {
        try session(containing: instant) != nil
    }

    /// 给定时刻之后的下一次开盘。用于休市时显示距开盘还有多久。
    public func nextOpen(after instant: Date) throws -> Date? {
        // 最长休市窗口是周末 + 假期，向前看 14 天足够覆盖任何真实情形。
        let horizon = DateInterval(start: instant, duration: 14 * 86_400)
        return try sessions(overlapping: horizon)
            .first { $0.opens > instant }?
            .opens
    }
}

/// CME Globex 股指期货（ES / NQ / MES / MNQ）的交易日历。
///
/// 全部时段由一条规则生成：
///
/// > 对每个 ET 日历日 `D`，若 `D` 是周一至周五，产生窗口 `[D−1 @18:00 ET, D @17:00 ET)`。
///
/// 这一条同时自动产生了：周日 18:00 开盘、周一至周四每日 17:00–18:00 维护停盘、
/// 周五 17:00 收盘、周六全天休市（没有结算于周六的时段，所以周五晚 18:00 不开盘）。
///
/// 选择「枚举窗口」而非「用规则逐点判定」，是因为假期本质上是对窗口的**变换**
/// （删除或截断）。用规则判定就要在一堆 weekday 分支里塞假期特判，很快不可读；
/// 而且 `nextOpen(after:)` 在枚举模型下是白送的。
public struct CMEEquityIndexCalendar: TradingCalendar {

    private static let defaultOpen  = TimeOfDayET(hour: 18, minute: 0)  // 结算日的前一日
    private static let defaultClose = TimeOfDayET(hour: 17, minute: 0)  // 结算日当日

    private let et: Calendar
    private let holidays: HolidayTable

    public var verificationStatus: VerificationStatus { holidays.status }

    public init(holidays: HolidayTable, timeZone: TimeZone? = nil) throws {
        guard let tz = timeZone ?? TimeZone(identifier: "America/New_York") else {
            throw KLineCoreError.unrepresentableLocalTime("time zone America/New_York is unavailable")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        self.et = cal
        self.holidays = holidays
    }

    public var verifiedCoverage: DateInterval {
        // 覆盖范围按结算日算，取 verifiedFrom 当天 00:00 到 verifiedThrough 次日 00:00。
        let start = (try? startOfDay(holidays.verifiedFrom)) ?? .distantPast
        let endDay = (try? startOfDay(holidays.verifiedThrough)) ?? .distantFuture
        return DateInterval(start: start, end: endDay.addingTimeInterval(86_400))
    }

    public func sessions(overlapping interval: DateInterval) throws -> [TradingSession] {

        try assertWithinCoverage(interval)

        var result: [TradingSession] = []

        // 时段从结算日前一晚开始，所以起点要往前多扫一天；
        // 终点多扫一天保证跨夜时段被完整包含。
        var day = et.startOfDay(for: interval.start.addingTimeInterval(-2 * 86_400))
        let last = interval.end.addingTimeInterval(2 * 86_400)

        while day <= last {
            defer { day = nextCalendarDay(after: day) }

            let weekday = et.component(.weekday, from: day) // 1 = Sunday … 7 = Saturday
            guard (2...6).contains(weekday) else { continue } // 只有周一至周五是结算日

            let settlement = try yearMonthDay(from: day)
            let rule = holidays.rule(for: settlement)

            if case .fullClosure = rule {
                continue // 整个时段消失，含前一晚的开盘
            }

            // 开盘：结算日前一日 18:00 ET（假期可延后）
            let previous = previousCalendarDay(before: day)
            var openTOD = Self.defaultOpen
            if case .lateOpen(let tod) = holidays.rule(for: try yearMonthDay(from: previous)) {
                openTOD = tod
            }
            let opens = try instant(onDay: previous, at: openTOD)

            // 收盘：结算日 17:00 ET（假期可提前）；周五收盘标记为 weekEnd
            var closeTOD = Self.defaultClose
            var kind: TradingSession.CloseKind = weekday == 6 ? .weekEnd : .regular
            if case .earlyClose(let tod) = rule {
                closeTOD = tod
                kind = .early
            }
            let closes = try instant(onDay: day, at: closeTOD)

            guard closes > opens else {
                throw KLineCoreError.degenerateSession(
                    settlementDay: settlement, opens: opens, closes: closes
                )
            }

            result.append(
                TradingSession(
                    opens: opens, closes: closes,
                    settlementDay: settlement, closeKind: kind
                )
            )
        }

        try assertOrderedAndDisjoint(result)

        return result.filter { $0.closes > interval.start && $0.opens < interval.end }
    }

    // MARK: - 私有

    /// 覆盖范围检查必须发生在查询**之前**。落在范围外时抛错，
    /// 而不是返回一个「看起来正常」的普通交易日时段。
    private func assertWithinCoverage(_ interval: DateInterval) throws {
        let coverage = verifiedCoverage
        guard interval.start >= coverage.start, interval.end <= coverage.end else {
            throw KLineCoreError.outsideVerifiedCoverage(
                queried: interval.start,
                verifiedFrom: holidays.verifiedFrom,
                verifiedThrough: holidays.verifiedThrough
            )
        }
    }

    private func assertOrderedAndDisjoint(_ sessions: [TradingSession]) throws {
        for (a, b) in zip(sessions, sessions.dropFirst()) {
            guard a.closes <= b.opens else {
                throw KLineCoreError.overlappingSessions(
                    "session settling \(a.settlementDay) closes at \(a.closes), "
                    + "but session settling \(b.settlementDay) opens earlier at \(b.opens)"
                )
            }
        }
    }

    private func nextCalendarDay(after day: Date) -> Date {
        // 加 26 小时再取 startOfDay，跨 DST 时也能稳定推进一个日历日。
        et.startOfDay(for: day.addingTimeInterval(26 * 3600))
    }

    private func previousCalendarDay(before day: Date) -> Date {
        et.startOfDay(for: day.addingTimeInterval(-22 * 3600))
    }

    private func yearMonthDay(from day: Date) throws -> YearMonthDay {
        let c = et.dateComponents([.year, .month, .day], from: day)
        guard let y = c.year, let m = c.month, let d = c.day else {
            throw KLineCoreError.unrepresentableLocalTime("cannot extract Y-M-D from \(day)")
        }
        return YearMonthDay(year: y, month: m, day: d)
    }

    private func startOfDay(_ ymd: YearMonthDay) throws -> Date {
        var c = DateComponents()
        c.year = ymd.year; c.month = ymd.month; c.day = ymd.day
        c.hour = 0; c.minute = 0; c.second = 0
        c.timeZone = et.timeZone
        guard let d = et.date(from: c) else {
            throw KLineCoreError.unrepresentableLocalTime("start of day \(ymd)")
        }
        return d
    }

    /// 有意不写 `?? someDefault`：ET 的 DST 切换发生在凌晨 2–3 点，
    /// 而 17:00 / 18:00 / 13:00 永远不会落进 DST 空洞。
    /// 真的返回 nil 说明这个前提被打破了（时区库变更？），必须炸出来。
    private func instant(onDay day: Date, at tod: TimeOfDayET) throws -> Date {
        var c = et.dateComponents([.year, .month, .day], from: day)
        c.hour = tod.hour; c.minute = tod.minute; c.second = 0
        c.timeZone = et.timeZone
        guard let d = et.date(from: c) else {
            throw KLineCoreError.unrepresentableLocalTime("\(tod) on \(day)")
        }
        return d
    }
}
