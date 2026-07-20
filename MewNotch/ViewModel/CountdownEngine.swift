//
//  CountdownEngine.swift
//  MewNotch
//

import AppKit
import Combine
import OSLog
import KLineCore

/// 倒计时引擎。
///
/// **必须是单例。** `NotchManager.refreshNotches()` 为每块屏各建一个 `NotchView`，
/// 若写成 `@StateObject` 就会变成 N 个 timer 和 **N 次响铃** ——
/// 双屏用户每根 K 线会听到两声。
@MainActor
final class CountdownEngine: ObservableObject {

    static let shared = CountdownEngine()

    @Published private(set) var presentation: CountdownPresentation = .dormant(.featureDisabled)

    /// 供设置页 Diagnostics 显示。
    @Published private(set) var clockTrust: ClockTrust = .unverified(since: Date(), lastError: "starting up")
    @Published private(set) var todaySessionDescription: String = "—"

    private let logger = Logger(subsystem: "com.monuk7735.mew.notch", category: "countdown")

    private let defaults = CountdownDefaults.shared
    private let scheduler: TickScheduler = SecondAlignedTickScheduler()

    /// 日历构造失败（假期表损坏/缺失）时保留错误，每个 tick 都发布为 fault。
    private let calendar: CMEEquityIndexCalendar?
    private let calendarLoadFailure: String?

    private var arming = AlertArming()
    private var cancellables = Set<AnyCancellable>()
    private var lastLoggedFault: Fault?

    /// 假期表过期后的宽限天数。过期日子里 95% 仍是普通交易日，
    /// 立刻变砖是纯损失；但告警会随时间升级，最终无法被忽略。
    private let expiryGraceDays = 60

    private init() {
        var loaded: CMEEquityIndexCalendar?
        var failure: String?
        do {
            loaded = try CMEEquityIndexCalendar(holidays: try HolidayTable.bundled())
        } catch {
            // 不 fallback 到空表 —— 空表会把每一天都当成普通交易日
            failure = String(describing: error)
        }
        self.calendar = loaded
        self.calendarLoadFailure = failure

        if let failure {
            logger.fault("假期表加载失败，倒计时将拒绝显示数字：\(failure, privacy: .public)")
        }

        observeSettings()
        observeSystemEvents()
    }

    func start() {
        scheduler.start { [weak self] instant in
            Task { @MainActor in self?.evaluate(at: instant) }
        }
        Task {
            if defaults.clockCalibrationEnabled {
                await ClockCalibrator.shared.calibrate()
            }
            await refreshClockTrust()
        }
        startPeriodicCalibration()
    }

    // MARK: - 主评估循环

    private func evaluate(at instant: Date) {
        guard defaults.isEnabled else {
            arming.disarm()
            return publish(.dormant(.featureDisabled))
        }

        // 1) 日历本身不可用 —— 最高优先级的故障
        guard let calendar else {
            return publish(.fault(.holidayTableUnreadable(calendarLoadFailure ?? "unknown")))
        }

        // 2) 时钟可信度是前置闸门：不可信就不算，更不显示
        let verdict = ClockPolicy.verdict(for: clockTrust, now: instant)
        if case let .untrusted(offset) = verdict {
            arming.disarm()
            if case .jumped = clockTrust {
                return publish(.fault(.clockJumped(delta: offset)))
            }
            return publish(.fault(.clockOffsetExceedsTolerance(
                offset: offset, threshold: ClockPolicy.hardThreshold
            )))
        }

        // 3) 假期表有效期检查，发生在查询**之前**
        let staleDays = daysStale(at: instant, calendar: calendar)
        if staleDays > expiryGraceDays {
            arming.disarm()
            return publish(.fault(.holidayTableExpired(daysStale: staleDays)))
        }

        // 4) 正常路径。任何 throw 都变成 fault，不吞
        do {
            guard let session = try calendar.session(containing: instant) else {
                arming.disarm()
                let nextOpen = try? calendar.nextOpen(after: instant)
                updateDiagnostics(session: nil, at: instant, calendar: calendar)
                return publish(.dormant(.marketClosed(nextOpen: nextOpen)))
            }

            let bar = try BarClock.bar(at: instant, period: defaults.period, session: session)
            let thresholds = defaults.thresholds
            let phase = CountdownPhase.of(remainingSeconds: bar.remainingSeconds, thresholds: thresholds)

            if defaults.soundEnabled,
               arming.shouldFire(
                   remainingSeconds: bar.remainingSeconds,
                   barCloses: bar.closes,
                   threshold: defaults.soundThreshold
               ) {
                CandleAlertPlayer.shared.play(named: defaults.soundName)
            }

            updateDiagnostics(session: session, at: instant, calendar: calendar)

            publish(.counting(Countdown(
                text: displayText(for: bar),
                widthTemplate: widthTemplate(),
                remainingSeconds: bar.remainingSeconds,
                barOpens: bar.opens,
                barCloses: bar.closes,
                isTruncatedByClose: bar.isTruncated,
                phase: phase,
                concerns: concerns(verdict: verdict, staleDays: staleDays, calendar: calendar)
            )))
        } catch {
            arming.disarm()
            publish(.fault(.calendarInconsistent(String(describing: error))))
        }
    }

