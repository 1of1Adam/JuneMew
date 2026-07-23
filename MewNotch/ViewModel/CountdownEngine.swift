//
//  CountdownEngine.swift
//  MewNotch
//

import AppKit
import Combine
import OSLog
import SwiftUI
import KLineCore

/// 悬停展开仪表盘的每秒快照。
///
/// 由 engine 在主评估循环里顺带算出，面板只做渲染 ——
/// K 线边界的真理来源必须唯一（`BarClock`），面板自己跑一套计算
/// 就会出现「主倒计时和矩阵差一秒」这类无法解释的错位。
struct DashboardModel: Equatable {

    struct PeriodEntry: Equatable, Identifiable {
        let period: BarPeriod
        let remainingText: String
        var id: Int { period.rawValue }
    }

    /// 全部可选周期的剩余时间，顺序同 `BarPeriod.userSelectable`。
    let entries: [PeriodEntry]

    /// 距时段收盘，已格式化（`H:MM:SS`）。
    let sessionRemainingText: String
}

/// 倒计时引擎。
///
/// **必须是单例。** `NotchManager.refreshNotches()` 为每块屏各建一个 `NotchView`，
/// 若写成 `@StateObject` 就会变成 N 个 timer 和 **N 次响铃** ——
/// 双屏用户每根 K 线会听到两声。
@MainActor
final class CountdownEngine: ObservableObject {

    static let shared = CountdownEngine()

    @Published private(set) var presentation: CountdownPresentation = .dormant(.featureDisabled)

    /// 仅在 `.counting` 时非空。与 `presentation` 在同一个 tick 里更新，
    /// 所以面板矩阵和主倒计时永远显示同一瞬间的值。
    @Published private(set) var dashboard: DashboardModel?

    /// 供设置页 Diagnostics 显示。
    @Published private(set) var clockTrust: ClockTrust = .unverified(since: Date(), lastError: "starting up")
    @Published private(set) var todaySessionDescription: String = "—"

    private let logger = Logger(subsystem: "io.github.1of1adam.JuneMew", category: "countdown")

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
        // 仪表盘快照只在走到正常路径时被填充；任何提前 return（故障、休市、
        // 功能关闭）都让它保持 nil。用 defer 统一提交，杜绝「某条分支忘了清空、
        // 面板展示昨天的矩阵」这类腐烂数据。
        var nextDashboard: DashboardModel? = nil
        defer {
            if dashboard != nextDashboard { dashboard = nextDashboard }
        }

        guard defaults.isEnabled else {
            standDown()
            return publish(.dormant(.featureDisabled))
        }

        // 1) 日历本身不可用 —— 最高优先级的故障
        guard let calendar else {
            return publish(.fault(.holidayTableUnreadable(calendarLoadFailure ?? "unknown")))
        }

        // 2) 时钟可信度是前置闸门：不可信就不算，更不显示
        let verdict = ClockPolicy.verdict(for: clockTrust, now: instant)
        if case let .untrusted(offset) = verdict {
            standDown()
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
            standDown()
            return publish(.fault(.holidayTableExpired(daysStale: staleDays)))
        }

        // 4) 正常路径。任何 throw 都变成 fault，不吞
        do {
            guard let session = try calendar.session(containing: instant) else {
                standDown()
                let nextOpen = try? calendar.nextOpen(after: instant)
                updateDiagnostics(session: nil, at: instant, calendar: calendar)
                return publish(.dormant(.marketClosed(nextOpen: nextOpen)))
            }

            let bar = try BarClock.bar(at: instant, period: defaults.period, session: session)
            let thresholds = defaults.thresholds
            let phase = CountdownPhase.of(remainingSeconds: bar.remainingSeconds, thresholds: thresholds)

            if defaults.soundEnabled {
                if arming.shouldFire(
                    remainingSeconds: bar.remainingSeconds,
                    barCloses: bar.closes,
                    threshold: defaults.soundThreshold
                ) {
                    CandleAlertPlayer.shared.play(
                        named: defaults.soundName,
                        repeating: defaults.alertMode == .untilDismissed
                    )
                }
            } else {
                // 播放中途关掉开关，必须立刻停 —— 一个关不掉的循环音是灾难
                CandleAlertPlayer.shared.dismiss()
            }

            updateDiagnostics(session: session, at: instant, calendar: calendar)

            nextDashboard = DashboardModel(
                entries: try BarPeriod.userSelectable.map { p in
                    DashboardModel.PeriodEntry(
                        period: p,
                        remainingText: BarClock.format(
                            remainingSeconds: try BarClock.bar(
                                at: instant, period: p, session: session
                            ).remainingSeconds
                        )
                    )
                },
                sessionRemainingText: BarClock.format(
                    remainingSeconds: max(1, Int(
                        session.closes.timeIntervalSince(instant).rounded(.up)
                    ))
                )
            )

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
            standDown()
            publish(.fault(.calendarInconsistent(String(describing: error))))
        }
    }

    /// 离开正常计时状态：解除提醒武装，并停止任何持续响铃。
    ///
    /// 持续响铃模式下「停不下来」是最严重的失败模式 —— 休市了还在响、
    /// 功能关了还在响、时钟出错了还在响，用户会以为 app 坏了而且找不到出口。
    /// 所以每一条离开正常计时的分支都必须经过这里，而不是只 disarm。
    private func standDown() {
        arming.disarm()
        CandleAlertPlayer.shared.dismiss()
    }

    /// 刘海展开/收起的动画曲线。
    ///
    /// dampingFraction 取 0.9 而非默认值：这是盯盘工具，刘海在视野边缘弹跳
    /// 会分散注意力，要的是「顺滑地收进去」而不是「弹一下」。
    private static let visibilityAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.9)

    private func publish(_ next: CountdownPresentation) {
        guard next != presentation else { return }

        if case let .fault(fault) = next, fault != lastLoggedFault {
            logger.error("倒计时进入故障态：\(String(describing: fault), privacy: .public)")
            lastLoggedFault = fault
        }
        if case .counting = next { lastLoggedFault = nil }

        // 只有跨形态切换才会增删槽位、改变刘海宽度，这时才需要动画事务。
        // 同一形态内部（倒计时每秒递减）不能包 withAnimation，否则每秒
        // 都会重播一次展开动画。
        //
        // 必须用 withAnimation 而不是在视图上写 .animation(_:value:)：
        // 后者只覆盖该视图自身的可动画属性，管不到槽位增删引起的父容器
        // 布局重算，实测宽度仍然是瞬间跳变。withAnimation 建立的是覆盖
        // 整个更新周期（含布局）的事务。
        if next.kind != presentation.kind {
            withAnimation(Self.visibilityAnimation) {
                presentation = next
            }
        } else {
            presentation = next
        }
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
