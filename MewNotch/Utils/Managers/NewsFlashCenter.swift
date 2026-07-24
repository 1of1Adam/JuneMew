//
//  NewsFlashCenter.swift
//  MewNotch
//

import AppKit
import SwiftUI
import Combine
import OSLog
import KLineCore

/// 红色快讯的灵动岛推送中枢。
///
/// FinancialJuice 的红色级别快讯（important，含 breaking/critical）实时到达时，
/// 让黑色形体从刘海向下生长出一条通知横幅：停留数秒、悬停暂停、点击开原文、
/// 到点自动收回。普通灰条永不打扰 —— 打断注意力的资格只属于会动价的新闻。
///
/// # 与其余刘海身份的互斥
///
/// 刘海同一时刻只能有一个身份，优先级从高到低：
/// 1. **响铃**（刘海是一整块停止按钮）—— 铃响瞬间弹幅让位、条目回队头，
///    铃停后未过期则补弹；
/// 2. **仪表盘展开**（用户主动索取信息，快讯区就在面板里）—— 展开瞬间
///    弹幅收回、队列清空，不做「收起面板后补播旧闻」；
/// 3. **红色快讯弹幅**（本类）；
/// 4. 折叠态倒计时。
///
/// # 启动免疫
///
/// NewsStore 首次发布（磁盘缓存或首拉）会一次涌入几十条历史 —— 全部记为
/// 基线、一条不弹。此后只有**基线之外新出现**且发布 ≤15 分钟的红色条目
/// 才有弹出资格：重启 app 不会把早上的旧闻再放一遍。
///
/// # 翻译异步
///
/// 推送到达时是英文，DeepSeek 译文晚几秒 —— 弹幅先出英文，译文到位后
/// 原位淡换中文，不重置停留计时。
@MainActor
final class NewsFlashCenter: ObservableObject {

    static let shared = NewsFlashCenter()

    struct Flash: Equatable, Identifiable {
        let id: Int
        var title: String
        var isTranslated: Bool
        let published: Date
        /// critical 级别（Level 含 "critical"）：脉冲点与标签加强辉光。
        let critical: Bool
        let url: String
        /// 设置页「预览效果」注入的演示条目：不受总开关清场影响。
        var isDemo: Bool = false
    }

    /// 当前弹幅。nil = 无。变化永远发生在 withAnimation 事务里 ——
    /// 弹幅增删引起的是父容器布局重算，视图上的 .animation(_:value:)
    /// 覆盖不到（与 CountdownEngine.publish 同一条经验）。
    @Published private(set) var current: Flash?

    private let logger = Logger(subsystem: "io.github.1of1adam.JuneMew", category: "news-flash")
    private let defaults = CountdownDefaults.shared

    private var cancellables = Set<AnyCancellable>()

    /// 基线是否已记录（NewsStore 首个非空发布）。
    private var baselineTaken = false
    /// 已见过的条目 id —— 见过 ≠ 弹过；基线条目、灰条也都算见过。
    private var seenIds = Set<Int>()
    private var queue: [Flash] = []

    /// 停留计时。悬停时挂起、离开时按剩余时间续走。
    private var dismissTimer: Timer?
    private var stayDeadline: Date?
    private var hovering = false

    /// 有几块屏的仪表盘处于展开态（每块屏一个 NotchView 实例）。
    private var expandedPanelCount = 0
    private var alerting = false

    /// 新到达的红色快讯超过这个年龄就没有弹出资格 ——
    /// 断线重连补拉的旧条目不该在半小时后突然弹出来吓人。
    private static let freshWindow: TimeInterval = 15 * 60
    /// 悬停结束后至少再留这么久，光标挪开的瞬间不该「啪」地消失。
    private static let hoverGrace: TimeInterval = 1.5
    /// 收回与下一条弹出之间的间隙：形体要先完整落回折叠态，
    /// 连续变形会读成抽搐。
    private static let interFlashGap: TimeInterval = 0.45

