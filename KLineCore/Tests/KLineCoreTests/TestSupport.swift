//
//  TestSupport.swift
//  KLineCoreTests
//

import Foundation
import XCTest
@testable import KLineCore

enum TestSupport {

    static var et: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// 构造一个 ET 本地时刻。
    static func etInstant(
        _ y: Int, _ mo: Int, _ d: Int,
        _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0
    ) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        c.hour = h; c.minute = mi; c.second = s
        c.timeZone = et.timeZone
        guard let date = et.date(from: c) else {
            fatalError("cannot build ET instant \(y)-\(mo)-\(d) \(h):\(mi):\(s)")
        }
        return date
    }

    /// 把时刻格式化成 ET 的 `yyyy-MM-dd HH:mm:ss`，便于断言失败时看懂。
    static func describeET(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = et.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: date)
    }

    static func makeCalendar() throws -> CMEEquityIndexCalendar {
        try CMEEquityIndexCalendar(holidays: try HolidayTable.bundled())
    }

    /// 已核验覆盖范围内的全部交易时段。
    static func allSessions() throws -> [TradingSession] {
        let cal = try makeCalendar()
        return try cal.sessions(overlapping: cal.verifiedCoverage)
    }
}
