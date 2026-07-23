//
//  EconomicCalendar.swift
//  KLineCore
//

import Foundation

/// 经济事件的重要度。上游用 -1 / 0 / 1 编码。
public enum EconomicImportance: Int, Codable, Comparable, Sendable {
    case low = -1
    case medium = 0
    case high = 1

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 单条经济日历事件（数据源：TradingView economic-calendar feed）。
///
/// 数值三元组（previous / forecast / actual）在解码时取**裸字段优先**：
/// 实测上游把「与 scale 配套的已缩放显示值」放裸字段（`previous: 1.41,
/// scale: "M"` = 1.41M），把未缩放标量放 `*Raw`（1410000）。显示必须用
/// 裸值 + scale 后缀；用 Raw 再贴 scale 会双重放大（"1,410,000 M"）。
/// Raw 只作裸字段缺失时的兜底。
public struct EconomicEvent: Equatable, Identifiable, Sendable, Codable {
    public let id: String
    public let title: String
    public let indicator: String
    public let country: String
    public let currency: String
    public let date: Date
    public let importance: EconomicImportance
    /// 报告期（"Jul/17"、"Q2" 等），上游可能缺省。
    public let period: String
    public let previous: Double?
    public let forecast: Double?
    public let actual: Double?
    /// 标量后缀（"%"、"K"、"bps"；指数点为空）。
    public let unit: String?
    /// 上游缩放标签（"M"、"B"），组合成 "1.2 B" 显示。
    public let scale: String?
    /// 指标说明，展开面板的 tooltip 用。
    public let comment: String?

    public init(
        id: String,
        title: String,
        indicator: String,
        country: String,
        currency: String,
        date: Date,
        importance: EconomicImportance,
        period: String,
        previous: Double?,
        forecast: Double?,
        actual: Double?,
        unit: String?,
        scale: String?,
        comment: String?
    ) {
        self.id = id
        self.title = title
        self.indicator = indicator
        self.country = country
        self.currency = currency
        self.date = date
        self.importance = importance
        self.period = period
        self.previous = previous
        self.forecast = forecast
        self.actual = actual
        self.unit = unit
        self.scale = scale
        self.comment = comment
    }

    /// 该事件是否根本没有数值可言（讲话、会议纪要等）。
    /// 这类事件发布后不该显示「等待数据中」—— 它永远不会有数据。
    public var hasNumericContent: Bool {
        previous != nil || forecast != nil || actual != nil
    }
}

/// actual 对 forecast 的偏离。发布前（任一侧缺失）为 nil —— 未发布不是惊喜。
public struct EconomicSurprise: Equatable, Sendable {
    public enum Sign: Sendable {
        case up, down, flat
    }

    public let delta: Double
    public let sign: Sign
    /// 偏离超过 forecast 的 10% 记为 large；forecast 为 0 时退化用绝对差。
    public let isLarge: Bool

    public static func compute(actual: Double?, forecast: Double?) -> EconomicSurprise? {
        guard let actual, let forecast else { return nil }
        let delta = actual - forecast
        if delta == 0 {
            return EconomicSurprise(delta: 0, sign: .flat, isLarge: false)
        }
        let ratio = forecast == 0 ? abs(delta) : abs(delta / forecast)
        return EconomicSurprise(
            delta: delta,
            sign: delta > 0 ? .up : .down,
            isLarge: ratio > 0.1
        )
    }
}

/// 按交易日历时区（ET）切出的一天。
public struct EconomicDayGroup: Equatable, Sendable {
    /// 该天在 ET 的 00:00 时刻。
    public let dayStart: Date
    /// 已按时间升序。
    public let events: [EconomicEvent]
}

/// 经济日历的解码与纯函数工具。网络、缓存、刷新调度都在 app 层 ——
/// 这里保持 KLineCore 的纯度：不碰网络，不读系统时钟。
public enum EconomicCalendarFeed {

    public enum DecodeError: Error, Equatable {
        /// 上游 envelope 的 status 不是 "ok"。
        case upstreamStatus(String)
        /// 事件缺关键字段或字段类型不对。宁可整包失败也不显示残缺数据。
        case malformedEvent(index: Int, reason: String)
        case notJSON
    }

    // MARK: - 解码

    /// 解析 `{status, result}` envelope。任何一条事件非法都让整包失败：
    /// 一个显示错误时刻的日历比没有日历更危险，与倒计时拒绝显示的哲学一致。
    public static func decode(_ data: Data) throws -> [EconomicEvent] {
        let envelope: RawEnvelope
        do {
            envelope = try JSONDecoder().decode(RawEnvelope.self, from: data)
        } catch {
            throw DecodeError.notJSON
        }

        guard envelope.status == "ok" else {
            throw DecodeError.upstreamStatus(envelope.status)
        }

        return try (envelope.result ?? []).enumerated().map { index, raw in
            try normalize(raw, index: index)
        }
    }

    private static func normalize(_ raw: RawEvent, index: Int) throws -> EconomicEvent {
        guard !raw.id.isEmpty else {
            throw DecodeError.malformedEvent(index: index, reason: "empty id")
        }
        guard !raw.title.isEmpty else {
            throw DecodeError.malformedEvent(index: index, reason: "empty title")
        }
        guard let date = parseDate(raw.date) else {
            throw DecodeError.malformedEvent(index: index, reason: "unparsable date \(raw.date)")
        }
        guard let importance = EconomicImportance(rawValue: raw.importance) else {
            throw DecodeError.malformedEvent(index: index, reason: "unknown importance \(raw.importance)")
        }

        return EconomicEvent(
            id: raw.id,
            title: raw.title,
            indicator: raw.indicator ?? raw.title,
            country: raw.country ?? "",
            currency: raw.currency ?? "",
            date: date,
            importance: importance,
            period: raw.period ?? "",
            previous: raw.previous ?? raw.previousRaw,
            forecast: raw.forecast ?? raw.forecastRaw,
            actual: raw.actual ?? raw.actualRaw,
            unit: raw.unit,
            scale: raw.scale,
            comment: raw.comment
        )
    }

