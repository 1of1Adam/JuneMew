//
//  HolidayTable.swift
//  KLineCore
//

import Foundation

/// 假期对交易时段的影响。
public enum HolidayRule: Equatable, Sendable {
    /// 该结算日的整个时段消失（含前一晚 18:00 的开盘）。
    case fullClosure
    /// 提前收盘到指定 ET 时刻。
    case earlyClose(TimeOfDayET)
    /// 延后开盘到指定 ET 时刻（前一晚）。
    case lateOpen(TimeOfDayET)
}

public struct HolidayEntry: Equatable, Sendable {
    public let date: YearMonthDay
    public let name: String
    public let rule: HolidayRule
}

/// 假期表的人工核验状态。
public enum VerificationStatus: String, Codable, Sendable {
    /// 已逐条对照交易所官方日历核对。
    case verified
    /// 未经官方核对的初稿 —— 日期可能对，但「全天休市 vs 提前收盘」及具体时刻未必对。
    case unverifiedDraft = "unverified_draft"
}

/// 交易所假期表。
///
/// **设计要点：`verifiedThrough` 与「表里有没有这一天的条目」是正交的。**
/// 「没有条目」必须能区分两种含义 —— 「已核验为普通交易日」和「根本没查过」。
/// 前者可以安全地按普通交易日处理，后者必须报错。把二者混同是这类工具最典型的
/// 静默错误来源：假期表过期后，用户会在休市日看到一个照常跳动的倒计时。
public struct HolidayTable: Sendable {

    public let exchange: String
    public let status: VerificationStatus
    public let source: String
    public let verifiedFrom: YearMonthDay
    public let verifiedThrough: YearMonthDay
    public let entries: [YearMonthDay: HolidayEntry]

    public func rule(for day: YearMonthDay) -> HolidayRule? {
        entries[day]?.rule
    }

    public func entry(for day: YearMonthDay) -> HolidayEntry? {
        entries[day]
    }

    public func covers(_ day: YearMonthDay) -> Bool {
        day >= verifiedFrom && day <= verifiedThrough
    }

    // MARK: - 解码

    /// 磁盘上的 JSON 形态。刻意与运行时类型分开，让解码错误停留在边界。
    private struct Wire: Decodable {
        struct Entry: Decodable {
            struct Rule: Decodable {
                let type: String
                let at: String?
            }
            let date: String
            let name: String
            let rule: Rule
        }
        let exchange: String
        let verificationStatus: VerificationStatus
        let source: String
        let verifiedFrom: String
        let verifiedThrough: String
        let entries: [Entry]
    }

    public init(jsonData: Data) throws {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: jsonData)
        } catch {
            // 有意不 fallback 到空表：一张空表会让每一天都被当成普通交易日，
            // 这正是最危险的失败模式。
            throw KLineCoreError.holidayTableUnreadable(String(describing: error))
        }

        let from = try YearMonthDay(iso: wire.verifiedFrom)
        let through = try YearMonthDay(iso: wire.verifiedThrough)
        guard from <= through else {
            throw KLineCoreError.holidayTableUnreadable(
                "verifiedFrom \(from) is after verifiedThrough \(through)"
            )
        }

        var parsed: [YearMonthDay: HolidayEntry] = [:]
        for e in wire.entries {
            let day = try YearMonthDay(iso: e.date)

            guard day >= from, day <= through else {
                throw KLineCoreError.holidayTableUnreadable(
                    "entry \(day) (\(e.name)) lies outside declared coverage \(from)...\(through)"
                )
            }
            guard parsed[day] == nil else {
                throw KLineCoreError.holidayTableUnreadable("duplicate entry for \(day)")
            }

            let rule: HolidayRule
            switch e.rule.type {
            case "fullClosure":
                rule = .fullClosure
            case "earlyClose":
                guard let at = e.rule.at else {
                    throw KLineCoreError.holidayTableUnreadable("earlyClose for \(day) is missing \"at\"")
                }
                rule = .earlyClose(try TimeOfDayET(hhmm: at))
            case "lateOpen":
                guard let at = e.rule.at else {
                    throw KLineCoreError.holidayTableUnreadable("lateOpen for \(day) is missing \"at\"")
                }
                rule = .lateOpen(try TimeOfDayET(hhmm: at))
            default:
                throw KLineCoreError.holidayTableUnreadable(
                    "unknown rule type \"\(e.rule.type)\" for \(day)"
                )
            }

            parsed[day] = HolidayEntry(date: day, name: e.name, rule: rule)
        }

        self.exchange = wire.exchange
        self.status = wire.verificationStatus
        self.source = wire.source
        self.verifiedFrom = from
        self.verifiedThrough = through
        self.entries = parsed
    }

    /// 从 package 资源加载随包分发的表。
    public static func bundled() throws -> HolidayTable {
        guard let url = Bundle.module.url(forResource: "cme-equity-index-holidays", withExtension: "json") else {
            throw KLineCoreError.holidayTableUnreadable("cme-equity-index-holidays.json not found in bundle")
        }
        return try HolidayTable(jsonData: try Data(contentsOf: url))
    }
}
