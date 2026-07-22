//
//  RuntimeTests.swift
//  KLineCoreTests
//

import XCTest
@testable import KLineCore

final class ClockIntegrityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 阈值判定（表驱动）

    func testVerdictThresholdTable() {
        func verdict(_ offset: TimeInterval) -> ClockVerdict {
            ClockPolicy.verdict(
                for: .verified(offset: offset, uncertainty: 0.55, at: now),
                now: now
            )
        }

        XCTAssertEqual(verdict(0.0), .trusted)
        XCTAssertEqual(verdict(1.4), .trusted)
        XCTAssertEqual(verdict(1.5), .trusted, "边界值不算超标")
        XCTAssertEqual(verdict(1.6), .degraded(offset: 1.6))
        XCTAssertEqual(verdict(5.0), .degraded(offset: 5.0), "边界值仍在软区")
        XCTAssertEqual(verdict(5.1), .untrusted(offset: 5.1))
        XCTAssertEqual(verdict(45.0), .untrusted(offset: 45.0))
    }

    /// 负偏差（本机慢）必须与正偏差对称处理。
    func testVerdictIsSymmetricForNegativeOffsets() {
        for magnitude in [1.4, 1.6, 5.1, 45.0] {
            let positive = ClockPolicy.verdict(for: .verified(offset: magnitude, uncertainty: 0.5, at: now), now: now)
            let negative = ClockPolicy.verdict(for: .verified(offset: -magnitude, uncertainty: 0.5, at: now), now: now)

            switch (positive, negative) {
            case (.trusted, .trusted):
                break
            case let (.degraded(a), .degraded(b)):
                XCTAssertEqual(a, -b)
            case let (.untrusted(a), .untrusted(b)):
                XCTAssertEqual(a, -b)
            default:
                XCTFail("\(magnitude) 的正负偏差判定不对称：\(positive) vs \(negative)")
            }
        }
    }

    /// 探测到阶跃后一律不可信，与幅度无关 —— 哪怕只跳了 0.6 秒。
    func testJumpIsAlwaysUntrustedRegardlessOfMagnitude() {
        for delta in [0.6, 2.0, 3600.0] {
            let v = ClockPolicy.verdict(for: .jumped(delta: delta, at: now), now: now)
            guard case .untrusted = v else {
                return XCTFail("阶跃 \(delta)s 应当判 untrusted，实际 \(v)")
            }
        }
    }

    /// 校准失败绝不能静默降级成 trusted。
    func testUnverifiedNeverBecomesTrusted() {
        let v = ClockPolicy.verdict(
            for: .unverified(since: now.addingTimeInterval(-7200), lastError: "offline"),
            now: now
        )
        guard case let .unverifiedButUsable(staleness) = v else {
            return XCTFail("期望 unverifiedButUsable，实际 \(v)")
        }
        XCTAssertEqual(staleness, 7200, accuracy: 0.001)
    }

    // MARK: - HTTP Date 头

    /// POSIX locale 回归测试。用户 locale 设成中文时，
    /// 默认 formatter 解析不了英文月份缩写 —— 这类 bug 只在部分机器上出现。
    func testIMFDateParsesUnderNonEnglishLocale() {
        let parsed = HTTPDateProbe.imfFormatter.date(from: "Mon, 20 Jul 2026 12:00:00 GMT")
        XCTAssertNotNil(parsed, "IMF-fixdate 解析失败 —— formatter 的 locale 不是 en_US_POSIX？")

        var expected = DateComponents()
        expected.year = 2026; expected.month = 7; expected.day = 20
        expected.hour = 12; expected.minute = 0; expected.second = 0
        expected.timeZone = TimeZone(secondsFromGMT: 0)
        XCTAssertEqual(parsed, Calendar(identifier: .gregorian).date(from: expected))
    }

    /// 偏差估计：本机快 3 秒时应当算出 +3（含头部量化的半秒修正）。
    func testSampleAccountsForRoundTripAndHeaderQuantisation() {
        let serverSaid = Date(timeIntervalSince1970: 1_800_000_000)
        // 本机在服务器时刻 +3.5 秒时发出请求，RTT 200ms
        let localBefore = Date(timeIntervalSince1970: 1_800_000_003.5)

        let sample = HTTPDateProbe.sample(
            requestSentAt: localBefore,
            roundTrip: 0.2,
            serverHeaderDate: serverSaid
        )

        // 本机中点 = 3.5 + 0.1 = 3.6；服务器估计 = 0 + 0.5 = 0.5；偏差 = 3.1
        XCTAssertEqual(sample.offset, 3.1, accuracy: 0.0001)
        XCTAssertEqual(sample.uncertainty, 0.6, accuracy: 0.0001)
    }

    /// 端点互相矛盾时返回 nil 而不是取平均。
    /// 平均一个对的和一个错的，会得到第三个错的、但看起来很合理的值。
    func testReconcileRejectsDisagreeingEndpointsInsteadOfAveraging() {
        let a = HTTPDateProbe.Sample(offset: 0.2, uncertainty: 0.6, roundTrip: 0.2)
        let b = HTTPDateProbe.Sample(offset: 30.0, uncertainty: 0.6, roundTrip: 0.1)

        XCTAssertNil(HTTPDateProbe.reconcile([a, b]), "分歧 29.8s 应当判 unverified")

        let c = HTTPDateProbe.Sample(offset: 0.5, uncertainty: 0.6, roundTrip: 0.05)
        let merged = HTTPDateProbe.reconcile([a, c])
        XCTAssertEqual(merged, c, "一致时应取 RTT 最小的样本")
    }

    func testReconcileHandlesEmptyAndSingle() {
        XCTAssertNil(HTTPDateProbe.reconcile([]))
        let only = HTTPDateProbe.Sample(offset: 9.9, uncertainty: 0.6, roundTrip: 0.3)
        XCTAssertEqual(HTTPDateProbe.reconcile([only]), only)
    }

    // MARK: - 单调哨兵

    /// 墙钟与单调钟同步推进时，drift 应当接近 0。
    func testSentinelReportsNoDriftWhenClocksAdvanceTogether() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let mono = ContinuousClock.now
        let sentinel = MonotonicSentinel(wall: base, mono: mono)

        let drift = sentinel.drift(
            wall: base.addingTimeInterval(10),
            mono: mono.advanced(by: .seconds(10))
        )
        XCTAssertEqual(drift, 0, accuracy: 0.001)
    }

    /// 墙钟被前跳 1 小时而单调钟只走了 10 秒 —— 应当报出约 3590 秒的阶跃。
    func testSentinelDetectsWallClockJump() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let mono = ContinuousClock.now
        let sentinel = MonotonicSentinel(wall: base, mono: mono)

        let drift = sentinel.drift(
            wall: base.addingTimeInterval(3600 + 10),
            mono: mono.advanced(by: .seconds(10))
        )
        XCTAssertEqual(drift, 3600, accuracy: 0.001)
        XCTAssertGreaterThan(abs(drift), ClockPolicy.jumpThreshold)
    }

    func testSentinelReanchorClearsDrift() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let mono = ContinuousClock.now
        var sentinel = MonotonicSentinel(wall: base, mono: mono)

        let jumped = base.addingTimeInterval(3600)
        let monoLater = mono.advanced(by: .seconds(10))
        XCTAssertGreaterThan(abs(sentinel.drift(wall: jumped, mono: monoLater)), 1)

        // 唤醒后重新锚定：睡眠期间的差异不构成阶跃证据
        sentinel.reanchor(wall: jumped, mono: monoLater)
        XCTAssertEqual(sentinel.drift(wall: jumped, mono: monoLater), 0, accuracy: 0.001)
    }
}