    /// 入场：与仪表盘展开同款 duang（ζ=0.65 过冲 ≈7%）——
    /// 快讯到达是全天最值得一次弹性的时刻。
    static let popAnimation: Animation = .spring(response: 0.45, dampingFraction: 0.65)
    /// 收回：干脆利落，不弹。
    static let collapseAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.95)

    /// 系统「减弱动态效果」时全部退化为短淡入淡出。
    /// center 不在视图层级里拿不到 @Environment，走 AppKit 的等价通道。
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var popTransaction: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : Self.popAnimation
    }

    private var collapseTransaction: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : Self.collapseAnimation
    }

    private init() {
        NewsStore.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                self?.ingest(items)
            }
            .store(in: &cancellables)

        // 响铃 = 刘海的最高优先级身份。铃响弹幅立即让位（条目回队头），
        // 铃停后走同一条 tryPresent 路径补弹，过期检查在那里统一做。
        CandleAlertPlayer.shared.$isAlerting
            .receive(on: RunLoop.main)
            .sink { [weak self] alerting in
                guard let self, alerting != self.alerting else { return }
                self.alerting = alerting
                if alerting {
                    self.yieldCurrentToQueue()
                } else {
                    self.scheduleNextPresentation(after: Self.interFlashGap)
                }
            }
            .store(in: &cancellables)

        // 总开关关闭 → 清场（演示条目除外：预览按钮就是给关着的人看效果的）。
        defaults.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.defaults.newsFlashEnabled else { return }
                self.queue.removeAll { !$0.isDemo }
                if let current = self.current, !current.isDemo {
                    self.dismissCurrent()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 新闻流入

    private func ingest(_ items: [NewsStore.DisplayItem]) {
        guard !items.isEmpty else { return }

        // 首个非空发布 = 历史基线，一条不弹。
        guard baselineTaken else {
            baselineTaken = true
            seenIds.formUnion(items.map(\.id))
            logger.info("红色快讯：基线 \(items.count) 条已免疫")
            return
        }

        // 译文到位：正在展示/排队的条目原位换标题，不重置计时。
        refreshTitles(from: items)

        let fresh = items.filter { !seenIds.contains($0.id) }
        guard !fresh.isEmpty else { return }
        seenIds.formUnion(fresh.map(\.id))

        guard defaults.newsFlashEnabled else { return }

        let candidates = fresh.filter {
            $0.important && Date().timeIntervalSince($0.published) <= Self.freshWindow
        }
        guard !candidates.isEmpty else { return }

        // 同批多条按时间旧→新入队，弹出顺序与发生顺序一致。
        for item in candidates.sorted(by: { $0.published < $1.published }) {
            queue.append(Flash(
                id: item.id,
                title: item.title,
                isTranslated: item.isTranslated,
                published: item.published,
                critical: item.critical,
                url: item.url
            ))
        }
        logger.info("红色快讯：+\(candidates.count) 条入队（队列 \(self.queue.count)）")
        tryPresent()
    }

    private func refreshTitles(from items: [NewsStore.DisplayItem]) {
        if var current, let updated = items.first(where: { $0.id == current.id }),
           updated.title != current.title {
            current.title = updated.title
            current.isTranslated = updated.isTranslated
            // 只换文字不动形体 —— 视图端的 contentTransition 负责淡换。
            self.current = current
        }
        for index in queue.indices {
            if let updated = items.first(where: { $0.id == queue[index].id }) {
                queue[index].title = updated.title
                queue[index].isTranslated = updated.isTranslated
            }
        }
    }

    // MARK: - 展示调度

    private func tryPresent() {
        guard current == nil, !alerting, expandedPanelCount == 0 else { return }

        // 队头过期丢弃（响铃/断线期间攒下的旧条目）。演示条目不过期。
        while let head = queue.first,
              !head.isDemo,
              Date().timeIntervalSince(head.published) > Self.freshWindow {
            queue.removeFirst()
        }
        guard !queue.isEmpty else { return }

        let flash = queue.removeFirst()
        withAnimation(popTransaction) {
            current = flash
        }
        scheduleDismiss(after: stayDuration(for: flash))
        logger.info("红色快讯：弹出 #\(flash.id)（停留 \(String(format: "%.1f", self.stayDuration(for: flash))) 秒）")
    }

    /// 停留时长按标题长度自适应：两行中文约 40 字读完 ≈6 秒，
    /// 加上「抬眼注意到弹幅」的反应时间。6–12 秒封顶 ——
    /// 更长的横幅是打扰，真想细读的人会悬停或点开原文。
    private func stayDuration(for flash: Flash) -> TimeInterval {
        min(12, max(6, 4.5 + Double(flash.title.count) * 0.13))
    }

    private func scheduleDismiss(after interval: TimeInterval) {
        dismissTimer?.invalidate()
        stayDeadline = Date().addingTimeInterval(interval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.hovering else { return }
                self.dismissCurrent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    /// 收回当前弹幅并在间隙后尝试下一条。
    func dismissCurrent() {
        guard current != nil else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        stayDeadline = nil
        withAnimation(collapseTransaction) {
            current = nil
        }
        scheduleNextPresentation(after: Self.interFlashGap)
    }

    /// 弹幅让位（响铃）：条目塞回队头，资格保留 —— 铃停后
    /// tryPresent 的过期检查决定它还配不配弹。
    private func yieldCurrentToQueue() {
        guard let flash = current else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        stayDeadline = nil
        queue.insert(flash, at: 0)
        withAnimation(collapseTransaction) {
            current = nil
        }
    }

    private func scheduleNextPresentation(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tryPresent() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - 视图回调

    /// 悬停 = 用户在读，停留计时挂起；离开后按剩余时间续走
    /// （至少 hoverGrace，光标挪开的瞬间不该「啪」地消失）。
    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        if value {
            dismissTimer?.invalidate()
            dismissTimer = nil
        } else if current != nil {
            let remaining = max(Self.hoverGrace, stayDeadline?.timeIntervalSinceNow ?? 0)
            scheduleDismiss(after: remaining)
        }
    }

    /// 任意一块屏的仪表盘展开/收起。展开时弹幅收回、真实队列清空 ——
    /// 快讯区就在面板里，收起面板后再补播旧闻是二次打扰。
    func setPanelExpanded(_ expanded: Bool) {
        expandedPanelCount = max(0, expandedPanelCount + (expanded ? 1 : -1))
        if expanded {
            queue.removeAll { !$0.isDemo }
            if current != nil {
                dismissTimer?.invalidate()
                dismissTimer = nil
                stayDeadline = nil
                // 展开屏上弹幅分支已被面板替换（同一 spring 事务），
                // 这里的 collapse 事务服务的是其余屏幕的正常收回。
                withAnimation(collapseTransaction) {
                    current = nil
                }
            }
        } else if expandedPanelCount == 0 {
            scheduleNextPresentation(after: Self.interFlashGap)
        }
    }

    // MARK: - 演示

    /// 设置页「预览效果」/ `--news-flash-demo` 启动参数：注入三条演示
    /// 快讯走完整展示链路 —— 中文两行、critical 强辉光、英文未译形态。
    func enqueueDemo() {
        let now = Date()
        queue.append(contentsOf: [
            Flash(
                id: -1,
                title: "美联储宣布紧急降息 50 个基点，鲍威尔：将不惜一切代价稳定市场流动性",
                isTranslated: true,
                published: now,
                critical: false,
                url: "",
                isDemo: true
            ),
            Flash(
                id: -2,
                title: "据路透：白宫确认对所有进口半导体启动 232 调查，最高或征 100% 关税",
                isTranslated: true,
                published: now.addingTimeInterval(-45),
                critical: true,
                url: "",
                isDemo: true
            ),
            Flash(
                id: -3,
                title: "BREAKING: US CPI YoY 2.4% vs 3.1% expected — largest downside miss since 2020",
                isTranslated: false,
                published: now.addingTimeInterval(-150),
                critical: false,
                url: "",
                isDemo: true
            ),
        ])
        tryPresent()
    }
}
