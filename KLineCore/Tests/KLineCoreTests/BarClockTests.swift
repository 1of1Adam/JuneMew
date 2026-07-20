//
//  BarClockTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

final class BarClockTests: XCTestCase {

    // MARK: - floorDiv

    func testFloorDivHandlesNegativesAsMathematicalFloor() {
        // Swift 的 `/` 会给出 0 / 0 / -1（向零截断），全是错的
        XCTAssertEqual(floorDiv(-1, 300), -1)
        XCTAssertEqual(floorDiv(-299, 300), -1)
        XCTAssertEqual(floorDiv(-300, 300), -1)
        XCTAssertEqual(floorDiv(-301, 300), -2)

        XCTAssertEqual(floorDiv(0, 300), 0)
        XCTAssertEqual(floorDiv(299, 300), 0)
        XCTAssertEqual(floorDiv(300, 300), 1)
        XCTAssertEqual(floorDiv(301, 300), 1)
    }

    // MARK: - 对齐性：把定理钉进 CI

    /// 对每个 `P | 3600` 的周期，时段锚定必须与朴素取模逐点一致。
    ///
    /// 这条测试守卫的是：CME Globex 开盘落在 UTC 整点（`3600 | S`）。
    /// 如果交易所将来改了开盘时刻，或时区数据变了，这条会先炸。
    func testSessionAnchoredEqualsModuloForHourDividingPeriods() throws {
        let sessions = try TestSupport.allSessions()
        XCTAssertGreaterThan(sessions.count, 400, "两年应该有 500 个左右的交易时段")

        let periods = BarPeriod.allCases.filter(\.dividesHour)
        XCTAssertEqual(periods.count, 6, "1m/3m/5m/15m/30m/1h 应当整除 3600")

        var checked = 0
        // 用质数步长采样，覆盖各种相位而不必逐秒遍历
        let stride = 137

        for session in sessions {
            let open = Int(session.opens.timeIntervalSince1970)
            let close = Int(session.closes.timeIntervalSince1970)

            for period in periods {
                var t = open
                while t < close {
                    let instant = Date(timeIntervalSince1970: TimeInterval(t))
                    let bar = try BarClock.bar(at: instant, period: period, session: session)

                    let naive = t - (t % period.seconds)
                    XCTAssertEqual(
                        Int(bar.opens.timeIntervalSince1970), naive,
                        "\(period.displayName) at \(TestSupport.describeET(instant)): "
                        + "anchored \(TestSupport.describeET(bar.opens)) != naive modulo"
                    )
                    checked += 1
                    t += stride
                }
            }
        }
        print("对齐性交叉验证了 \(checked) 个采样点")
        XCTAssertGreaterThan(checked, 400_000, "采样点太少，覆盖不足")
    }

    /// 反向断言：4h **必须**与朴素取模不同。
    ///
    /// 这条存在的意义是防止有人日后把通用公式「优化」成取模快路径。
    /// 4h（14400 秒）不整除 3600，取模会把边界放在 15:00/19:00/23:00 ET（冬令时），
    /// 而正确边界是 18:00/22:00/02:00 ET。
    func testFourHourDivergesFromNaiveModulo() throws {
        XCTAssertFalse(BarPeriod.h4.dividesHour)

        let sessions = try TestSupport.allSessions()
        var divergences = 0
        var total = 0

        for session in sessions.prefix(60) {
            let open = Int(session.opens.timeIntervalSince1970)
            let close = Int(session.closes.timeIntervalSince1970)
            var t = open
            while t < close {
                let bar = try BarClock.bar(
                    at: Date(timeIntervalSince1970: TimeInterval(t)),
                    period: .h4,
                    session: session
                )
                if Int(bar.opens.timeIntervalSince1970) != t - (t % 14400) { divergences += 1 }
                total += 1
                t += 601
            }
        }

        XCTAssertEqual(divergences, total,
            "4h 的时段锚定应当在所有采样点都异于朴素取模，实际 \(divergences)/\(total)")
    }

    /// 4h 的最后一根被时段收盘截断：Globex 时段 23 小时，23 ÷ 4 = 5.75。
    func testFourHourLastBarIsTruncatedBySessionClose() throws {
        let sessions = try TestSupport.allSessions()
        // 挑一个普通交易日（收盘类型 regular，即周一至周四）
        guard let session = sessions.first(where: { $0.closeKind == .regular }) else {
            return XCTFail("找不到普通交易时段")
        }

        // 时段最后一秒
        let last = session.closes.addingTimeInterval(-1)
        let bar = try BarClock.bar(at: last, period: .h4, session: session)

        XCTAssertTrue(bar.isTruncated, "4h 的最后一根应当被收盘截断")
        XCTAssertEqual(bar.closes, session.closes, "截断后的收线时刻应等于时段收盘")

        // 而 5m 的最后一根正好落在收盘上，不算截断
        let bar5 = try BarClock.bar(at: last, period: .m5, session: session)
        XCTAssertFalse(bar5.isTruncated, "5m 恰好整除，最后一根不应被截断")
        XCTAssertEqual(bar5.remainingSeconds, 1)
    }