final class TickTimingTests: XCTestCase {

    /// 相位：任意起点算出的目标时刻都应落在整数秒之后一点点。
    ///
    /// 容差取 1e-6：Unix 时间戳量级约 1.8e9，Double 在此处的 ULP 是
    /// `1.8e9 / 2^52 ≈ 4e-7`，`now + delay` 的加法必然引入这个量级的误差。
    /// 8ms 的 overshoot 比它大三个数量级，所以实际调度行为不受影响。
    func testDelayAlwaysLandsJustAfterASecondBoundary() {
        let epsilon = 1e-6

        for i in 0..<1000 {
            let now = 1_800_000_000.0 + Double(i) * 0.0137
            let target = now + TickTiming.delayToNextBoundary(from: now)
            let phase = target.truncatingRemainder(dividingBy: 1.0)

            XCTAssertGreaterThanOrEqual(phase, TickTiming.overshoot - epsilon,
                "目标相位 \(phase) 早于整数秒，floor() 可能还没翻位")
            XCTAssertLessThan(phase, TickTiming.overshoot + TickTiming.minimumLead + epsilon,
                "目标相位 \(phase) 离整数秒太远")
        }
    }

    /// 已经贴着边界时必须跳到下一秒，不能在同一个整数秒里算两次。
    func testDelaySkipsAheadWhenAlreadyAtBoundary() {
        let justBefore = 1_800_000_000.999
        let delay = TickTiming.delayToNextBoundary(from: justBefore)
        XCTAssertGreaterThan(delay, 1.0, "距边界不足 minimumLead 时应跳到下一秒")

        let exactly = 1_800_000_000.0
        XCTAssertEqual(TickTiming.delayToNextBoundary(from: exactly), 1.0 + TickTiming.overshoot, accuracy: 1e-9)
    }

