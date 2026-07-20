//
//  ClockIntegrity.swift
//  KLineCore
//

import Foundation

/// 系统时钟的可信状态。
public enum ClockTrust: Equatable, Sendable {
    /// 已成功校准。`offset` 为正表示本机快于参考时间。
    case verified(offset: TimeInterval, uncertainty: TimeInterval, at: Date)
    /// 从未成功校准（网络不通、端点互相矛盾等）。
    case unverified(since: Date, lastError: String)
    /// 探测到墙钟阶跃，重新校准前一律不可信。
    case jumped(delta: TimeInterval, at: Date)
}

/// 由可信状态推出的显示决策。
public enum ClockVerdict: Equatable, Sendable {
    case trusted
    /// 显示数字 + 琥珀点。
    case degraded(offset: TimeInterval)
    /// **拒绝显示数字**，只画红色告警。
    case untrusted(offset: TimeInterval)
    /// 显示数字 + 灰点；长时间未校准会升级。
    case unverifiedButUsable(staleness: TimeInterval)
}

public enum ClockPolicy {

    /// 软阈值：超过就加可见标记，但仍显示数字。
    public static let softThreshold: TimeInterval = 1.5
    /// 硬阈值：超过就拒绝显示数字。
    public static let hardThreshold: TimeInterval = 5.0
    /// 单调钟与墙钟的偏差超过这个值即判定为阶跃。
    public static let jumpThreshold: TimeInterval = 0.5

    /// 纯函数，便于表驱动测试。
    ///
    /// 三条刻意的决策：
    /// 1. **绝不用测得的偏差去悄悄修正倒计时。** 那等于把坏时钟藏起来，
    ///    而且 app 内其他时间（声音调度）会和显示值不自洽。测量、暴露、不修正。
    /// 2. **超过硬阈值就完全不显示数字。** 见 `Fault` 的说明。
    /// 3. **校准失败 ≠ 校准通过。** `.unverified` 是独立状态，永远带可见标记，
    ///    绝不静默降级成 `.trusted`。
    public static func verdict(
        for trust: ClockTrust,
        now: Date,
        soft: TimeInterval = softThreshold,
        hard: TimeInterval = hardThreshold
    ) -> ClockVerdict {
        switch trust {
        case let .verified(offset, _, _):
            let magnitude = abs(offset)
            if magnitude > hard { return .untrusted(offset: offset) }
            if magnitude > soft { return .degraded(offset: offset) }
            return .trusted

        case let .jumped(delta, _):
            // 阶跃后在重新校准之前一律不可信，与幅度无关
            return .untrusted(offset: delta)

        case let .unverified(since, _):
            return .unverifiedButUsable(staleness: now.timeIntervalSince(since))
        }
    }
}

/// 单调钟哨兵。
///
/// **必须用 `ContinuousClock`（睡眠期间继续走），不能用 `SuspendingClock` 或
/// `mach_absolute_time()`（睡眠期间停走）。** 后者与墙钟对比时，每次从睡眠唤醒
/// 都会误报一次「时钟跳变」—— 睡了 8 小时就报 8 小时的假阶跃。
///
/// 另外要清楚这个哨兵**探测的是变化，不是静态偏差**。一台从开机起就慢 45 秒、
/// 且永不同步的机器，两个时钟走速一致，哨兵永远不会报警。所以它只是网络校准的
/// 补充，不能替代。
public struct MonotonicSentinel: Sendable {

    private var anchorWall: Date
    private var anchorMono: ContinuousClock.Instant

    public init(wall: Date = Date(), mono: ContinuousClock.Instant = ContinuousClock.now) {
        self.anchorWall = wall
        self.anchorMono = mono
    }

    /// 自上次锚定以来，墙钟相对单调钟的额外位移。
    /// 绝对值大说明墙钟被阶跃调整过（NTP 纠正、用户改表）。
    public func drift(wall: Date = Date(), mono: ContinuousClock.Instant = ContinuousClock.now) -> TimeInterval {
        let wallElapsed = wall.timeIntervalSince(anchorWall)
        let monoElapsed = TimeInterval(mono - anchorMono) / 1.0
        return wallElapsed - monoElapsed
    }

    /// 重新锚定。睡眠唤醒后必须调用 —— 睡眠期间两个时钟的差异不构成阶跃证据。
    public mutating func reanchor(wall: Date = Date(), mono: ContinuousClock.Instant = ContinuousClock.now) {
        anchorWall = wall
        anchorMono = mono
    }
}

private extension TimeInterval {
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self = Double(seconds) + Double(attoseconds) * 1e-18
    }
}

/// 从 HTTPS 响应头的 `Date` 字段估计时钟偏差。
public struct HTTPDateProbe: Sendable {

    public struct Sample: Equatable, Sendable {
        /// 正值表示本机时钟快于服务器。
        public let offset: TimeInterval
        public let uncertainty: TimeInterval
        public let roundTrip: TimeInterval
    }

    public enum ProbeError: Error, Equatable {
        case notHTTP
        case missingDateHeader
        case unparsableDate(String)
        case badStatus(Int)
    }

    /// **必须是 `en_US_POSIX`。** 用户 locale 设成中文时，默认 formatter
    /// 解析不了 `"Mon, 20 Jul 2026 12:00:00 GMT"` 这种 IMF-fixdate。
    /// 这类 bug 只在部分用户机器上出现，极难复现。
    public static let imfFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// 由一次请求的三个观测量算出偏差估计。抽成纯函数以便测试。
    ///
    /// `Date` 头只有秒级精度（RFC 9110 IMF-fixdate），真实服务器时间落在
    /// `[header, header+1)`，所以取中点 `header + 0.5` 作为估计，
    /// 并把 0.5 秒的量化误差计入不确定度。
    public static func sample(
        requestSentAt localBefore: Date,
        roundTrip: TimeInterval,
        serverHeaderDate: Date
    ) -> Sample {
        let localAtMidpoint = localBefore.addingTimeInterval(roundTrip / 2)
        let serverEstimate = serverHeaderDate.addingTimeInterval(0.5)
        return Sample(
            offset: localAtMidpoint.timeIntervalSince(serverEstimate),
            uncertainty: 0.5 + roundTrip / 2,
            roundTrip: roundTrip
        )
    }

    /// 合并多个端点的样本。
    ///
    /// 端点之间互相矛盾时返回 nil（判 `.unverified`）而**不是取平均** ——
    /// 平均一个正确值和一个错误值会得到第三个错误值，且看起来很合理。
    public static func reconcile(
        _ samples: [Sample],
        maximumDisagreement: TimeInterval = 1.0
    ) -> Sample? {
        guard !samples.isEmpty else { return nil }
        guard samples.count > 1 else { return samples[0] }

        let offsets = samples.map(\.offset)
        guard let lo = offsets.min(), let hi = offsets.max(), hi - lo <= maximumDisagreement else {
            return nil
        }
        // 取 RTT 最小的样本 —— 网络抖动最小，估计最准
        return samples.min { $0.roundTrip < $1.roundTrip }
    }
}