    private func publish(_ next: CountdownPresentation) {
        guard next != presentation else { return }

        if case let .fault(fault) = next, fault != lastLoggedFault {
            logger.error("倒计时进入故障态：\(String(describing: fault), privacy: .public)")
            lastLoggedFault = fault
        }
        if case .counting = next { lastLoggedFault = nil }

        presentation = next
    }

    // MARK: - 显示文本

    private func displayText(for bar: Bar) -> String {
        let time = BarClock.format(remainingSeconds: bar.remainingSeconds)
        return defaults.showPeriodLabel ? "\(defaults.period.displayName) \(time)" : time
    }

    private func widthTemplate() -> String {
        let base = BarClock.widthTemplate(for: defaults.period)
        return defaults.showPeriodLabel ? "\(defaults.period.displayName) \(base)" : base
    }

    // MARK: - 关切项

    private func concerns(
        verdict: ClockVerdict,
        staleDays: Int,
        calendar: CMEEquityIndexCalendar
    ) -> [Concern] {
        var result: [Concern] = []

        switch verdict {
        case .trusted:
            break
        case let .degraded(offset):
            result.append(.clockDrift(seconds: offset))
        case let .unverifiedButUsable(staleness):
            result.append(.clockUnverified(staleness: staleness))
        case .untrusted:
            break // 已在上游转成 fault
        }

        if staleDays > 0 {
            result.append(.holidayTableStale(daysStale: staleDays))
        } else if staleDays > -30 {
            result.append(.holidayTableExpiringSoon(daysLeft: -staleDays))
        }

        if calendar.verificationStatus == .unverifiedDraft {
            result.append(.holidayTableUnverified)
        }

        return result
    }

    /// 距假期表有效期结束的天数。正数表示已过期。
    private func daysStale(at instant: Date, calendar: CMEEquityIndexCalendar) -> Int {
        let end = calendar.verifiedCoverage.end
        return Int(instant.timeIntervalSince(end) / 86_400)
    }

    private func updateDiagnostics(
        session: TradingSession?,
        at instant: Date,
        calendar: CMEEquityIndexCalendar
    ) {
        let description: String
        if let session {
            switch session.closeKind {
            case .regular:
                description = "Regular session, closes 17:00 ET"
            case .early:
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "America/New_York")
                f.dateFormat = "HH:mm"
                description = "Early close at \(f.string(from: session.closes)) ET"
            case .weekEnd:
                description = "Final session of the week, closes 17:00 ET Friday"
            }
        } else if let nextOpen = try? calendar.nextOpen(after: instant) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "America/New_York")
            f.dateFormat = "EEE HH:mm"
            description = "Closed — reopens \(f.string(from: nextOpen)) ET"
        } else {
            description = "Closed"
        }

        if description != todaySessionDescription {
            todaySessionDescription = description
        }
    }

    // MARK: - 时钟

    private func refreshClockTrust() async {
        clockTrust = await ClockCalibrator.shared.currentTrust()
    }

    private func startPeriodicCalibration() {
        Timer.publish(every: 1800, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    if self.defaults.clockCalibrationEnabled {
                        await ClockCalibrator.shared.calibrate()
                    }
                    await self.refreshClockTrust()
                }
            }
            .store(in: &cancellables)

        // 阶跃哨兵跑在低频轮询上，不占用 1Hz 主循环
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                Task { await ClockCalibrator.shared.checkForJump() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 观察

    private func observeSettings() {
        defaults.objectWillChange
            .sink { [weak self] _ in
                // 改设置后重新武装，避免调完阈值立刻响一声
                self?.arming.disarm()
                self?.scheduler.fireImmediately()
            }
            .store(in: &cancellables)
    }

    private func observeSystemEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await ClockCalibrator.shared.handleWake()
                await self.refreshClockTrust()
                // 立即重算，不等下一秒 —— 否则会看到一帧陈旧值
                self.scheduler.fireImmediately()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await ClockCalibrator.shared.handleSystemClockChange()
                await self.refreshClockTrust()
                self.scheduler.fireImmediately()
            }
        }

        // 锁屏时静音，解锁后恢复
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.arming.disarm() }
        }
    }
}