    /// 延迟永远为正 —— 不能出现立即重复触发。
    func testDelayIsAlwaysPositive() {
        for i in 0..<2000 {
            let now = 1_800_000_000.0 + Double(i) * 0.0005
            XCTAssertGreaterThan(TickTiming.delayToNextBoundary(from: now), 0)
        }
    }
}

final class AlertArmingTests: XCTestCase {

    private let closeA = Date(timeIntervalSince1970: 1_800_000_300)
    private let closeB = Date(timeIntervalSince1970: 1_800_000_600)

    /// 同一根 K 线只响一次，哪怕每秒都问一遍。
    func testFiresOnlyOncePerBar() {
        var arming = AlertArming()

        // 先观察到阈值之外，完成武装
        XCTAssertFalse(arming.shouldFire(remainingSeconds: 60, barCloses: closeA, threshold: 15))

        var fires = 0
        for remaining in stride(from: 15, through: 1, by: -1) {
            if arming.shouldFire(remainingSeconds: remaining, barCloses: closeA, threshold: 15) {
                fires += 1
            }
        }
        XCTAssertEqual(fires, 1, "一根 K 线内应当只响一次")
    }

    /// 启动时恰好落在阈值内 —— 必须静默跳过这一根。
    func testDoesNotFireWhenStartingInsideThreshold() {
        var arming = AlertArming()
        // app 刚启动，当前 K 线只剩 8 秒，阈值 15
        XCTAssertFalse(arming.shouldFire(remainingSeconds: 8, barCloses: closeA, threshold: 15),
            "刚打开就响是很糟的第一印象")
        XCTAssertFalse(arming.shouldFire(remainingSeconds: 3, barCloses: closeA, threshold: 15))

        // 下一根 K 线正常响
        XCTAssertFalse(arming.shouldFire(remainingSeconds: 300, barCloses: closeB, threshold: 15))
        XCTAssertTrue(arming.shouldFire(remainingSeconds: 15, barCloses: closeB, threshold: 15))
    }

    /// K 线滚动后守卫自动重置，不需要手动清状态。
    func testRearmsAutomaticallyOnNextBar() {
        var arming = AlertArming()

        _ = arming.shouldFire(remainingSeconds: 60, barCloses: closeA, threshold: 15)
        XCTAssertTrue(arming.shouldFire(remainingSeconds: 10, barCloses: closeA, threshold: 15))

        _ = arming.shouldFire(remainingSeconds: 300, barCloses: closeB, threshold: 15)
        XCTAssertTrue(arming.shouldFire(remainingSeconds: 10, barCloses: closeB, threshold: 15))
    }

    /// 丢 tick（例如系统卡顿跳过了阈值那一秒）仍然会响。
    func testFiresEvenWhenThresholdSecondWasSkipped() {
        var arming = AlertArming()
        _ = arming.shouldFire(remainingSeconds: 120, barCloses: closeA, threshold: 15)
        // 直接从 120 跳到 4 —— 期间的 tick 都丢了
        XCTAssertTrue(arming.shouldFire(remainingSeconds: 4, barCloses: closeA, threshold: 15))
    }

    /// 睡眠唤醒后不该为错过的旧 K 线补响。
    func testDoesNotBackfillMissedBarAfterWake() {
        var arming = AlertArming()
        _ = arming.shouldFire(remainingSeconds: 200, barCloses: closeA, threshold: 15)

        // 睡了一觉，醒来已经在 closeB 那根的中段
        XCTAssertFalse(arming.shouldFire(remainingSeconds: 250, barCloses: closeB, threshold: 15),
            "醒来时不在阈值内，不该响")
        // closeB 走到阈值内才响，且只响一次
        XCTAssertTrue(arming.shouldFire(remainingSeconds: 12, barCloses: closeB, threshold: 15))
        XCTAssertFalse(arming.shouldFire(remainingSeconds: 11, barCloses: closeB, threshold: 15))
    }

