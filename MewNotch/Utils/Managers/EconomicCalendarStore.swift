//
//  EconomicCalendarStore.swift
//  MewNotch
//

import Foundation
import Combine
import OSLog
import KLineCore

/// 经济日历数据源。
///
/// 拉 TradingView 的 economic-calendar feed（无需账号；上游只认
/// Origin/Referer 是否指向 tradingview.com，原生 URLSession 可以直接带上）。
/// KLineCore 负责解码与纯计算，这里只做三件脏活：网络、磁盘缓存、刷新调度。
///
/// 刷新节奏：
/// - 常规每 20 分钟一轮（预测值会被修订，actual 会陆续出现）
/// - 事件发布后 75 秒补拉一次 —— CPI 08:30 发布，08:31:15 面板里就该有 actual
/// - 面板展开时数据超过 5 分钟没刷就顺手刷一次
///
/// 失败保留上次成功数据并记下错误 —— 日历的时刻表是预排的，断网不会让
/// 「CPI 在 08:30 发布」变错；但陈旧要如实标注，绝不装作刚刷新过。
@MainActor
final class EconomicCalendarStore: ObservableObject {

    static let shared = EconomicCalendarStore()

    struct Feed: Equatable, Codable {
        let events: [EconomicEvent]
        let fetchedAt: Date
    }

    @Published private(set) var feed: Feed?
    /// 最近一次刷新失败的原因；成功后清空。feed 与它可同时非空（旧数据 + 新错误）。
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    /// 指标英文标题 → 中文标准译名（"Initial Jobless Claims" → "初请失业金人数"）。
    /// 按标题字符串缓存并持久化：同一指标每周新事件 id 但标题不变，
    /// 首轮翻完后新增极少，几乎不再产生 API 调用。
    @Published private(set) var titleTranslations: [String: String] = [:]

    private let logger = Logger(subsystem: "io.github.1of1adam.JuneMew", category: "calendar")
    private let defaults = CountdownDefaults.shared

    private var periodicTimer: Timer?
    private var releaseTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    /// 请求过但失败的标题，会话内不重试（下次启动重试）。
    private var failedTitles: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    private static let upstream = "https://economic-calendar.tradingview.com/events"
    private static let periodicInterval: TimeInterval = 20 * 60
    private static let staleThreshold: TimeInterval = 5 * 60
    /// 发布后多久补拉。数据商通常在 1 分钟内挂出 actual。
    private static let postReleaseDelay: TimeInterval = 75