    /// 上游日期两种形态并存："2026-07-22T11:00:00.000Z" 与不带毫秒的变体。
    public static func parseDate(_ string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) { return date }
        return plainFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - 分组

    /// 按 ET 日界分组，组内按时间升序，组间按日期升序。
    /// ET 而不是本地时区：整个 app 的「今天」都锚在交易日历的时区上，
    /// 一个亚洲用户的凌晨两点属于 ET 的「今天下午」。
    public static func groupByETDay(_ events: [EconomicEvent]) -> [EconomicDayGroup] {
        var calendar = Calendar(identifier: .gregorian)
        guard let et = TimeZone(identifier: "America/New_York") else {
            preconditionFailure("America/New_York must exist")
        }
        calendar.timeZone = et

        var buckets: [Date: [EconomicEvent]] = [:]
        for event in events {
            let dayStart = calendar.startOfDay(for: event.date)
            buckets[dayStart, default: []].append(event)
        }

        return buckets
            .map { dayStart, events in
                EconomicDayGroup(
                    dayStart: dayStart,
                    // 同一时刻（08:30 常有三四条同时发布）按重要度降序，
                    // CPI 永远压过同分钟的次要数据。
                    events: events.sorted {
                        ($0.date, -$0.importance.rawValue, $0.id) < ($1.date, -$1.importance.rawValue, $1.id)
                    }
                )
            }
            .sorted { $0.dayStart < $1.dayStart }
    }

    // MARK: - 数值格式化

    /// 精度阶梯：|v| ≥ 100 免小数（313）、10–100 留一位（3.4）、<10 留两位（0.25）。
    /// unit 为 "%" 直接贴；scale（"M"/"B"）与 unit 组成尾巴："264 B"、"1.2 M USD"。
    /// 空值渲染为 en dash（–）。
    ///
    /// 上游对「个数」类指标（Jobless Claims 208000、New Home Sales 580000）
    /// 既不给 unit 也不给 scale —— 裸渲染成 "208,000" 会撑爆任何窄列。
    /// 无单位且 |v| ≥ 10 000 时自动缩写成 "208K" / "1.2M" / "3.4B"
    /// （贴写不带空格，与显式 unit 的 "226 K" 区分来源）。
    public static func formatValue(
        _ value: Double?,
        unit: String?,
        scale: String?
    ) -> String {
        guard let value, !value.isNaN else { return "–" }

        let trimmedScale = (scale == "units" ? "" : scale ?? "").trimmingCharacters(in: .whitespaces)
        let trimmedUnit = (unit ?? "").trimmingCharacters(in: .whitespaces)

        var displayValue = value
        var compactSuffix = ""
        if trimmedUnit.isEmpty, trimmedScale.isEmpty, abs(value) >= 10_000 {
            switch abs(value) {
            case 1e9...: displayValue = value / 1e9; compactSuffix = "B"
            case 1e6...: displayValue = value / 1e6; compactSuffix = "M"
            default: displayValue = value / 1e3; compactSuffix = "K"
            }
        }

        let magnitude = abs(displayValue)
        let digits = magnitude >= 100 ? 0 : magnitude >= 10 ? 1 : 2
        let number = formatter(maxFractionDigits: digits)
            .string(from: NSNumber(value: displayValue)) ?? String(displayValue)

        if !compactSuffix.isEmpty { return number + compactSuffix }
        if unit == "%" { return "\(number)%" }

        // scale 是数量级后缀，紧贴数字（"1.41M"）；unit 是计量单位，
        // 空格隔开（"226 K"、"1.41M USD"）。
        var result = number
        if !trimmedScale.isEmpty { result += trimmedScale }
        if !trimmedUnit.isEmpty { result += " \(trimmedUnit)" }
        return result
    }

    private static let formatterCache: [NumberFormatter] = (0...2).map { digits in
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        return f
    }

    private static func formatter(maxFractionDigits: Int) -> NumberFormatter {
        formatterCache[maxFractionDigits]
    }

    // MARK: - 倒计时文案

    /// 紧凑的「还有多久」标签，放进面板 50pt 宽的数值列：
    /// "即将" / "5m" / "1h05" / "14h" / "2d"。
    /// 单位沿用 K 线周期的既有语言（1m/5m/1H）—— 中文界面里生造
    /// 「1时17」反而别扭，交易终端的 m/h/d 就是通用语。
    /// 已过期（target ≤ now）显示 "即将" —— 调用方应在拿到 actual 后停用。
    public static func formatCountdown(to target: Date, now: Date) -> String {
        let minutes = Int((target.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "即将" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 10 {
            let rest = minutes % 60
            return rest == 0
                ? "\(hours)h"
                : "\(hours)h" + String(format: "%02d", rest)
        }
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    // MARK: - Raw schema

    /// 上游 JSON 的原样映射。字段可空性以实测响应为准：
    /// id/title/importance/date 必有，其余在部分事件上缺省。
    private struct RawEnvelope: Decodable {
        let status: String
        let result: [RawEvent]?
    }

    private struct RawEvent: Decodable {
        let id: String
        let title: String
        let indicator: String?
        let country: String?
        let currency: String?
        let date: String
        let importance: Int
        let period: String?
        let previous: Double?
        let forecast: Double?
        let actual: Double?
        let previousRaw: Double?
        let forecastRaw: Double?
        let actualRaw: Double?
        let unit: String?
        let scale: String?
        let comment: String?
    }
}
