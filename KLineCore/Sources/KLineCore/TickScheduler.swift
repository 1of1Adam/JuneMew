//
//  TickScheduler.swift
//  KLineCore
//

import Foundation

public protocol TickScheduler: AnyObject {
    func start(onTick: @escaping @Sendable (Date) -> Void)
    func stop()
    /// 立即触发一次，不等下一个秒边界。唤醒、恢复可见时用。
    func fireImmediately()
}

public enum TickTiming {

    /// 边界前的最小间隙。已经贴着整数秒时跳到下一秒，
    /// 避免同一个整数秒被计算两次（会看到数字停顿一拍）。
    public static let minimumLead: TimeInterval = 0.004
    /// 落在整数秒**之后**的偏移，确保 `floor()` 已经翻位。
    public static let overshoot: TimeInterval = 0.008

    /// 距下一个秒边界（略微过界）的延迟。抽成纯函数以便断言相位。
    public static func delayToNextBoundary(from now: TimeInterval) -> TimeInterval {
        var delta = 1.0 - now.truncatingRemainder(dividingBy: 1.0)
        if delta < minimumLead { delta += 1.0 }
        return delta + overshoot
    }
}

/// 对齐到秒边界的 1Hz 调度器。
///
/// 选 `DispatchSourceTimer` 而不是：
/// - `Timer.scheduledTimer`：依赖 runloop mode。这个 UI 就住在菜单栏区域，
///   用户点开任意菜单，`.default` mode 的 timer 会停摆，倒计时冻住。
/// - `TimelineView(.periodic)`：`context.date` 是「计划时刻」不是实际墙钟，
///   调度被合并时是陈旧值；且窗口不可见时会连声音提醒一起停掉。
/// - `CADisplayLink`：60–120Hz 驱动 1Hz 显示，纯浪费电。
public final class SecondAlignedTickScheduler: TickScheduler, @unchecked Sendable {

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var onTick: (@Sendable (Date) -> Void)?

    public init(label: String = "com.monuk7735.mew.notch.kline.tick") {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    deinit { timer?.cancel() }

    public func start(onTick: @escaping @Sendable (Date) -> Void) {
        queue.async { [self] in
            timer?.cancel()
            self.onTick = onTick

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                // 每次现取墙钟，绝不自减。系统时间被 NTP 调整时，
                // 下一 tick 自动归位，最多影响一帧。
                self.onTick?(Date())
                self.scheduleNext(on: t)
            }
            self.timer = t
            self.scheduleNext(on: t)
            t.resume()
        }
    }

    private func scheduleNext(on t: DispatchSourceTimer) {
        let delay = TickTiming.delayToNextBoundary(from: Date().timeIntervalSince1970)
        // 必须用 deadline:（单调）而非 wallDeadline:。后者在墙钟前跳时会立刻
        // 连续触发、后跳时会挂住整个跳变时长；配合「每 tick 重新计算 delta」
        // 才能做到阶跃只影响一帧。
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(20))
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    public func fireImmediately() {
        queue.async { [self] in
            onTick?(Date())
        }
    }
}

/// 测试替身：由测试代码显式驱动。
public final class ManualTickScheduler: TickScheduler, @unchecked Sendable {

    private var onTick: (@Sendable (Date) -> Void)?
    public private(set) var isRunning = false
    public private(set) var immediateFireCount = 0

    public init() {}

    public func start(onTick: @escaping @Sendable (Date) -> Void) {
        self.onTick = onTick
        isRunning = true
    }

    public func stop() {
        isRunning = false
    }

    public func fireImmediately() {
        immediateFireCount += 1
        onTick?(Date())
    }

    /// 以指定时刻驱动一次 tick。
    public func tick(at instant: Date) {
        onTick?(instant)
    }
}
