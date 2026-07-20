//
//  ClockCalibrator.swift
//  MewNotch
//

import Foundation
import OSLog
import KLineCore

/// 用 HTTPS 响应头的 `Date` 字段校准系统时钟。
///
/// 为什么不读系统的「自动设置时间」开关：
/// 1. `/var/db/timed/` 需要特权，无权限时 `defaults read` **静默返回空字典而不报错** ——
///    正好是最坏的失败模式（会得到一个看起来合法的错误答案）。
/// 2. 它回答的是错的问题。「NTP 开关是否打开」≠「时钟是否准确」：
///    公司网络封 UDP 123、NTP 服务器不可达、刚从长期休眠恢复，
///    这些情况下开关是开的而时钟是错的。
///
/// 精度约 ±0.55 秒（`Date` 头只有秒级精度 + RTT 的一半），
/// 对 1 秒分辨率的显示足够。要更高精度得自己实现 SNTP。
actor ClockCalibrator {

    static let shared = ClockCalibrator()

    private let logger = Logger(subsystem: "com.monuk7735.mew.notch", category: "clock")

    /// 两个独立的高可用端点。互相矛盾时判 unverified 而不取平均。
    private let endpoints = [
        URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!,
        URL(string: "https://www.apple.com/library/test/success.html")!
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var sentinel = MonotonicSentinel()
    private var trust: ClockTrust
    private var isCalibrating = false

    private init() {
        self.trust = .unverified(since: Date(), lastError: "not calibrated yet")
    }

    func currentTrust() -> ClockTrust { trust }

    /// 每个 tick 调用，检查墙钟是否被阶跃调整过。
    ///
    /// 注意这个哨兵**只探测变化，不探测静态偏差** —— 一台从开机起就慢 45 秒
    /// 且从不同步的机器，两个时钟走速一致，这里永远不会报警。所以它是网络
    /// 校准的补充而非替代。
    func checkForJump() {
        let drift = sentinel.drift()
        guard abs(drift) > ClockPolicy.jumpThreshold else { return }

        logger.warning("检测到墙钟阶跃 \(drift, format: .fixed(precision: 3)) 秒，标记为不可信并重新校准")
        trust = .jumped(delta: drift, at: Date())
        sentinel.reanchor()

        Task { await calibrate() }
    }

    /// 睡眠唤醒后调用。睡眠期间墙钟与单调钟的差异不构成阶跃证据。
    func handleWake() {
        sentinel.reanchor()
        Task { await calibrate() }
    }

    /// 系统时钟被改动（NTP 纠正、用户手动改表）时调用。
    func handleSystemClockChange() {
        sentinel.reanchor()
        Task { await calibrate() }
    }

    func calibrate() async {
        guard !isCalibrating else { return }
        isCalibrating = true
        defer { isCalibrating = false }

        var samples: [HTTPDateProbe.Sample] = []
        var lastError: String?

        for endpoint in endpoints {
            do {
                // 每个端点探三次取 RTT 最小的，压掉网络抖动
                var best: HTTPDateProbe.Sample?
                for _ in 0..<3 {
                    let sample = try await probe(endpoint)
                    if best == nil || sample.roundTrip < best!.roundTrip { best = sample }
                }
                if let best { samples.append(best) }
            } catch {
                lastError = "\(endpoint.host() ?? endpoint.absoluteString): \(error)"
                logger.notice("时钟校准端点失败 \(lastError!, privacy: .public)")
            }
        }

        guard let reconciled = HTTPDateProbe.reconcile(samples) else {
            // 校准失败绝不静默降级成 trusted
            let reason = samples.count > 1
                ? "endpoints disagree by more than 1s"
                : (lastError ?? "no endpoint reachable")
            if case .unverified = trust {
                // 保留最初的失败时刻，让 staleness 能持续累积
            } else {
                trust = .unverified(since: Date(), lastError: reason)
            }
            logger.notice("时钟校准未完成：\(reason, privacy: .public)")
            return
        }

        sentinel.reanchor()
        trust = .verified(
            offset: reconciled.offset,
            uncertainty: reconciled.uncertainty,
            at: Date()
        )
        logger.info("时钟已校准：偏差 \(reconciled.offset, format: .fixed(precision: 3)) 秒 ± \(reconciled.uncertainty, format: .fixed(precision: 3))")
    }

    private func probe(_ url: URL) async throws -> HTTPDateProbe.Sample {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let before = Date()
        let monoBefore = ContinuousClock.now
        let (_, response) = try await session.data(for: request)
        let roundTrip = Double((ContinuousClock.now - monoBefore).components.seconds)
            + Double((ContinuousClock.now - monoBefore).components.attoseconds) * 1e-18

        guard let http = response as? HTTPURLResponse else {
            throw HTTPDateProbe.ProbeError.notHTTP
        }
        guard (200..<400).contains(http.statusCode) else {
            throw HTTPDateProbe.ProbeError.badStatus(http.statusCode)
        }
        guard let raw = http.value(forHTTPHeaderField: "Date") else {
            throw HTTPDateProbe.ProbeError.missingDateHeader
        }
        guard let serverDate = HTTPDateProbe.imfFormatter.date(from: raw) else {
            throw HTTPDateProbe.ProbeError.unparsableDate(raw)
        }

        return HTTPDateProbe.sample(
            requestSentAt: before,
            roundTrip: roundTrip,
            serverHeaderDate: serverDate
        )
    }
}
