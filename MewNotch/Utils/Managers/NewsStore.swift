//
//  NewsStore.swift
//  MewNotch
//

import Foundation
import Combine
import OSLog
import KLineCore

/// FinancialJuice 快讯流 + DeepSeek 中文化。
///
/// 抓取链路（与 hangzhou 的 news domain 同源）：
/// 1. headlines 页面里挖 info token（20 分钟缓存）
/// 2. `GetPreviousNews` 拉最新一页（ASMX XML 包 JSON）
/// 3. 60 秒轮询 —— 刘海场景不需要亚秒级实时，轮询比 WebSocket
///    少一整套连接生命周期管理
///
/// 翻译链路：新标题 → DeepSeek（批量、json_object、temperature 0）→
/// 缓存 by NewsID。key 缺失（SecretVault 为 nil）时整条链路不存在，
/// 显示英文原文 —— 功能分层，不因少个 key 而残废。
@MainActor
final class NewsStore: ObservableObject {

    static let shared = NewsStore()

    struct DisplayItem: Equatable, Identifiable {
        let id: Int
        /// 中文标题（已翻）或英文原文。
        let title: String
        let originalTitle: String
        let isTranslated: Bool
        let published: Date
        let breaking: Bool
        let critical: Bool
        let important: Bool
        let url: String
    }

    @Published private(set) var items: [DisplayItem] = []
    @Published private(set) var lastError: String?

    /// 本构建是否具备翻译能力（key 是否注入）。设置页用来解释状态。
    nonisolated static var translationAvailable: Bool { SecretVault.deepSeekAPIKey != nil }

    private let logger = Logger(subsystem: "io.github.1of1adam.JuneMew", category: "news")
    private let defaults = CountdownDefaults.shared

    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// WebSocket 实时通道。在线时新闻秒级到达，轮询降频为校对；
    /// 断线期间轮询以 60s 全速兜底。
    private let realtime = NewsRealtimeClient()
    private var realtimeConnected = false
    private var lastFetchAt: Date?

    /// 原始新闻（英文，最新在前）。
    private var rawItems: [FJNewsItem] = []
    /// NewsID → 中文标题。持久化，防重复烧 token。
    private var translations: [Int: String] = [:]
    /// 已请求过但翻译失败/被跳过的 id，本次会话内不再重试（下次启动重试）。
    private var failedTranslationIds: Set<Int> = []

    private var cachedInfoToken: (value: String, expiresAt: Date)?

    private static let pollInterval: TimeInterval = 60
    private static let tokenTTL: TimeInterval = 20 * 60
    private static let keepCount = 60
    /// 全部保留条目都翻 —— 新闻区可以滚到底，滚到哪儿都不该突然变英文。
    /// 60 条一次性也就几千 token，翻过的有缓存不重复。
    private static let translateWindow = keepCount
    private static let deepSeekBatchSize = 20
    private static let headlinesURL = "https://feed.financialjuice.com/widgets/headlines.aspx?wtype=NEWS&mode=Light"
    private static let historyURL = "https://live.financialjuice.com/FJService.asmx/GetPreviousNews"