    // MARK: - remainingSeconds 语义

    /// 值域恒为 `1...P`，永不为 0 —— 倒计时不会停在 00:00。
    func testRemainingSecondsNeverZeroAndWithinPeriod() throws {
        let sessions = try TestSupport.allSessions()

        for session in sessions.prefix(40) {
            let open = Int(session.opens.timeIntervalSince1970)
            let close = Int(session.closes.timeIntervalSince1970)

            for period in BarPeriod.allCases {
                var t = open
                while t < close {
                    let bar = try BarClock.bar(
                        at: Date(timeIntervalSince1970: TimeInterval(t)),
                        period: period,
                        session: session
                    )
                    XCTAssertGreaterThanOrEqual(bar.remainingSeconds, 1,
                        "\(period.displayName) 在 \(TestSupport.describeET(bar.opens)) 给出了 0 或负数")
                    XCTAssertLessThanOrEqual(bar.remainingSeconds, period.seconds)
                    t += 53
                }
            }
        }
    }

    /// ceil 语义的两个端点。
    func testCeilSemanticsAtBarBoundaries() throws {
        let sessions = try TestSupport.allSessions()
        guard let session = sessions.first(where: { $0.closeKind == .regular }) else {
            return XCTFail("找不到普通交易时段")
        }

        // 时段开盘瞬间：整根 K 线都还在
        let atOpen = try BarClock.bar(at: session.opens, period: .m5, session: session)
        XCTAssertEqual(atOpen.remainingSeconds, 300)
        XCTAssertEqual(atOpen.opens, session.opens)

        // 收线前 1 毫秒：应当显示 1 秒而不是 0
        let justBeforeClose = atOpen.closes.addingTimeInterval(-0.001)
        let nearEnd = try BarClock.bar(at: justBeforeClose, period: .m5, session: session)
        XCTAssertEqual(nearEnd.remainingSeconds, 1)
        XCTAssertEqual(nearEnd.opens, session.opens, "还没跨到下一根")
    }

    /// 时段外查询必须抛错，不能返回一个看似合理的值。
    func testQueryOutsideSessionThrows() throws {
        let sessions = try TestSupport.allSessions()
        guard let session = sessions.first else { return XCTFail("没有时段") }

        XCTAssertThrowsError(
            try BarClock.bar(at: session.closes, period: .m5, session: session),
            "收盘时刻属于开区间端点，应当抛错"
        )
        XCTAssertThrowsError(
            try BarClock.bar(at: session.opens.addingTimeInterval(-1), period: .m5, session: session)
        )
    }

    // MARK: - 格式化

    func testFormatUsesHoursOnlyWhenNeeded() {
        XCTAssertEqual(BarClock.format(remainingSeconds: 1), "00:01")
        XCTAssertEqual(BarClock.format(remainingSeconds: 59), "00:59")
        XCTAssertEqual(BarClock.format(remainingSeconds: 272), "04:32")
        XCTAssertEqual(BarClock.format(remainingSeconds: 300), "05:00")
        XCTAssertEqual(BarClock.format(remainingSeconds: 3599), "59:59")

        // 4h 用 MM:SS 会溢出成 "240:00"
        XCTAssertEqual(BarClock.format(remainingSeconds: 3600), "1:00:00")
        XCTAssertEqual(BarClock.format(remainingSeconds: 14400), "4:00:00")
        XCTAssertEqual(BarClock.format(remainingSeconds: 14399), "3:59:59")
    }

    /// 宽度模板必须真的不窄于任何可能出现的显示串。
    func testWidthTemplateIsNeverNarrowerThanActualText() {
        for period in BarPeriod.allCases {
            let template = BarClock.widthTemplate(for: period)
            for remaining in [1, 59, 60, 299, 300, period.seconds] where remaining <= period.seconds {
                let text = BarClock.format(remainingSeconds: remaining)
                XCTAssertGreaterThanOrEqual(
                    template.count, text.count,
                    "\(period.displayName) 的模板 \"\(template)\" 窄于实际文本 \"\(text)\""
                )
            }
        }
    }

    /// v1 不开放 4h —— 锚定约定尚未实测确认。
    func testUserSelectablePeriodsExcludeFourHour() {
        XCTAssertFalse(BarPeriod.userSelectable.contains(.h4))
        XCTAssertTrue(BarPeriod.userSelectable.allSatisfy(\.dividesHour),
            "开放给用户的周期必须全部整除 3600")
    }
}
