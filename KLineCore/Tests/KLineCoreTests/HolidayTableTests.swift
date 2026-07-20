//
//  HolidayTableTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

final class HolidayTableTests: XCTestCase {

    // MARK: - 假期对时段的影响

    /// 全天休市：该结算日没有时段，**且前一晚 18:00 不开盘**。
    func testFullClosureAlsoRemovesPreviousEveningOpen() throws {
        let c = try TestSupport.makeCalendar()

        // 2026-04-03 Good Friday，全天休市
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 4, 3, 10, 0)))
        // 前一晚（周四 4/2 18:00）也不该开盘 —— 那本是结算于周五的时段
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 4, 2, 19, 0)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 4, 2, 23, 0)))
        // 但周四白天正常交易
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 4, 2, 10, 0)))
        // 周四 17:00 收盘
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 4, 2, 17, 0)))
    }

    /// 提前收盘：时段的 closes 被改到指定时刻，且 closeKind 标记为 early。
    func testEarlyCloseTruncatesSession() throws {
        let c = try TestSupport.makeCalendar()

        // 2026-11-27 感恩节次日，提前到 13:15 ET
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 11, 27, 13, 14, 59)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 11, 27, 13, 15, 0)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 11, 27, 16, 0)))

        guard let session = try c.session(containing: TestSupport.etInstant(2026, 11, 27, 10, 0)) else {
            return XCTFail("感恩节次日上午应当在交易时段内")
        }
        XCTAssertEqual(session.closes, TestSupport.etInstant(2026, 11, 27, 13, 15))
        XCTAssertEqual(session.closeKind, .early)
    }

    /// 提前收盘会截断最后一根 K 线。13:15 不在 30m 网格上。
    func testEarlyCloseTruncatesFinalBar() throws {
        let c = try TestSupport.makeCalendar()
        guard let session = try c.session(containing: TestSupport.etInstant(2026, 11, 27, 13, 10)) else {
            return XCTFail("应当在交易时段内")
        }

        // 13:00 起的 30m 线本该到 13:30，被 13:15 截断
        let bar = try BarClock.bar(
            at: TestSupport.etInstant(2026, 11, 27, 13, 10),
            period: .m30,
            session: session
        )
        XCTAssertTrue(bar.isTruncated)
        XCTAssertEqual(bar.closes, TestSupport.etInstant(2026, 11, 27, 13, 15))
        XCTAssertEqual(bar.remainingSeconds, 300)

        // 5m 恰好落在 13:15 上，不算截断
        let bar5 = try BarClock.bar(
            at: TestSupport.etInstant(2026, 11, 27, 13, 12),
            period: .m5,
            session: session
        )
        XCTAssertFalse(bar5.isTruncated)
        XCTAssertEqual(bar5.closes, TestSupport.etInstant(2026, 11, 27, 13, 15))
    }

    /// 感恩节整周的序列。
    func testThanksgivingWeekSequence() throws {
        let c = try TestSupport.makeCalendar()

        // 周三 11/25 正常交易到 17:00
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 11, 25, 16, 0)))
        // 周四 11/26 感恩节，提前到 13:00
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 11, 26, 12, 0)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 11, 26, 14, 0)))
        // 周四晚照常 18:00 重开
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 11, 26, 19, 0)))
        // 周五 11/27 提前到 13:15
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 11, 27, 13, 0)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 11, 27, 14, 0)))
        // 周五晚不开盘（周末）
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 11, 27, 19, 0)))
    }

    // MARK: - 覆盖范围：核心安全性质

    /// 查询落在已核验范围外必须**抛错**，而不是当作普通交易日。
    ///
    /// 这是整个假期机制里最重要的一条：如果越界时静默返回一个正常时段，
    /// 用户会在假期表过期后看到照常跳动、但完全错误的倒计时。
    func testQueryOutsideVerifiedCoverageThrows() throws {
        let c = try TestSupport.makeCalendar()

        XCTAssertThrowsError(
            try c.sessions(overlapping: DateInterval(
                start: TestSupport.etInstant(2029, 6, 1),
                duration: 86_400
            ))
        ) { error in
            guard case KLineCoreError.outsideVerifiedCoverage = error else {
                return XCTFail("期望 outsideVerifiedCoverage，实际 \(error)")
            }
        }

        XCTAssertThrowsError(
            try c.sessions(overlapping: DateInterval(
                start: TestSupport.etInstant(2020, 1, 1),
                duration: 86_400
            ))
        )
    }

    /// 「表里没有这一天的条目」≠「没查过这一天」。
    /// 范围内的普通交易日必须正常返回时段。
    func testDayInsideCoverageWithNoEntryIsARegularTradingDay() throws {
        let c = try TestSupport.makeCalendar()
        let ordinary = TestSupport.etInstant(2026, 3, 2, 10, 0)
        XCTAssertTrue(try c.isOpen(at: ordinary))
        XCTAssertEqual(try c.session(containing: ordinary)?.closeKind, .regular)
    }

    // MARK: - 解码的失败模式

    /// 损坏的 JSON 必须抛错，绝不 fallback 到空表。
    /// 空表意味着每一天都是普通交易日 —— 最危险的失败模式。
    func testCorruptJSONThrowsInsteadOfFallingBackToEmptyTable() {
        XCTAssertThrowsError(try HolidayTable(jsonData: Data("{ not json".utf8)))

        // 缺字段
        let missing = #"{ "exchange": "X", "verificationStatus": "verified" }"#
        XCTAssertThrowsError(try HolidayTable(jsonData: Data(missing.utf8)))
    }

    func testUnknownRuleTypeThrows() {
        let json = """
        {
          "exchange": "X", "verificationStatus": "verified", "source": "s",
          "verifiedFrom": "2026-01-01", "verifiedThrough": "2026-12-31",
          "entries": [ { "date": "2026-05-25", "name": "n", "rule": { "type": "halfDay" } } ]
        }
        """
        XCTAssertThrowsError(try HolidayTable(jsonData: Data(json.utf8))) { error in
            guard case KLineCoreError.holidayTableUnreadable = error else {
                return XCTFail("期望 holidayTableUnreadable，实际 \(error)")
            }
        }
    }

    func testEarlyCloseWithoutTimeThrows() {
        let json = """
        {
          "exchange": "X", "verificationStatus": "verified", "source": "s",
          "verifiedFrom": "2026-01-01", "verifiedThrough": "2026-12-31",
          "entries": [ { "date": "2026-05-25", "name": "n", "rule": { "type": "earlyClose" } } ]
        }
        """
        XCTAssertThrowsError(try HolidayTable(jsonData: Data(json.utf8)))
    }

    /// 条目落在声明的覆盖范围之外说明表自相矛盾。
    func testEntryOutsideDeclaredCoverageThrows() {
        let json = """
        {
          "exchange": "X", "verificationStatus": "verified", "source": "s",
          "verifiedFrom": "2026-01-01", "verifiedThrough": "2026-06-30",
          "entries": [ { "date": "2026-11-26", "name": "n", "rule": { "type": "fullClosure" } } ]
        }
        """
        XCTAssertThrowsError(try HolidayTable(jsonData: Data(json.utf8)))
    }

    func testDuplicateEntryThrows() {
        let json = """
        {
          "exchange": "X", "verificationStatus": "verified", "source": "s",
          "verifiedFrom": "2026-01-01", "verifiedThrough": "2026-12-31",
          "entries": [
            { "date": "2026-05-25", "name": "a", "rule": { "type": "fullClosure" } },
            { "date": "2026-05-25", "name": "b", "rule": { "type": "fullClosure" } }
          ]
        }
        """
        XCTAssertThrowsError(try HolidayTable(jsonData: Data(json.utf8)))
    }

    func testMalformedDateThrows() {
        XCTAssertThrowsError(try YearMonthDay(iso: "2026-13-01"))
        XCTAssertThrowsError(try YearMonthDay(iso: "2026/04/03"))
        XCTAssertThrowsError(try YearMonthDay(iso: "not-a-date"))
        XCTAssertThrowsError(try TimeOfDayET(hhmm: "25:00"))
        XCTAssertThrowsError(try TimeOfDayET(hhmm: "13"))
    }

    // MARK: - 有效期硬闸

    /// 假期表必须始终保有充足的剩余有效期。
    ///
    /// 这是「表过期」这个问题的**真正修复**：运行期告警只能在数据烂掉之后才响，
    /// 而这条测试保证永远不可能发布一个即将过期的表。
    func testHolidayTableHasSufficientRunway() throws {
        let table = try HolidayTable.bundled()

        var c = DateComponents()
        c.year = table.verifiedThrough.year
        c.month = table.verifiedThrough.month
        c.day = table.verifiedThrough.day
        c.timeZone = TestSupport.et.timeZone
        guard let through = TestSupport.et.date(from: c) else {
            return XCTFail("无法解析 verifiedThrough")
        }

        let runwayDays = through.timeIntervalSinceNow / 86_400
        XCTAssertGreaterThan(runwayDays, 270, """
            假期表只剩 \(Int(runwayDays)) 天有效期。
            发版前必须对照 CME 官方 Holiday Calendar 更新条目并前推 verifiedThrough。
            见 Resources/cme-equity-index-holidays.json 里的 _README。
            """)
    }

    /// 假期表应当经过人工核对。
    ///
    /// 当前**预期失败** —— 随包的表是 unverified_draft。这不是代码缺陷，是一件
    /// 明确记录在案的待办：日期已用算法交叉验证，但下面这些只能对着官方日历核：
    ///   1. 每个假期是全天休市还是提前收盘
    ///   2. 提前收盘的准确时刻（12:00 CT 还是 12:15 CT）
    ///   3. 四个落周末假期的观察日规则
    ///      2026-07-04(六) / 2027-06-19(六) / 2027-07-04(日) / 2027-12-25(六)
    ///
    /// 核对完成后把 JSON 的 verificationStatus 改成 "verified"，
    /// 此时 XCTExpectFailure 会因「预期的失败没有发生」而报错，
    /// 提醒你把这层包裹删掉 —— 状态机是闭合的，不会有人忘记。
    func testHolidayTableHasBeenHumanVerified() throws {
        XCTExpectFailure("随包假期表尚未对照 CME 官方日历人工核对；应用会在设置页显示告警") {
            let table = try? HolidayTable.bundled()
            XCTAssertEqual(table?.status, .verified)
        }
    }
}