    /// disarm 后必须重新观察一次阈值之外 —— 改完设置不该立刻响。
    func testDisarmRequiresReobservation() {
        var arming = AlertArming()
        _ = arming.shouldFire(remainingSeconds: 60, barCloses: closeA, threshold: 15)

        arming.disarm()
        XCTAssertFalse(arming.shouldFire(remainingSeconds: 10, barCloses: closeA, threshold: 15))

        _ = arming.shouldFire(remainingSeconds: 60, barCloses: closeA, threshold: 15)
        XCTAssertTrue(arming.shouldFire(remainingSeconds: 10, barCloses: closeA, threshold: 15))
    }

    /// 连续调用 300 次是幂等的（模拟 1Hz 轮询整根 5m K 线）。
    func testIdempotentAcrossFullBar() {
        var arming = AlertArming()
        var fires = 0
        for remaining in stride(from: 300, through: 1, by: -1) {
            if arming.shouldFire(remainingSeconds: remaining, barCloses: closeA, threshold: 15) {
                fires += 1
            }
        }
        XCTAssertEqual(fires, 1)
    }

    /// 阈值必须被如实遵守 —— 设 30 就在剩 30 秒时响，不是 15。
    ///
    /// 用户报过「改成 30 秒还是只在 15s 响」。真正的根因在设置层
    /// （换周期时阈值被重置，见 ThresholdClampTests），但这里把
    /// 「引擎侧按给定阈值触发」这条性质也钉住，排除回归。
    func testFiresExactlyAtTheGivenThreshold() {
        for threshold in [5, 15, 30, 60, 120] {
            var arming = AlertArming()
            var firedAt: Int?

            for remaining in stride(from: 300, through: 1, by: -1) {
                if arming.shouldFire(
                    remainingSeconds: remaining,
                    barCloses: closeA,
                    threshold: threshold
                ) {
                    XCTAssertNil(firedAt, "阈值 \(threshold) 触发了不止一次")
                    firedAt = remaining
                }
            }

            XCTAssertEqual(firedAt, threshold,
                           "阈值设为 \(threshold) 时应当恰好在剩 \(threshold) 秒触发")
        }
    }
}

final class CountdownPhaseTests: XCTestCase {

    func testPhaseBoundaries() {
        let t = CountdownThresholds(warning: 60, urgent: 15)

        XCTAssertEqual(CountdownPhase.of(remainingSeconds: 300, thresholds: t), .normal)
        XCTAssertEqual(CountdownPhase.of(remainingSeconds: 61, thresholds: t), .normal)
        XCTAssertEqual(CountdownPhase.of(remainingSeconds: 60, thresholds: t), .warning)
        XCTAssertEqual(CountdownPhase.of(remainingSeconds: 16, thresholds: t), .warning)
        XCTAssertEqual(CountdownPhase.of(remainingSeconds: 15, thresholds: t), .urgent)
        XCTAssertEqual(CountdownPhase.of(remainingSeconds: 1, thresholds: t), .urgent)
    }

    /// 推荐阈值必须满足 `0 < urgent < warning < period`。
    func testRecommendedThresholdsAreWellFormedForEveryPeriod() {
        for period in BarPeriod.allCases {
            let t = CountdownThresholds.recommended(for: period)
            XCTAssertGreaterThan(t.urgent, 0, "\(period.displayName)")
            XCTAssertGreaterThan(t.warning, t.urgent, "\(period.displayName)")
            XCTAssertLessThan(t.warning, period.seconds, "\(period.displayName) 的 warning 覆盖了整根 K 线")
        }
    }

    func testRecommendedThresholdsForCommonPeriods() {
        XCTAssertEqual(CountdownThresholds.recommended(for: .m5).warning, 60)
        XCTAssertEqual(CountdownThresholds.recommended(for: .m5).urgent, 15)
        // 1m：60/4 = 15 秒警告、60/10 = 6 秒紧急，不会盖掉整根
        XCTAssertEqual(CountdownThresholds.recommended(for: .m1).warning, 15)
        XCTAssertEqual(CountdownThresholds.recommended(for: .m1).urgent, 6)
    }
}