    private init() {
        // calendarEnabled 开关翻转时启停。objectWillChange 对所有设置都发，
        // 用 isRunning 对比避免每次调阈值都重启网络层。
        defaults.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.defaults.calendarEnabled != self.isRunning {
                    self.defaults.calendarEnabled ? self.start() : self.stop()
                }
            }
            .store(in: &cancellables)
    }

    private var isRunning: Bool { periodicTimer != nil }

    // MARK: - 生命周期

    func start() {
        guard defaults.calendarEnabled, !isRunning else { return }

        if feed == nil, let cached = Self.loadCache() {
            feed = cached
            logger.info("经济日历：磁盘缓存命中，\(cached.events.count) 条，\(cached.fetchedAt, privacy: .public) 抓取")
        }
        if titleTranslations.isEmpty {
            titleTranslations = Self.loadTitleCache()
        }

        let timer = Timer(timeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer

        refresh()
    }

    func stop() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        releaseTimer?.invalidate()
        releaseTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        translateTask?.cancel()
        translateTask = nil
    }

    /// 面板展开时调：数据够新就什么都不做，别让每次展开都打一枪网络。
    func panelWillShow() {
        guard defaults.calendarEnabled else { return }
        guard let feed else { return refresh() }
        if Date().timeIntervalSince(feed.fetchedAt) > Self.staleThreshold {
            refresh()
        }
    }

    // MARK: - 刷新

    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true

        // Task {} 继承 @MainActor，闭包体内直接改状态是安全的
        refreshTask = Task {
            do {
                let events = try await Self.fetch()
                if !Task.isCancelled { apply(events: events) }
            } catch {
                if !Task.isCancelled { applyFailure(error) }
            }
            refreshTask = nil
            isRefreshing = false
        }
    }

    private func apply(events: [EconomicEvent]) {
        let next = Feed(events: events, fetchedAt: Date())
        feed = next
        lastError = nil
        Self.saveCache(next)
        scheduleReleaseRefresh(events: events)
        kickTranslation()
        logger.info("经济日历：刷新成功，\(events.count) 条")
    }

    // MARK: - 指标名中文化

    /// 把 feed 里还没有中文名的指标标题分批送翻。与快讯共用开关与
    /// key；缓存按标题字符串持久化，指标名每周重复，首轮之后基本
    /// 不再花钱。
    private func kickTranslation() {
        guard defaults.newsTranslationEnabled,
              let apiKey = SecretVault.deepSeekAPIKey,
              translateTask == nil,
              let feed else { return }

        var seen = Set<String>()
        let pending = feed.events.map(\.title).filter {
            !$0.isEmpty && titleTranslations[$0] == nil && !failedTitles.contains($0)
                && seen.insert($0).inserted
        }
        guard !pending.isEmpty else { return }

        let batch = Array(pending.prefix(20))
        translateTask = Task {
            do {
                // id 用批内索引 —— 指标名没有稳定数字 id，标题本身才是主键
                let byId = try await DeepSeekClient.translate(
                    items: batch.enumerated().map { ($0.offset, $0.element) },
                    systemPrompt: Self.indicatorPrompt,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }

                for (index, title) in batch.enumerated() {
                    if let zh = byId[index] {
                        titleTranslations[title] = zh
                    } else {
                        failedTitles.insert(title)
                    }
                }
                Self.saveTitleCache(titleTranslations)
                logger.info("日历译名：+\(byId.count)/\(batch.count)，累计 \(self.titleTranslations.count)")
            } catch {
                guard !Task.isCancelled else { return }
                for title in batch { failedTitles.insert(title) }
                logger.error("日历译名失败：\(String(describing: error), privacy: .public)")
            }
            translateTask = nil
            kickTranslation()
        }
    }

    /// 指标名不是新闻 —— 要的不是重写，是**行业标准译名**（金十/华尔街见闻
    /// 的叫法），术语必须稳定到每周同一个指标译出同一个词。
    private static let indicatorPrompt = [
        "You translate US economic calendar indicator names into the standard Chinese terms used by Chinese financial media (金十数据 / 华尔街见闻 style).",
        "Rules:",
        "- Use the established translation, not a literal one: Initial Jobless Claims → 初请失业金人数; Continuing Jobless Claims → 续请失业金人数; Non-Farm Payrolls → 非农就业人数; Fed Interest Rate Decision → 美联储利率决议; Durable Goods Orders → 耐用品订单.",
        "- Keep abbreviations Chinese media keep: CPI, PPI, PCE, GDP, PMI, FOMC, EIA, API, MBA.",
        "- Period suffixes: MoM → 环比; YoY → 同比; QoQ → 环比; Flash/Prel → 初值; Final → 终值; Adv → 初值.",
        "- Auctions: 4-Week Bill Auction → 4周期国库券拍卖; 10-Year Note Auction → 10年期国债拍卖; TIPS → 通胀保值债券.",
        "- Speeches: Fed Chair Powell Speech → 美联储主席鲍威尔讲话; use established Chinese names for people.",
        "- Concise: no explanations, no parentheses unless the English has them.",
        "Return exactly one translation for every input id, in the same id set.",
        "Return only a JSON object: {\"translations\":[{\"id\":number,\"title\":string}]}",
    ].joined(separator: "\n")

    private func applyFailure(_ error: Error) {
        lastError = String(describing: error)
        logger.error("经济日历刷新失败：\(String(describing: error), privacy: .public)")
        // 失败也要排下一次补拉 —— 时刻表还在（旧 feed），发布节点照旧到来
        if let feed {
            scheduleReleaseRefresh(events: feed.events)
        }
    }

    /// 把一次性补拉挂在「下一个尚未到时的事件」发布后 75 秒。
    /// 触发时该事件已成过去，下一轮 apply 会自然滚动到再下一个 —— 无需状态机。
    private func scheduleReleaseRefresh(events: [EconomicEvent]) {
        releaseTimer?.invalidate()
        releaseTimer = nil

        let now = Date()
        guard let next = events.filter({ $0.date > now }).min(by: { $0.date < $1.date }) else {
            return
        }

        let fireAt = next.date.addingTimeInterval(Self.postReleaseDelay)
        let timer = Timer(timeInterval: fireAt.timeIntervalSince(now), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    // MARK: - 网络

    /// 窗口：昨天起（今天 ET 全天含隔夜已发布）到 8 天后（休市的周末
    /// 看下周整周）。importance 全拉，筛选在客户端做 —— 换档不必重新联网。
    private static func fetch() async throws -> [EconomicEvent] {
        let now = Date()
        let from = now.addingTimeInterval(-24 * 3600)
        let to = now.addingTimeInterval(8 * 24 * 3600)

        let iso = ISO8601DateFormatter()
        var components = URLComponents(string: upstream)!
        components.queryItems = [
            URLQueryItem(name: "from", value: iso.string(from: from)),
            URLQueryItem(name: "to", value: iso.string(from: to)),
            URLQueryItem(name: "countries", value: "US"),
            URLQueryItem(name: "minImportance", value: "-1"),
        ]

        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        // 上游拒绝 Referer/Origin 不指向 tradingview.com 的请求
        request.setValue("https://www.tradingview.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.tradingview.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "calendar upstream returned \(http.statusCode)"
            ])
        }
        return try EconomicCalendarFeed.decode(data)
    }

    // MARK: - 磁盘缓存

    /// 启动即有内容可显（面板永远不该先给一个 spinner），断网期间也能
    /// 看时刻表。数值可能缺 actual —— 面板按 fetchedAt 如实标注新旧。
    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = dir.appendingPathComponent("JuneMew", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("economic-calendar.json")
    }

    private static let cacheLogger = Logger(
        subsystem: "io.github.1of1adam.JuneMew", category: "calendar-cache"
    )

    private static func loadCache() -> Feed? {
        guard let url = cacheURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Feed.self, from: Data(contentsOf: url))
        } catch {
            // 缓存坏了不致命（下一轮网络刷新会重建），但必须留痕
            cacheLogger.error("经济日历缓存读取失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func saveCache(_ feed: Feed) {
        guard let url = cacheURL else { return }
        do {
            try JSONEncoder().encode(feed).write(to: url, options: .atomic)
        } catch {
            cacheLogger.error("经济日历缓存写入失败：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 译名缓存

    private static var titleCacheURL: URL? {
        cacheURL?.deletingLastPathComponent()
            .appendingPathComponent("calendar-titles.json")
    }

    private static func loadTitleCache() -> [String: String] {
        guard let url = titleCacheURL,
              FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        } catch {
            cacheLogger.error("日历译名缓存读取失败：\(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private static func saveTitleCache(_ translations: [String: String]) {
        guard let url = titleCacheURL else { return }
        do {
            try JSONEncoder().encode(translations).write(to: url, options: .atomic)
        } catch {
            cacheLogger.error("日历译名缓存写入失败：\(String(describing: error), privacy: .public)")
        }
    }
}