    private init() {
        defaults.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.defaults.newsEnabled != self.isRunning {
                    self.defaults.newsEnabled ? self.start() : self.stop()
                }
            }
            .store(in: &cancellables)
    }

    private var isRunning: Bool { pollTimer != nil }

    // MARK: - 生命周期

    func start() {
        guard defaults.newsEnabled, !isRunning else { return }

        if rawItems.isEmpty, let cached = Self.loadCache() {
            rawItems = cached.items
            translations = cached.translations
            publish()
            logger.info("快讯：磁盘缓存命中，\(cached.items.count) 条 / \(cached.translations.count) 译")
        }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        realtime.onItems = { [weak self] items in
            self?.apply(fetched: items)
        }
        realtime.onStateChange = { [weak self] connected in
            self?.realtimeConnected = connected
        }
        realtime.start()

        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        translateTask?.cancel()
        translateTask = nil
        realtime.stop()
        realtimeConnected = false
    }

    /// 实时通道在线时轮询降频为 5 分钟一次的校对（防推送漏条）；
    /// 断线时保持 60 秒全速兜底。
    private func pollTick() {
        if realtimeConnected,
           let lastFetchAt,
           Date().timeIntervalSince(lastFetchAt) < 5 * 60 {
            return
        }
        refresh()
    }

    // MARK: - 抓取

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            do {
                let fetched = try await fetchLatest()
                if !Task.isCancelled {
                    lastFetchAt = Date()
                    apply(fetched: fetched)
                }
            } catch {
                if !Task.isCancelled {
                    lastError = String(describing: error)
                    logger.error("快讯抓取失败：\(String(describing: error), privacy: .public)")
                }
            }
            refreshTask = nil
        }
    }

    private func apply(fetched: [FJNewsItem]) {
        lastError = nil

        // 合并：新抓的一页在前，接上已知的旧条目，按 id 去重、时间排序
        var seen = Set<Int>()
        var merged: [FJNewsItem] = []
        for item in fetched + rawItems where seen.insert(item.id).inserted {
            merged.append(item)
        }
        merged.sort { ($0.published, $0.id) > ($1.published, $1.id) }
        rawItems = Array(merged.prefix(Self.keepCount))

        publish()
        Self.saveCache(items: rawItems, translations: translations)
        kickTranslation()
    }

    private func publish() {
        items = rawItems.map { raw in
            let translated = translations[raw.id]
            return DisplayItem(
                id: raw.id,
                title: translated ?? raw.title,
                originalTitle: raw.title,
                isTranslated: translated != nil,
                published: raw.published,
                breaking: raw.breaking,
                critical: raw.critical,
                important: raw.important,
                url: raw.url
            )
        }
    }

    // MARK: - FinancialJuice 网络

    private func fetchLatest() async throws -> [FJNewsItem] {
        let token = try await infoToken()

        var components = URLComponents(string: Self.historyURL)!
        // 必须手动 percent-encode：URLComponents 按 RFC 3986 不编码 query
        // 里的 "+"，而上游（ASP.NET）把 "+" 解成空格 —— token 是 base64
        // 形态含 "+"，一旦被解坏，上游静默返回空数组。只放行字母数字，
        // 引号（info 参数要求 JSON 字符串字面量）与 +/= 全部转义。
        let encodedToken = "\"\(token)\"".addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? ""
        components.percentEncodedQuery = [
            "info=\(encodedToken)",
            "TimeOffset=0",
            "tabID=0",
            "oldID=0",
            "TickerID=0",
            "FeedCompanyID=0",
            "strSearch=%22%22",
            "extraNID=0",
        ].joined(separator: "&")

        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("https://feed.financialjuice.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // token 失效的典型表现：非 200。作废缓存，下一轮重新挖
            cachedInfoToken = nil
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "news upstream returned \(http.statusCode)"
            ])
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let items = try FinancialJuiceFeed.parseHistoryResponse(body)
        // 宏观快讯流 24/7 不断更 —— 解析成功却一条都没有，几乎必然是
        // token 被上游拒了（历史上就是 "+" 编码坏掉的形态）。作废 token
        // 并显式报错，下一轮重挖重试，而不是让面板永远 "Loading…"。
        guard !items.isEmpty else {
            cachedInfoToken = nil
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "news upstream returned an empty page (token rejected?)"
            ])
        }
        return items
    }

    private func infoToken() async throws -> String {
        if let cached = cachedInfoToken, cached.expiresAt > Date() {
            return cached.value
        }

        var request = URLRequest(url: URL(string: Self.headlinesURL)!, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8),
              let match = html.range(of: #"var\s+info\s*=\s*'([^']+)'"#, options: .regularExpression) else {
            throw URLError(.cannotParseResponse, userInfo: [
                NSLocalizedDescriptionKey: "info token not found in headlines page"
            ])
        }
        let fragment = String(html[match])
        guard let start = fragment.firstIndex(of: "'"),
              let end = fragment.lastIndex(of: "'"),
              start < end else {
            throw URLError(.cannotParseResponse)
        }
        let token = String(fragment[fragment.index(after: start)..<end])
        cachedInfoToken = (token, Date().addingTimeInterval(Self.tokenTTL))
        return token
    }

    // MARK: - 翻译

    private func kickTranslation() {
        guard defaults.newsTranslationEnabled,
              let apiKey = SecretVault.deepSeekAPIKey,
              translateTask == nil else { return }

        let pending = rawItems.prefix(Self.translateWindow).filter {
            translations[$0.id] == nil && !failedTranslationIds.contains($0.id)
        }
        guard !pending.isEmpty else { return }

        let batch = Array(pending.prefix(Self.deepSeekBatchSize))
        translateTask = Task {
            do {
                let byId = try await DeepSeekClient.translate(
                    items: batch.map { ($0.id, FinancialJuiceFeed.sanitizeForTranslation($0.title)) },
                    systemPrompt: Self.systemPrompt,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }

                for item in batch {
                    if let title = byId[item.id] {
                        translations[item.id] = title
                    } else {
                        // 批内个别缺失：本次会话不再追打，避免对同一条空转
                        failedTranslationIds.insert(item.id)
                    }
                }
                publish()
                Self.saveCache(items: rawItems, translations: translations)
                logger.info("快讯翻译：+\(byId.count)/\(batch.count)")
            } catch {
                guard !Task.isCancelled else { return }
                // 整批失败多半是网络/额度：这批标记跳过，60s 后新条目照常尝试
                for item in batch { failedTranslationIds.insert(item.id) }
                logger.error("快讯翻译失败：\(String(describing: error), privacy: .public)")
            }
            // 置空后再补一脚：窗口里还有没翻的（首启一次拉几十条）就接着
            // 下一批；没有则 no-op。不能在置空前递归 —— 新任务会被这里的
            // 收尾误清掉。
            translateTask = nil
            kickTranslation()
        }
    }

    /// 与 hangzhou 的 news-title-zh-v3 对齐的新闻标题重写 prompt。
    private static let systemPrompt = [
        "You are a senior Chinese financial news editor at a trading desk.",
        "Given English headlines, rewrite each as a native Chinese headline — as if you saw the event firsthand and wrote it for a Chinese trading terminal.",
        "Do NOT translate word-by-word. Reconstruct the meaning in natural Chinese financial news style: concise, professional, reads like it was originally written in Chinese.",
        "Rules:",
        "- Keep numbers, tickers ($AAPL), currencies, percentages exact.",
        "- People and institutions: use their established Chinese names when widely known (e.g. 鲍威尔, 马斯克, 美联储, 高盛), otherwise keep English.",
        "- Source attribution after a colon (e.g. \"…: Reuters\" or \"…: Reporter on X\") → move to the beginning: \"据 Source：…\"",
        "- Insert a space between adjacent Chinese and English/number characters.",
        "- \"Taiwan regional leader\" or \"leader of Taiwan region\" → always render as \"台湾地区领导人\".",
        "- No opinions, no summaries, no added context. Same facts, Chinese voice.",
        "Return exactly one rewrite for every input id, in the same id set.",
        "Return only a JSON object: {\"translations\":[{\"id\":number,\"title\":string}]}",
    ].joined(separator: "\n")

    // MARK: - 磁盘缓存

    private struct CacheFile: Codable {
        let items: [FJNewsItem]
        let translations: [Int: String]
    }

    private static let cacheLogger = Logger(
        subsystem: "io.github.1of1adam.JuneMew", category: "news-cache"
    )

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = dir.appendingPathComponent("JuneMew", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("news.json")
    }

    private static func loadCache() -> CacheFile? {
        guard let url = cacheURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(CacheFile.self, from: Data(contentsOf: url))
        } catch {
            cacheLogger.error("快讯缓存读取失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func saveCache(items: [FJNewsItem], translations: [Int: String]) {
        guard let url = cacheURL else { return }
        // 只留还在列表里的翻译，缓存不无限膨胀
        let liveIds = Set(items.map(\.id))
        let pruned = translations.filter { liveIds.contains($0.key) }
        do {
            try JSONEncoder().encode(CacheFile(items: items, translations: pruned))
                .write(to: url, options: .atomic)
        } catch {
            cacheLogger.error("快讯缓存写入失败：\(String(describing: error), privacy: .public)")
        }
    }
}
