//
//  ThresholdClampTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

/// 守卫一个真实发生过的 bug：换周期时用户手调的阈值被静默重置成推荐值。
///
/// 症状是「把响铃阈值改成 30 秒，实际还是 15 秒响」—— 因为 Picker 的 setter
/// 无条件调用了 applyRecommendedThresholds，而 SwiftUI 在视图重建或重复选中
/// 同一项时也会触发 setter。
final class ThresholdClampTests: XCTestCase {

    /// 核心性质：只要在新周期里仍然合法，用户的绝对秒数必须原样保留。
    func testUserValuesSurviveAPeriodChangeWhenStillLegal() {
        let user = CountdownThresholds(warning: 90, urgent: 30)

        // 5m → 15m：宽松得多，必须一字不动
        let widened = user.clamped(toPeriodSeconds: BarPeriod.m15.seconds)
        XCTAssertEqual(widened.warning, 90)
        XCTAssertEqual(widened.urgent, 30, "用户设的 30 秒不该在换周期后变回 15")

        // 5m → 5m（Picker 重复触发同一项）：同样一字不动
        let same = user.clamped(toPeriodSeconds: BarPeriod.m5.seconds)
        XCTAssertEqual(same.warning, 90)
        XCTAssertEqual(same.urgent, 30)
    }

    /// 放不下时才压缩，且压缩后仍满足 `0 < urgent < warning < period`。
    func testValuesAreCompressedOnlyWhenTheyDoNotFit() {
        let user = CountdownThresholds(warning: 90, urgent: 30)

        // 换到 1m（60s）：90 秒的 warning 放不下，必须压到 59
        let narrowed = user.clamped(toPeriodSeconds: BarPeriod.m1.seconds)
        XCTAssertEqual(narrowed.warning, 59)
        XCTAssertEqual(narrowed.urgent, 30, "urgent 仍放得下，应当保留")
        XCTAssertLessThan(narrowed.urgent, narrowed.warning)
        XCTAssertLessThan(narrowed.warning, BarPeriod.m1.seconds)
    }

    /// 极端压缩：两个阈值都放不下时仍保持合法序关系。
    func testInvariantsHoldUnderExtremeCompression() {
        let user = CountdownThresholds(warning: 900, urgent: 800)

        for period in BarPeriod.allCases {
            let c = user.clamped(toPeriodSeconds: period.seconds)
            XCTAssertGreaterThan(c.urgent, 0, "\(period.displayName)")
            XCTAssertGreaterThan(c.warning, c.urgent,
                                 "\(period.displayName)：urgent 必须严格小于 warning")
            XCTAssertLessThan(c.warning, period.seconds,
                              "\(period.displayName)：warning 必须小于周期长度")
        }
    }

    /// 夹取是幂等的 —— 反复换周期不该逐次缩水。
    func testClampingIsIdempotent() {
        let user = CountdownThresholds(warning: 90, urgent: 30)
        let once = user.clamped(toPeriodSeconds: BarPeriod.m1.seconds)
        let twice = once.clamped(toPeriodSeconds: BarPeriod.m1.seconds)
        XCTAssertEqual(once, twice)

        // 来回切换周期，值不应当持续衰减
        var t = user
        for _ in 0..<10 {
            t = t.clamped(toPeriodSeconds: BarPeriod.m15.seconds)
            t = t.clamped(toPeriodSeconds: BarPeriod.m15.seconds)
        }
        XCTAssertEqual(t, user, "在宽松周期上反复夹取不该改变用户的值")
    }

    /// 对照：recommended 仍然只用于初始化，且自身合法。
    func testRecommendedRemainsWellFormed() {
        for period in BarPeriod.allCases {
            let r = CountdownThresholds.recommended(for: period)
            XCTAssertGreaterThan(r.urgent, 0)
            XCTAssertGreaterThan(r.warning, r.urgent)
            XCTAssertLessThan(r.warning, period.seconds)
        }
    }
}
