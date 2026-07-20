//
//  LiveSanityTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

/// 对「此时此刻」的自洽性检查。
///
/// 与其他测试不同，这些跑在真实的当前时间上。它们不断言具体数值（那会随时间
/// 变化），而是断言两条独立路径给出同一个答案，并把结果打印出来供人工对照
/// 行情软件。这是「对着 TradingView 核对」之外，本地能做的最强验证。
final class LiveSanityTests: XCTestCase {

    func testCurrentInstantIsSelfConsistent() throws {
        let calendar = try TestSupport.makeCalendar()
        let now = Date()
        let ts = Int(now.timeIntervalSince1970)

        print("──────── 实时自洽性检查 ────────")
        print("本机 UTC 时间戳 : \(ts)")
        print("ET 当前时间     : \(TestSupport.describeET(now))")

        guard let session = try calendar.session(containing: now) else {
            let nextOpen = try calendar.nextOpen(after: now)
            print("市场状态        : 休市 → 刘海上应当完全不渲染")
            if let nextOpen {
                print("下次开盘        : \(TestSupport.describeET(nextOpen))")
                XCTAssertGreaterThan(nextOpen, now, "下次开盘必须在未来")
            }
            print("────────────────────────────────")
            return
        }

        print("市场状态        : 开盘中（结算日 \(session.settlementDay)，收盘类型 \(session.closeKind)）")
        print("时段窗口        : \(TestSupport.describeET(session.opens))")
        print("               → \(TestSupport.describeET(session.closes))")

        let bar = try BarClock.bar(at: now, period: .m5, session: session)
        let text = BarClock.format(remainingSeconds: bar.remainingSeconds)

        print("5m 倒计时       : \(text)   （剩 \(bar.remainingSeconds) 秒）")
        print("当前 K 线起点   : \(TestSupport.describeET(bar.opens))")
        print("当前 K 线收线   : \(TestSupport.describeET(bar.closes))")

        // 交叉验证：用完全独立的实现算一遍。
        // 5m 满足 P|3600 且 CME 开盘落在 UTC 整点，所以两者必须一致。
        let independentRemaining = 300 - (ts % 300)
        let independentBarOpen = ts - (ts % 300)

        XCTAssertEqual(
            bar.remainingSeconds, independentRemaining,
            "时段锚定给出 \(bar.remainingSeconds)s，独立取模给出 \(independentRemaining)s"
        )
        XCTAssertEqual(Int(bar.opens.timeIntervalSince1970), independentBarOpen)

        // 不变量
        XCTAssertGreaterThanOrEqual(bar.remainingSeconds, 1, "倒计时永不为 0")
        XCTAssertLessThanOrEqual(bar.remainingSeconds, 300)
        XCTAssertEqual(bar.closes.timeIntervalSince(bar.opens), 300, "5m 在时段中段不应被截断")

        let thresholds = CountdownThresholds(warning: 60, urgent: 15)
        let phase = CountdownPhase.of(remainingSeconds: bar.remainingSeconds, thresholds: thresholds)
        print("相位            : \(phase)")
        print("────────────────────────────────")
    }

    /// 从现在起连续走 30 分钟，逐秒断言序列合法。
    /// 这条不依赖真实时钟推进 —— 用注入的时刻回放。
    func testNextThirtyMinutesFormAValidSequence() throws {
        let calendar = try TestSupport.makeCalendar()
        let start = Date()

        var previousRemaining: Int?
        var barChanges = 0
        var closedSamples = 0

        for offset in 0..<1800 {
            let instant = start.addingTimeInterval(TimeInterval(offset))

            guard let session = try calendar.session(containing: instant) else {
                closedSamples += 1
                previousRemaining = nil
                continue
            }

            let bar = try BarClock.bar(at: instant, period: .m5, session: session)

            XCTAssertGreaterThanOrEqual(bar.remainingSeconds, 1)
            XCTAssertLessThanOrEqual(bar.remainingSeconds, 300)

            if let previous = previousRemaining {
                if bar.remainingSeconds == previous - 1 {
                    // 正常递减
                } else {
                    // 唯一允许的跳变：跨到新 K 线，直接回到周期长度
                    XCTAssertEqual(
                        previous, 1,
                        "在 \(TestSupport.describeET(instant)) 出现非法跳变：\(previous) → \(bar.remainingSeconds)"
                    )
                    barChanges += 1
                }
            }
            previousRemaining = bar.remainingSeconds
        }

        print("30 分钟回放：跨越 \(barChanges) 根 K 线，休市采样 \(closedSamples) 秒")
        if closedSamples == 0 {
            XCTAssertGreaterThanOrEqual(barChanges, 5, "30 分钟应当跨越至少 5 根 5m K 线")
        }
    }
}
