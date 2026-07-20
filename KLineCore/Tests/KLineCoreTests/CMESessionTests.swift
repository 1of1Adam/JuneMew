//
//  CMESessionTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

final class CMESessionTests: XCTestCase {

    private func cal() throws -> CMEEquityIndexCalendar { try TestSupport.makeCalendar() }

    // MARK: - 边界语义

    /// 收盘瞬间属于开区间端点：17:00:00.000 已经收盘。
    func testMondayCloseBoundary() throws {
        let c = try cal()
        // 2026-03-02 是周一（普通交易日，无假期）
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 3, 2, 16, 59, 59)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 2, 17, 0, 0)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 2, 17, 30, 0)))
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 3, 2, 18, 0, 0)))
    }

    /// 最容易写错的一条：周五 18:00 ET **不开盘**。
    /// 因为没有结算于周六的时段，所以周五晚上不会有新时段开始。
    func testFridayEveningDoesNotReopen() throws {
        let c = try cal()
        // 2026-03-06 是周五
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 3, 6, 16, 59, 59)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 6, 17, 0, 0)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 6, 18, 0, 0)),
            "周五晚 18:00 不开盘 —— 没有结算于周六的时段")
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 6, 23, 59, 59)))
    }

    /// 周六全天休市。
    func testSaturdayIsAlwaysClosed() throws {
        let c = try cal()
        for hour in 0..<24 {
            XCTAssertFalse(
                try c.isOpen(at: TestSupport.etInstant(2026, 3, 7, hour, 30, 0)),
                "周六 \(hour):30 ET 不应开盘"
            )
        }
    }

    /// 周日 18:00 ET 开盘（结算于周一的时段）。
    func testSundayEveningOpens() throws {
        let c = try cal()
        // 2026-03-08 是周日
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 8, 17, 59, 59)))
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 3, 8, 18, 0, 0)))
        XCTAssertTrue(try c.isOpen(at: TestSupport.etInstant(2026, 3, 8, 23, 0, 0)))
    }

    /// 一周的窗口枚举快照：2026-03-02 那一周恰好 5 个时段。
    func testWeeklySessionSnapshot() throws {
        let c = try cal()
        let week = DateInterval(
            start: TestSupport.etInstant(2026, 3, 1),   // 周日
            end:   TestSupport.etInstant(2026, 3, 8)    // 下个周日
        )
        let sessions = try c.sessions(overlapping: week)

        XCTAssertEqual(sessions.count, 5, "周一至周五各一个结算时段")

        // 第一个：周日 18:00 -> 周一 17:00
        XCTAssertEqual(sessions[0].opens,  TestSupport.etInstant(2026, 3, 1, 18, 0))
        XCTAssertEqual(sessions[0].closes, TestSupport.etInstant(2026, 3, 2, 17, 0))
        XCTAssertEqual(sessions[0].closeKind, .regular)

        // 最后一个：周四 18:00 -> 周五 17:00，且标记为周末收盘
        XCTAssertEqual(sessions[4].opens,  TestSupport.etInstant(2026, 3, 5, 18, 0))
        XCTAssertEqual(sessions[4].closes, TestSupport.etInstant(2026, 3, 6, 17, 0))
        XCTAssertEqual(sessions[4].closeKind, .weekEnd)

        // 时段之间必须严格不重叠且有序
        for (a, b) in zip(sessions, sessions.dropFirst()) {
            XCTAssertLessThanOrEqual(a.closes, b.opens)
        }
    }

    // MARK: - DST

    /// 守卫「前提一」：每日 18:00 / 17:00 / 13:00 ET 恒落在 UTC 整点。
    /// 这是「时段锚定 ≡ 取模」成立的基础，一旦被打破必须先炸在这里。
    func testDailyBoundaryInstantsAlwaysLandOnUTCHour() throws {
        for year in 2024...2030 {
            for month in 1...12 {
                for day in 1...28 {
                    for (h, m) in [(18, 0), (17, 0), (13, 0)] {
                        let t = Int(TestSupport.etInstant(year, month, day, h, m).timeIntervalSince1970)
                        XCTAssertEqual(t % 3600, 0,
                            "\(year)-\(month)-\(day) \(h):\(m) ET 没有落在 UTC 整点")
                    }
                }
            }
        }
    }

    /// 春季 DST 切换（2026-03-08 凌晨 2 点）落在休市窗口内。
    func testSpringForwardFallsInsideClosedWindow() throws {
        let c = try cal()
        // 切换发生在周日 02:00 -> 03:00，而周五 17:00 收盘、周日 18:00 才开盘
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 8, 1, 30)))
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 3, 8, 3, 30)))

        // 跨切换的这一周：周五 17:00 EST 收盘 -> 周日 18:00 EDT 开盘
        let fridayClose = TestSupport.etInstant(2026, 3, 6, 17, 0)
        let sundayOpen  = TestSupport.etInstant(2026, 3, 8, 18, 0)
        let gap = sundayOpen.timeIntervalSince(fridayClose)
        XCTAssertEqual(gap, 49 * 3600 - 3600,
            "跨春季切换的休市间隔应当比名义上的 49 小时少 1 小时")
    }

    /// 秋季 DST 切换（2026-11-01）同理，间隔多 1 小时。
    func testFallBackFallsInsideClosedWindow() throws {
        let c = try cal()
        XCTAssertFalse(try c.isOpen(at: TestSupport.etInstant(2026, 11, 1, 1, 30)))

        let fridayClose = TestSupport.etInstant(2026, 10, 30, 17, 0)
        let sundayOpen  = TestSupport.etInstant(2026, 11, 1, 18, 0)
        XCTAssertEqual(sundayOpen.timeIntervalSince(fridayClose), 49 * 3600 + 3600,
            "跨秋季切换的休市间隔应当比名义上的 49 小时多 1 小时")
    }

    /// 切换前后 5m 对齐都成立。
    func testAlignmentHoldsAcrossDSTTransition() throws {
        let c = try cal()
        for instant in [
            TestSupport.etInstant(2026, 3, 6, 10, 3, 17),    // 切换前（EST）
            TestSupport.etInstant(2026, 3, 9, 10, 3, 17),    // 切换后（EDT）
            TestSupport.etInstant(2026, 10, 30, 10, 3, 17),  // 秋季切换前（EDT）
            TestSupport.etInstant(2026, 11, 2, 10, 3, 17)    // 秋季切换后（EST）
        ] {
            guard let session = try c.session(containing: instant) else {
                return XCTFail("\(TestSupport.describeET(instant)) 应当在交易时段内")
            }
            let bar = try BarClock.bar(at: instant, period: .m5, session: session)
            let t = Int(instant.timeIntervalSince1970)
            XCTAssertEqual(Int(bar.opens.timeIntervalSince1970), t - (t % 300),
                "\(TestSupport.describeET(instant)) 的 5m 对齐被 DST 破坏了")
        }
    }

    // MARK: - nextOpen

    func testNextOpenFromWeekendPointsAtSundayEvening() throws {
        let c = try cal()
        let saturday = TestSupport.etInstant(2026, 3, 7, 12, 0)
        let next = try c.nextOpen(after: saturday)
        XCTAssertEqual(next, TestSupport.etInstant(2026, 3, 8, 18, 0))
    }

    func testNextOpenFromMaintenanceWindowPointsAtSameEvening() throws {
        let c = try cal()
        let maintenance = TestSupport.etInstant(2026, 3, 2, 17, 30)
        let next = try c.nextOpen(after: maintenance)
        XCTAssertEqual(next, TestSupport.etInstant(2026, 3, 2, 18, 0))
    }
}
