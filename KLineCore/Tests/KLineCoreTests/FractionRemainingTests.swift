//
//  FractionRemainingTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

final class FractionRemainingTests: XCTestCase {

    private func makeCountdown(remaining: Int, opens: Date, closes: Date) -> Countdown {
        Countdown(
            text: "", widthTemplate: "00:00", remainingSeconds: remaining,
            barOpens: opens, barCloses: closes, isTruncatedByClose: false,
            phase: .normal, concerns: []
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 满 K 线：开盘时约 1，中点约 0.5，收线前一秒约 1/length。
    func testFractionAcrossAFullBar() {
        let opens = t0
        let closes = t0.addingTimeInterval(300)

        XCTAssertEqual(makeCountdown(remaining: 300, opens: opens, closes: closes).fractionRemaining,
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(makeCountdown(remaining: 150, opens: opens, closes: closes).fractionRemaining,
                       0.5, accuracy: 0.0001)
        XCTAssertEqual(makeCountdown(remaining: 1, opens: opens, closes: closes).fractionRemaining,
                       1.0 / 300.0, accuracy: 0.0001)
    }

    /// 值域恒在 0...1，且永不为 0（与「倒计时永不显示 00:00」一致）。
    func testFractionStaysInUnitRangeAndNeverZero() {
        let opens = t0
        let closes = t0.addingTimeInterval(300)
        for remaining in 1...300 {
            let f = makeCountdown(remaining: remaining, opens: opens, closes: closes).fractionRemaining
            XCTAssertGreaterThan(f, 0)
            XCTAssertLessThanOrEqual(f, 1)
        }
    }

    /// 被截断的 K 线（4h 末根 / 提前收盘）：分母用实际长度，不是名义周期。
    /// 一根只有 180 秒的 K 线，剩 90 秒时应当是 0.5，而不是 90/300。
    func testTruncatedBarUsesActualLengthNotNominalPeriod() {
        let opens = t0
        let closes = t0.addingTimeInterval(180)   // 被截断到 3 分钟
        let f = makeCountdown(remaining: 90, opens: opens, closes: closes).fractionRemaining
        XCTAssertEqual(f, 0.5, accuracy: 0.0001,
                       "截断的 K 线应当按实际长度算比例，否则环会在收线前提早走空")
    }

    /// 用真实日历跑一根 5m K 线，逐秒断言比例单调不增、且首末符合预期。
    func testMonotonicOverRealBar() throws {
        let calendar = try TestSupport.makeCalendar()
        // 2026-03-02 周一 10:00 ET，普通交易时段中段
        let start = TestSupport.etInstant(2026, 3, 2, 10, 0, 0)
        guard let session = try calendar.session(containing: start) else {
            return XCTFail("应当在交易时段内")
        }

        var previous = 1.01
        for offset in 0..<300 {
            let instant = start.addingTimeInterval(TimeInterval(offset))
            let bar = try BarClock.bar(at: instant, period: .m5, session: session)
            let c = makeCountdown(remaining: bar.remainingSeconds, opens: bar.opens, closes: bar.closes)
            let f = c.fractionRemaining

            XCTAssertLessThanOrEqual(f, previous + 0.0001, "比例应单调不增")
            XCTAssertGreaterThan(f, 0)
            XCTAssertLessThanOrEqual(f, 1)
            previous = f
        }
    }
}
